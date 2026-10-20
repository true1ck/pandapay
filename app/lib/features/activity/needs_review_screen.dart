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
  // Keep older card-shaped messages useful when their body omitted the words
  // "credit card".
  return TxnInstrument.creditCard;
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
  if (parsed?.dueDate == null) return;

  final title = parsed!.billerName?.trim().isNotEmpty == true
      ? parsed.billerName!.trim()
      : item.sender;
  final category = CommitmentCategory.fromText('$title ${item.sender}');
  final account = parsed.accountLast4;
  // Keep a tombstone so an explicitly rejected observation cannot recreate a
  // low-confidence commitment after the review item is removed.
  await ref
      .read(commitmentsRepositoryProvider)
      .save(
        Commitment(
          id: 'review-dismissed-${item.id}',
          title: title,
          category: category,
          amount: parsed.amountDue,
          dueOn: parsed.dueDate!,
          identifier: account == null ? null : '••••$account',
          source: CommitmentSource.sms,
          status: CommitmentStatus.dismissed,
          isUserConfirmed: true,
          confidence: 1,
        ),
      );
}

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

  Future<void> _saveCommitment() async {
    setState(() => _busy = true);
    try {
      final parsed = _parse();
      final dueOn = parsed?.dueDate;
      if (parsed == null || dueOn == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'This message does not contain a usable due date yet.',
              ),
            ),
          );
        }
        return;
      }
      final title = parsed.billerName?.trim().isNotEmpty == true
          ? parsed.billerName!.trim()
          : widget.item.sender;
      final category = CommitmentCategory.fromText(
        '$title ${widget.item.sender}',
      );
      final body = widget.item.body.toLowerCase();
      final cadence = body.contains('monthly')
          ? CommitmentCadence.monthly
          : body.contains('quarterly')
          ? CommitmentCadence.quarterly
          : body.contains('half-yearly') || body.contains('half yearly')
          ? CommitmentCadence.halfYearly
          : body.contains('annual') || body.contains('yearly')
          ? CommitmentCadence.annual
          : category == CommitmentCategory.insurance
          ? CommitmentCadence.annual
          : CommitmentCadence.monthly;
      final account = parsed.accountLast4;
      await ref
          .read(commitmentsRepositoryProvider)
          .save(
            Commitment(
              id: 'review-${widget.item.id}',
              title: title,
              category: category,
              amount: parsed.amountDue,
              dueOn: dueOn,
              identifier: account == null ? null : '••••$account',
              cadence: cadence,
              source: CommitmentSource.sms,
              isUserConfirmed: true,
              confidence: 1,
            ),
          );
      await ref.read(needsReviewRepositoryProvider).remove(widget.item.id);
      ref.invalidate(commitmentsProvider);
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
                  onPressed: _busy ? null : _saveCommitment,
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
    await ref.read(needsReviewRepositoryProvider).remove(widget.item.id);
    ref.invalidate(needsReviewItemsProvider);
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
          Text(
            item.sender,
            style: BambooFonts.heading(14.5, color: BambooInk.ink900),
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
            _reviewInstrumentLabel(_instrumentFromReviewText(item.body)),
            style: BambooFonts.ui(
              12.5,
              weight: FontWeight.w700,
              color:
                  _instrumentFromReviewText(item.body) == TxnInstrument.upiBank
                  ? BambooInk.jade
                  : BambooInk.ink500,
            ),
          ),
          if (item.reason != null) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              'Reason: ${humanizeIdentifier(item.reason)} (${item.reason})',
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
                  child: const Text('Not a transaction'),
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
                  onPressed: _busy ? null : _fillManually,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: BambooInk.lime,
                          ),
                        )
                      : const Text('Fill in fields'),
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

    InputDecoration inputDecoration(String label) => InputDecoration(
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
              'Fill in the missing fields',
              style: BambooFonts.heading(17, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'Review the suggestions from this SMS before saving.',
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
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: inputDecoration('Amount (₹)'),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _merchantController,
              textCapitalization: TextCapitalization.words,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: inputDecoration('Merchant or payee'),
            ),
            const SizedBox(height: AppSpace.lg),
            DropdownButtonFormField<TxnEntryKind>(
              initialValue: _entryKind,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: inputDecoration('Entry type'),
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
              decoration: inputDecoration('Payment type'),
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
                if (amount == null || amount <= 0) return;
                final selectedCardId = _cardId ?? matchingCard?.id;
                if (_isPhysicalCardInstrument(_instrument) &&
                    selectedCardId == null) {
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
              child: const Text('Log transaction'),
            ),
          ],
        ),
      ),
    );
  }
}
