import 'package:pandapay_domain/sms_v2.dart';
import '../personal/personal_format_service.dart';
import '../corrections/corrections_service.dart';
import 'personal_format_form.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../activity/edit_transaction_screen.dart' show AddedTransaction;
import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/design/widgets.dart';
import '../../../app/providers.dart' as app;
import '../pipeline/review_answers.dart';
import '../pipeline/trace.dart';
import '../providers/ai_status_provider.dart';
import '../providers/data_providers.dart';
import 'correction_form.dart';
import 'dismissed_reviews_view.dart';
import 'review_clustering.dart';
import 'review_controller.dart';
import 'review_draft.dart';
import 'review_history_views.dart';
import 'screen_parts.dart';
import 'sharing_offer_card.dart';

// Defined with the bundling they feed; the screen's other files import them from here.
export 'review_clustering.dart' show isReceiptQuestion, reviewKindOf;

/// The question, from the stored facts of the receipt and the wording set.
String receiptQuestion(LocalReviewItem item, [String locale = 'en']) {
  final payload = item.payload;
  final minor = (payload['amountMinor'] as num?)?.toInt() ?? 0;
  final at = DateTime.tryParse(payload['receiptAt'] as String? ?? '');
  return receiptReviewText(locale).question(
    cardBill: payload['cardBill'] == true,
    amount: formatReceiptRupees(minor),
    date: at == null ? '' : formatReceiptDate(at),
    app: (payload['app'] ?? payload['biller']) as String?,
  );
}

/// Sentinel the account picker returns for "Another account".
const _anotherAccount = '__another_account__';

class ReviewInboxScreen extends ConsumerStatefulWidget {
  const ReviewInboxScreen({super.key});
  @override
  ConsumerState<ReviewInboxScreen> createState() => _ReviewInboxScreenState();
}

class _ReviewInboxScreenState extends ConsumerState<ReviewInboxScreen> {
  bool _saving = false;
  int _tab = 0;
  ScaffoldMessengerState? _messenger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void dispose() {
    // The messenger outlives this screen. An "Undo" left on it would call back
    // into a disposed State, so it goes with the screen.
    _messenger?.hideCurrentSnackBar();
    super.dispose();
  }

  /// The confirmed credit cards, one per bank and number, listed by bank.
  List<Instrument> _distinctCards(List<Instrument> all) {
    final seen = <String>{};
    final cards = [
      for (final i in all)
        if (i.kind == InstrumentKind.creditCard &&
            i.status == InstrumentStatus.confirmed &&
            seen.add('${i.issuerSlug}|${i.maskDigits ?? i.instrumentId}'))
          i,
    ]..sort((a, b) {
        final byBank = defaultIssuerLabel(
          a.issuerSlug,
        ).compareTo(defaultIssuerLabel(b.issuerSlug));
        return byBank != 0 ? byBank : a.displayName.compareTo(b.displayName);
      });
    return cards;
  }

  /// Edit the whole transaction a question is about. Where no transaction
  /// exists yet (a receipt, a message the app cannot read) the same Edit screen
  /// opens on a draft filled in with what the question already knows. Saving it
  /// adds the transaction and answers the question (it moves to History);
  /// backing out adds nothing and leaves the question as it was.
  Future<void> _edit(LocalReviewItem item, String namespace) async {
    final eventId = item.payload['eventId'];
    if (eventId is String) {
      await context.push<bool>('/activity/v2:$eventId/edit');
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      // The edit may have settled the question (a card chosen, a category set).
      ref.invalidate(reviewItemsProvider);
      return;
    }
    final draft = reviewDraftEntry(item);
    final added = await context.push<Object?>(
      '/activity/${draft.id}/edit',
      extra: draft,
    );
    if (added is! AddedTransaction ||
        !mounted ||
        namespace != ref.read(app.cacheNamespaceProvider)) {
      return;
    }
    final cache = await ref.read(app.responseCacheProvider.future);
    if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
    markAnsweredByAdding(
      cache.financialStore,
      namespace: namespace,
      reviewId: item.id,
      added: added.toJson(),
    );
    ref.invalidate(reviewItemsProvider);
    ref.invalidate(settledListsProvider);
  }

  Future<void> _act(List<LocalReviewItem> group, String action) async {
    if (_saving) return;
    final namespace = ref.read(app.cacheNamespaceProvider);
    CorrectionEdit? edit;
    if (action.startsWith('receipt-')) {
      await _answerReceipt(group, action, namespace);
      return;
    }
    if (action == 'edit') {
      await _edit(group.first, namespace);
      return;
    }
    if (action == 'choose-card') {
      final cards = _distinctCards(await ref.read(instrumentsProvider.future));
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      // Step 1: what did this payment pay? A bill-pay app can be paying a card,
      // a loan or something else; only a card bill needs a card.
      final kind = await showBambooChoiceSheet<String>(
        context: context,
        title: 'What did this payment pay?',
        subtitle: 'A payment is counted once, against what it paid.',
        icon: Icons.help_outline_rounded,
        options: [
          BambooChoice(
            value: 'card',
            label: 'A credit card bill',
            detail: cards.isEmpty
                ? 'No confirmed credit cards yet'
                : cards.length == 1
                ? 'Your ${cards.single.displayName}'
                : 'Choose which of your ${cards.length} cards',
            icon: Icons.credit_card_rounded,
          ),
          if (group.length == 1)
            const BambooChoice(
              value: 'other',
              label: 'Something else',
              detail: 'Edit the payment: merchant, category, account',
              icon: Icons.edit_outlined,
            ),
        ],
      );
      if (kind == null ||
          !mounted ||
          namespace != ref.read(app.cacheNamespaceProvider)) {
        return;
      }
      if (kind == 'other') {
        await _edit(group.first, namespace);
        return;
      }
      // Step 2: which card, under its bank.
      final chosen = await showBambooChoiceSheet<String>(
        context: context,
        title: 'Which card did this pay?',
        subtitle: 'The bill payment is counted once, against this card.',
        icon: Icons.credit_card_rounded,
        emptyMessage:
            'Confirm your credit cards under Accounts first, then come back.',
        options: [
          for (final card in cards)
            BambooChoice(
              value: card.instrumentId,
              label: card.displayName,
              detail: '••${card.maskDigits ?? 'unknown'}',
              icon: Icons.credit_card_rounded,
              group: defaultIssuerLabel(card.issuerSlug),
            ),
        ],
      );
      if (chosen == null ||
          !mounted ||
          namespace != ref.read(app.cacheNamespaceProvider)) {
        return;
      }
      edit = CorrectionEdit(CorrectionKind.wrongInstrument, {
        'targetInstrumentId': chosen,
      });
    }
    if (action == 'match') {
      final candidates = group.first.payload['candidates'] as List? ?? const [];
      final selected = await showBambooChoiceSheet<Map>(
        context: context,
        title: 'Which payment matches?',
        subtitle: 'The two messages will be counted as one payment.',
        icon: Icons.link_rounded,
        options: [
          for (final candidate in candidates.whereType<Map>())
            BambooChoice(
              value: candidate,
              label:
                  candidate['label'] as String? ??
                  'Payment ${candidates.indexOf(candidate) + 1}',
              icon: Icons.receipt_long_outlined,
            ),
        ],
      );
      if (selected == null ||
          !mounted ||
          namespace != ref.read(app.cacheNamespaceProvider)) {
        return;
      }
      edit = CorrectionEdit(CorrectionKind.wrongLink, {
        '_matchEventId': selected['eventId'],
        '_candidateFactId': selected['factId'],
        '_candidateRole': selected['role'],
      });
    }
    if (action == 'fix' &&
        (group.length > 1 ||
            group.every((item) => item.payload['hasReading'] != true))) {
      try {
        final raw = group.first.message;
        if (raw == null) {
          throw ArgumentError(
            'The original message is unavailable on this phone',
          );
        }
        final instruments = await ref.read(instrumentsProvider.future);
        if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) {
          return;
        }
        final choice = await showBambooSheet<PersonalFormatChoice>(
          context: context,
          builder: (_) => PersonalFormatForm(
            message: SmsMessage(
              sender: raw.message.sender,
              body: raw.message.body,
              observedAt: raw.message.receivedAt.toUtc(),
              sourceKey: raw.id,
            ),
            instruments: instruments,
            groupCount: group.length,
          ),
        );
        if (choice == null ||
            !mounted ||
            namespace != ref.read(app.cacheNamespaceProvider)) {
          return;
        }
        final controller = await smsReviewController(ref);
        if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) {
          return;
        }
        CorrectionsService(
          financial: controller.financial,
          namespace: namespace,
          bundle: controller.bundle,
          categoryIdBySlug: controller.categoryIdBySlug,
        ).teachFormat(
          choice: choice,
          sourceKeys: group.map(
            (item) => item.payload['sourceKey'] as String? ?? item.message!.id,
          ),
          appVersion: ref.read(app.appVersionProvider).valueOrNull ?? '1.0.0',
        );
        ref.invalidate(reviewItemsProvider);
      } catch (error) {
        if (mounted) smsShowError(context, error);
      }
      return;
    }
    if (action == 'fix') {
      edit = await showBambooSheet<CorrectionEdit>(
        context: context,
        builder: (_) => CorrectionForm(groupCount: group.length),
      );
      if (edit == null ||
          !mounted ||
          namespace != ref.read(app.cacheNamespaceProvider)) {
        return;
      }
    }
    setState(() => _saving = true);
    try {
      final controller = await smsReviewController(ref);
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      controller.apply(
        items: group,
        kind:
            edit?.kind ??
            (action == 'correct' || action == 'separate'
                ? CorrectionKind.wrongLink
                : CorrectionKind.notFinancial),
        corrected: edit?.corrected ?? const {},
        confirm: action == 'correct' || action == 'separate',
      );
      ref.invalidate(reviewItemsProvider);
      ref.invalidate(dismissedReviewItemsProvider);
      if (action == 'ignore' &&
          group.every((i) => i.kind == 'template' && i.message != null) &&
          mounted) {
        final n = group.length;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                n == 1
                    ? 'Marked as not financial.'
                    : '$n messages marked as not financial.',
              ),
              persist: false,
              duration: const Duration(seconds: 8),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () => _restore(group),
              ),
            ),
          );
      }
    } catch (error) {
      if (mounted) smsShowError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Takes back "Not financial" for unknown formats: the ignore rule goes and
  /// the messages return to Needs review.
  Future<void> _restore(List<LocalReviewItem> group) async {
    if (_saving || !mounted) return;
    final namespace = ref.read(app.cacheNamespaceProvider);
    setState(() => _saving = true);
    try {
      final controller = await smsReviewController(ref);
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      final n = controller.restoreDismissed(group);
      ref.invalidate(reviewItemsProvider);
      ref.invalidate(dismissedReviewItemsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                n == 1
                    ? 'Moved back to review.'
                    : '$n messages moved back to review.',
              ),
            ),
          );
      }
    } catch (error) {
      if (mounted) smsShowError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _answerReceipt(
    List<LocalReviewItem> group,
    String action,
    String namespace,
  ) async {
    final text = receiptReviewText();
    if (action == 'receipt-unsure') {
      // Stays in review: nothing changes.
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(text.notSureSnack)));
      return;
    }
    String? funding;
    if (action == 'receipt-yes') {
      final accounts = (await ref.read(instrumentsProvider.future))
          .where(
            (i) =>
                (i.kind == InstrumentKind.bankAccount ||
                    i.kind == InstrumentKind.wallet) &&
                i.status == InstrumentStatus.confirmed,
          )
          .toList()
        ..sort((a, b) {
          final byKind = (a.kind == InstrumentKind.wallet ? 1 : 0).compareTo(
            b.kind == InstrumentKind.wallet ? 1 : 0,
          );
          return byKind != 0 ? byKind : a.displayName.compareTo(b.displayName);
        });
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      final chosen = await showBambooChoiceSheet<String>(
        context: context,
        title: text.chooseAccountTitle,
        icon: Icons.account_balance_outlined,
        options: [
          for (final account in accounts)
            BambooChoice(
              value: account.instrumentId,
              label: account.displayName,
              detail: '••${account.maskDigits ?? 'unknown'}',
              icon: account.kind == InstrumentKind.wallet
                  ? Icons.account_balance_wallet_outlined
                  : Icons.account_balance_outlined,
              group: account.kind == InstrumentKind.wallet
                  ? 'Wallets'
                  : 'Bank accounts',
            ),
          BambooChoice(
            value: _anotherAccount,
            label: text.anotherAccount,
            icon: Icons.more_horiz_rounded,
          ),
        ],
      );
      if (chosen == null ||
          !mounted ||
          namespace != ref.read(app.cacheNamespaceProvider)) {
        return;
      }
      funding = chosen == _anotherAccount ? null : chosen;
    }
    setState(() => _saving = true);
    try {
      final reviews = await smsReceiptReviews(ref);
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      for (final item in group) {
        if (action == 'receipt-yes') {
          reviews.confirm(reviewId: item.id, fundingInstrumentId: funding);
        } else {
          reviews.dismiss(reviewId: item.id);
        }
      }
      ref.invalidate(reviewItemsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              action == 'receipt-yes' ? text.countedSnack : text.dismissedSnack,
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) smsShowError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final review = ref.watch(reviewItemsProvider);
    final dismissed =
        ref.watch(dismissedReviewItemsProvider).valueOrNull ?? const [];
    final ai =
        ref.watch(aiReviewStatusProvider).valueOrNull ?? const AiReviewStatus();
    final aiItems = [
      for (final item in review.valueOrNull ?? const <LocalReviewItem>[])
        if (ai.resolutionOf(item) != null) item,
    ];
    // What the person still has to answer, as questions: a format shared by
    // many messages is one question.
    final openItems = [
      for (final item in review.valueOrNull ?? const <LocalReviewItem>[])
        if (ai.resolutionOf(item) == null) item,
    ];
    final settled = ref.watch(settledListsProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Needs review'),
        actions: [
          IconButton(
            key: const Key('open-corrections-status'),
            tooltip: 'Your corrections',
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: () => context.push('/sms-v2/corrections'),
          ),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.sm,
                AppSpace.lg,
                AppSpace.xs,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<int>(
                  segments: [
                    ButtonSegment(
                      value: 0,
                      label: Text(
                        'Needs review${review.valueOrNull == null ? '' : ' (${reviewQuestionCount(openItems, reviewKindOf)})'}',
                      ),
                    ),
                    if (aiItems.isNotEmpty)
                      ButtonSegment(
                        value: 2,
                        label: Text(
                          'AI suggested (${reviewQuestionCount(aiItems, reviewKindOf)})',
                        ),
                      ),
                    ButtonSegment(
                      value: 3,
                      label: Text(
                        'AI auto-resolved (${settled?.auto.length ?? 0})',
                      ),
                    ),
                    ButtonSegment(
                      value: 4,
                      label: Text('History (${settled?.history.length ?? 0})'),
                    ),
                    ButtonSegment(
                      value: 1,
                      label: Text('Dismissed (${dismissed.length})'),
                    ),
                  ],
                  selected: {_tab},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _tab = s.first),
                ),
              ),
            ),
            // Always shown, on every tab: whether AI is working or not.
            GeminiStatusBar(
              openItems: (review.valueOrNull?.length ?? 0) - aiItems.length,
            ),
            Expanded(
              child: _tab == 3
                  ? const SettledList(history: false)
                  : _tab == 4
                  ? const SettledList(history: true)
                  : _tab == 2 && aiItems.isNotEmpty
                  ? ReviewInboxList(
                      items: aiItems,
                      busy: _saving,
                      onAction: _act,
                      aiStatus: ai,
                      header: const _AiSuggestedNote(),
                    )
                  : _tab == 1
                  ? DismissedReviewList(
                      items: dismissed,
                      busy: _saving,
                      onRestore: _restore,
                    )
                  : review.when(
                      skipLoadingOnReload: true,
                      skipLoadingOnRefresh: true,
                      loading: () => const SmsLoading(),
                      error: (_, _) => SmsError(
                        onRetry: () => ref.invalidate(reviewItemsProvider),
                      ),
                      data: (items) {
                        final rest = [
                          for (final item in items)
                            if (ai.resolutionOf(item) == null) item,
                        ];
                        return ReviewInboxList(
                          items: rest,
                          busy: _saving,
                          onAction: _act,
                          aiStatus: ai,
                          header: SharingOfferCard(openItems: rest.length),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class ReviewInboxList extends StatefulWidget {
  const ReviewInboxList({
    super.key,
    required this.items,
    required this.onAction,
    this.busy = false,
    this.header,
    this.aiStatus = const AiReviewStatus(),
  });
  final List<LocalReviewItem> items;

  /// What the AI check says about these items (labels only).
  final AiReviewStatus aiStatus;
  final bool busy;
  final void Function(List<LocalReviewItem>, String) onAction;

  /// Shown under the privacy note (the sharing offer).
  final Widget? header;

  @override
  State<ReviewInboxList> createState() => _ReviewInboxListState();
}

class _ReviewInboxListState extends State<ReviewInboxList> {
  ReviewFilter _filter = ReviewFilter.all;
  String? _month;

  /// Only unknown formats can be set aside in bulk, and only under the
  /// "Declined & alerts" chip: that is the one group that is not financial by
  /// nature. Anything else could hold real spends, so it is decided card by
  /// card. Unknown-format items are also the ones whose dismissal can be
  /// undone (they have no event, so nothing else was changed).
  static List<LocalReviewItem> _dismissable(List<ReviewBundle> bundles) => [
    for (final b in bundles)
      if (b.kind == 'template')
        for (final i in b.items)
          if (i.message != null) i,
  ];

  Future<void> _confirmBulkDismiss(
    List<LocalReviewItem> targets,
    String scope,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Mark ${targets.length} messages as not financial?'),
        content: Text(
          'These are the ${targets.length} messages shown under $scope. '
          'Future messages in the same formats will be ignored too. '
          'You can undo this right after, or later from the Dismissed tab.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Mark all'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) widget.onAction(targets, 'ignore');
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) {
      return const SmsEmpty(
        'You’re all caught up. New formats and payments that need your help will appear here.',
        icon: Icons.task_alt_rounded,
      );
    }
    final typeOf = {
      for (final item in items) item: reviewFilterOf(item, reviewKindOf),
    };
    // Counts are questions (bundles), not messages.
    final byType = <ReviewFilter, List<LocalReviewItem>>{};
    for (final entry in typeOf.entries) {
      (byType[entry.value] ??= []).add(entry.key);
    }
    final typeCounts = {
      for (final entry in byType.entries)
        entry.key: reviewQuestionCount(entry.value, reviewKindOf),
    };
    // A chip whose items were all dealt with falls back to All instead of
    // leaving an empty screen.
    final filter =
        _filter != ReviewFilter.all && (typeCounts[_filter] ?? 0) == 0
        ? ReviewFilter.all
        : _filter;
    final ofType = [
      for (final item in items)
        if (filter == ReviewFilter.all || typeOf[item] == filter) item,
    ];
    final byMonth = <String, List<LocalReviewItem>>{};
    for (final item in ofType) {
      final key = reviewMonthKey(item);
      if (key != null) (byMonth[key] ??= []).add(item);
    }
    final monthCounts = {
      for (final entry in byMonth.entries)
        entry.key: reviewQuestionCount(entry.value, reviewKindOf),
    };
    final months = monthCounts.keys.toList()..sort((a, b) => b.compareTo(a));
    final month = _month != null && monthCounts.containsKey(_month)
        ? _month
        : null;
    final visible = month == null
        ? ofType
        : [
            for (final item in ofType)
              if (reviewMonthKey(item) == month) item,
          ];

    final sections = <String, List<ReviewBundle>>{};
    for (final bundle in bundleReviewItems(visible, reviewKindOf)) {
      final title = switch (bundle.kind) {
        'receipt' => receiptReviewText().title,
        'template' => 'New message formats',
        'link' => 'Is this the same payment?',
        'category' => 'What is this merchant?',
        _ => 'Please confirm',
      };
      sections.putIfAbsent(title, () => []).add(bundle);
    }
    // Teaching a big format clears the most messages, so those come first.
    sections['New message formats']?.sort((a, b) {
      final bySize = b.items.length.compareTo(a.items.length);
      if (bySize != 0) return bySize;
      final byDate = (b.latest ?? DateTime(0)).compareTo(
        a.latest ?? DateTime(0),
      );
      return byDate != 0 ? byDate : a.key.compareTo(b.key);
    });

    final scope = [
      '“${filter.label}”',
      if (month != null) reviewMonthLabel(month),
    ].join(' in ');

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      children: [
        const BambooNote(
          'Messages PandaPay cannot read yet are sent to an AI service (numbers changed) so it can learn their format. A format choice applies to every message in that group.',
        ),
        ?widget.header,
        if (widget.busy)
          const Padding(
            padding: EdgeInsets.only(top: AppSpace.md),
            child: ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
              child: LinearProgressIndicator(minHeight: 3),
            ),
          ),
        if (typeCounts.length > 1) ...[
          const SizedBox(height: AppSpace.md),
          _ChipRow(
            children: [
              _ReviewChip(
                label: 'All (${reviewQuestionCount(items, reviewKindOf)})',
                selected: filter == ReviewFilter.all,
                onTap: () => setState(() {
                  _filter = ReviewFilter.all;
                  _month = null;
                }),
              ),
              for (final f in ReviewFilter.values)
                if (f != ReviewFilter.all && (typeCounts[f] ?? 0) > 0)
                  _ReviewChip(
                    label: '${f.label} (${typeCounts[f]})',
                    selected: filter == f,
                    onTap: () => setState(() {
                      _filter = f;
                      _month = null;
                    }),
                  ),
            ],
          ),
        ],
        if (months.length > 1) ...[
          const SizedBox(height: AppSpace.xs),
          _ChipRow(
            children: [
              _ReviewChip(
                label: 'All time',
                selected: month == null,
                onTap: () => setState(() => _month = null),
              ),
              for (final m in months)
                _ReviewChip(
                  label: '${reviewMonthLabel(m)} (${monthCounts[m]})',
                  selected: month == m,
                  onTap: () => setState(() => _month = m),
                ),
            ],
          ),
        ],
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xl),
            child: Column(
              children: [
                Text(
                  'Nothing matches these filters.',
                  style: BambooFonts.ui(14.5, color: BambooInk.ink700),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _filter = ReviewFilter.all;
                    _month = null;
                  }),
                  child: const Text('Show everything'),
                ),
              ],
            ),
          ),
        for (final section in sections.entries) ...[
          BambooSectionLabel(section.key, asTitle: true),
          if (filter == ReviewFilter.alerts &&
              section.key == 'New message formats' &&
              _dismissable(section.value).length > 1)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: BambooButtons.quiet,
                onPressed: widget.busy
                    ? null
                    : () => _confirmBulkDismiss(
                        _dismissable(section.value),
                        scope,
                      ),
                child: Text(
                  'Not financial — all ${_dismissable(section.value).length} shown',
                ),
              ),
            ),
          for (final bundle in section.value)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: _ReviewGroupPanel(
                key: ValueKey(bundle.key),
                bundle: bundle,
                busy: widget.busy,
                onAction: widget.onAction,
                aiStatus: widget.aiStatus,
              ),
            ),
        ],
      ],
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(spacing: AppSpace.xs, children: children),
  );
}

class _ReviewChip extends StatelessWidget {
  const _ReviewChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    selected: selected,
    selectedColor: BambooInk.slate,
    onSelected: (_) => onTap(),
    label: Text(label),
    showCheckmark: false,
    labelStyle: BambooFonts.ui(
      12.5,
      weight: selected ? FontWeight.w600 : FontWeight.w500,
      color: selected ? BambooInk.onSlate : BambooInk.ink700,
    ),
    backgroundColor: selected ? BambooInk.slate : BambooInk.paperMuted,
    side: BorderSide(
      color: selected ? BambooInk.slate : BambooInk.hairlineOnPaper,
    ),
    shape: const StadiumBorder(),
    padding: const EdgeInsets.symmetric(horizontal: 4),
    materialTapTargetSize: MaterialTapTargetSize.padded,
  );
}

class _ReviewGroupPanel extends StatefulWidget {
  const _ReviewGroupPanel({
    super.key,
    required this.bundle,
    required this.busy,
    required this.onAction,
    this.aiStatus = const AiReviewStatus(),
  });
  final AiReviewStatus aiStatus;
  final ReviewBundle bundle;
  final bool busy;
  final void Function(List<LocalReviewItem>, String) onAction;

  @override
  State<_ReviewGroupPanel> createState() => _ReviewGroupPanelState();
}

class _ReviewGroupPanelState extends State<_ReviewGroupPanel> {
  bool _expanded = false;

  List<LocalReviewItem> get group => widget.bundle.items;

  VoidCallback? _on(String action) =>
      widget.busy ? null : () => widget.onAction(group, action);

  String _summary(ReviewBundle b) {
    final parts = <String>[
      if (b.totalMinor != null) '${formatRupeesMinor(b.totalMinor!)} total',
      if (b.earliest != null && b.latest != null)
        formatBundleSpan(b.earliest!, b.latest!),
    ];
    return parts.join(' · ');
  }

  Widget _members() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final item in group)
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        if (reviewItemDate(item) case final d?)
                          DateFormat('d MMM yyyy').format(d.toLocal()),
                        if (reviewItemAmountMinor(item) case final a?)
                          formatRupeesMinor(a),
                      ].join(' · '),
                      style: BambooFonts.ui(
                        12,
                        weight: FontWeight.w700,
                        color: BambooInk.ink500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.message?.message.body ??
                          'The original message is no longer on this phone.',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(
                        13,
                        color: BambooInk.ink900,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                style: BambooButtons.quiet,
                onPressed: widget.busy
                    ? null
                    : () => widget.onAction([item], 'edit'),
                child: const Text('Edit'),
              ),
              if (item.message != null)
                TextButton(
                  style: BambooButtons.quiet,
                  onPressed: widget.busy
                      ? null
                      : () => widget.onAction([item], 'ignore'),
                  child: const Text('Not financial'),
                ),
            ],
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final bundle = widget.bundle;
    final first = group.first;
    final kind = reviewKindOf(first);
    final isReceipt = kind == 'receipt';
    final hasReading = group.every((i) => i.payload['hasReading'] == true);
    final allMessages = group.every((i) => i.message != null);
    final uniform = bundle.uniformFormat;
    final aiResolution = widget.aiStatus.resolutionOf(first);
    final aiChecking =
        aiResolution == null && group.every(widget.aiStatus.isChecking);
    // Every question can also be answered by editing the whole transaction. A
    // group of several messages has no single transaction: each message has
    // its own Edit in the expanded list.
    final hasTransaction = first.payload['eventId'] is String;
    final Widget? editWhole = group.length == 1
        ? TextButton(
            key: const Key('review-edit-transaction'),
            style: BambooButtons.quiet,
            onPressed: _on('edit'),
            child: Text(
              isReceipt
                  ? 'Add the payment yourself'
                  : hasTransaction
                  ? 'Edit transaction'
                  : 'Add as transaction',
            ),
          )
        : null;
    final notFinancial = TextButton(
      style: BambooButtons.quiet,
      onPressed: _on('ignore'),
      child: Text(group.length > 1 ? 'Not financial (all)' : 'Not financial'),
    );
    Widget fix(bool primary) => primary
        ? FilledButton(
            style: BambooButtons.primary,
            onPressed: _on('fix'),
            child: const Text('Fix'),
          )
        : OutlinedButton(
            style: BambooButtons.secondary,
            onPressed: _on('fix'),
            child: const Text('Fix'),
          );

    final Widget actions;
    if (isReceipt) {
      final text = receiptReviewText();
      actions = BambooActionBar(
        primary: FilledButton(
          style: BambooButtons.primary,
          onPressed: _on('receipt-yes'),
          child: Text(text.yes),
        ),
        secondary: [
          OutlinedButton(
            style: BambooButtons.secondary,
            onPressed: _on('receipt-no'),
            child: Text(text.no),
          ),
        ],
        quiet: [
          TextButton(
            style: BambooButtons.quiet,
            onPressed: _on('receipt-unsure'),
            child: Text(text.notSure),
          ),
          ?editWhole,
        ],
      );
    } else if (first.kind == 'bill_target') {
      actions = BambooActionBar(
        primary: FilledButton(
          style: BambooButtons.primary,
          onPressed: _on('choose-card'),
          child: const Text('Which card did this pay?'),
        ),
        quiet: [?editWhole, if (allMessages) notFinancial],
      );
    } else if (first.kind == 'link') {
      actions = BambooActionBar(
        primary: FilledButton(
          style: BambooButtons.primary,
          onPressed: _on('match'),
          child: const Text('Choose match'),
        ),
        secondary: [
          OutlinedButton(
            style: BambooButtons.secondary,
            onPressed: _on('separate'),
            child: const Text('Keep separate'),
          ),
        ],
        quiet: [?editWhole, if (allMessages) notFinancial],
      );
    } else if (bundle.kind == 'template' &&
        uniform &&
        allMessages &&
        const {
          ReviewContent.security,
          ReviewContent.promotion,
          ReviewContent.declined,
        }.contains(bundle.content)) {
      // Nothing here moved money, so setting it aside is the likely answer.
      // Fix stays available in case the wording was misread.
      actions = BambooActionBar(
        primary: FilledButton(
          style: BambooButtons.primary,
          onPressed: _on('ignore'),
          child: Text(switch (bundle.content!) {
            ReviewContent.security => 'Dismiss notice',
            ReviewContent.promotion => 'Dismiss promotion',
            _ => 'Not a spend',
          }),
        ),
        secondary: [fix(false)],
        quiet: [?editWhole],
      );
    } else if (!uniform) {
      // A Pay Later bundle spans several message formats. Teaching or
      // confirming one format for all of them would be wrong, so only the
      // safe bundle-wide action is offered; each message can still be set
      // aside on its own from the expanded list.
      actions = BambooActionBar(quiet: [if (allMessages) notFinancial]);
    } else {
      actions = BambooActionBar(
        primary: hasReading
            ? FilledButton(
                style: BambooButtons.primary,
                onPressed: _on('correct'),
                child: const Text('Correct'),
              )
            : fix(true),
        secondary: [if (hasReading) fix(false)],
        quiet: [?editWhole, if (allMessages) notFinancial],
      );
    }

    final count =
        '${group.length} ${group.length == 1 ? 'message' : 'messages'}';
    final summary = _summary(bundle);
    return BambooPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                isReceipt
                    ? Icons.receipt_long_outlined
                    : bundle.isPayLater
                    ? Icons.credit_score_outlined
                    : Icons.sms_outlined,
                size: 16,
                color: BambooInk.ink500,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  bundle.isPayLater
                      ? '${bundle.payLaterProvider} · $count'
                      : bundle.kind == 'template' &&
                            bundle.content != null &&
                            bundle.content != ReviewContent.other
                      ? '$count · ${bundle.content!.label}'
                      : count,
                  style: BambooFonts.ui(
                    12.5,
                    weight: FontWeight.w700,
                    color: BambooInk.ink500,
                  ),
                ),
              ),
            ],
          ),
          if (group.length > 1 && summary.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              summary,
              style: BambooFonts.ui(
                14.5,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
          ],
          if (aiResolution != null) ...[
            const SizedBox(height: 2),
            AiStatusLine(
              icon: aiResolution.verified
                  ? Icons.verified_outlined
                  : Icons.auto_awesome_outlined,
              text: aiResolution.verified
                  ? 'Verified by PandaPay'
                  : 'AI suggested, not yet verified',
            ),
          ] else if (aiChecking) ...[
            const SizedBox(height: 2),
            const AiStatusLine(
              icon: Icons.hourglass_top_rounded,
              text: 'Checking with AI… we’ll read it for you when it’s ready.',
            ),
          ] else if (bundle.kind == 'template' && !bundle.isPayLater) ...[
            const SizedBox(height: 2),
            Text(
              'We can’t read this message format yet.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.4),
            ),
          ],
          if (bundle.isPayLater && group.length > 1) ...[
            const SizedBox(height: 2),
            Text(
              'Credit line drawdowns, usually billed together in a monthly AutoPay.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.4),
            ),
          ],
          const SizedBox(height: 10),
          if (isReceipt)
            Text(
              receiptQuestion(first),
              style: BambooFonts.ui(
                14.5,
                weight: FontWeight.w500,
                color: BambooInk.ink900,
                height: 1.45,
              ),
            )
          else
            BambooMessageQuote(
              first.message?.message.body ??
                  'The original message is no longer on this phone.',
              sender: first.message?.message.sender,
            ),
          if (group.length > 1 && !isReceipt) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: BambooButtons.quiet,
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? 'Hide messages' : 'Show all ${group.length}',
                ),
              ),
            ),
            if (_expanded) _members(),
          ],
          if (first.payload['reading'] case final String reading) ...[
            const SizedBox(height: AppSpace.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.auto_awesome_outlined,
                    size: 16,
                    color: BambooInk.ink700,
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'Suggested reading: $reading',
                    style: BambooFonts.ui(
                      13.5,
                      weight: FontWeight.w600,
                      color: BambooInk.ink900,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpace.lg),
          actions,
        ],
      ),
    );
  }
}

/// One line under a review card: the AI check is running, or the AI's reading
/// is awaiting an admin's verification.
class AiStatusLine extends StatelessWidget {
  const AiStatusLine({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(icon, size: 15, color: BambooInk.ink700),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          style: BambooFonts.ui(12.5, color: BambooInk.ink700, height: 1.4),
        ),
      ),
    ],
  );
}

class _AiSuggestedNote extends StatelessWidget {
  const _AiSuggestedNote();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Text(
      'These were read by an AI-written rule that no one at PandaPay has '
      'checked yet. Use Fix if a reading is wrong; once it is verified the '
      'label changes.',
      style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.4),
    ),
  );
}
