import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/display_text.dart';
import '../../app/design/widgets.dart';
import '../../app/category_picker.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/commitments_repository.dart';
import '../../data/local/auto_resolved_history_repository.dart';
import '../../data/local/sms_facts_outbox.dart';
import '../../data/local_sms_parser.dart';
import '../../data/needs_review_repository.dart';
import '../../data/sms_fact_contract.dart';
import '../../data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument, UserCard;
import 'needs_review_clustering.dart';

String _feedbackSourceKey(String reviewId) {
  final commitment = RegExp(
    r'^commitment:([a-fA-F0-9]{64})$',
  ).firstMatch(reviewId);
  return commitment?.group(1) ?? reviewId;
}

TxnInstrument _instrumentFromReviewText(String body, [String sender = '']) {
  final text = body.toLowerCase();
  final senderText = sender.toLowerCase();
  if (senderText.contains('axio') ||
      text.contains('axio') ||
      RegExp(r'\b(?:pay\s+later|credit\s+line)\b').hasMatch(text)) {
    return TxnInstrument.other;
  }
  if (RegExp(
    r'\b(?:wallet|paytm\s+wallet|amazon\s+pay\s+balance)\b',
  ).hasMatch(text)) {
    return TxnInstrument.wallet;
  }
  final accountLike = RegExp(
    r'\b(?:a/c|account|upi|imps|neft)\b',
  ).hasMatch(text);
  if (accountLike && !RegExp(r'\b(?:credit|debit)\s+card\b').hasMatch(text)) {
    return TxnInstrument.upiBank;
  }
  if (RegExp(
    r'\bdebit\s+card\b|\b(?:atm|cash\s+withdrawal|withdrawn)\b|\bblock\s+dc\b',
  ).hasMatch(text)) {
    return TxnInstrument.debitCard;
  }
  if (RegExp(r'\bcredit\s+card\b|\bcard\b').hasMatch(text)) {
    return TxnInstrument.creditCard;
  }
  return TxnInstrument.other;
}

bool _isPhysicalCardInstrument(TxnInstrument instrument) =>
    instrument == TxnInstrument.creditCard ||
    instrument == TxnInstrument.debitCard;

String _reviewInstrumentLabel(TxnInstrument instrument) => switch (instrument) {
  TxnInstrument.creditCard => 'Credit card alert',
  TxnInstrument.debitCard => 'Debit card alert',
  TxnInstrument.upiBank => 'Bank account / UPI transfer',
  TxnInstrument.cash => 'Cash purchase',
  TxnInstrument.wallet => 'Wallet payment',
  TxnInstrument.other => 'Other payment',
};

bool _isSecurityOrServiceAlert(String body) =>
    NeedsReviewRepository.isSecurityOrServiceAlert(body);

bool _isInvestmentSettlement(String body) =>
    NeedsReviewRepository.isInvestmentSettlement(body);

bool _isMandateReview(String body) =>
    NeedsReviewRepository.isMandateReview(body);

String _reviewTypeLabel(NeedsReviewItem item) {
  if (item.kind == NeedsReviewKind.payLaterDrawdown ||
      NeedsReviewRepository.isPayLaterDrawdown(
        item.body,
        sender: item.sender,
      )) {
    return 'Pay Later / Credit line drawdown';
  }
  if (item.kind == NeedsReviewKind.securityOrServiceAlert ||
      _isSecurityOrServiceAlert(item.body)) {
    return 'Security or service alert';
  }
  if (item.aiSuggestions?.isNotEmpty == true) {
    final first = item.aiSuggestions!.first;
    final type = first['factType'];
    return switch (type) {
      'balance_snapshot' => 'Bank balance alert',
      'bill_obligation' => 'Card bill alert',
      'mandate_lifecycle' => 'AutoPay mandate alert',
      'posted_movement' => 'Possible transaction',
      'security_or_service_alert' => 'Security or service alert',
      _ => 'Financial alert',
    };
  }
  if (item.kind == NeedsReviewKind.investmentSettlement ||
      _isInvestmentSettlement(item.body)) {
    if (RegExp(
      r'\b(?:asba|ipo|lien)\b',
      caseSensitive: false,
    ).hasMatch(item.body)) {
      return 'ASBA / IPO lien block';
    }
    return 'Investment settlement payout';
  }
  if (item.kind == NeedsReviewKind.mandate || _isMandateReview(item.body)) {
    return 'AutoPay mandate alert';
  }
  final instrument = _instrumentFromReviewText(item.body, item.sender);
  return instrument == TxnInstrument.other
      ? 'Possible transaction'
      : _reviewInstrumentLabel(instrument);
}

String _reviewReasonLabel(String? reason, String body) {
  if (NeedsReviewRepository.isPayLaterDrawdown(body)) {
    return 'Credit facility drawdown (Amazon Pay Later / Axio). Actual debit occurs via monthly AutoPay bill payment.';
  }
  if (_isSecurityOrServiceAlert(body)) {
    return 'Verification or service notice — not a spending transaction.';
  }
  if (_isInvestmentSettlement(body)) {
    if (RegExp(r'\b(?:asba|ipo|lien)\b', caseSensitive: false).hasMatch(body)) {
      return 'Funds blocked or lien marked for ASBA / IPO application.';
    }
    return 'Funds settlement from broker or demat account.';
  }
  if (_isMandateReview(body)) {
    return 'Mandate authorization or notification.';
  }
  return switch (reason) {
    'no_transaction_match' =>
      'We could not match this message to a transaction.',
    'unparseable_amount' => 'The amount in this message is unclear.',
    'ambiguous_account_debit' =>
      'We could not tell which account or payment method was used.',
    'not_a_successful_spend' =>
      'This message may not describe a completed payment.',
    null => 'Please check the message before adding it.',
    _ => 'Please check the message before adding it.',
  };
}

String _reviewActionLabel(NeedsReviewItem item) {
  if (item.kind == NeedsReviewKind.payLaterDrawdown ||
      NeedsReviewRepository.isPayLaterDrawdown(
        item.body,
        sender: item.sender,
      )) {
    return 'Add as Amazon Pay Later spend';
  }
  if (item.kind == NeedsReviewKind.securityOrServiceAlert ||
      _isSecurityOrServiceAlert(item.body)) {
    return 'Dismiss alert';
  }
  if (item.aiSuggestions?.isNotEmpty == true) {
    final first = item.aiSuggestions!.first;
    final type = first['factType'];
    return switch (type) {
      'balance_snapshot' => 'Confirm balance',
      'bill_obligation' => 'Review bill',
      'mandate_lifecycle' => 'Confirm mandate',
      'security_or_service_alert' => 'Dismiss alert',
      'promotion' => 'Dismiss promotion',
      _ => 'Review transaction',
    };
  }
  if (item.kind == NeedsReviewKind.investmentSettlement ||
      _isInvestmentSettlement(item.body)) {
    return 'Review transfer';
  }
  if (item.kind == NeedsReviewKind.mandate || _isMandateReview(item.body)) {
    return 'Confirm mandate';
  }
  if (item.reason == 'ambiguous_account_debit' ||
      item.reason == 'card_not_unambiguous') {
    return 'Choose card/account';
  }
  return 'Review transaction';
}

/// The category the AI proposed for the first extracted fact, shown as a
/// visible badge so a medium-confidence item can be resolved in one tap.
String _suggestedCategoryName(NeedsReviewItem item) {
  final first = item.aiSuggestions?.isNotEmpty == true
      ? item.aiSuggestions!.first
      : null;
  final payload = first?['payload'];
  final raw = payload is Map ? payload['category'] : null;
  return LocalSmsParser.categoryDisplayName(raw is String ? raw : null) ??
      'Review';
}

String _aiSuggestedSummary(NeedsReviewItem item) {
  if (item.aiTopic?.trim().isNotEmpty == true) {
    final topic = item.aiTopic!.trim().replaceAll('_', ' ');
    return '✦ AI decision · $topic';
  }
  return '✦ AI suggested · ${_suggestedCategoryName(item)}';
}

Future<void> _persistCommitmentDismissal(
  WidgetRef ref,
  NeedsReviewItem item,
) async {
  final parsed = LocalSmsParser.parse(
    namespace: ref.read(cacheNamespaceProvider),
    sender: item.sender,
    body: item.body,
    receivedAt: item.receivedAt,
  );
  final title = parsed?.billerName?.trim().isNotEmpty == true
      ? parsed!.billerName!.trim()
      : item.sender;
  final category = CommitmentCategory.fromText('$title ${item.sender}');
  final account = parsed?.accountLast4 ?? parsed?.cardLast4;
  // Keep a tombstone so an explicitly rejected observation cannot recreate a
  // low-confidence commitment after the review item is removed.
  await ref
      .read(commitmentsRepositoryProvider)
      .save(
        Commitment(
          id: 'review-dismissed-${item.id}',
          title: title,
          category: category,
          amount: parsed?.amountDue,
          // A dismissal is useful even when the SMS did not contain a due
          // date. The received date is only a tombstone anchor; dismissed
          // commitments are never shown as actionable bills.
          dueOn: parsed?.dueDate ?? item.receivedAt,
          identifier: account == null ? null : '••••$account',
          source: CommitmentSource.sms,
          status: CommitmentStatus.dismissed,
          isUserConfirmed: true,
          confidence: 1,
        ),
      );
}

Future<void> _persistSmsFactCorrection(
  WidgetRef ref, {
  required String sourceKey,
  required int factIndex,
  required Map<String, dynamic> patch,
  required String reason,
  String? sampleBody,
  String? templateText,
}) async {
  final namespace = ref.read(cacheNamespaceProvider);
  final cache = await ref.read(responseCacheProvider.future);
  final outbox = SmsFactsOutbox(cache.financialStore.database);
  outbox.enqueueOverride(
    namespace,
    sourceKey: sourceKey,
    factIndex: factIndex,
    patch: patch,
    reason: reason,
    sampleBody: sampleBody,
    templateText: templateText,
  );

  final repository = ref.read(userCardsRepositoryProvider);
  if (repository == null || ref.read(isOnlineProvider).valueOrNull == false) {
    return;
  }
  try {
    final accepted = await repository.overrideSmsFact(
      sourceKey: sourceKey,
      factIndex: factIndex,
      patch: patch,
      reason: reason,
      sampleBody: sampleBody,
      templateText: templateText,
    );
    if (accepted) {
      outbox.acknowledgeOverride(namespace, sourceKey, factIndex);
    } else {
      outbox.failedOverride(namespace, sourceKey, factIndex);
    }
  } catch (_) {
    outbox.failedOverride(namespace, sourceKey, factIndex);
  }
}

typedef _BillReviewResult = ({
  String title,
  Money? amount,
  DateTime dueOn,
  CommitmentCategory category,
  CommitmentCadence cadence,
  String? identifier,
});

/// D4 Needs Review Queue (ui-spec Group D) — unparsed SMS messages with
/// raw text shown for context (kept on-device only; see
/// NeedsReviewRepository's own doc-comment for why this can't be a
/// server-side queue), one-tap fill of missing fields, "not a transaction"
/// dismiss, bulk dismiss.
enum _ReviewFilterCategory {
  all('All types'),
  spends('Spends / Debits'),
  bills('Bills & Mandates'),
  alerts('Alerts & Notices'),
  payLater('Pay Later / BNPL');

  final String label;
  const _ReviewFilterCategory(this.label);
}

_ReviewFilterCategory _categorizeItem(NeedsReviewItem item) {
  if (item.kind == NeedsReviewKind.payLaterDrawdown ||
      NeedsReviewRepository.isPayLaterDrawdown(
        item.body,
        sender: item.sender,
      )) {
    return _ReviewFilterCategory.payLater;
  }
  if (item.kind == NeedsReviewKind.commitment ||
      item.kind == NeedsReviewKind.mandate ||
      _isMandateReview(item.body)) {
    return _ReviewFilterCategory.bills;
  }
  if (item.aiSuggestions?.isNotEmpty == true) {
    final types = item.aiSuggestions!.map((fact) => fact['factType']).toSet();
    if (types.contains('posted_movement')) {
      return _ReviewFilterCategory.spends;
    }
    if (types.contains('bill_obligation') ||
        types.contains('mandate_lifecycle')) {
      return _ReviewFilterCategory.bills;
    }
    if (types.contains('balance_snapshot') ||
        types.contains('security_or_service_alert') ||
        types.contains('promotion')) {
      return _ReviewFilterCategory.alerts;
    }
  }
  if (item.kind == NeedsReviewKind.securityOrServiceAlert ||
      _isSecurityOrServiceAlert(item.body)) {
    return _ReviewFilterCategory.alerts;
  }
  return _ReviewFilterCategory.spends;
}

class _MonthEntry {
  final String key;
  final String label;
  final int count;
  final DateTime date;
  const _MonthEntry({
    required this.key,
    required this.label,
    required this.count,
    required this.date,
  });
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      selected: selected,
      selectedColor: BambooInk.slate,
      onSelected: (_) => onTap(),
      label: Text(label),
      // The tick pushed the label sideways and read as a second selection
      // marker next to the slate fill that already shows the state.
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
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );
  }
}

class NeedsReviewScreen extends ConsumerStatefulWidget {
  const NeedsReviewScreen({super.key});

  @override
  ConsumerState<NeedsReviewScreen> createState() => _NeedsReviewScreenState();
}

class _NeedsReviewScreenState extends ConsumerState<NeedsReviewScreen> {
  String? _selectedMonth;
  String? _selectedMonthLabel;
  DateTimeRange? _customDateRange;
  _ReviewFilterCategory _selectedCategory = _ReviewFilterCategory.all;
  int _selectedTab = 0;
  bool _retryingAiReviews = false;
  bool _hasObservedAiReviewRun = false;
  bool _showAiReviewCompleted = false;

  bool _canRetryAiReview(NeedsReviewItem item) {
    if (item.aiStatus != AiReviewStatus.unavailable) return false;
    final reason = item.aiFailureReason?.toLowerCase() ?? '';
    return !reason.contains('payload_refused_sensitive') &&
        !reason.contains('invalid_source_key') &&
        !reason.contains('malformed_payload');
  }

  Future<void> _retryFailedAiReviews(List<NeedsReviewItem> failedItems) async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null || _retryingAiReviews) return;
    final namespace = ref.read(cacheNamespaceProvider);
    final retryable = failedItems.where(_canRetryAiReview).toList();
    if (retryable.isEmpty) return;
    setState(() {
      _retryingAiReviews = true;
      _hasObservedAiReviewRun = true;
      _showAiReviewCompleted = false;
    });
    var queued = 0;
    for (final item in retryable) {
      if (!mounted || ref.read(cacheNamespaceProvider) != namespace) break;
      final sourceKey = _feedbackSourceKey(item.id);
      try {
        final jobId = await repo.submitAiJob(
          sourceKey: sourceKey,
          sender: item.sender,
          body: item.body,
          occurredAt: item.receivedAt,
          retryFailed: true,
        );
        if (jobId == null) continue;
        queued++;
        await ref
            .read(needsReviewRepositoryProvider)
            .updateAiStatus(item.id, AiReviewStatus.queued);
      } on Object catch (error) {
        // Keep failed state visible for a later page-level retry. A lost
        // response is safe to retry because the server deduplicates by source.
        if (error is ApiException && error.statusCode != null) {
          await ref
              .read(needsReviewRepositoryProvider)
              .updateAiStatus(
                item.id,
                AiReviewStatus.unavailable,
                failureReason: error.errorCode ?? 'http_${error.statusCode}',
              );
        }
      }
    }
    if (mounted) {
      setState(() {
        _retryingAiReviews = false;
        if (queued == 0) _hasObservedAiReviewRun = false;
      });
      ref.read(smsFlushTriggerProvider.notifier).state++;
      ref.invalidate(needsReviewItemsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            queued == 0
                ? 'No failed AI reviews could be retried.'
                : 'Retrying AI review for $queued message${queued == 1 ? '' : 's'}.',
          ),
        ),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(smsFlushTriggerProvider.notifier).state++;
    });
  }

  Widget _buildTabSelector(int pendingCount, int autoCount) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.sm,
      ),
      child: SegmentedButton<int>(
        segments: [
          ButtonSegment(value: 0, label: Text('Needs Review ($pendingCount)')),
          ButtonSegment(value: 1, label: Text('Auto-Resolved ($autoCount)')),
        ],
        selected: {_selectedTab},
        showSelectedIcon: false,
        // Split the width evenly: the shrink-wrapped control floated in the
        // middle of the header while every chip row below is edge-aligned.
        expandedInsets: EdgeInsets.zero,
        onSelectionChanged: (selection) =>
            setState(() => _selectedTab = selection.first),
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: WidgetStatePropertyAll(
            BambooFonts.ui(12.5, weight: FontWeight.w600),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: AppSpace.sm),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? BambooInk.slate
                : BambooInk.paperMuted,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? BambooInk.onSlate
                : BambooInk.ink700,
          ),
          side: const WidgetStatePropertyAll(
            BorderSide(color: BambooInk.hairlineOnPaper),
          ),
        ),
      ),
    );
  }

  Widget _buildAutoResolvedTab() {
    final history = ref.watch(autoResolvedHistoryProvider);
    return history.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () {
          ref.invalidate(autoResolvedHistoryProvider);
          ref.invalidate(autoResolvedCountProvider);
        },
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return const EmptyState(
            icon: Icons.auto_awesome_outlined,
            title: 'No auto-resolved items yet',
            message:
                'Confidently categorized alerts appear here so you can review or change them.',
          );
        }
        final sorted = List<AutoResolvedHistoryEntry>.from(entries)
          ..sort((a, b) {
            final byTime = b.autoResolvedAt.compareTo(a.autoResolvedAt);
            return byTime != 0 ? byTime : a.id.compareTo(b.id);
          });
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(autoResolvedHistoryProvider);
            ref.invalidate(autoResolvedCountProvider);
            try {
              await ref.read(autoResolvedHistoryProvider.future);
            } catch (_) {
              // The error state renders on the next build.
            }
          },
          child: ListView.builder(
            padding: const EdgeInsets.all(AppSpace.lg),
            itemCount: sorted.length,
            itemBuilder: (context, index) => Padding(
              key: ValueKey(sorted[index].id),
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: _AutoResolvedCard(sorted[index]),
            ),
          ),
        );
      },
    );
  }

  Future<void> _chooseCustomDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _customDateRange,
      helpText: 'Choose review dates',
      saveText: 'Apply dates',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _customDateRange = picked;
      _selectedMonth = null;
      _selectedMonthLabel = null;
    });
  }

  Future<void> _dismissItems(
    List<NeedsReviewItem> itemsToDismiss, {
    required int totalPendingCount,
  }) async {
    final isFiltered = itemsToDismiss.length < totalPendingCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isFiltered
              ? 'Dismiss ${itemsToDismiss.length} filtered review items?'
              : 'Dismiss all $totalPendingCount review items?',
        ),
        content: Text(
          isFiltered
              ? 'This removes only the ${itemsToDismiss.length} items currently visible under this filter. Other review items will not be affected.'
              : 'This removes all $totalPendingCount items from Needs Review.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isFiltered ? 'Dismiss filtered' : 'Dismiss all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final repo = ref.read(userCardsRepositoryProvider);
    for (final item in itemsToDismiss) {
      if (item.kind == NeedsReviewKind.commitment) {
        await _persistCommitmentDismissal(ref, item);
      }
      if (repo != null) {
        repo
            .dismissSms(
              sourceKey: _feedbackSourceKey(item.id),
              sender: item.sender,
              sampleBody: item.body,
              reason: 'user_dismissed',
              family: 'ignore_noise',
            )
            .ignore();
      }
    }
    final ids = [for (final item in itemsToDismiss) item.id];
    await ref.read(needsReviewRepositoryProvider).removeAll(ids);
    ref.invalidate(commitmentsProvider);
    ref.invalidate(needsReviewItemsProvider);
    ref.invalidate(needsReviewCountProvider);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<List<NeedsReviewItem>>>(needsReviewItemsProvider, (
      previous,
      next,
    ) {
      final items = next.valueOrNull;
      if (items == null) return;
      final hadActive =
          previous?.valueOrNull?.any(
            (item) =>
                item.aiStatus == AiReviewStatus.queued ||
                item.aiStatus == AiReviewStatus.processing,
          ) ??
          false;
      final hasActive = items.any(
        (item) =>
            item.aiStatus == AiReviewStatus.queued ||
            item.aiStatus == AiReviewStatus.processing,
      );
      if (hasActive) _hasObservedAiReviewRun = true;
      if (hadActive && !hasActive && _hasObservedAiReviewRun) {
        _hasObservedAiReviewRun = false;
        setState(() => _showAiReviewCompleted = true);
      }
      if (hasActive && !hadActive) {
        ref.read(smsFlushTriggerProvider.notifier).state++;
      }
    });

    final items = ref.watch(needsReviewItemsProvider);
    final pendingItems = items.valueOrNull ?? const <NeedsReviewItem>[];
    final retryableAiCount = pendingItems.where(_canRetryAiReview).length;
    final queuedAiCount = pendingItems
        .where((item) => item.aiStatus == AiReviewStatus.queued)
        .length;
    final processingAiCount = pendingItems
        .where((item) => item.aiStatus == AiReviewStatus.processing)
        .length;
    final activeAiCount = queuedAiCount + processingAiCount;
    final failedAiCount = pendingItems
        .where((item) => item.aiStatus == AiReviewStatus.unavailable)
        .length;
    final checkedNeedsReviewCount = pendingItems
        .where((item) => item.aiStatus == AiReviewStatus.checked)
        .length;
    final notQueuedAiCount = pendingItems
        .where((item) => item.aiStatus == AiReviewStatus.notChecked)
        .length;
    final autoCount = ref.watch(autoResolvedCountProvider).valueOrNull ?? 0;

    final sortedList = List<NeedsReviewItem>.from(pendingItems)
      ..sort((a, b) {
        final byDate = b.receivedAt.compareTo(a.receivedAt);
        return byDate != 0 ? byDate : a.id.compareTo(b.id);
      });

    final monthMap = <String, ({String label, int count, DateTime date})>{};
    for (final item in sortedList) {
      final key =
          '${item.receivedAt.year}-${item.receivedAt.month.toString().padLeft(2, '0')}';
      final current = monthMap[key];
      if (current == null) {
        monthMap[key] = (
          label: DateFormat('MMM yyyy').format(item.receivedAt),
          count: 1,
          date: DateTime(item.receivedAt.year, item.receivedAt.month),
        );
      } else {
        monthMap[key] = (
          label: current.label,
          count: current.count + 1,
          date: current.date,
        );
      }
    }

    final availableMonths =
        monthMap.entries
            .map(
              (e) => _MonthEntry(
                key: e.key,
                label: e.value.label,
                count: e.value.count,
                date: e.value.date,
              ),
            )
            .toList()
          ..sort((a, b) => b.date.compareTo(a.date));

    final filteredList = sortedList.where((item) {
      if (_customDateRange != null) {
        final date = item.receivedAt;
        final start = _customDateRange!.start;
        final end = _customDateRange!.end;
        final rangeStart = DateTime(start.year, start.month, start.day);
        final rangeEndExclusive = DateTime(end.year, end.month, end.day + 1);
        if (date.isBefore(rangeStart) || !date.isBefore(rangeEndExclusive)) {
          return false;
        }
      }
      if (_selectedMonth != null) {
        final itemMonthKey =
            '${item.receivedAt.year}-${item.receivedAt.month.toString().padLeft(2, '0')}';
        if (itemMonthKey != _selectedMonth) return false;
      }
      if (_selectedCategory != _ReviewFilterCategory.all) {
        if (_categorizeItem(item) != _selectedCategory) return false;
      }
      return true;
    }).toList();

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Needs review',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
        actions: [
          if (_selectedTab == 0 &&
              pendingItems.isNotEmpty &&
              filteredList.isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: BambooInk.ink900),
              onPressed: () => _dismissItems(
                filteredList,
                totalPendingCount: pendingItems.length,
              ),
              child: Text(
                filteredList.length < pendingItems.length
                    ? 'Dismiss filtered (${filteredList.length})'
                    : 'Dismiss all',
              ),
            ),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            _buildTabSelector(pendingItems.length, autoCount),
            if (_selectedTab == 0 &&
                (_retryingAiReviews || activeAiCount > 0 || failedAiCount > 0))
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  0,
                  AppSpace.lg,
                  AppSpace.sm,
                ),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpace.sm),
                  decoration: BoxDecoration(
                    color: BambooInk.paper,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: BambooInk.hairlineOnPaper),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _retryingAiReviews
                            ? 'Sending $retryableAiCount failed message${retryableAiCount == 1 ? '' : 's'} for AI review…'
                            : activeAiCount > 0
                                ? 'AI is reviewing $activeAiCount message${activeAiCount == 1 ? '' : 's'}'
                                : 'AI review paused · ${pendingItems.length} need review',
                        style: BambooFonts.ui(
                          12.5,
                          weight: FontWeight.w700,
                          color: BambooInk.ink900,
                        ),
                      ),
                      if (!_retryingAiReviews) ...[
                        const SizedBox(height: 2),
                        Text(
                          '$queuedAiCount queued · $processingAiCount in progress · $failedAiCount failed',
                          style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                        ),
                        Text(
                          '$checkedNeedsReviewCount checked, still need review · $notQueuedAiCount not queued',
                          style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                        ),
                      ],
                      if (_retryingAiReviews || activeAiCount > 0) ...[
                        const SizedBox(height: AppSpace.xs),
                        const LinearProgressIndicator(minHeight: 3),
                      ],
                    ],
                  ),
                ),
              ),
            if (_selectedTab == 0 &&
                !_retryingAiReviews &&
                activeAiCount == 0 &&
                _showAiReviewCompleted)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  0,
                  AppSpace.lg,
                  AppSpace.sm,
                ),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.sm,
                    vertical: AppSpace.xs,
                  ),
                  decoration: BoxDecoration(
                    color: BambooInk.paper,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: BambooInk.hairlineOnPaper),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check_circle_outline_rounded,
                        size: 17,
                        color: BambooInk.jade,
                      ),
                      const SizedBox(width: AppSpace.xs),
                      Expanded(
                        child: Text(
                          'AI review finished. Auto-resolved results are in Auto-Resolved; undecided messages remain here.',
                          style: BambooFonts.ui(11.5, color: BambooInk.ink700),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Dismiss status',
                        onPressed: () =>
                            setState(() => _showAiReviewCompleted = false),
                        icon: const Icon(Icons.close_rounded, size: 17),
                      ),
                    ],
                  ),
                ),
              ),
            if (_selectedTab == 0 && retryableAiCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  0,
                  AppSpace.lg,
                  AppSpace.sm,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _retryingAiReviews
                        ? null
                        : () => _retryFailedAiReviews(pendingItems),
                    icon: _retryingAiReviews
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    label: Text(
                      _retryingAiReviews
                          ? 'Retrying failed AI reviews…'
                          : 'Retry failed AI reviews ($retryableAiCount)',
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _selectedTab == 1
                  ? _buildAutoResolvedTab()
                  : items.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (err, _) =>
                          ErrorState(message: userFacingErrorMessage(err)),
                      data: (list) {
                        if (list.isEmpty) {
                          return const EmptyState(
                            icon: Icons.mark_email_read_outlined,
                            title: 'Nothing needs review',
                            message:
                                'Messages we couldn\'t automatically parse show up here — nothing is ever dropped silently.',
                          );
                        }

                        return Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                vertical: AppSpace.sm,
                              ),
                              decoration: const BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: BambooInk.hairlineOnPaper,
                                  ),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppSpace.lg,
                                    ),
                                    child: Row(
                                      children: [
                                        _FilterChip(
                                          label: 'All time',
                                          selected:
                                              _selectedMonth == null &&
                                              _customDateRange == null,
                                          onTap: () => setState(() {
                                            _selectedMonth = null;
                                            _selectedMonthLabel = null;
                                            _customDateRange = null;
                                          }),
                                        ),
                                        const SizedBox(width: AppSpace.xs),
                                        _FilterChip(
                                          label: _customDateRange == null
                                              ? 'Custom'
                                              : '${DateFormat(_customDateRange!.start.year == _customDateRange!.end.year ? 'd MMM' : 'd MMM yy').format(_customDateRange!.start)}–${DateFormat('d MMM yy').format(_customDateRange!.end)}',
                                          selected: _customDateRange != null,
                                          onTap: _chooseCustomDateRange,
                                        ),
                                        for (final m in availableMonths) ...[
                                          const SizedBox(width: AppSpace.xs),
                                          _FilterChip(
                                            label: '${m.label} (${m.count})',
                                            selected: _selectedMonth == m.key,
                                            onTap: () => setState(() {
                                              _selectedMonth = m.key;
                                              _selectedMonthLabel = m.label;
                                              _customDateRange = null;
                                            }),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: AppSpace.xs),
                                  SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppSpace.lg,
                                    ),
                                    child: Row(
                                      children: [
                                        for (
                                          int i = 0;
                                          i <
                                              _ReviewFilterCategory
                                                  .values
                                                  .length;
                                          i++
                                        ) ...[
                                          if (i > 0)
                                            const SizedBox(width: AppSpace.xs),
                                          _FilterChip(
                                            label: _ReviewFilterCategory
                                                .values[i]
                                                .label,
                                            selected:
                                                _selectedCategory ==
                                                _ReviewFilterCategory.values[i],
                                            onTap: () => setState(() {
                                              _selectedCategory =
                                                  _ReviewFilterCategory
                                                      .values[i];
                                            }),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: filteredList.isEmpty
                                  ? EmptyState(
                                      icon: Icons.filter_alt_off_outlined,
                                      title: _selectedMonthLabel != null
                                          ? 'No review items in $_selectedMonthLabel'
                                          : _customDateRange != null
                                          ? 'No review items in selected dates'
                                          : 'No review items in ${_selectedCategory.label}',
                                      message:
                                          'Try changing your date or type filter.',
                                    )
                                  : RefreshIndicator(
                                      onRefresh: () async {
                                        ref
                                            .read(
                                              smsFlushTriggerProvider.notifier,
                                            )
                                            .state++;
                                        ref.invalidate(
                                          needsReviewItemsProvider,
                                        );
                                        try {
                                          await ref.read(
                                            needsReviewItemsProvider.future,
                                          );
                                        } catch (_) {}
                                        await Future.delayed(
                                          const Duration(milliseconds: 600),
                                        );
                                      },
                                      child: Builder(
                                        builder: (context) {
                                          final groups = clusterReviewItems(
                                            filteredList,
                                          );
                                          return ListView.builder(
                                            padding: const EdgeInsets.all(
                                              AppSpace.lg,
                                            ),
                                            itemCount: groups.length,
                                            itemBuilder: (context, index) {
                                              final group = groups[index];
                                              return Padding(
                                                key: ValueKey(switch (group) {
                                                  BundleReviewGroup(
                                                    :final key,
                                                  ) =>
                                                    'bundle_$key',
                                                  SingleReviewGroup(
                                                    :final item,
                                                  ) =>
                                                    item.id,
                                                }),
                                                padding: const EdgeInsets.only(
                                                  bottom: AppSpace.md,
                                                ),
                                                child: switch (group) {
                                                  BundleReviewGroup() =>
                                                    _ReviewBundleCard(
                                                      group: group,
                                                    ),
                                                  SingleReviewGroup(
                                                    :final item,
                                                  ) =>
                                                    item.kind ==
                                                            NeedsReviewKind
                                                                .commitment
                                                        ? _CommitmentNeedsReviewTile(
                                                            item,
                                                          )
                                                        : _NeedsReviewTile(
                                                            item,
                                                          ),
                                                },
                                              );
                                            },
                                          );
                                        },
                                      ),
                                    ),
                            ),
                          ],
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

class _AutoResolvedCard extends ConsumerStatefulWidget {
  final AutoResolvedHistoryEntry entry;
  const _AutoResolvedCard(this.entry);

  @override
  ConsumerState<_AutoResolvedCard> createState() => _AutoResolvedCardState();
}

class _AutoResolvedCardState extends ConsumerState<_AutoResolvedCard> {
  bool _busy = false;
  bool _showSourceSms = false;

  String _dateLabel(AutoResolvedHistoryEntry entry) {
    final showDue =
        entry.resolvedKind == 'bill' &&
        entry.dueDate != null &&
        entry.dueDate!.isNotEmpty;
    final raw = showDue ? entry.dueDate! : entry.occurredAt;
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return showDue ? 'Due $raw' : raw;
    final formatted = DateFormat('MMM d, yyyy').format(parsed);
    return showDue ? 'Due $formatted' : 'On $formatted';
  }

  Future<void> _changeCategory() async {
    final categories = smsSpendCategories.toList(growable: false);
    final slug = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.sm,
                AppSpace.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Change category',
                      style: BambooFonts.heading(17, color: BambooInk.ink900),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: AppSpace.lg),
                itemCount: categories.length,
                itemBuilder: (context, index) {
                  final categorySlug = categories[index];
                  return ListTile(
                    title: Text(
                      LocalSmsParser.categoryDisplayName(categorySlug) ??
                          categorySlug,
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                    ),
                    trailing: widget.entry.categorySlug == categorySlug
                        ? const Icon(Icons.check_rounded, color: BambooInk.jade)
                        : null,
                    onTap: () => Navigator.of(context).pop(categorySlug),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (slug == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(smsAutoResolutionControllerProvider)
          .changeCategory(widget.entry, slug);
      ref.invalidate(autoResolvedHistoryProvider);
      ref.invalidate(autoResolvedCountProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editTransaction() async {
    final result = await showModalBottomSheet<_AutoResolvedEditResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (_) => _AutoResolvedEditSheet(entry: widget.entry),
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(smsAutoResolutionControllerProvider)
          .editTransaction(
            widget.entry,
            merchantName: result.merchantName,
            amount: result.amount,
            occurredAt: result.occurredAt,
          );
      ref.invalidate(autoResolvedHistoryProvider);
      ref.invalidate(autoResolvedCountProvider);
      ref.invalidate(transactionsProvider);
      ref.invalidate(homeSummaryProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _moveToReview() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(smsAutoResolutionControllerProvider)
          .moveToReview(widget.entry);
      ref.invalidate(autoResolvedHistoryProvider);
      ref.invalidate(autoResolvedCountProvider);
      ref.invalidate(needsReviewItemsProvider);
      ref.invalidate(needsReviewCountProvider);
      ref.invalidate(commitmentsProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Moved to Needs Review')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final isDismissed = entry.resolvedKind == 'dismissed';
    final displayTitle = entry.title.replaceFirst(
      RegExp(r'^gemini dismissed\s*·\s*', caseSensitive: false),
      'AI dismissed · ',
    );
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.auto_awesome_rounded, color: BambooInk.jade),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayTitle,
                      style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isDismissed
                          ? '✦ AI decision · Dismissed'
                          : '✦ Auto-Categorized by AI · ${entry.categoryName}',
                      style: BambooFonts.ui(
                        12.5,
                        weight: FontWeight.w600,
                        color: BambooInk.jade,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _dateLabel(entry),
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              if (!isDismissed)
                Text(
                  entry.amount.format(),
                  style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                ),
            ],
          ),
          if (entry.sourceBody?.trim().isNotEmpty == true) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: BambooFonts.ui(12.5, weight: FontWeight.w700),
                ),
                onPressed: () => setState(() {
                  _showSourceSms = !_showSourceSms;
                }),
                icon: Icon(
                  _showSourceSms
                      ? Icons.expand_less_rounded
                      : Icons.sms_outlined,
                  size: 18,
                ),
                label: Text(
                  _showSourceSms ? 'Hide original SMS' : 'View original SMS',
                ),
              ),
            ),
            if (_showSourceSms)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: BambooInk.paperMuted,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SMS from ${entry.sender}',
                      style: BambooFonts.ui(
                        11.5,
                        weight: FontWeight.w700,
                        color: BambooInk.ink500,
                      ),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      entry.sourceBody!,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink700),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: AppSpace.xs),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              if (entry.resolvedKind == 'transaction')
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: BambooFonts.ui(12.5, weight: FontWeight.w700),
                  ),
                  onPressed: _busy ? null : _editTransaction,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit transaction'),
                ),
              if (!isDismissed)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: BambooFonts.ui(12.5, weight: FontWeight.w700),
                  ),
                  onPressed: _busy ? null : _changeCategory,
                  child: const Text('Change Category'),
                ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: BambooFonts.ui(12.5, weight: FontWeight.w700),
                ),
                onPressed: _busy ? null : _moveToReview,
                child: Text(
                  isDismissed ? 'Review this decision' : 'Move to Review',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AutoResolvedEditResult {
  final String merchantName;
  final Money amount;
  final DateTime occurredAt;

  const _AutoResolvedEditResult({
    required this.merchantName,
    required this.amount,
    required this.occurredAt,
  });
}

class _AutoResolvedEditSheet extends StatefulWidget {
  final AutoResolvedHistoryEntry entry;

  const _AutoResolvedEditSheet({required this.entry});

  @override
  State<_AutoResolvedEditSheet> createState() => _AutoResolvedEditSheetState();
}

class _AutoResolvedEditSheetState extends State<_AutoResolvedEditSheet> {
  late final TextEditingController _merchantController;
  late final TextEditingController _amountController;
  late DateTime _occurredAt;
  String? _error;

  @override
  void initState() {
    super.initState();
    _merchantController = TextEditingController(text: widget.entry.title);
    _amountController = TextEditingController(
      text: widget.entry.amount.rupees.toStringAsFixed(2),
    );
    _occurredAt =
        DateTime.tryParse(widget.entry.occurredAt)?.toLocal() ?? DateTime.now();
  }

  @override
  void dispose() {
    _merchantController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _chooseDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 2),
      helpText: 'Choose transaction date',
    );
    if (picked != null && mounted) setState(() => _occurredAt = picked);
  }

  void _save() {
    final merchant = _merchantController.text.trim();
    final amount = double.tryParse(_amountController.text.trim());
    if (merchant.isEmpty) {
      setState(() => _error = 'Enter a merchant or biller.');
      return;
    }
    if (amount == null || !amount.isFinite || amount <= 0) {
      setState(() => _error = 'Enter a valid amount greater than zero.');
      return;
    }
    Navigator.of(context).pop(
      _AutoResolvedEditResult(
        merchantName: merchant,
        amount: Money.fromRupees(amount),
        occurredAt: _occurredAt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      AppSpace.lg,
      AppSpace.lg,
      AppSpace.lg,
      MediaQuery.viewInsetsOf(context).bottom + AppSpace.lg,
    ),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Edit transaction', style: BambooFonts.heading(18)),
          const SizedBox(height: AppSpace.md),
          TextField(
            controller: _merchantController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Merchant or biller'),
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount (₹)'),
          ),
          const SizedBox(height: AppSpace.sm),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Transaction date'),
            subtitle: Text(DateFormat('MMM d, yyyy').format(_occurredAt)),
            trailing: const Icon(Icons.calendar_month_outlined),
            onTap: _chooseDate,
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpace.xs),
            Text(_error!, style: BambooFonts.ui(12.5, color: Colors.red)),
          ],
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _CommitmentNeedsReviewTile extends ConsumerStatefulWidget {
  final NeedsReviewItem item;
  const _CommitmentNeedsReviewTile(this.item);

  @override
  ConsumerState<_CommitmentNeedsReviewTile> createState() =>
      _CommitmentNeedsReviewTileState();
}

class _CommitmentNeedsReviewTileState
    extends ConsumerState<_CommitmentNeedsReviewTile> {
  bool _busy = false;

  LocalSmsObservation? _parse() => LocalSmsParser.parse(
    namespace: ref.read(cacheNamespaceProvider),
    sender: widget.item.sender,
    body: widget.item.body,
    receivedAt: widget.item.receivedAt,
  );

  Future<void> _dismiss() async {
    setState(() => _busy = true);
    try {
      await _persistCommitmentDismissal(ref, widget.item);
      ref.invalidate(commitmentsProvider);
      // Immediate optimistic UI dismissal: remove and invalidate before background sync
      await ref.read(needsReviewRepositoryProvider).remove(widget.item.id);
      ref.invalidate(needsReviewItemsProvider);
      ref.invalidate(needsReviewCountProvider);
      final repo = ref.read(userCardsRepositoryProvider);
      if (repo != null) {
        repo
            .dismissSms(
              sourceKey: _feedbackSourceKey(widget.item.id),
              sender: widget.item.sender,
              sampleBody: widget.item.body,
              reason: 'user_dismissed',
              family: 'ignore_noise',
            )
            .ignore();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveCommitment(_BillReviewResult result) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(commitmentsRepositoryProvider)
          .save(
            Commitment(
              id: 'review-${widget.item.id}',
              title: result.title,
              category: result.category,
              amount: result.amount,
              dueOn: result.dueOn,
              identifier: result.identifier,
              cadence: result.cadence,
              source: CommitmentSource.sms,
              isUserConfirmed: true,
              confidence: 1,
            ),
          );
      await ref.read(needsReviewRepositoryProvider).remove(widget.item.id);
      ref.invalidate(commitmentsProvider);
      ref.invalidate(needsReviewItemsProvider);
      ref.invalidate(needsReviewCountProvider);
      // Phase 4: the confirmed decision also rides the typed-fact contract.
      // A structured override (source key + fact index + payload patch, no
      // raw text) makes the server's bill projection agree with the user
      // even if a later replay re-uploads the parser-derived payload — the
      // read path always applies user corrections first.
      await _overrideConfirmedBillFacts(ref, result);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _archivePastPremiumNotice() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(needsReviewRepositoryProvider)
          .archivePastPremiumNotice(widget.item);
      ref.invalidate(needsReviewItemsProvider);
      ref.invalidate(needsReviewCountProvider);
      ref.invalidate(pastBillReceiptsProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Best-effort structured correction for the source this review item came
  /// from (`commitment:<sourceKey>`). Never blocks the local save: a 404
  /// (facts are not on the server yet) or any network failure leaves the
  /// correction for a future sync — the local decision is already durable.
  Future<void> _overrideConfirmedBillFacts(
    WidgetRef ref,
    _BillReviewResult result,
  ) async {
    if (!widget.item.id.startsWith('commitment:')) return;
    final sourceKey = widget.item.id.substring('commitment:'.length);
    if (sourceKey.length != 64) return;
    final observation = _parse();
    if (observation == null) return;
    final facts = buildSmsFactsForObservation(
      body: widget.item.body,
      observation: observation,
      receivedAt: widget.item.receivedAt,
    );
    final billFact = facts
        .where((fact) => fact.payload['amountRole'] == 'due_total')
        .firstOrNull;
    if (billFact == null) return;
    final patch = <String, dynamic>{
      'dueDate': result.dueOn.toUtc().toIso8601String(),
      if (result.amount != null) 'amountDueInr': result.amount!.rupees,
    };
    await _persistSmsFactCorrection(
      ref,
      sourceKey: sourceKey,
      factIndex: billFact.factIndex ?? 0,
      patch: patch,
      reason: 'confirmed in needs review',
    );
    ref.invalidate(needsReviewItemsProvider);
  }

  Future<void> _reviewAndSaveCommitment() async {
    final result = await showModalBottomSheet<_BillReviewResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _ReviewBillSheet(
        item: widget.item,
        parsed: _parse(),
        onDiscard: _dismiss,
      ),
    );
    if (result == null || !mounted) return;
    await _saveCommitment(result);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final parsed = _parse();
    final nextPremiumMonth = LocalSmsParser.nextPremiumDueMonth(item.body);
    final monthOnlyPremium =
        parsed?.reasonCodes.contains('next_premium_due_month_only') == true;
    final pastPremiumNotice =
        monthOnlyPremium &&
        nextPremiumMonth != null &&
        DateTime(
          nextPremiumMonth.year,
          nextPremiumMonth.month,
        ).isBefore(DateTime(DateTime.now().year, DateTime.now().month));
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_outlined, color: BambooInk.jade),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  'Possible bill or renewal',
                  style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                ),
              ),
              IconButton(
                tooltip: 'Dismiss message',
                onPressed: _busy ? null : _dismiss,
                icon: const Icon(Icons.close_rounded),
                color: BambooInk.ink500,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            item.sender,
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: 2),
          Text(
            DateFormat(
              'MMM d, yyyy • h:mm a',
            ).format(item.receivedAt.toLocal()),
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
          if (item.aiSuggestions?.isNotEmpty == true ||
              item.aiTopic?.trim().isNotEmpty == true ||
              (item.aiDecision?['topic'] is String &&
                  (item.aiDecision!['topic'] as String).trim().isNotEmpty)) ...[
            const SizedBox(height: AppSpace.xs),
            _AiBadge(summary: _aiSuggestedSummary(item)),
          ],
          const SizedBox(height: AppSpace.sm),
          Container(
            padding: const EdgeInsets.all(AppSpace.sm),
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              item.body,
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
          if (monthOnlyPremium && nextPremiumMonth != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              pastPremiumNotice
                  ? 'Next premium was due ${DateFormat('MMMM yyyy').format(nextPremiumMonth)}. This notice will be archived without assuming payment.'
                  : 'Next premium is due in ${DateFormat('MMMM yyyy').format(nextPremiumMonth)}. Choose the exact day before saving.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ] else if (item.reason != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              'Needs confirmation: ${humanizeIdentifier(item.reason)}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              // Intrinsic width, so the longer primary label keeps one line.
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: BambooInk.ink900,
                  side: const BorderSide(color: BambooInk.hairlineOnPaper),
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                ),
                onPressed: _busy ? null : _dismiss,
                child: const Text('Not a bill'),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size.fromHeight(44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                  ),
                  onPressed: _busy
                      ? null
                      : pastPremiumNotice
                      ? _archivePastPremiumNotice
                      : _reviewAndSaveCommitment,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: BambooInk.lime,
                          ),
                        )
                      : Text(
                          pastPremiumNotice
                              ? 'Archive past notice'
                              : monthOnlyPremium
                              ? 'Review reminder'
                              : 'Save bill',
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReviewBillSheet extends ConsumerStatefulWidget {
  final NeedsReviewItem item;
  final LocalSmsObservation? parsed;
  final Map<String, dynamic>? suggestionFact;
  final Future<void> Function() onDiscard;

  const _ReviewBillSheet({
    required this.item,
    this.parsed,
    this.suggestionFact,
    required this.onDiscard,
  });

  @override
  ConsumerState<_ReviewBillSheet> createState() => _ReviewBillSheetState();
}

class _ReviewBillSheetState extends ConsumerState<_ReviewBillSheet> {
  late final TextEditingController _titleController;
  late final TextEditingController _amountController;
  late final TextEditingController _identifierController;
  late CommitmentCategory _category;
  late CommitmentCadence _cadence;
  DateTime? _dueOn;

  @override
  void initState() {
    super.initState();
    final parsed = widget.parsed;
    final payload = widget.suggestionFact?['payload'] as Map<String, dynamic>?;
    final suggestedTitle =
        parsed?.billerName?.trim() ??
        (payload?['billerName'] as String?)?.trim();
    _titleController = TextEditingController(
      text: suggestedTitle?.isNotEmpty == true
          ? suggestedTitle!
          : widget.item.sender,
    );
    final amtPaise =
        parsed?.amountDue?.paise ??
        (payload?['amountDueInr'] is num
            ? ((payload!['amountDueInr'] as num) * 100).round()
            : null) ??
        (payload?['minimumDueInr'] is num
            ? ((payload!['minimumDueInr'] as num) * 100).round()
            : null);
    _amountController = TextEditingController(
      text: amtPaise == null ? '' : (amtPaise / 100).toStringAsFixed(2),
    );
    final last4 =
        parsed?.accountLast4 ??
        parsed?.cardLast4 ??
        (payload?['last4'] as String?);
    _identifierController = TextEditingController(
      text: last4 == null || last4.isEmpty ? '' : '••••$last4',
    );
    _category = CommitmentCategory.fromText(
      '${_titleController.text} ${widget.item.sender}',
    );
    _cadence = switch (parsed?.cadenceHint ?? payload?['cadence']) {
      'quarterly' => CommitmentCadence.quarterly,
      'halfYearly' => CommitmentCadence.halfYearly,
      'annual' => CommitmentCadence.annual,
      _ =>
        _category == CommitmentCategory.insurance
            ? CommitmentCadence.annual
            : CommitmentCadence.monthly,
    };
    final dueStr = payload?['dueDate'] as String?;
    final monthOnlyPremium =
        parsed?.reasonCodes.contains('next_premium_due_month_only') == true;
    _dueOn = monthOnlyPremium
        ? null
        : parsed?.dueDate ??
              (dueStr != null ? DateTime.tryParse(dueStr) : null);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _identifierController.dispose();
    super.dispose();
  }

  InputDecoration _inputDecoration(String label) => InputDecoration(
    labelText: label,
    labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
    filled: true,
    fillColor: BambooInk.glassFillOnPaper,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
    ),
  );

  String _dateLabel(DateTime? date) {
    if (date == null) return 'Select due date';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueOn ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _dueOn = picked);
  }

  void _save() {
    final title = _titleController.text.trim();
    final dueOn = _dueOn;
    final amountText = _amountController.text.trim().replaceAll(',', '');
    final amountValue = amountText.isEmpty ? null : double.tryParse(amountText);
    if (title.isEmpty ||
        dueOn == null ||
        (amountText.isNotEmpty &&
            (amountValue == null ||
                !amountValue.isFinite ||
                amountValue <= 0 ||
                amountValue > 9999999999.99))) {
      return;
    }
    final identifier = _identifierController.text.trim();
    Navigator.of(context).pop((
      title: title,
      amount: amountValue == null ? null : Money.fromRupees(amountValue),
      dueOn: dueOn,
      category: _category,
      cadence: _cadence,
      identifier: identifier.isEmpty ? null : identifier,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final nextPremiumMonth = LocalSmsParser.nextPremiumDueMonth(
      widget.item.body,
    );
    final amountText = _amountController.text.trim().replaceAll(',', '');
    final amountValue = amountText.isEmpty ? null : double.tryParse(amountText);
    final canSave =
        _titleController.text.trim().isNotEmpty &&
        _dueOn != null &&
        (amountText.isEmpty ||
            (amountValue != null &&
                amountValue.isFinite &&
                amountValue > 0 &&
                amountValue <= 9999999999.99));
    return Container(
      decoration: const BoxDecoration(
        color: BambooInk.paper,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      padding: EdgeInsets.only(
        left: AppSpace.lg,
        right: AppSpace.lg,
        top: AppSpace.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.receipt_long_outlined, color: BambooInk.jade),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'Review bill details',
                    style: BambooFonts.heading(17, color: BambooInk.ink900),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              'Check the suggestions from this SMS. Nothing is saved until you tap Save bill.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            Container(
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                color: BambooInk.paperMuted,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                widget.item.body,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _titleController,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: _inputDecoration('Bill or payee name'),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: _inputDecoration('Amount due (optional)'),
            ),
            const SizedBox(height: AppSpace.lg),
            InkWell(
              onTap: _pickDueDate,
              borderRadius: BorderRadius.circular(16),
              child: InputDecorator(
                decoration: _inputDecoration('Due date'),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _dateLabel(_dueOn),
                        style: BambooFonts.ui(
                          14.5,
                          color: _dueOn == null
                              ? BambooInk.ink500
                              : BambooInk.ink900,
                        ),
                      ),
                    ),
                    const Icon(Icons.calendar_today_outlined, size: 19),
                  ],
                ),
              ),
            ),
            if (nextPremiumMonth != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                'The SMS gives only ${DateFormat('MMMM yyyy').format(nextPremiumMonth)}, not an exact day. Select the verified day before saving; PandaPay will not assume the earlier premium was paid.',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            DropdownButtonFormField<CommitmentCategory>(
              initialValue: _category,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: _inputDecoration('Category'),
              items: [
                for (final category in CommitmentCategory.values)
                  DropdownMenuItem(
                    value: category,
                    child: Text(category.label),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _category = value);
              },
            ),
            const SizedBox(height: AppSpace.lg),
            DropdownButtonFormField<CommitmentCadence>(
              initialValue: _cadence,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: _inputDecoration('Repeats'),
              items: [
                for (final cadence in CommitmentCadence.values)
                  DropdownMenuItem(value: cadence, child: Text(cadence.label)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _cadence = value);
              },
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _identifierController,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: _inputDecoration('Account or card (optional)'),
            ),
            const SizedBox(height: AppSpace.xl),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                disabledBackgroundColor: BambooInk.paperMuted,
                disabledForegroundColor: BambooInk.ink500,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
              ),
              onPressed: canSave ? _save : null,
              child: const Text('Save bill'),
            ),
            const SizedBox(height: AppSpace.sm),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await widget.onDiscard();
              },
              child: const Text('Discard message — not a bill'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewBalanceSheet extends ConsumerStatefulWidget {
  final NeedsReviewItem item;
  final Map<String, dynamic>? fact;

  const _ReviewBalanceSheet({required this.item, this.fact});

  @override
  ConsumerState<_ReviewBalanceSheet> createState() =>
      _ReviewBalanceSheetState();
}

class _ReviewBalanceSheetState extends ConsumerState<_ReviewBalanceSheet> {
  late final TextEditingController _balanceController;
  late final TextEditingController _accountController;
  late DateTime _asOfAt;

  @override
  void initState() {
    super.initState();
    final payload = widget.fact?['payload'] as Map<String, dynamic>?;
    final balance = payload?['availableBalanceInr'];
    _balanceController = TextEditingController(
      text: balance is num && balance.isFinite
          ? balance.toStringAsFixed(2)
          : '',
    );
    final account = payload?['accountLast4'] as String?;
    _accountController = TextEditingController(
      text: account != null && account.isNotEmpty ? account : '',
    );
    final asOfStr = payload?['asOfAt'] as String?;
    _asOfAt =
        (asOfStr != null ? DateTime.tryParse(asOfStr) : null) ??
        widget.item.receivedAt;
  }

  @override
  void dispose() {
    _balanceController.dispose();
    _accountController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _asOfAt,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _asOfAt = picked);
  }

  void _confirm() {
    final balText = _balanceController.text.trim().replaceAll(',', '');
    final balValue = double.tryParse(balText);
    if (balValue == null ||
        !balValue.isFinite ||
        balValue < 0 ||
        balValue > 9999999999.99) {
      return;
    }
    final acct = _accountController.text.trim().replaceAll(
      RegExp(r'[^\d]'),
      '',
    );
    Navigator.of(context).pop((
      balance: balValue,
      accountLast4: acct.length >= 4
          ? acct.substring(acct.length - 4)
          : (acct.isEmpty ? null : acct),
      asOfAt: _asOfAt,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final balText = _balanceController.text.trim().replaceAll(',', '');
    final balValue = double.tryParse(balText);
    final canConfirm =
        balValue != null &&
        balValue.isFinite &&
        balValue >= 0 &&
        balValue <= 9999999999.99;

    return Container(
      decoration: const BoxDecoration(
        color: BambooInk.paper,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      padding: EdgeInsets.only(
        left: AppSpace.lg,
        right: AppSpace.lg,
        top: AppSpace.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.account_balance_outlined,
                  color: BambooInk.jade,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'Confirm bank balance',
                    style: BambooFonts.heading(17, color: BambooInk.ink900),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              'Confirm or correct the balance detected in this message.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            Container(
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                color: BambooInk.paperMuted,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                widget.item.body,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _balanceController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: InputDecoration(
                labelText: 'Available balance (₹)',
                prefixText: '₹ ',
                filled: true,
                fillColor: BambooInk.glassFillOnPaper,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _accountController,
              keyboardType: TextInputType.number,
              maxLength: 4,
              onChanged: (_) => setState(() {}),
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: InputDecoration(
                labelText: 'Account last 4 digits (optional)',
                counterText: '',
                filled: true,
                fillColor: BambooInk.glassFillOnPaper,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(16),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'As of date',
                  filled: true,
                  fillColor: BambooInk.glassFillOnPaper,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_asOfAt.day.toString().padLeft(2, '0')}/${_asOfAt.month.toString().padLeft(2, '0')}/${_asOfAt.year}',
                        style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      ),
                    ),
                    const Icon(Icons.calendar_today_outlined, size: 19),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
              ),
              onPressed: canConfirm ? _confirm : null,
              child: const Text('Confirm balance'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewMandateSheet extends ConsumerStatefulWidget {
  final NeedsReviewItem item;
  final Map<String, dynamic>? fact;

  const _ReviewMandateSheet({required this.item, this.fact});

  @override
  ConsumerState<_ReviewMandateSheet> createState() =>
      _ReviewMandateSheetState();
}

class _ReviewMandateSheetState extends ConsumerState<_ReviewMandateSheet> {
  late final TextEditingController _titleController;
  late final TextEditingController _amountController;
  late final TextEditingController _identifierController;
  CommitmentCadence _cadence = CommitmentCadence.monthly;
  DateTime _dueOn = DateTime.now();

  @override
  void initState() {
    super.initState();
    final payload = widget.fact?['payload'] as Map<String, dynamic>?;
    final name = payload?['mandateName'] as String?;
    _titleController = TextEditingController(
      text: name != null && name.trim().isNotEmpty
          ? name.trim()
          : widget.item.sender,
    );
    final limit = payload?['limitInr'] ?? payload?['amountLimitInr'];
    _amountController = TextEditingController(
      text: limit is num && limit.isFinite ? limit.toStringAsFixed(2) : '',
    );
    final last4 = payload?['last4'] as String?;
    _identifierController = TextEditingController(
      text: last4 != null && last4.isNotEmpty ? '••••$last4' : '',
    );
    final cadenceStr = payload?['cadence'] as String?;
    _cadence = switch (cadenceStr) {
      'quarterly' => CommitmentCadence.quarterly,
      'halfYearly' => CommitmentCadence.halfYearly,
      'annual' => CommitmentCadence.annual,
      _ => CommitmentCadence.monthly,
    };
    final asOfStr =
        payload?['asOfAt'] as String? ?? payload?['startDate'] as String?;
    _dueOn =
        (asOfStr != null ? DateTime.tryParse(asOfStr) : null) ??
        widget.item.receivedAt;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _identifierController.dispose();
    super.dispose();
  }

  void _confirm() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    final amtText = _amountController.text.trim().replaceAll(',', '');
    final amtValue = amtText.isEmpty ? null : double.tryParse(amtText);
    if (amtText.isNotEmpty &&
        (amtValue == null ||
            !amtValue.isFinite ||
            amtValue < 0 ||
            amtValue > 9999999999.99)) {
      return;
    }
    final identifier = _identifierController.text.trim();
    Navigator.of(context).pop((
      title: title,
      amount: amtValue == null ? null : Money.fromRupees(amtValue),
      dueOn: _dueOn,
      category: CommitmentCategory.subscription,
      cadence: _cadence,
      identifier: identifier.isEmpty ? null : identifier,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final title = _titleController.text.trim();
    return Container(
      decoration: const BoxDecoration(
        color: BambooInk.paper,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      padding: EdgeInsets.only(
        left: AppSpace.lg,
        right: AppSpace.lg,
        top: AppSpace.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.autorenew_rounded, color: BambooInk.jade),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'Confirm AutoPay mandate',
                    style: BambooFonts.heading(17, color: BambooInk.ink900),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              'Confirm or edit the recurring mandate detected from this SMS.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            Container(
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                color: BambooInk.paperMuted,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                widget.item.body,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _titleController,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: InputDecoration(
                labelText: 'Mandate or service name',
                filled: true,
                fillColor: BambooInk.glassFillOnPaper,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: InputDecoration(
                labelText: 'Maximum limit (optional)',
                prefixText: '₹ ',
                filled: true,
                fillColor: BambooInk.glassFillOnPaper,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            DropdownButtonFormField<CommitmentCadence>(
              initialValue: _cadence,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: InputDecoration(
                labelText: 'Repeats',
                filled: true,
                fillColor: BambooInk.glassFillOnPaper,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              items: [
                for (final cadence in CommitmentCadence.values)
                  DropdownMenuItem(value: cadence, child: Text(cadence.label)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _cadence = value);
              },
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _identifierController,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: InputDecoration(
                labelText: 'Account or card (optional)',
                filled: true,
                fillColor: BambooInk.glassFillOnPaper,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
              ),
              onPressed: title.isNotEmpty ? _confirm : null,
              child: const Text('Confirm mandate'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NeedsReviewTile extends ConsumerStatefulWidget {
  final NeedsReviewItem item;
  const _NeedsReviewTile(this.item);

  @override
  ConsumerState<_NeedsReviewTile> createState() => _NeedsReviewTileState();
}

class _NeedsReviewTileState extends ConsumerState<_NeedsReviewTile> {
  bool _busy = false;

  Future<void> _dismissNotATransaction() async {
    setState(() => _busy = true);
    try {
      // Immediate optimistic UI dismissal: remove and invalidate before background sync
      await ref.read(needsReviewRepositoryProvider).remove(widget.item.id);
      ref.invalidate(needsReviewItemsProvider);
      ref.invalidate(needsReviewCountProvider);
      final repo = ref.read(userCardsRepositoryProvider);
      if (repo != null) {
        repo
            .dismissSms(
              sourceKey: _feedbackSourceKey(widget.item.id),
              sender: widget.item.sender,
              sampleBody: widget.item.body,
              reason: 'user_dismissed',
              family: 'ignore_noise',
            )
            .ignore();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resolveFactSuggestion(int factIndex) async {
    final current = widget.item.aiSuggestions ?? const [];
    final remaining = current
        .where((s) => s['factIndex'] != factIndex)
        .toList();
    if (remaining.isEmpty) {
      await ref.read(needsReviewRepositoryProvider).remove(widget.item.id);
    } else {
      await ref
          .read(needsReviewRepositoryProvider)
          .updateAiSuggestions(widget.item.id, remaining);
    }
    ref.invalidate(needsReviewItemsProvider);
    ref.invalidate(needsReviewCountProvider);
  }

  Future<void> _reviewMovement([Map<String, dynamic>? movementFact]) async {
    final fact =
        movementFact ??
        widget.item.aiSuggestions
            ?.where((suggestion) => suggestion['factType'] == 'posted_movement')
            .firstOrNull;
    final result =
        await showModalBottomSheet<
          ({
            String? cardId,
            double amount,
            String? categoryId,
            String? merchantName,
            DateTime occurredAt,
            TxnInstrument instrument,
            TxnEntryKind entryKind,
          })
        >(
          context: context,
          isScrollControlled: true,
          builder: (context) =>
              _FillFieldsSheet(item: widget.item, suggestionFact: fact),
        );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(userCardsRepositoryProvider)!
          .logTransaction(
            userCardId: result.cardId,
            amount: Money.fromRupees(result.amount),
            categoryId: result.categoryId,
            merchantName: result.merchantName,
            occurredAt: result.occurredAt,
            instrument: result.instrument,
            entryKind: result.entryKind,
          );
      final suggestedIndex = fact?['factIndex'];
      final factIdx = suggestedIndex is int && suggestedIndex >= 0
          ? suggestedIndex
          : 0;
      if (widget.item.id.length == 64) {
        await _persistSmsFactCorrection(
          ref,
          sourceKey: widget.item.id,
          factIndex: factIdx,
          patch: {
            'entryKind': result.entryKind.wireValue,
            'amountInr': result.amount,
            if (result.merchantName != null) 'merchant': result.merchantName,
            'instrument': result.instrument.wireValue,
            'occurredAt': result.occurredAt.toUtc().toIso8601String(),
            'amountRole': 'posted',
          },
          reason: 'confirmed in needs review',
          sampleBody: widget.item.body,
        );
      }
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      await _resolveFactSuggestion(factIdx);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewBalance([Map<String, dynamic>? balanceFact]) async {
    final fact =
        balanceFact ??
        widget.item.aiSuggestions
            ?.where((s) => s['factType'] == 'balance_snapshot')
            .firstOrNull;
    final result =
        await showModalBottomSheet<
          ({double balance, String? accountLast4, DateTime asOfAt})
        >(
          context: context,
          isScrollControlled: true,
          builder: (context) =>
              _ReviewBalanceSheet(item: widget.item, fact: fact),
        );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final namespace = ref.read(cacheNamespaceProvider);
      final cache = await ref.read(responseCacheProvider.future);
      final rawSender = widget.item.sender
          .toUpperCase()
          .replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '')
          .replaceFirst(RegExp(r'-[A-Z]$'), '');
      final factIdx =
          (fact?['factIndex'] is int && (fact!['factIndex'] as int) >= 0)
          ? fact['factIndex'] as int
          : 0;
      final obsId = widget.item.id.length == 64
          ? '${widget.item.id}:$factIdx'
          : widget.item.id;
      cache.financialStore.saveObservation(namespace, obsId, {
        'id': obsId,
        'sender_bank': rawSender,
        'parser_version': LocalSmsParser.version,
        'received_at': result.asOfAt.toUtc().toIso8601String(),
        'account_last4': result.accountLast4,
        'is_bank_account': true,
        'balance_paise': (result.balance * 100).round(),
        'confidence': 1.0,
      });
      ref.invalidate(bankAccountSummariesProvider);
      ref.invalidate(homeSummaryProvider);
      if (widget.item.id.length == 64) {
        await _persistSmsFactCorrection(
          ref,
          sourceKey: widget.item.id,
          factIndex: factIdx,
          patch: {
            'availableBalanceInr': result.balance,
            if (result.accountLast4 != null)
              'accountLast4': result.accountLast4,
            'asOfAt': result.asOfAt.toUtc().toIso8601String(),
          },
          reason: 'confirmed in needs review',
          sampleBody: widget.item.body,
        );
      }
      await _resolveFactSuggestion(factIdx);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewBill([Map<String, dynamic>? billFact]) async {
    final fact =
        billFact ??
        widget.item.aiSuggestions
            ?.where((s) => s['factType'] == 'bill_obligation')
            .firstOrNull;
    final factIdx =
        (fact?['factIndex'] is int && (fact!['factIndex'] as int) >= 0)
        ? fact['factIndex'] as int
        : 0;
    final result = await showModalBottomSheet<_BillReviewResult>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ReviewBillSheet(
        item: widget.item,
        suggestionFact: fact,
        onDiscard: () async {
          await _resolveFactSuggestion(factIdx);
        },
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(commitmentsRepositoryProvider)
          .save(
            Commitment(
              id: 'review-${widget.item.id}-$factIdx',
              title: result.title,
              category: result.category,
              amount: result.amount,
              dueOn: result.dueOn,
              identifier: result.identifier,
              cadence: result.cadence,
              source: CommitmentSource.sms,
              isUserConfirmed: true,
              confidence: 1,
            ),
          );
      ref.invalidate(commitmentsProvider);
      if (widget.item.id.length == 64) {
        await _persistSmsFactCorrection(
          ref,
          sourceKey: widget.item.id,
          factIndex: factIdx,
          patch: {
            'dueDate': result.dueOn.toUtc().toIso8601String(),
            if (result.amount != null) 'amountDueInr': result.amount!.rupees,
          },
          reason: 'confirmed in needs review',
          sampleBody: widget.item.body,
        );
      }
      await _resolveFactSuggestion(factIdx);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewMandate([Map<String, dynamic>? mandateFact]) async {
    final fact =
        mandateFact ??
        widget.item.aiSuggestions
            ?.where((s) => s['factType'] == 'mandate_lifecycle')
            .firstOrNull;
    final factIdx =
        (fact?['factIndex'] is int && (fact!['factIndex'] as int) >= 0)
        ? fact['factIndex'] as int
        : 0;
    final result = await showModalBottomSheet<_BillReviewResult>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ReviewMandateSheet(item: widget.item, fact: fact),
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(commitmentsRepositoryProvider)
          .save(
            Commitment(
              id: 'mandate-${widget.item.id}-$factIdx',
              title: result.title,
              category: CommitmentCategory.subscription,
              amount: result.amount,
              dueOn: result.dueOn,
              identifier: result.identifier,
              cadence: result.cadence,
              source: CommitmentSource.sms,
              isUserConfirmed: true,
              confidence: 1,
            ),
          );
      ref.invalidate(commitmentsProvider);
      if (widget.item.id.length == 64) {
        await _persistSmsFactCorrection(
          ref,
          sourceKey: widget.item.id,
          factIndex: factIdx,
          patch: {
            'mandateStatus': 'registered',
            if (result.amount != null) 'limitInr': result.amount!.rupees,
          },
          reason: 'confirmed in needs review',
          sampleBody: widget.item.body,
        );
      }
      await _resolveFactSuggestion(factIdx);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addPayLaterSpend() async {
    final m = RegExp(
      r'\bavail(?:ing|ed)\s+(?:(?:amazon\s+)?pay\s+later\s+)?credit\s+of\s+(?:Rs\.?\s*)(\d+(?:\.\d+)?)',
      caseSensitive: false,
    ).firstMatch(widget.item.body);
    final rawAmt = m?.group(1)?.replaceAll(',', '');
    final parsedAmt = rawAmt != null ? double.tryParse(rawAmt) : null;
    final amount = (parsedAmt != null && parsedAmt > 0)
        ? parsedAmt
        : LocalSmsParser.extractReceiptAmount(widget.item.body)?.rupees;

    if (amount == null || amount <= 0) {
      await _reviewMovement();
      return;
    }

    setState(() => _busy = true);
    try {
      final userCardsRepo = ref.read(userCardsRepositoryProvider);
      if (userCardsRepo != null) {
        await userCardsRepo.logTransaction(
          amount: Money.fromRupees(amount),
          merchantName: 'Amazon Pay Later',
          occurredAt: widget.item.receivedAt,
          instrument: TxnInstrument.other,
          entryKind: TxnEntryKind.spend,
        );
      }
      await ref.read(needsReviewRepositoryProvider).remove(widget.item.id);
      ref.invalidate(needsReviewItemsProvider);
      ref.invalidate(needsReviewCountProvider);
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      ref.invalidate(homeSummaryProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handlePrimaryAction() async {
    if (widget.item.kind == NeedsReviewKind.securityOrServiceAlert ||
        _isSecurityOrServiceAlert(widget.item.body)) {
      await _dismissNotATransaction();
      return;
    }
    if (widget.item.kind == NeedsReviewKind.payLaterDrawdown ||
        NeedsReviewRepository.isPayLaterDrawdown(
          widget.item.body,
          sender: widget.item.sender,
        )) {
      await _addPayLaterSpend();
      return;
    }
    final suggestions = widget.item.aiSuggestions;
    if (suggestions != null && suggestions.isNotEmpty) {
      final first = suggestions.first;
      final type = first['factType'];
      switch (type) {
        case 'balance_snapshot':
          await _reviewBalance(first);
          return;
        case 'bill_obligation':
          await _reviewBill(first);
          return;
        case 'mandate_lifecycle':
          await _reviewMandate(first);
          return;
        case 'security_or_service_alert':
        case 'promotion':
          await _resolveFactSuggestion((first['factIndex'] as int?) ?? 0);
          return;
        case 'posted_movement':
        default:
          await _reviewMovement(first);
          return;
      }
    }
    if (widget.item.kind == NeedsReviewKind.mandate ||
        _isMandateReview(widget.item.body)) {
      await _reviewMandate();
      return;
    }
    await _reviewMovement();
  }

  Widget _buildSuggestionTile(Map<String, dynamic> s) {
    final type = s['factType'] as String? ?? '';
    final payload = (s['payload'] as Map<String, dynamic>?) ?? const {};
    final (icon, title, subtitle, actionLabel) = switch (type) {
      'posted_movement' => (
        Icons.credit_card_outlined,
        'Transaction: ₹${((payload['amountInr'] as num?) ?? 0).toStringAsFixed(2)}',
        (payload['merchant'] as String?) ?? 'Purchase',
        'Review',
      ),
      'balance_snapshot' => (
        Icons.account_balance_outlined,
        'Balance: ₹${((payload['availableBalanceInr'] as num?) ?? 0).toStringAsFixed(2)}',
        payload['accountLast4'] != null
            ? 'A/c ••••${payload['accountLast4']}'
            : 'Bank balance',
        'Confirm',
      ),
      'bill_obligation' => (
        Icons.receipt_long_outlined,
        'Bill: ₹${((payload['amountDueInr'] as num?) ?? (payload['minimumDueInr'] as num?) ?? 0).toStringAsFixed(2)}',
        (payload['billerName'] as String?) ?? 'Card/Utility bill',
        'Review',
      ),
      'mandate_lifecycle' => (
        Icons.autorenew_rounded,
        'Mandate: ${(payload['mandateName'] as String?) ?? 'AutoPay'}',
        payload['limitInr'] != null
            ? 'Limit ₹${(payload['limitInr'] as num).toStringAsFixed(2)}'
            : 'Recurring mandate',
        'Confirm',
      ),
      'security_or_service_alert' => (
        Icons.privacy_tip_outlined,
        'Security or service alert',
        'Not a transaction',
        'Dismiss',
      ),
      'promotion' => (
        Icons.local_offer_outlined,
        'Promotional message',
        'Not a transaction',
        'Dismiss',
      ),
      _ => (Icons.info_outline, 'Financial detail', type, 'Review'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: BambooInk.paper,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: BambooInk.jade),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: BambooFonts.ui(
                    12.5,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                ),
                Text(
                  subtitle,
                  style: BambooFonts.ui(11, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(48, 48),
            ),
            onPressed: _busy
                ? null
                : () async {
                    switch (type) {
                      case 'balance_snapshot':
                        await _reviewBalance(s);
                        break;
                      case 'bill_obligation':
                        await _reviewBill(s);
                        break;
                      case 'mandate_lifecycle':
                        await _reviewMandate(s);
                        break;
                      case 'security_or_service_alert':
                      case 'promotion':
                        await _resolveFactSuggestion(
                          (s['factIndex'] as int?) ?? 0,
                        );
                        break;
                      case 'posted_movement':
                      default:
                        await _reviewMovement(s);
                        break;
                    }
                  },
            child: Text(
              actionLabel,
              style: BambooFonts.ui(12, weight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.sender,
                      style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat(
                        'MMM d, yyyy • h:mm a',
                      ).format(item.receivedAt.toLocal()),
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Dismiss message',
                onPressed: _busy ? null : _dismissNotATransaction,
                icon: const Icon(Icons.close_rounded),
                color: BambooInk.ink500,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Container(
            padding: const EdgeInsets.all(AppSpace.sm),
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              item.body,
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            _reviewTypeLabel(item),
            style: BambooFonts.ui(
              12.5,
              weight: FontWeight.w700,
              color:
                  _instrumentFromReviewText(item.body, item.sender) ==
                      TxnInstrument.upiBank
                  ? BambooInk.jade
                  : BambooInk.ink500,
            ),
          ),
          if (item.aiSuggestions != null && item.aiSuggestions!.length > 1) ...[
            const SizedBox(height: AppSpace.sm),
            for (final suggestion in item.aiSuggestions!)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.xs),
                child: _buildSuggestionTile(suggestion),
              ),
          ],
          if (item.reason != null ||
              _isSecurityOrServiceAlert(item.body) ||
              _isInvestmentSettlement(item.body) ||
              _isMandateReview(item.body)) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              _reviewReasonLabel(item.reason, item.body),
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              // Let the secondary keep its intrinsic width so the descriptive
              // primary label ("Review drawdown", "Choose card/account") isn't
              // squeezed into a half-width button and wrapped onto two lines.
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: BambooInk.ink900,
                  side: const BorderSide(color: BambooInk.hairlineOnPaper),
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                ),
                onPressed: _busy ? null : _dismissNotATransaction,
                child: const Text('Ignore message'),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size.fromHeight(44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                  ),
                  onPressed: _busy ? null : _handlePrimaryAction,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: BambooInk.lime,
                          ),
                        )
                      : Text(_reviewActionLabel(item)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReviewBundleCard extends ConsumerStatefulWidget {
  final BundleReviewGroup group;

  const _ReviewBundleCard({required this.group});

  @override
  ConsumerState<_ReviewBundleCard> createState() => _ReviewBundleCardState();
}

class _ReviewBundleCardState extends ConsumerState<_ReviewBundleCard> {
  bool _expanded = false;
  bool _busy = false;

  Future<void> _dismissBundle() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(userCardsRepositoryProvider);
      for (final item in widget.group.items) {
        if (item.kind == NeedsReviewKind.commitment) {
          await _persistCommitmentDismissal(ref, item);
        }
        if (repo != null) {
          repo
              .dismissSms(
                sourceKey: _feedbackSourceKey(item.id),
                sender: item.sender,
                sampleBody: item.body,
                reason: 'bundle_dismissed',
                family: 'ignore_noise',
              )
              .ignore();
        }
      }
      final ids = [for (final item in widget.group.items) item.id];
      await ref.read(needsReviewRepositoryProvider).removeAll(ids);
      ref.invalidate(commitmentsProvider);
      ref.invalidate(needsReviewItemsProvider);
      ref.invalidate(needsReviewCountProvider);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _buildBadge(String text, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: (color ?? BambooInk.ink700).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(
          color: (color ?? BambooInk.ink700).withValues(alpha: 0.18),
        ),
      ),
      child: Text(
        text,
        style: BambooFonts.ui(
          11,
          weight: FontWeight.w600,
          color: color ?? BambooInk.ink700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final dateSpan = formatBundleDateSpan(group.earliest, group.latest);

    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpace.xs),
                decoration: BoxDecoration(
                  color: BambooInk.paperMuted,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Icon(
                  Icons.layers_rounded,
                  size: 20,
                  color: BambooInk.ink700,
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.title,
                      style: BambooFonts.heading(15, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Wrap(
                      spacing: AppSpace.xs,
                      runSpacing: AppSpace.xs,
                      children: [
                        _buildBadge('${group.items.length} messages'),
                        if (group.totalAmount != null)
                          _buildBadge(
                            'Total: ₹${group.totalAmount!.rupees.toStringAsFixed(2)}',
                            color: BambooInk.jade,
                          ),
                        _buildBadge(dateSpan),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      group.subtitle,
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          // A Wrap stretched each outlined button to the full card width, so
          // the two actions stacked as two oversized rows. The collapsed
          // builder keeps its intrinsic width and shares the line instead.
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _dismissBundle,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: BambooInk.hairlineOnPaper),
                    foregroundColor: BambooInk.ink900,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm,
                      vertical: AppSpace.xs,
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: BambooInk.ink700,
                          ),
                        )
                      : Text(
                          group.isPayLater
                              ? 'Dismiss all ${group.items.length} (Billed in AutoPay)'
                              : 'Dismiss all ${group.items.length}',
                          style: BambooFonts.ui(12, weight: FontWeight.w600),
                        ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(
                  foregroundColor: BambooInk.ink700,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.sm,
                    vertical: AppSpace.xs,
                  ),
                  textStyle: BambooFonts.ui(12, weight: FontWeight.w600),
                ),
                icon: Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                ),
                label: Text(
                  _expanded
                      ? 'Hide messages'
                      : 'Show all ${group.items.length}',
                ),
              ),
            ],
          ),
          if (_expanded) ...[
            const SizedBox(height: AppSpace.sm),
            const Divider(color: BambooInk.hairlineOnPaper),
            const SizedBox(height: AppSpace.sm),
            Padding(
              padding: const EdgeInsets.only(left: AppSpace.sm),
              child: Column(
                children: [
                  for (final item in group.items)
                    Padding(
                      key: ValueKey(item.id),
                      padding: const EdgeInsets.only(bottom: AppSpace.sm),
                      child: item.kind == NeedsReviewKind.commitment
                          ? _CommitmentNeedsReviewTile(item)
                          : _NeedsReviewTile(item),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FillFieldsSheet extends ConsumerStatefulWidget {
  final NeedsReviewItem item;
  final Map<String, dynamic>? suggestionFact;
  const _FillFieldsSheet({required this.item, this.suggestionFact});

  @override
  ConsumerState<_FillFieldsSheet> createState() => _FillFieldsSheetState();
}

class _FillFieldsSheetState extends ConsumerState<_FillFieldsSheet> {
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  String? _cardId;
  String? _categoryId;
  late final LocalSmsReviewDraft _draft;
  late TxnInstrument _instrument;
  late TxnEntryKind _entryKind;
  late DateTime _occurredAt;

  @override
  void initState() {
    super.initState();
    _draft = LocalSmsParser.reviewDraft(
      namespace: 'needs_review',
      sender: widget.item.sender,
      body: widget.item.body,
      receivedAt: widget.item.receivedAt,
    );
    _instrument = _draft.instrument;
    _entryKind = _draft.entryKind;
    _occurredAt = _draft.occurredAt;
    if (_draft.amount != null) {
      _amountController.text = _draft.amount!.rupees.toStringAsFixed(2);
    }
    _merchantController.text = _draft.merchantName ?? '';
    final movement =
        widget.suggestionFact ??
        widget.item.aiSuggestions
            ?.where((suggestion) => suggestion['factType'] == 'posted_movement')
            .firstOrNull;
    final payload = movement?['payload'];
    if (payload is Map) {
      final amount = payload['amountInr'];
      if (amount is num && amount.isFinite && amount > 0) {
        _amountController.text = amount.toStringAsFixed(2);
      }
      final merchant = payload['merchant'];
      if (merchant is String && merchant.trim().isNotEmpty) {
        _merchantController.text = merchant.trim();
      }
      final instrument = payload['instrument'];
      if (instrument is String) {
        _instrument = TxnInstrument.fromJson(instrument);
      }
      final entryKind = payload['entryKind'];
      if (entryKind is String) {
        _entryKind = TxnEntryKind.fromJson(entryKind);
      }
      final category = payload['category'];
      if (category is String && category.trim().isNotEmpty) {
        _categoryId = category.trim();
      }
      final occurredAt = DateTime.tryParse('${payload['occurredAt'] ?? ''}');
      if (occurredAt != null) _occurredAt = occurredAt;
    }

    final senderUpper = widget.item.sender.toUpperCase();
    final isInvestmentSender =
        senderUpper.contains('HDFCMF') ||
        senderUpper.contains('CAMSSM') ||
        senderUpper.contains('KFINTE');
    final isFolioOrSip = RegExp(
      r'\b(?:folio|sip)\b',
      caseSensitive: false,
    ).hasMatch(widget.item.body);
    final isInvestment =
        isInvestmentSender ||
        isFolioOrSip ||
        widget.item.kind == NeedsReviewKind.investmentSettlement ||
        _isInvestmentSettlement(widget.item.body) ||
        LocalSmsParser.isInvestmentFolioAllotment(widget.item.body);

    if (isInvestment) {
      _categoryId ??= 'investments';
      _entryKind = TxnEntryKind.investment;
      if (_amountController.text.isEmpty) {
        final amt = LocalSmsParser.extractReceiptAmount(widget.item.body);
        if (amt != null && amt.paise > 0) {
          _amountController.text = amt.rupees.toStringAsFixed(2);
        }
      }
    }

    final isPayLater =
        widget.item.kind == NeedsReviewKind.payLaterDrawdown ||
        NeedsReviewRepository.isPayLaterDrawdown(
          widget.item.body,
          sender: widget.item.sender,
        );
    if (isPayLater) {
      if (_merchantController.text.isEmpty) {
        _merchantController.text = 'Amazon Pay Later';
      }
      _instrument = TxnInstrument.other;
      _entryKind = TxnEntryKind.spend;
      if (_amountController.text.isEmpty) {
        final m = RegExp(
          r'\bavail(?:ing|ed)\s+(?:(?:amazon\s+)?pay\s+later\s+)?credit\s+of\s+(?:Rs\.?\s*)(\d+(?:\.\d+)?)',
          caseSensitive: false,
        ).firstMatch(widget.item.body);
        final raw = m?.group(1)?.replaceAll(',', '');
        if (raw != null) {
          _amountController.text = raw;
        } else {
          final amt = LocalSmsParser.extractReceiptAmount(widget.item.body);
          if (amt != null && amt.paise > 0) {
            _amountController.text = amt.rupees.toStringAsFixed(2);
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    super.dispose();
  }

  UserCard? _matchingCard(List<UserCard> cards) {
    final last4 = _draft.cardLast4;
    if (last4 == null) return null;
    final matches = cards.where(
      (card) =>
          !card.isArchived &&
          card.last4 == last4 &&
          (_instrument != TxnInstrument.debitCard ||
              card.cardType == 'debit') &&
          (_instrument != TxnInstrument.creditCard || card.cardType != 'debit'),
    );
    return matches.length == 1 ? matches.single : null;
  }

  Future<void> _pickDate() async {
    final latest = DateTime.now().add(const Duration(days: 1));
    final earliest = DateTime(2000);
    final initialDate = _occurredAt.isBefore(earliest)
        ? earliest
        : _occurredAt.isAfter(latest)
        ? latest
        : _occurredAt;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: earliest,
      lastDate: latest,
    );
    if (picked != null && mounted) setState(() => _occurredAt = picked);
  }

  String _dateLabel(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  @override
  Widget build(BuildContext context) {
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
    final matchingCard = _matchingCard(cards);
    final eligibleCards = cards.where((card) {
      if (card.isArchived) return false;
      if (_instrument == TxnInstrument.debitCard) {
        return card.cardType == 'debit';
      }
      if (_instrument == TxnInstrument.creditCard) {
        return card.cardType != 'debit';
      }
      return false;
    }).toList();

    final amountText = _amountController.text.trim().replaceAll(',', '');
    final amount = double.tryParse(amountText);
    final amountError =
        amount == null ||
            !amount.isFinite ||
            amount <= 0 ||
            amount > 9999999999.99
        ? 'Enter a valid amount greater than zero.'
        : null;
    final selectedCardId = _cardId ?? matchingCard?.id;
    final cardError =
        _isPhysicalCardInstrument(_instrument) && selectedCardId == null
        ? eligibleCards.isEmpty
              ? 'Add a matching card or choose another payment method.'
              : 'Choose the card used for this transaction.'
        : null;

    InputDecoration inputDecoration(String label, {String? errorText}) {
      final border = OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: errorText == null
              ? BambooInk.hairlineOnPaper
              : AppColors.error,
          width: errorText == null ? 1 : 1.6,
        ),
      );
      return InputDecoration(
        labelText: label,
        labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
        errorText: errorText,
        errorStyle: BambooFonts.ui(12, color: AppColors.error),
        filled: true,
        fillColor: BambooInk.glassFillOnPaper,
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(
            color: errorText == null ? BambooInk.slate : AppColors.error,
            width: 1.6,
          ),
        ),
        errorBorder: border.copyWith(
          borderSide: const BorderSide(color: AppColors.error, width: 1.6),
        ),
        focusedErrorBorder: border.copyWith(
          borderSide: const BorderSide(color: AppColors.error, width: 1.8),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        color: BambooInk.paper,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      padding: EdgeInsets.only(
        left: AppSpace.lg,
        right: AppSpace.lg,
        top: AppSpace.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Review this transaction',
              style: BambooFonts.heading(17, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'We found a possible transaction in this message. Check the details before saving it.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            Container(
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                color: BambooInk.paperMuted,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                widget.item.body,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _amountController,
              onChanged: (_) => setState(() {}),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: inputDecoration('Amount (₹)', errorText: amountError),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _merchantController,
              textCapitalization: TextCapitalization.words,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: inputDecoration('Merchant or sender'),
            ),
            const SizedBox(height: AppSpace.lg),
            DropdownButtonFormField<TxnEntryKind>(
              initialValue: _entryKind,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: inputDecoration('What happened?'),
              items: [
                for (final kind in TxnEntryKind.values)
                  DropdownMenuItem(value: kind, child: Text(kind.label)),
              ],
              onChanged: (v) =>
                  setState(() => _entryKind = v ?? TxnEntryKind.spend),
            ),
            const SizedBox(height: AppSpace.lg),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(16),
              child: InputDecorator(
                decoration: inputDecoration('Date'),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _dateLabel(_occurredAt),
                        style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      ),
                    ),
                    const Icon(Icons.calendar_today_outlined, size: 19),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            DropdownButtonFormField<TxnInstrument>(
              initialValue: _instrument,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: inputDecoration('How was it paid?'),
              items: [
                for (final instrument in const [
                  TxnInstrument.creditCard,
                  TxnInstrument.debitCard,
                  TxnInstrument.upiBank,
                  TxnInstrument.cash,
                  TxnInstrument.wallet,
                  TxnInstrument.other,
                ])
                  DropdownMenuItem(
                    value: instrument,
                    child: Text(_reviewInstrumentLabel(instrument)),
                  ),
              ],
              onChanged: (v) => setState(() {
                final next = v ?? TxnInstrument.other;
                if (next != _instrument) _cardId = null;
                _instrument = next;
              }),
            ),
            if (_isPhysicalCardInstrument(_instrument)) ...[
              const SizedBox(height: AppSpace.lg),
              DropdownButtonFormField<String>(
                initialValue: _cardId ?? matchingCard?.id,
                style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                decoration: inputDecoration(
                  _instrument == TxnInstrument.debitCard
                      ? 'Debit card'
                      : 'Credit card',
                  errorText: cardError,
                ),
                items: [
                  for (final c in eligibleCards)
                    DropdownMenuItem(
                      value: c.id,
                      child: Text(
                        c.nickname?.isNotEmpty == true
                            ? c.nickname!
                            : c.cardName,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _cardId = v),
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            CategoryPickerField(
              categories: categories,
              selectedId: _categoryId,
              label: 'Category (optional)',
              onSelected: (v) => setState(() => _categoryId = v),
            ),
            const SizedBox(height: AppSpace.xl),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
              ),
              onPressed: () {
                final amount = double.tryParse(
                  _amountController.text.trim().replaceAll(',', ''),
                );
                if (amount == null ||
                    !amount.isFinite ||
                    amount <= 0 ||
                    amount > 9999999999.99) {
                  setState(() {});
                  return;
                }
                final selectedCardId = _cardId ?? matchingCard?.id;
                if (_isPhysicalCardInstrument(_instrument) &&
                    selectedCardId == null) {
                  setState(() {});
                  return;
                }
                final merchant = _merchantController.text.trim();
                Navigator.of(context).pop((
                  cardId: selectedCardId,
                  amount: amount,
                  categoryId: _categoryId,
                  merchantName: merchant.isEmpty ? null : merchant,
                  occurredAt: _occurredAt,
                  instrument: _instrument,
                  entryKind: _entryKind,
                ));
              },
              child: const Text('Save transaction'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiBadge extends StatelessWidget {
  final String summary;
  const _AiBadge({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Color(0xFF8064C7).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: Color(0xFF8064C7).withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 11,
              color: Color(0xFF8064C7),
            ),
            const SizedBox(width: 4),
            Text(
              summary,
              style: BambooFonts.ui(
                11.5,
                weight: FontWeight.w600,
                color: Color(0xFF8064C7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
