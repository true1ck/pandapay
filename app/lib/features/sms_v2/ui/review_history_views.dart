import '../../activity/transaction_badge.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart' show Database;

import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/providers.dart' as app;
import '../../../data/user_cards_repository.dart';
import '../providers/ai_status_provider.dart';
import '../providers/data_providers.dart';
import '../providers/runtime_provider.dart';
import '../storage/dismissal_store.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import '../sync/ai_server_status.dart';
import '../sync/template_resend.dart';
import '../ledger/providers.dart';
import 'ai_read_summary.dart';
import 'auto_dismissal_actions.dart';
import 'dismissed_reviews_view.dart';
import 'review_clustering.dart';
import 'screen_parts.dart';

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

/// One row of AI auto-resolved: a transaction the AI filed ([SettledItem]) or any
/// other message the AI read ([AiReadItem]). A message is here only while it is
/// not an open question on Needs review and the person has not dismissed it.
sealed class AutoItem {
  /// When it happened, for newest-first order.
  DateTime get occurredAt;

  /// Stable id of the row (the tie-break that keeps the order the same).
  String get orderKey;
}

/// One transaction the app settled, and who settled it.
class SettledItem implements AutoItem {
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

  @override
  DateTime get occurredAt => entry.occurredAt;

  @override
  String get orderKey => entry.id;
}

/// A message an AI rule read that left no transaction (a bill reminder, a failed
/// payment attempt, a balance or limit notice, an info message...). Listed so the
/// person can see what the AI understood, fix it when it got it wrong, or
/// dismiss it.
class AiReadItem implements AutoItem {
  const AiReadItem({
    required this.sourceKey,
    required this.occurredAt,
    required this.summary,
    required this.unverified,
    this.confidence,
  });

  /// The message (its capture id): what Fix reopens.
  final String sourceKey;

  /// The facts' observed time (when the message arrived).
  @override
  final DateTime occurredAt;

  /// What the AI understood, in plain words: "Bill due ₹1,179 on 15 Nov".
  final String summary;

  /// The AI rule that read it exists only on this phone, so PandaPay has not
  /// checked it yet (its id carries `:local:`, the same test as for a transaction).
  final bool unverified;

  /// The lowest confidence among the facts the AI read from it.
  final double? confidence;

  @override
  String get orderKey => sourceKey;
}

/// A message the person dismissed from AI auto-resolved, as a History row. Its
/// [record] says where it came from and what Recover has to put back.
class DismissedAutoItem {
  const DismissedAutoItem({
    required this.record,
    required this.title,
    required this.occurredAt,
    this.entry,
  });

  final AutoDismissal record;

  /// The shop of a transaction, or what the AI understood from a message.
  final String title;
  final DateTime occurredAt;

  /// The hidden transaction row (a dismissed transaction), when it is still on
  /// the phone.
  final TransactionEntry? entry;

  String get sourceKey => record.sourceKey;
}

/// The transactions the person added themselves to answer a review question
/// (see `markAnsweredByAdding`), as History entries, newest first. [syncedId]
/// gives the real transaction id once the phone's queue has delivered it; until
/// then the entry carries the queued id, which the edit screen understands.
List<SettledItem> addedFromReview(
  Database db, {
  required String namespace,
  String? Function(String clientMutationId)? syncedId,
}) {
  final items = <SettledItem>[];
  for (final row in db.select(
    "SELECT payload FROM v2_review_items WHERE namespace=? AND status='resolved' "
    "AND json_extract(payload,'\$.answer')='added'",
    [namespace],
  )) {
    try {
      final added = ((jsonDecode(row['payload'] as String) as Map)['added'] as Map)
          .cast<String, Object?>();
      final occurredAt = DateTime.parse(added['occurredAt'] as String);
      final mutationId = added['clientMutationId'] as String;
      final merchant = added['merchantName'] as String?;
      items.add(
        SettledItem(
          entry: TransactionEntry(
            id: syncedId?.call(mutationId) ?? 'local-outbox:$mutationId',
            amount: Money.fromPaise((added['amountMinor'] as num).toInt()),
            occurredAt: occurredAt.toLocal(),
            merchantName: merchant == null || merchant.isEmpty ? null : merchant,
            instrumentKnown: false,
            entryKind: added['entryKind'] == 'income'
                ? TxnEntryKind.income
                : TxnEntryKind.spend,
            source: 'manual',
            status: 'active',
          ),
          byUser: true,
          source: SettledSource.onDevice,
          how: 'You added this from a message',
        ),
      );
    } catch (_) {
      continue; // a record this build cannot read is not listed
    }
  }
  items.sort((a, b) => b.entry.occurredAt.compareTo(a.entry.occurredAt));
  return items;
}

class SettledLists {
  const SettledLists({
    this.auto = const [],
    this.history = const [],
    this.dismissed = const [],
  });

  /// These lists with [added] in History, newest first.
  SettledLists withAdded(List<SettledItem> added) {
    if (added.isEmpty) return this;
    final merged = [...history, ...added]
      ..sort((a, b) => b.entry.occurredAt.compareTo(a.entry.occurredAt));
    return SettledLists(
      auto: auto,
      history: List.unmodifiable(merged),
      dismissed: dismissed,
    );
  }

  /// Everything an AI rule read and was sure about, newest first: the
  /// transactions it filed and the messages it read that made no transaction.
  /// Not the ones open on Needs review, not the ones the person dismissed.
  final List<AutoItem> auto;

  /// The transactions among [auto].
  Iterable<SettledItem> get autoTransactions => auto.whereType<SettledItem>();

  /// The messages among [auto] that made no transaction.
  Iterable<AiReadItem> get autoReads => auto.whereType<AiReadItem>();

  /// Transactions the person confirmed, fixed or added, newest first, all time.
  final List<SettledItem> history;

  /// Messages the person dismissed from AI auto-resolved, newest first. (The ones
  /// dismissed from Needs review come from `dismissedReviewItemsProvider`.)
  final List<DismissedAutoItem> dismissed;

  /// The messages History lists from this model (without the Needs review
  /// dismissals, which are grouped by format and counted by the screen).
  int get historyMessages => history.length + dismissed.length;
}

/// Sorts the stored SMS transactions and AI readings into the lists of the
/// three-tab Needs review screen:
///
///  * AI auto-resolved ([SettledLists.auto]): what an AI rule read, that is not
///    an open question ([openReviewSources], the messages shown on Needs review)
///    and not dismissed. A message is in exactly one of Needs review and AI
///    auto-resolved.
///  * History ([SettledLists.history], [SettledLists.dismissed]): the AI
///    readings the person confirmed or fixed, and what they dismissed.
///
/// [confirmedEvents] are the ledger events the person decided (`user_confirmed`),
/// each with its decision time. A correction does not put a user fact under the
/// message's own source (it writes a new fact under `correction:<id>`), so the
/// event is where a person's edit of an AI reading shows. A transaction the
/// person dismissed and then recovered keeps the decision time its restore
/// stamped ([AutoDismissal.restoredDecidedAt]); while the event still carries
/// exactly that time it is AI auto-resolved again, and any later edit ends it.
SettledLists settledLists(
  Iterable<TransactionEntry> transactions,
  Map<String, List<Fact>> factsBySource, {
  Set<String> openReviewSources = const {},
  Map<String, DateTime?> confirmedEvents = const {},
  Iterable<AutoDismissal> dismissals = const [],
}) {
  final dismissalBySource = {
    for (final dismissal in dismissals) dismissal.sourceKey: dismissal,
  };
  final auto = <AutoItem>[];
  final history = <SettledItem>[];
  final entriesById = <String, TransactionEntry>{};
  // Messages that already have a transaction row above (whoever read them).
  final withTransaction = <String>{};
  for (final entry in transactions) {
    entriesById[entry.id] = entry;
    if (entry.pipelineVersion != 2) continue;
    final source = entry.sourceKey;
    if (source == null || entry.eventId == null) continue;
    withTransaction.add(source);
    // Deleted, left out or dismissed: not an AI reading that counts any more. A
    // dismissal is listed from its own record (History).
    if (entry.status != 'active') continue;
    final facts = factsBySource[source] ?? const <Fact>[];
    if (facts.isEmpty) continue;
    final machine = facts.firstWhere(
      (f) => f.provenance.engine != Engine.user,
      orElse: () => facts.first,
    );
    final ruleIds = [
      for (final f in facts)
        if (f.provenance.engine != Engine.user) f.provenance.ruleId,
    ];
    final reader = settledSourceOf(ruleIds);
    var byUser = facts.any((f) => f.provenance.engine == Engine.user);
    // The person decided an AI reading: a fix, or a confirmation. (Only AI
    // readings are looked at here; rules and the on-device reader sort quietly.)
    var fixedAiReading = false;
    if (!byUser &&
        reader == SettledSource.ai &&
        confirmedEvents.containsKey(entry.eventId)) {
      final restored = DateTime.tryParse(
        dismissalBySource[source]?.restoredDecidedAt ?? '',
      );
      final decided = confirmedEvents[entry.eventId];
      byUser =
          restored == null ||
          decided == null ||
          !decided.isAtSameMomentAs(restored);
      fixedAiReading = byUser;
    }
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
      how: fixedAiReading
          ? 'The AI read this; you confirmed or fixed it'
          : byUser
          ? 'You confirmed or edited this'
          : switch (reader) {
              SettledSource.ai =>
                unverified
                    ? 'Read by an AI rule, not yet verified'
                    : 'Read by an AI rule, verified',
              SettledSource.onDevice => 'Read by the on-device reader',
              SettledSource.rule => 'Read by a rule',
            },
    );
    // Rules and the on-device reader sort quietly: they are not listed. Only
    // what the person changed (History) or what Gemini filed and is sure about
    // (AI auto-resolved).
    if (byUser) {
      history.add(item);
    } else if (reader == SettledSource.ai &&
        !openReviewSources.contains(source)) {
      auto.add(item);
    }
  }
  // Whatever else an AI rule read (a bill reminder, a failed attempt, a balance
  // or limit notice, an info message...) made no transaction, so it is not in
  // the loop above. One pass over the facts already in memory; no query.
  for (final MapEntry(key: source, value: facts) in factsBySource.entries) {
    if (withTransaction.contains(source) || facts.isEmpty) continue;
    final dismissal = dismissalBySource[source];
    if (dismissal != null && !dismissal.restored) continue;
    if (openReviewSources.contains(source)) continue;
    final machine = [
      for (final f in facts)
        if (f.provenance.engine != Engine.user) f,
    ];
    final ai = [
      for (final f in machine)
        if (f.provenance.ruleId.startsWith('AI-')) f,
    ];
    // Not an AI read, or the person edited it: not listed.
    if (ai.isEmpty || machine.length != facts.length) continue;
    auto.add(
      AiReadItem(
        sourceKey: source,
        occurredAt: ai
            .map((f) => f.observedAt)
            .reduce((a, b) => a.isAfter(b) ? a : b),
        summary: aiReadSummary(ai),
        unverified: ai.any((f) => f.provenance.ruleId.contains(':local:')),
        confidence: ai.map((f) => f.confidence).reduce((a, b) => a < b ? a : b),
      ),
    );
  }
  // What the person dismissed from AI auto-resolved.
  final dismissed = <DismissedAutoItem>[];
  for (final dismissal in dismissals) {
    if (dismissal.restored) continue;
    if (dismissal.isTransaction) {
      final entry = entriesById[dismissal.entryId];
      // Back on screen (a restore from Activity): it is not dismissed any more.
      if (entry != null && entry.status == 'active') continue;
      dismissed.add(
        DismissedAutoItem(
          record: dismissal,
          title: (entry?.merchantName ?? '').trim().isEmpty
              ? 'Transaction'
              : entry!.merchantName!.trim(),
          occurredAt: entry?.occurredAt ?? dismissal.dismissedAt,
          entry: entry,
        ),
      );
    } else {
      final ai = [
        for (final f in factsBySource[dismissal.sourceKey] ?? const <Fact>[])
          if (f.provenance.engine != Engine.user &&
              f.provenance.ruleId.startsWith('AI-'))
            f,
      ];
      dismissed.add(
        DismissedAutoItem(
          record: dismissal,
          title: ai.isEmpty ? 'A message the AI read' : aiReadSummary(ai),
          occurredAt: ai.isEmpty
              ? dismissal.dismissedAt
              : ai
                    .map((f) => f.observedAt)
                    .reduce((a, b) => a.isAfter(b) ? a : b),
        ),
      );
    }
  }
  int newest(AutoItem a, AutoItem b) {
    final byTime = b.occurredAt.compareTo(a.occurredAt);
    return byTime != 0 ? byTime : a.orderKey.compareTo(b.orderKey);
  }

  auto.sort(newest);
  history.sort(newest);
  dismissed.sort((a, b) {
    final byTime = b.occurredAt.compareTo(a.occurredAt);
    return byTime != 0 ? byTime : a.sourceKey.compareTo(b.sourceKey);
  });
  // Both lists are built lazily by the screen, so their length costs nothing to
  // draw: no row cap (History used to stop at 90 days and 200 rows).
  return SettledLists(
    auto: List.unmodifiable(auto),
    history: List.unmodifiable(history),
    dismissed: List.unmodifiable(dismissed),
  );
}

final settledListsProvider = FutureProvider<SettledLists>((ref) async {
  final model = await ref.watch(smsV2LedgerReadModelProvider.future);
  // A question answered by adding the transaction changes no ledger revision,
  // only the review table; follow it.
  ref.watch(app.financialStoreRevisionProvider('needs_review'));
  // What is open on Needs review decides what is NOT AI auto-resolved. Both are
  // already built for the screen this list belongs to.
  final reviews = await ref.watch(reviewItemsProvider.future);
  final ai = await ref.watch(aiReviewStatusProvider.future);
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final outbox = await ref.watch(app.outboxRepositoryProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  return settledLists(
    model.transactions,
    model.factsBySource,
    openReviewSources: {
      for (final item in reviews)
        if (!ai.settledByAi(item))
          if (item.payload['sourceKey'] case final String source) source,
    },
    confirmedEvents: {
      for (final event in model.ledger.events)
        if (event.status == EventStatus.userConfirmed)
          event.eventId: event.decidedAt,
    },
    dismissals: DismissalStore(SyncStateStore(db, namespace: namespace)).all(),
  ).withAdded(
    addedFromReview(db, namespace: namespace, syncedId: outbox.syncedTransactionId),
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

/// Puts a message the AI read, but that made no transaction, back on Needs
/// review as an open question. It is the question the pipeline itself raises for
/// a message it could not read (a `template` review item keyed by the message),
/// so the normal Fix and Not financial answers handle it, through the same
/// personal-format and correction services. Nothing about the AI's reading is
/// changed here. `aiHold` keeps the message from being sent to the AI again for
/// a new rule (the same marker the pipeline uses for messages no rule can read).
Future<void> reopenReadForReview(WidgetRef ref, String sourceKey) async {
  final namespace = ref.read(app.cacheNamespaceProvider);
  final cache = await ref.read(app.responseCacheProvider.future);
  final store = cache.financialStore;
  final db = store.database.db;
  SmsV2Schema.ensure(db);
  store.batch(() {
    db.execute(
      'INSERT INTO v2_review_items (namespace, review_id, kind, payload, status) '
      "VALUES (?, ?, 'template', ?, 'open') "
      "ON CONFLICT(namespace, review_id) DO UPDATE SET status='open', payload=excluded.payload",
      [
        namespace,
        'reopen-read:$sourceKey',
        jsonEncode({
          'sourceKey': sourceKey,
          'reason': 'reopened',
          'aiHold': 'reopened',
        }),
      ],
    );
    store.notifyExternalChanges(namespace, const ['needs_review']);
  });
  ref.invalidate(reviewItemsProvider);
}

/// The sender and the first words of one message, for the card on screen.
class AiReadPreview {
  const AiReadPreview({required this.sender, required this.head});
  final String sender;
  final String head;
}

/// How much of the message a card quotes.
const aiReadSnippetChars = 140;

/// Reads one message's sender and its first [aiReadSnippetChars] characters, when
/// its card is built (a lazy list builds only the cards on screen). One primary
/// key lookup; the rest of the text is never read.
final aiReadPreviewProvider = FutureProvider.autoDispose
    .family<AiReadPreview?, String>((ref, sourceKey) async {
      final namespace = ref.watch(app.cacheNamespaceProvider);
      final cache = await ref.watch(app.responseCacheProvider.future);
      final rows = cache.financialStore.database.db.select(
        'SELECT sender, substr(body, 1, $aiReadSnippetChars) AS head '
        'FROM sms_captured_messages WHERE namespace=? AND id=? LIMIT 1',
        [namespace, sourceKey],
      );
      if (rows.isEmpty) return null;
      return AiReadPreview(
        sender: rows.first['sender'] as String,
        head: rows.first['head'] as String,
      );
    });

/// How many message formats the AI could not turn into a rule (failed, or its
/// draft was turned down by a reviewer). Read from the phone's own sync state.
final aiUnreadCountProvider = FutureProvider<int>((ref) async {
  // Re-read whenever the AI status itself changes.
  await ref.watch(aiReviewStatusProvider.future);
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  return aiUnreadCountIn(db, namespace);
});

/// The count behind [aiUnreadCountProvider]. Only a stored AI answer is a JSON value: one key that is not (the old
/// `ai:resend:at` held a bare date) made json_extract fail the whole query with "malformed JSON", and the count
/// with it, for as long as the key existed.
int aiUnreadCountIn(Database db, String namespace) {
  final row = db.select(
    "SELECT count(*) AS n FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%' "
    "AND CASE WHEN json_valid(value) THEN json_extract(value, '\$.status') END IN ('failed', 'rejected')",
    [namespace],
  );
  return (row.first['n'] as num).toInt();
}

/// The AI auto-resolved tab: everything an AI rule read and was sure about.
class SettledList extends ConsumerWidget {
  const SettledList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(settledListsProvider);
    return lists.when(
      skipLoadingOnReload: true,
      loading: () => const SmsLoading(),
      error: (_, _) =>
          SmsError(onRetry: () => ref.invalidate(settledListsProvider)),
      data: (value) {
        final items = value.auto;
        if (items.isEmpty) {
          return const SmsEmpty(
            'No message has been read by AI and settled yet. When the AI reads one and is sure of it, '
            'it appears here, newest first, already counted. Readings it is unsure about wait in Needs review.',
            icon: Icons.auto_awesome_outlined,
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
                ? const BambooNote(
                    'Messages the AI read and was sure of, newest first, all time. They are already counted. '
                    '"Not verified yet" means PandaPay has not checked the AI\'s rule yet. '
                    'Fix sends one back to Needs review. Dismiss is for something that is not a real transaction: '
                    'it leaves your totals and moves to History, where you can bring it back.',
                    icon: Icons.info_outline_rounded,
                  )
                : switch (items[i - 1]) {
                    final SettledItem item => SettledCard(item: item),
                    final AiReadItem item => AiReadCard(item: item),
                  },
          ),
        );
      },
    );
  }
}

/// The History tab: everything the person dismissed (from Needs review and from
/// AI auto-resolved) and the AI readings they fixed, all time, newest first.
/// Every dismissed row has one Recover action.
class HistoryList extends ConsumerWidget {
  const HistoryList({super.key, required this.onRecoverReview, this.busy = false});

  /// Brings a group of messages dismissed from Needs review back to it.
  final void Function(List<LocalReviewItem>) onRecoverReview;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(settledListsProvider);
    final reviewDismissed =
        ref.watch(dismissedReviewItemsProvider).valueOrNull ?? const [];
    return lists.when(
      skipLoadingOnReload: true,
      loading: () => const SmsLoading(),
      error: (_, _) =>
          SmsError(onRetry: () => ref.invalidate(settledListsProvider)),
      data: (value) {
        final epoch = DateTime.fromMillisecondsSinceEpoch(0);
        // One row per format for what was dismissed from Needs review (Recover
        // frees the format for all of its messages), one per message otherwise.
        final rows = <({DateTime when, String key, Widget Function() build})>[
          for (final bundle in bundleReviewItems(
            reviewDismissed,
            (_) => 'template',
          ))
            (
              when: bundle.latest ?? epoch,
              key: 'review:${bundle.key}',
              build: () => DismissedReviewPanel(
                bundle: bundle,
                busy: busy,
                onRecover: () => onRecoverReview(bundle.items),
              ),
            ),
          for (final item in value.dismissed)
            (
              when: item.occurredAt,
              key: 'auto:${item.sourceKey}',
              build: () => DismissedAutoCard(item: item),
            ),
          for (final item in value.history)
            (
              when: item.occurredAt,
              key: 'edited:${item.entry.id}',
              build: () => SettledCard(item: item, inHistory: true),
            ),
        ]..sort((a, b) {
            final byTime = b.when.compareTo(a.when);
            return byTime != 0 ? byTime : a.key.compareTo(b.key);
          });
        if (rows.isEmpty) {
          return const SmsEmpty(
            'Nothing here yet. Messages you dismiss, and AI readings you fix, appear here, '
            'so you can bring a dismissed one back.',
            icon: Icons.history_rounded,
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(settledListsProvider);
            ref.invalidate(dismissedReviewItemsProvider);
            await ref.read(settledListsProvider.future);
          },
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.sm,
              AppSpace.lg,
              AppSpace.xxl,
            ),
            itemCount: rows.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpace.md),
            itemBuilder: (context, i) => i == 0
                ? const BambooNote(
                    'Everything you dismissed or fixed, all time, newest first. Recover puts a dismissed message '
                    'back where it came from. An AI reading you fixed stays as you fixed it: PandaPay cannot '
                    'restore the AI\'s version automatically, but you can open it to change it again.',
                    icon: Icons.info_outline_rounded,
                  )
                : rows[i - 1].build(),
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
  const SettledCard({super.key, required this.item, this.inHistory = false});
  final SettledItem item;

  /// A History row (something the person fixed): Edit only, no way back to the
  /// AI's reading.
  final bool inHistory;

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

  Future<void> _dismiss(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await dismissTransactionFromCard(ref, item.entry);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Dismissed. It is in History if you want it back.'),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not dismiss this one')),
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
                    if (txnBadgeKind(e) case final badge?)
                      TransactionBadgePill(kind: badge),
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
          if (inHistory && item.byUser && item.source == SettledSource.ai) ...[
            const SizedBox(height: 4),
            Text(
              'Changed by you: the AI\'s reading cannot be restored automatically.',
              key: Key('history-no-restore-${e.id}'),
              style: BambooFonts.ui(12, color: BambooInk.ink500, height: 1.4),
            ),
          ],
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
            quiet: inHistory
                ? const []
                : [
                    TextButton(
                      key: Key('reopen-${e.id}'),
                      style: BambooButtons.quiet,
                      onPressed: () => _reopen(context, ref),
                      child: const Text('Move back to review'),
                    ),
                    TextButton(
                      key: Key('dismiss-${e.id}'),
                      style: BambooButtons.quiet,
                      onPressed: () => _dismiss(context, ref),
                      child: const Text('Dismiss'),
                    ),
                  ],
          ),
        ],
      ),
    );
  }
}

/// A message the AI read that made no transaction: what it understood, when,
/// from whom, whether PandaPay has checked the AI's rule, Fix and Dismiss.
class AiReadCard extends ConsumerWidget {
  const AiReadCard({super.key, required this.item});
  final AiReadItem item;

  Future<void> _fix(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await reopenReadForReview(ref, item.sourceKey);
      messenger.showSnackBar(
        const SnackBar(content: Text('Moved to Needs review')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not move this one to review')),
      );
    }
  }

  Future<void> _dismiss(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await dismissReadFromCard(ref, item.sourceKey);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Dismissed. It is in History if you want it back.'),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not dismiss this one')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(aiReadPreviewProvider(item.sourceKey)).valueOrNull;
    final date = DateFormat('d MMM y').format(item.occurredAt.toLocal());
    return BambooPanel(
      key: Key('ai-read-${item.sourceKey}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            item.summary,
            style: BambooFonts.heading(15.5, color: BambooInk.ink900),
          ),
          const SizedBox(height: 2),
          Text(
            [date, ?preview?.sender].join(' · '),
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Icon(
                item.unverified
                    ? Icons.auto_awesome_outlined
                    : Icons.verified_outlined,
                size: 16,
                color: BambooInk.ink500,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  item.unverified ? 'Not verified yet' : 'Verified',
                  key: Key('ai-read-badge-${item.sourceKey}'),
                  style: BambooFonts.ui(
                    12.5,
                    weight: FontWeight.w700,
                    color: BambooInk.ink700,
                  ),
                ),
              ),
            ],
          ),
          if (preview != null && preview.head.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              preview.head.length >= aiReadSnippetChars
                  ? '${preview.head.trimRight()}…'
                  : preview.head,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.4),
            ),
          ],
          const SizedBox(height: AppSpace.md),
          BambooActionBar(
            secondary: [
              OutlinedButton(
                key: Key('fix-read-${item.sourceKey}'),
                style: BambooButtons.secondary,
                onPressed: () => _fix(context, ref),
                child: const Text('Fix'),
              ),
            ],
            quiet: [
              TextButton(
                key: Key('dismiss-read-${item.sourceKey}'),
                style: BambooButtons.quiet,
                onPressed: () => _dismiss(context, ref),
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A History row for a message dismissed from AI auto-resolved, with Recover.
class DismissedAutoCard extends ConsumerWidget {
  const DismissedAutoCard({super.key, required this.item});
  final DismissedAutoItem item;

  Future<void> _recover(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final to = await recoverFromHistory(ref, item);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            to == RecoveredTo.autoResolved
                ? 'Back in AI auto-resolved.'
                : 'The AI no longer reads this one, so it is back in Needs review.',
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not recover this one')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = DateFormat('d MMM y').format(item.occurredAt.toLocal());
    final amount = item.entry == null
        ? null
        : _money.format(item.entry!.amount.paise / 100);
    return BambooPanel(
      key: Key('dismissed-auto-${item.sourceKey}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  item.title,
                  style: BambooFonts.heading(15.5, color: BambooInk.ink900),
                ),
              ),
              if (amount != null)
                Text(
                  amount,
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '$date · Dismissed from AI auto-resolved',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          OutlinedButton(
            key: Key('recover-${item.sourceKey}'),
            style: BambooButtons.secondary,
            onPressed: () => _recover(context, ref),
            child: const Text('Recover'),
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
    this.serverDetail,
  });
  final GeminiTone tone;
  final String title;
  final String detail;

  /// Show a moving bar: layouts are waiting or being drafted right now.
  final bool progress;

  /// The server's own counts, shown under "Phone details" only. They count
  /// message formats (a format is shared by many messages), for the whole
  /// account and all time, so they never sit next to the per-message line.
  final String? serverDetail;
}

/// The plain per-message line of the bar, from this phone's own data.
String _messagesLine(
  int read,
  int notRead, {
  bool retrying = false,
  int needCheck = 0,
}) {
  final head = read == 0
      ? 'AI has not read any of your messages yet'
      : 'AI read $read of your messages'
            '${needCheck > 0 ? ' · $needCheck of them need your check in Needs review' : ''}';
  if (notRead <= 0) return head;
  return '$head · $notRead could not be read yet${retrying ? ', retrying' : ''}';
}

/// Turns what the server reports (and, when it cannot be reached, what the
/// phone itself knows) into one honest line for the bar. Pure, so every case is
/// tested.
///
/// The main line counts MESSAGES, from this phone: [aiReadMessages] the
/// messages an AI rule read (AI auto-resolved plus the readings it is unsure
/// about, [aiNeedsCheck], which wait in Needs review), [unreadMessages] the
/// messages still waiting for a reading in Needs review. Either falls back to the older
/// numbers when the caller has not loaded them. The server's numbers count
/// message FORMATS, and go to [GeminiBarState.serverDetail].
GeminiBarState geminiBarState({
  required AiServerStatus? server,
  required AiReviewStatus? local,
  required int unreadOnPhone,
  required int openItems,
  int? aiReadMessages,
  int? unreadMessages,
  int aiNeedsCheck = 0,
  bool sharingOff = false,
  bool offline = false,
}) {
  String plural(int n, String one, [String? many]) =>
      '$n ${n == 1 ? one : (many ?? '${one}s')}';
  // What Gemini answered is not the same as what this phone has applied: both
  // are kept, under Phone details.
  final applied = local?.resolved.length ?? 0;
  final read = aiReadMessages ?? applied;
  final notRead = unreadMessages ?? unreadOnPhone;
  // Gemini only ever sees anonymised layouts the person agreed to share. With
  // that off nothing is sent, whatever the server says.
  if (sharingOff) {
    return const GeminiBarState(
      tone: GeminiTone.warn,
      title: 'AI is off: sharing is off on this phone',
      detail:
          'The AI only sees anonymised message layouts you agree to share. '
          'Turn on "Help PandaPay read messages" to let it work.',
    );
  }
  if (server == null) {
    final waiting = local?.checkingTemplates.length ?? 0;
    final phone =
        'AI read $read of your messages'
        '${aiNeedsCheck > 0 ? ' · $aiNeedsCheck need your check' : ''}'
        '${notRead > 0 ? ' · $notRead could not be read yet' : ''}'
        ' · $openItems still need you';
    // No connection: say so, and say it is not Gemini or the server that is
    // at fault. Nothing is lost; the status comes back with the connection.
    if (offline) {
      return GeminiBarState(
        tone: GeminiTone.unknown,
        title: "You're offline",
        detail:
            "The AI status will show again when you're back online. "
            'This phone knows: '
            '${waiting > 0 ? '$waiting waiting · ' : ''}$phone',
      );
    }
    if (waiting > 0) {
      return GeminiBarState(
        tone: GeminiTone.ok,
        title: 'AI is checking ${plural(waiting, 'message format')}',
        detail: 'From this phone: $waiting waiting · $phone',
        progress: true,
      );
    }
    return GeminiBarState(
      tone: GeminiTone.unknown,
      title: 'AI status unavailable',
      detail: 'Could not reach the server. This phone knows: $phone',
    );
  }
  // The server's per-format numbers, labelled so they cannot be mistaken for
  // messages.
  final serverDetail =
      'Formats learned for your account: ${server.total} '
      '(formats, not messages; all time, all your devices)\n'
      'Formats: ${server.ready + server.covered} answered · '
      '${server.working} drafting · ${server.queued} waiting · '
      '${server.failed} failed · ${server.held} held back\n'
      'Formats applied on this phone: $applied';
  if (!server.countedNow && server.inProgress == 0) {
    return GeminiBarState(
      tone: GeminiTone.warn,
      title: 'AI is not receiving your message formats yet',
      detail: server.held > 0
          ? '${plural(server.held, 'format')} held back: AI drafts are not '
                'switched on for this phone yet. Nothing for you to do; they '
                'are sent again as soon as it is.'
          : 'AI drafts are not switched on for this phone yet, so formats '
                'sent now would be held back. Nothing for you to do.',
      serverDetail: serverDetail,
    );
  }
  if (server.inProgress > 0) {
    return GeminiBarState(
      tone: GeminiTone.ok,
      title: 'AI is working',
      detail: _messagesLine(read, notRead, retrying: true, needCheck: aiNeedsCheck),
      progress: true,
      serverDetail: serverDetail,
    );
  }
  if (server.failed > 0) {
    return GeminiBarState(
      tone: GeminiTone.warn,
      title: 'AI could not draft ${plural(server.failed, 'format')}',
      detail:
          '${_messagesLine(read, notRead, retrying: true, needCheck: aiNeedsCheck)}\n'
          // Held layouts are old ones this phone no longer has an open message for (it sends the open ones again by
          // itself): not a failure, so they are not counted in this red line.
          'Messages in a failed format stay in Needs review for you to '
          'answer. PandaPay tries a failed format again on its own after a '
          'hiccup on our side, and once more whenever the AI is improved.',
      serverDetail: serverDetail,
    );
  }
  if (server.total == 0) {
    return GeminiBarState(
      tone: GeminiTone.ok,
      title: 'AI is on',
      detail: read > 0
          ? _messagesLine(read, notRead, needCheck: aiNeedsCheck)
          : 'No unreadable message formats have been sent yet.',
      serverDetail: serverDetail,
    );
  }
  return GeminiBarState(
    tone: GeminiTone.ok,
    title: 'AI is on',
    detail: _messagesLine(read, notRead, needCheck: aiNeedsCheck),
    serverDetail: serverDetail,
  );
}

/// The server's view of this phone's formats; refreshed while the bar is shown.
final geminiServerStatusProvider = FutureProvider.autoDispose<AiServerStatus?>((
  ref,
) async {
  // Offline there is nothing to ask. Watching the connection also asks again
  // the moment it returns.
  if (ref.watch(app.isOnlineProvider).valueOrNull == false) return null;
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

/// A bar at the top of Needs review that says whether AI is working: how
/// many formats it is drafting or waiting on, how many are done or failed, and
/// whether this phone's formats are reaching it at all.
class GeminiStatusBar extends ConsumerStatefulWidget {
  const GeminiStatusBar({
    super.key,
    required this.openItems,
    this.aiReadMessages,
    this.unreadMessages,
    this.aiNeedsCheck = 0,
  });
  final int openItems;

  /// Of [aiReadMessages], how many wait on Needs review for the person's check.
  final int aiNeedsCheck;

  /// Messages an AI rule read, from this phone (the AI results tab). Null until
  /// that list has loaded.
  final int? aiReadMessages;

  /// Messages still waiting for a reading in Needs review.
  final int? unreadMessages;

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

  /// The "phone details" line is open.
  bool _showDetails = false;

  @override
  void initState() {
    super.initState();
    // Ask again every 30 s, or every 10 s while the server is not answering.
    _refresh = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      // No connection, no polling: it asks again when the connection returns.
      if (ref.read(app.isOnlineProvider).valueOrNull == false) return;
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
      offline: ref.watch(app.isOnlineProvider).valueOrNull == false,
      server: answer ?? (recent ? _lastGood : null),
      local: ref.watch(aiReviewStatusProvider).valueOrNull,
      unreadOnPhone: ref.watch(aiUnreadCountProvider).valueOrNull ?? 0,
      openItems: widget.openItems,
      aiReadMessages: widget.aiReadMessages,
      aiNeedsCheck: widget.aiNeedsCheck,
      // The phone's own count of messages no rule has read yet (the same number Phone details shows). Counting the open
      // review cards here said "14 could not be read" for payment questions that are not unreadable messages.
      unreadMessages:
          ref.watch(aiPhoneDiagnosticsProvider).valueOrNull?.unknownMessages ??
          widget.unreadMessages,
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
            const SizedBox(height: 6),
            GestureDetector(
              key: const Key('gemini-phone-details-toggle'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _showDetails = !_showDetails),
              child: Text(
                _showDetails ? 'Hide phone details' : 'Phone details',
                style: BambooFonts.ui(
                  12,
                  weight: FontWeight.w700,
                  color: warn ? BambooInk.clayInk : BambooInk.ink500,
                ).copyWith(decoration: TextDecoration.underline),
              ),
            ),
            if (_showDetails) _PhoneDetails(serverDetail: state.serverDetail),
          ],
        ),
      ),
    );
  }
}

/// What this phone holds about the AI check. Counts only.
class _PhoneDetails extends ConsumerWidget {
  const _PhoneDetails({this.serverDetail});

  /// What the server counted (message formats, not messages), when it answered.
  final String? serverDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = BambooFonts.ui(12, color: BambooInk.ink700, height: 1.5);
    final details = ref.watch(aiPhoneDiagnosticsProvider);
    return Padding(
      key: const Key('gemini-phone-details'),
      padding: const EdgeInsets.only(top: 4),
      child: details.when(
        skipLoadingOnReload: true,
        loading: () => Text('Reading this phone…', style: style),
        error: (_, _) => Text('Could not read this phone.', style: style),
        data: (d) => Text(
          '${serverDetail == null ? '' : '$serverDetail\n'}'
          'AI answers saved here: ${d.answersReady} usable, ${d.answersFailed} failed\n'
          'Formats linked to answers: ${d.linksSaved}; usable answers with their link: ${d.readyWithLink} of ${d.answersReady}\n'
          'AI rules in use now: ${d.activeAiRules}\n'
          'Messages read by an AI rule: ${d.readByAiRule}\n'
          'Unknown messages: ${d.unknownMessages}, text still here: ${d.unknownWithText}\n'
          'Answers last erased: ${d.lastErasedAt ?? 'never'}; restores tried: ${d.restoresTried}\n'
          'Last sync problem: ${d.lastPullProblem == null ? 'none' : '${d.lastPullProblem} (${d.lastPullProblemAt ?? 'time unknown'})'}',
          style: style,
        ),
      ),
    );
  }
}
