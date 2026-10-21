import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/display_text.dart';
import '../../app/design/widgets.dart';
import '../../app/category_picker.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/commitments_repository.dart';
import '../../data/local_sms_parser.dart';
import '../../data/local/sms_facts_outbox.dart';
import '../../data/needs_review_repository.dart';
import '../../data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument, UserCard;

TxnInstrument _instrumentFromReviewText(String body) {
  final text = body.toLowerCase();
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

bool _isSecurityOrServiceAlert(String body) {
  final text = body.toLowerCase();
  return RegExp(
    r'\b(?:transaction\s+check\s+alert|check\s+alert|confirm\s+(?:the\s+)?(?:following\s+)?txn|call\s+forwarding\b|sim\s+swap|service\s+alert|fraud\s+alert|suspicious\s+activity)\b',
  ).hasMatch(text);
}

bool _isInvestmentSettlement(String body) {
  final text = body.toLowerCase();
  return RegExp(
    r'\b(?:kotak\s+neo|demat|settlement\s+payout|running\s+a/?c\s+settlement)\b',
  ).hasMatch(text);
}

bool _isMandateReview(String body) {
  final text = body.toLowerCase();
  return RegExp(
    r'\b(?:auto[-\s]?pay|e[-\s]?mandate|standing\s+instruction)\b',
  ).hasMatch(text);
}

String _reviewTypeLabel(NeedsReviewItem item) {
  if (item.kind == NeedsReviewKind.securityOrServiceAlert ||
      _isSecurityOrServiceAlert(item.body)) {
    return 'Security or service alert';
  }
  if (item.kind == NeedsReviewKind.investmentSettlement ||
      _isInvestmentSettlement(item.body)) {
    return 'Investment settlement payout';
  }
  if (item.kind == NeedsReviewKind.mandate || _isMandateReview(item.body)) {
    return 'AutoPay mandate alert';
  }
  final instrument = _instrumentFromReviewText(item.body);
  return instrument == TxnInstrument.other
      ? 'Possible transaction'
      : _reviewInstrumentLabel(instrument);
}

String _reviewReasonLabel(String? reason, String body) {
  if (_isSecurityOrServiceAlert(body)) {
    return 'Verification or service notice — not a spending transaction.';
  }
  if (_isInvestmentSettlement(body)) {
    return 'Funds settlement from broker or demat account.';
  }
  if (_isMandateReview(body)) {
    return 'Mandate authorization or notification.';
  }
  return switch (reason) {
    'no_transaction_match' => 'We could not match this message to a transaction.',
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
  if (item.kind == NeedsReviewKind.securityOrServiceAlert ||
      _isSecurityOrServiceAlert(item.body)) {
    return 'Dismiss alert';
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
  );

  final repository = ref.read(userCardsRepositoryProvider);
  if (repository == null || ref.read(isOnlineProvider).valueOrNull == false) return;
  try {
    final accepted = await repository.overrideSmsFact(
      sourceKey: sourceKey,
      factIndex: factIndex,
      patch: patch,
      reason: reason,
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
class NeedsReviewScreen extends ConsumerWidget {
  const NeedsReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(needsReviewItemsProvider);
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
          if ((items.valueOrNull ?? const []).isNotEmpty)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: BambooInk.ink900),
              onPressed: () async {
                final reviewItems =
                    items.valueOrNull ?? const <NeedsReviewItem>[];
                for (final item in reviewItems) {
                  if (item.kind == NeedsReviewKind.commitment) {
                    await _persistCommitmentDismissal(ref, item);
                  }
                }
                final ids = [for (final item in reviewItems) item.id];
                await ref.read(needsReviewRepositoryProvider).removeAll(ids);
                ref.invalidate(commitmentsProvider);
                ref.invalidate(needsReviewItemsProvider);
              },
              child: const Text('Dismiss all'),
            ),
        ],
      ),
      body: AppBackground(
        child: items.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
          data: (list) {
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.mark_email_read_outlined,
                title: 'Nothing needs review',
                message:
                    'Messages we couldn\'t automatically parse show up here — nothing is ever dropped silently.',
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(AppSpace.lg),
              itemCount: list.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                child: list[index].kind == NeedsReviewKind.commitment
                    ? _CommitmentNeedsReviewTile(list[index])
                    : _NeedsReviewTile(list[index]),
              ),
            );
          },
        ),
      ),
    );
  }
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
      await ref.read(needsReviewRepositoryProvider).remove(widget.item.id);
      ref.invalidate(needsReviewItemsProvider);
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
          if (item.reason != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              'Needs confirmation: ${humanizeIdentifier(item.reason)}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BambooInk.ink900,
                    side: const BorderSide(color: BambooInk.hairlineOnPaper),
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                  ),
                  onPressed: _busy ? null : _dismiss,
                  child: const Text('Not a bill'),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                  ),
                  onPressed: _busy ? null : _reviewAndSaveCommitment,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: BambooInk.lime,
                          ),
                        )
                      : const Text('Save bill'),
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
  final Future<void> Function() onDiscard;

  const _ReviewBillSheet({
    required this.item,
    required this.parsed,
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
    final suggestedTitle = parsed?.billerName?.trim();
    _titleController = TextEditingController(
      text: suggestedTitle?.isNotEmpty == true
          ? suggestedTitle
          : widget.item.sender,
    );
    _amountController = TextEditingController(
      text: parsed?.amountDue == null
          ? ''
          : (parsed!.amountDue!.paise / 100).toStringAsFixed(2),
    );
    final identifier = parsed?.accountLast4 ?? parsed?.cardLast4;
    _identifierController = TextEditingController(
      text: identifier == null ? '' : '••••$identifier',
    );
    _category = CommitmentCategory.fromText(
      '${_titleController.text} ${widget.item.sender}',
    );
    _cadence = switch (parsed?.cadenceHint) {
      'quarterly' => CommitmentCadence.quarterly,
      'halfYearly' => CommitmentCadence.halfYearly,
      'annual' => CommitmentCadence.annual,
      _ =>
        _category == CommitmentCategory.insurance
            ? CommitmentCadence.annual
            : CommitmentCadence.monthly,
    };
    _dueOn = parsed?.dueDate;
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
    if (picked != null) setState(() => _dueOn = picked);
  }

  void _save() {
    final title = _titleController.text.trim();
    final dueOn = _dueOn;
    final amountText = _amountController.text.trim().replaceAll(',', '');
    final amountValue = amountText.isEmpty ? null : double.tryParse(amountText);
    if (title.isEmpty ||
        dueOn == null ||
        (amountValue != null && amountValue <= 0)) {
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
    final amountText = _amountController.text.trim().replaceAll(',', '');
    final amountValue = amountText.isEmpty ? null : double.tryParse(amountText);
    final canSave =
        _titleController.text.trim().isNotEmpty &&
        _dueOn != null &&
        (amountValue == null || amountValue > 0);
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
      await ref.read(needsReviewRepositoryProvider).remove(widget.item.id);
      ref.invalidate(needsReviewItemsProvider);
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

  Future<void> _fillManually() async {
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
          builder: (context) => _FillFieldsSheet(item: widget.item),
        );
    if (result == null) return;
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
      await ref.read(needsReviewRepositoryProvider).remove(widget.item.id);
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      ref.invalidate(needsReviewItemsProvider);
      if (widget.item.id.length == 64) {
        await _persistSmsFactCorrection(
          ref,
          sourceKey: widget.item.id,
          factIndex: 0,
          patch: {
              'entryKind': result.entryKind.wireValue,
              'amountInr': result.amount,
              if (result.merchantName != null) 'merchant': result.merchantName,
              'instrument': result.instrument.wireValue,
              'occurredAt': result.occurredAt.toUtc().toIso8601String(),
              'amountRole': 'posted',
          },
          reason: 'confirmed in needs review',
        );
      }
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
    await _fillManually();
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
                child: Text(
                  item.sender,
                  style: BambooFonts.heading(14.5, color: BambooInk.ink900),
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
                  _instrumentFromReviewText(item.body) == TxnInstrument.upiBank
                  ? BambooInk.jade
                  : BambooInk.ink500,
            ),
          ),
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
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BambooInk.ink900,
                    side: const BorderSide(color: BambooInk.hairlineOnPaper),
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                  ),
                  onPressed: _busy ? null : _dismissNotATransaction,
                  child: const Text('Ignore message'),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size.fromHeight(44),
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

class _FillFieldsSheet extends ConsumerStatefulWidget {
  final NeedsReviewItem item;
  const _FillFieldsSheet({required this.item});

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
    if (picked != null) setState(() => _occurredAt = picked);
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
                final amount = double.tryParse(_amountController.text.trim());
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
