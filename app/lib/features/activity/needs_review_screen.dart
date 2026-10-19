import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/display_text.dart';
import '../../app/design/widgets.dart';
import '../../app/category_picker.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/catalogue_repository.dart' show categoryIdForServer;
import '../../data/needs_review_repository.dart';
import '../../data/user_cards_repository.dart' show TxnInstrument;

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
                final ids = <String>[
                  for (final i
                      in items.valueOrNull ?? const <NeedsReviewItem>[])
                    i.id,
                ];
                await ref.read(needsReviewRepositoryProvider).removeAll(ids);
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
                child: _NeedsReviewTile(list[index]),
              ),
            );
          },
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
            TxnInstrument instrument,
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
            categoryId: categoryIdForServer(result.categoryId),
            instrument: result.instrument,
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
  String? _cardId;
  String? _categoryId;
  late TxnInstrument _instrument = _instrumentFromReviewText(widget.item.body);

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Fill in the missing fields',
            style: BambooFonts.heading(17, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.lg),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: BambooFonts.ui(14.5, color: BambooInk.ink900),
            decoration: inputDecoration('Amount (₹)'),
            autofocus: true,
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
                TxnInstrument.other,
              ])
                DropdownMenuItem(
                  value: instrument,
                  child: Text(_reviewInstrumentLabel(instrument)),
                ),
            ],
            onChanged: (v) => setState(() {
              _instrument = v ?? TxnInstrument.other;
              if (!_isPhysicalCardInstrument(_instrument)) _cardId = null;
            }),
          ),
          if (_isPhysicalCardInstrument(_instrument)) ...[
            const SizedBox(height: AppSpace.lg),
            DropdownButtonFormField<String>(
              initialValue: _cardId,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: inputDecoration(
                _instrument == TxnInstrument.debitCard
                    ? 'Debit card'
                    : 'Credit card',
              ),
              items: [
                for (final c in cards)
                  DropdownMenuItem(
                    value: c.id,
                    child: Text(
                      c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName,
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
              if (_isPhysicalCardInstrument(_instrument) && _cardId == null) {
                return;
              }
              Navigator.of(context).pop((
                cardId: _cardId,
                amount: amount,
                categoryId: _categoryId,
                instrument: _instrument,
              ));
            },
            child: const Text('Log transaction'),
          ),
        ],
      ),
    );
  }
}
