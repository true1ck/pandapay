import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/providers.dart' as app;
import '../../../data/user_cards_repository.dart';
import '../providers/ai_status_provider.dart';
import '../providers/data_providers.dart';
import '../providers/runtime_provider.dart';
import '../storage/schema.dart';
import '../sync/ai_server_status.dart';
import '../sync/template_resend.dart';
import '../ledger/providers.dart';
import 'screen_parts.dart';

/// How far back the Auto-resolved and History lists reach, and how many rows
/// each shows. Both read the in-memory ledger model, never the whole history.
const settledWindow = Duration(days: 90);
const settledMaxRows = 200;

/// Who read a transaction without asking.
enum SettledSource {
  /// A signed shared rule.
  rule,

  /// The on-device reader that works from the wording of the message.
  onDevice,

  /// A rule Gemini drafted for this message format.
  ai,
}

/// Names the source from the ids of the rules that read the message. A rule
/// Gemini drafted has an id starting `AI-`; the on-device reader's start
/// `SOLVER-`. (Neither is stamped as a different engine, so the id is the only
/// trace.)
SettledSource settledSourceOf(Iterable<String> ruleIds) {
  final ids = ruleIds.toList();
  if (ids.any((id) => id.startsWith('AI-'))) return SettledSource.ai;
  if (ids.any((id) => id.startsWith('SOLVER-'))) return SettledSource.onDevice;
  return SettledSource.rule;
}

/// One transaction the app settled, and who settled it.
class SettledItem {
  const SettledItem({
    required this.entry,
    required this.byUser,
    required this.how,
    this.source = SettledSource.rule,
    this.confidence,
  });

  /// Which reader settled it (meaningful when [byUser] is false).
  final SettledSource source;

  final TransactionEntry entry;

  /// True when the person confirmed or edited it; false when the rules or the
  /// AI read it and no one was asked.
  final bool byUser;

  /// A plain-words line: "Read by a rule", "Read by an AI rule", "You edited".
  final String how;
  final double? confidence;
}

class SettledLists {
  const SettledLists({this.auto = const [], this.history = const []});

  /// Filed by a Gemini-drafted rule without asking, newest first.
  final List<SettledItem> auto;

  /// Settled or changed by the person, newest first.
  final List<SettledItem> history;
}

/// Splits the recent stored SMS transactions into those the engine settled by
/// itself and those the person settled or edited by hand.
SettledLists settledLists(
  Iterable<TransactionEntry> transactions,
  Map<String, List<Fact>> factsBySource, {
  required DateTime now,
}) {
  final cutoff = now.subtract(settledWindow);
  final auto = <SettledItem>[];
  final history = <SettledItem>[];
  for (final entry in transactions) {
    if (entry.pipelineVersion != 2) continue;
    final source = entry.sourceKey;
    if (source == null || entry.eventId == null) continue;
    if (entry.occurredAt.isBefore(cutoff)) continue;
    final facts = factsBySource[source] ?? const <Fact>[];
    if (facts.isEmpty) continue;
    final byUser = facts.any((f) => f.provenance.engine == Engine.user);
    final machine = facts.firstWhere(
      (f) => f.provenance.engine != Engine.user,
      orElse: () => facts.first,
    );
    final ruleIds = [
      for (final f in facts)
        if (f.provenance.engine != Engine.user) f.provenance.ruleId,
    ];
    final reader = settledSourceOf(ruleIds);
    // An AI rule that only exists on this phone has not been checked by
    // PandaPay yet (its id carries a ':local:' suffix).
    final unverified = ruleIds.any(
      (id) => id.startsWith('AI-') && id.contains(':local:'),
    );
    final item = SettledItem(
      entry: entry,
      byUser: byUser,
      source: reader,
      confidence: machine.confidence,
      how: byUser
          ? 'You confirmed or edited this'
          : switch (reader) {
              SettledSource.ai =>
                unverified
                    ? 'Read by a Gemini AI rule, not yet verified'
                    : 'Read by a Gemini AI rule, verified',
              SettledSource.onDevice => 'Read by the on-device reader',
              SettledSource.rule => 'Read by a rule',
            },
    );
    // Rules and the on-device reader sort quietly: they are not listed. Only
    // what the person changed (History) or what Gemini filed (AI auto-resolved).
    if (byUser) {
      history.add(item);
    } else if (reader == SettledSource.ai) {
      auto.add(item);
    }
  }
  int newest(SettledItem a, SettledItem b) =>
      b.entry.occurredAt.compareTo(a.entry.occurredAt);
  auto.sort(newest);
  history.sort(newest);
  return SettledLists(
    auto: auto.take(settledMaxRows).toList(growable: false),
    history: history.take(settledMaxRows).toList(growable: false),
  );
}

final settledListsProvider = FutureProvider<SettledLists>((ref) async {
  final model = await ref.watch(smsV2LedgerReadModelProvider.future);
  return settledLists(
    model.transactions,
    model.factsBySource,
    now: DateTime.now(),
  );
});

/// Puts a settled transaction back on the Needs review list as an open
/// question. The transaction itself is not changed; answering the question
/// (Looks right, Fix) goes through the same correction service as any other.
Future<void> reopenForReview(WidgetRef ref, TransactionEntry entry) async {
  final source = entry.sourceKey;
  final eventId = entry.eventId;
  if (source == null || eventId == null) {
    throw ArgumentError('This transaction has no message to review');
  }
  final namespace = ref.read(app.cacheNamespaceProvider);
  final cache = await ref.read(app.responseCacheProvider.future);
  final store = cache.financialStore;
  final db = store.database.db;
  SmsV2Schema.ensure(db);
  store.batch(() {
    db.execute(
      'INSERT INTO v2_review_items (namespace, review_id, kind, payload, status) '
      "VALUES (?, ?, 'event', ?, 'open') "
      "ON CONFLICT(namespace, review_id) DO UPDATE SET status='open', payload=excluded.payload",
      [
        namespace,
        'reopen:$eventId',
        jsonEncode({
          'sourceKey': source,
          'eventId': eventId,
          'reason': 'reopened',
          'hasReading': true,
        }),
      ],
    );
    store.notifyExternalChanges(namespace, const ['needs_review']);
  });
  ref.invalidate(reviewItemsProvider);
}

/// How many message formats the AI could not turn into a rule (failed, or its
/// draft was turned down by a reviewer). Read from the phone's own sync state.
final aiUnreadCountProvider = FutureProvider<int>((ref) async {
  // Re-read whenever the AI status itself changes.
  await ref.watch(aiReviewStatusProvider.future);
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  final row = db.select(
    "SELECT count(*) AS n FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%' "
    "AND json_extract(value, '\$.status') IN ('failed', 'rejected')",
    [namespace],
  );
  return (row.first['n'] as num).toInt();
});

/// The AI auto-resolved and History tabs share this list.
class SettledList extends ConsumerWidget {
  const SettledList({super.key, required this.history});

  /// True for the History tab, false for AI auto-resolved.
  final bool history;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(settledListsProvider);
    return lists.when(
      skipLoadingOnReload: true,
      loading: () => const SmsLoading(),
      error: (_, _) =>
          SmsError(onRetry: () => ref.invalidate(settledListsProvider)),
      data: (value) {
        final items = history ? value.history : value.auto;
        if (items.isEmpty) {
          return SmsEmpty(
            history
                ? 'Nothing settled by you yet. Messages you confirm or fix appear here, so you can change them again.'
                : 'Nothing filed by Gemini yet. Messages Gemini AI sorted without asking appear here, so you can correct a wrong guess.',
            icon: history ? Icons.history_rounded : Icons.auto_awesome_outlined,
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(settledListsProvider);
            await ref.read(settledListsProvider.future);
          },
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.sm,
              AppSpace.lg,
              AppSpace.xxl,
            ),
            itemCount: items.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpace.md),
            itemBuilder: (context, i) => i == 0
                ? BambooNote(
                    history
                        ? 'Things you confirmed or fixed, last 90 days. Open one to change it again.'
                        : 'Filed by Gemini AI without asking you, last 90 days. Open one if it is wrong.',
                    icon: Icons.info_outline_rounded,
                  )
                : SettledCard(item: items[i - 1]),
          ),
        );
      },
    );
  }
}

final _money = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
);

class SettledCard extends ConsumerWidget {
  const SettledCard({super.key, required this.item});
  final SettledItem item;

  Future<void> _reopen(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await reopenForReview(ref, item.entry);
      messenger.showSnackBar(
        const SnackBar(content: Text('Moved back to review')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not move this one back')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = item.entry;
    final title = (e.merchantName ?? '').trim().isEmpty
        ? 'Transaction'
        : e.merchantName!.trim();
    final category = e.categoryName ?? e.subcategoryName;
    final date = DateFormat('d MMM y').format(e.occurredAt.toLocal());
    void edit() => context.push('/activity/${e.id}/edit', extra: e);
    return BambooPanel(
      key: Key('settled-${e.id}'),
      onTap: edit,
      semanticLabel: 'Open $title',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.heading(16, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [date, ?category].join(' · '),
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                _money.format(e.amount.paise / 100),
                style: BambooFonts.heading(16, color: BambooInk.ink900),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Icon(
                item.byUser
                    ? Icons.person_outline_rounded
                    : switch (item.source) {
                        SettledSource.ai => Icons.auto_awesome_outlined,
                        SettledSource.onDevice => Icons.smartphone_rounded,
                        SettledSource.rule => Icons.rule_rounded,
                      },
                size: 16,
                color: BambooInk.ink500,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  item.how,
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          BambooActionBar(
            secondary: [
              OutlinedButton(
                key: Key('edit-${e.id}'),
                style: BambooButtons.secondary,
                onPressed: edit,
                child: const Text('Edit'),
              ),
            ],
            quiet: [
              TextButton(
                key: Key('reopen-${e.id}'),
                style: BambooButtons.quiet,
                onPressed: () => _reopen(context, ref),
                child: const Text('Move back to review'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// How the Gemini status bar looks.
enum GeminiTone {
  /// Working, or idle and healthy.
  ok,

  /// Not reaching Gemini (held back, failures): something to act on.
  warn,

  /// Not known (offline, no answer yet).
  unknown,
}

class GeminiBarState {
  const GeminiBarState({
    required this.tone,
    required this.title,
    required this.detail,
    this.progress = false,
  });
  final GeminiTone tone;
  final String title;
  final String detail;

  /// Show a moving bar: layouts are waiting or being drafted right now.
  final bool progress;
}

/// Turns what the server reports (and, when it cannot be reached, what the
/// phone itself knows) into one honest line for the bar. Pure, so every case is
/// tested.
GeminiBarState geminiBarState({
  required AiServerStatus? server,
  required AiReviewStatus? local,
  required int unreadOnPhone,
  required int openItems,
  bool sharingOff = false,
}) {
  String plural(int n, String one, [String? many]) =>
      '$n ${n == 1 ? one : (many ?? '${one}s')}';
  // Gemini only ever sees anonymised layouts the person agreed to share. With
  // that off nothing is sent, whatever the server says.
  if (sharingOff) {
    return const GeminiBarState(
      tone: GeminiTone.warn,
      title: 'Gemini is off: sharing is off on this phone',
      detail:
          'Gemini only sees anonymised message layouts you agree to share. '
          'Turn on "Help PandaPay read messages" to let it work.',
    );
  }
  if (server == null) {
    final waiting = local?.checkingTemplates.length ?? 0;
    final read = local?.resolved.length ?? 0;
    if (waiting > 0) {
      return GeminiBarState(
        tone: GeminiTone.ok,
        title: 'Gemini is checking ${plural(waiting, 'message format')}',
        detail:
            'From this phone: $waiting waiting · $read read by AI · '
            '$openItems still need you',
        progress: true,
      );
    }
    return GeminiBarState(
      tone: GeminiTone.unknown,
      title: 'Gemini status unavailable',
      detail:
          'Could not reach the server. This phone knows: $read read by AI'
          '${unreadOnPhone > 0 ? ' · $unreadOnPhone could not be read' : ''}'
          ' · $openItems still need you',
    );
  }
  if (!server.countedNow && server.inProgress == 0) {
    return GeminiBarState(
      tone: GeminiTone.warn,
      title: 'Gemini is not receiving your message formats yet',
      detail: server.held > 0
          ? '${plural(server.held, 'format')} held back: AI drafts are not '
                'switched on for this phone yet. Nothing for you to do; they '
                'are sent again as soon as it is.'
          : 'AI drafts are not switched on for this phone yet, so formats '
                'sent now would be held back. Nothing for you to do.',
    );
  }
  if (server.inProgress > 0) {
    return GeminiBarState(
      tone: GeminiTone.ok,
      title: 'Gemini is working',
      detail:
          '${server.working} drafting · ${server.queued} waiting · '
          '${server.ready + server.covered} done · ${server.failed} failed',
      progress: true,
    );
  }
  if (server.failed > 0) {
    return GeminiBarState(
      tone: GeminiTone.warn,
      title: 'Gemini could not draft ${plural(server.failed, 'format')}',
      detail:
          '${server.ready + server.covered} done · ${server.failed} failed'
          '${server.held > 0 ? ' · ${server.held} held back' : ''}',
    );
  }
  if (server.total == 0) {
    return const GeminiBarState(
      tone: GeminiTone.ok,
      title: 'Gemini is on',
      detail: 'No unreadable message formats have been sent yet.',
    );
  }
  return GeminiBarState(
    tone: GeminiTone.ok,
    title: 'Gemini is on',
    detail:
        '${plural(server.total, 'format')} sent · '
        '${server.ready + server.covered} done · ${server.held} held back',
  );
}

/// The server's view of this phone's formats; refreshed while the bar is shown.
final geminiServerStatusProvider = FutureProvider.autoDispose<AiServerStatus?>((
  ref,
) async {
  final runtime = await ref.watch(smsV2RuntimeProvider.future);
  if (runtime == null) return null;
  final status = await fetchAiServerStatus(
    client: runtime.client,
    baseUri: runtime.baseUri,
    headers: runtime.headers,
  );
  if (status != null) {
    // Counted now but layouts still held from before: send them again once.
    final cache = await ref.read(app.responseCacheProvider.future);
    final db = cache.financialStore.database.db;
    SmsV2Schema.ensure(db);
    resendHeldTemplates(
      db,
      namespace: ref.read(app.cacheNamespaceProvider),
      status: status,
      now: DateTime.now(),
    );
  }
  return status;
});

/// A bar at the top of Needs review that says whether Gemini is working: how
/// many formats it is drafting or waiting on, how many are done or failed, and
/// whether this phone's formats are reaching it at all.
class GeminiStatusBar extends ConsumerStatefulWidget {
  const GeminiStatusBar({super.key, required this.openItems});
  final int openItems;

  @override
  ConsumerState<GeminiStatusBar> createState() => _GeminiStatusBarState();
}

class _GeminiStatusBarState extends ConsumerState<GeminiStatusBar> {
  Timer? _refresh;

  /// The last answer the server gave. A server that is restarting for a minute
  /// (a deploy) must not turn a good status into "unavailable".
  AiServerStatus? _lastGood;
  DateTime? _lastGoodAt;
  DateTime _lastAsked = DateTime.now();
  static const _keepLastFor = Duration(minutes: 10);

  @override
  void initState() {
    super.initState();
    // Ask again every 30 s, or every 10 s while the server is not answering.
    _refresh = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      final answering =
          ref.read(geminiServerStatusProvider).valueOrNull != null;
      final due =
          DateTime.now().difference(_lastAsked) >= const Duration(seconds: 30);
      if (!answering || due) {
        _lastAsked = DateTime.now();
        ref.invalidate(geminiServerStatusProvider);
      }
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final answer = ref.watch(geminiServerStatusProvider).valueOrNull;
    if (answer != null) {
      _lastGood = answer;
      _lastGoodAt = DateTime.now();
    }
    final recent =
        _lastGoodAt != null &&
        DateTime.now().difference(_lastGoodAt!) < _keepLastFor;
    final consent = ref.watch(app.smsSharedLearningConsentProvider);
    final state = geminiBarState(
      server: answer ?? (recent ? _lastGood : null),
      local: ref.watch(aiReviewStatusProvider).valueOrNull,
      unreadOnPhone: ref.watch(aiUnreadCountProvider).valueOrNull ?? 0,
      openItems: widget.openItems,
      // No consent record: sharing is off and nothing is sent.
      sharingOff: consent.hasValue && consent.value == null,
    );
    final warn = state.tone == GeminiTone.warn;
    final color = switch (state.tone) {
      GeminiTone.ok => BambooInk.jade,
      GeminiTone.warn => BambooInk.clayInk,
      GeminiTone.unknown => BambooInk.ink500,
    };
    return Padding(
      key: const Key('gemini-status-bar'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: warn ? BambooInk.warningBg : BambooInk.paperMuted,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: warn ? Border.all(color: BambooInk.warningBorder) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  warn ? Icons.error_outline_rounded : Icons.auto_awesome,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.title,
                    style: BambooFonts.ui(
                      13.5,
                      weight: FontWeight.w700,
                      color: warn ? BambooInk.clayInk : BambooInk.ink900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              state.detail,
              style: BambooFonts.ui(
                12.5,
                color: warn ? BambooInk.clayInk : BambooInk.ink700,
                height: 1.4,
              ),
            ),
            if (state.progress) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 3),
            ],
          ],
        ),
      ),
    );
  }
}
