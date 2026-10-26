import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/card_bill_ledger.dart';
import '../../data/user_cards_repository.dart';

/// Captured bill messages that need a card choice remain visible here. A
/// manually linked message stays available so the choice can be corrected.
class CardBillReviewSection extends ConsumerWidget {
  final bool Function(CardBillReviewItem) includes;

  const CardBillReviewSection({super.key, required this.includes});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(cardBillReviewItemsProvider).valueOrNull ?? const [];
    final visible = items.where(includes).toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();
    final cards = ref.watch(myCardsProvider).valueOrNull ?? const <UserCard>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Bills from messages',
            style: BambooFonts.heading(15, color: BambooInk.ink900)),
        const SizedBox(height: AppSpace.xs),
        Text('Check the details and choose the card for uncertain bills.',
            style: BambooFonts.ui(12, color: BambooInk.ink500)),
        const SizedBox(height: AppSpace.md),
        for (final item in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: CardBillReviewTile(item: item, cards: cards),
          ),
        const SizedBox(height: AppSpace.lg),
      ],
    );
  }
}

class CardBillReviewTile extends ConsumerWidget {
  final CardBillReviewItem item;
  final List<UserCard> cards;

  const CardBillReviewTile({
    super.key,
    required this.item,
    required this.cards,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = cards.where((c) => c.id == item.assignedCardId).firstOrNull;
    final title = item.billerName?.trim().isNotEmpty == true
        ? item.billerName!.trim()
        : 'Credit-card bill';
    final due = item.dueDate == null
        ? 'Due date not found'
        : 'Due ${DateFormat('d MMM yyyy').format(item.dueDate!)}';
    return InkWell(
      key: ValueKey('card-bill-review-${item.id}'),
      borderRadius: BorderRadius.circular(16),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _CardBillReviewSheet(item: item, cards: cards),
      ),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          children: [
            const Icon(Icons.receipt_long_outlined, color: BambooInk.jade),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: BambooFonts.ui(13, weight: FontWeight.w600,
                      color: BambooInk.ink900)),
                  Text('$due · ${card == null ? 'Choose card' : 'Linked to ${card.nickname ?? card.cardName}'}',
                      style: BambooFonts.ui(11, color: BambooInk.ink500)),
                ],
              ),
            ),
            Text(item.amountDue?.format(hidePaise: true) ?? 'Amount unknown',
                style: BambooFonts.money(13, color: BambooInk.ink900)),
            const SizedBox(width: AppSpace.xs),
            const Icon(Icons.chevron_right_rounded, color: BambooInk.ink500),
          ],
        ),
      ),
    );
  }
}

class _CardBillReviewSheet extends ConsumerStatefulWidget {
  final CardBillReviewItem item;
  final List<UserCard> cards;

  const _CardBillReviewSheet({required this.item, required this.cards});

  @override
  ConsumerState<_CardBillReviewSheet> createState() =>
      _CardBillReviewSheetState();
}

class _CardBillReviewSheetState extends ConsumerState<_CardBillReviewSheet> {
  late final TextEditingController _amount;
  late final TextEditingController _due;
  late final TextEditingController _statement;
  String? _cardId;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _cardId = widget.item.assignedCardId;
    _amount = TextEditingController(
      text: widget.item.amountDue?.rupees.toStringAsFixed(2) ?? '',
    );
    _due = TextEditingController(text: _dateText(widget.item.dueDate));
    _statement = TextEditingController(
      text: _dateText(widget.item.statementDate),
    );
  }

  static String _dateText(DateTime? date) =>
      date == null ? '' : DateFormat('yyyy-MM-dd').format(date);

  @override
  void dispose() {
    _amount.dispose();
    _due.dispose();
    _statement.dispose();
    super.dispose();
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(controller.text) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) controller.text = _dateText(picked);
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim().replaceAll(',', ''));
    final due = DateTime.tryParse(_due.text.trim());
    final statement = _statement.text.trim().isEmpty
        ? null : DateTime.tryParse(_statement.text.trim());
    if (_cardId == null || amount == null || amount <= 0 || due == null ||
        (_statement.text.trim().isNotEmpty && statement == null)) {
      setState(() => _error = 'Choose a card and enter a valid amount and due date.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final cache = await ref.read(responseCacheProvider.future);
      final namespace = ref.read(cacheNamespaceProvider);
      cache.financialStore.saveCardBillAssignment(
        namespace,
        widget.item.id,
        userCardId: _cardId,
        amountDuePaise: Money.fromRupees(amount).paise,
        dueDate: due,
        statementDate: statement,
      );
      ref.invalidate(cardBillLedgerProvider);
      ref.invalidate(cardBillReviewItemsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save this bill. Try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.cards
        .where((c) => !c.isArchived && c.cardType != 'debit')
        .toList(growable: false);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20,
            MediaQuery.viewInsetsOf(context).bottom + 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Review credit-card bill',
                  style: BambooFonts.heading(18, color: BambooInk.ink900)),
              const SizedBox(height: AppSpace.md),
              Text('From ${widget.item.sender}',
                  style: BambooFonts.ui(12, color: BambooInk.ink500)),
              if (widget.item.body?.isNotEmpty == true) ...[
                const SizedBox(height: AppSpace.sm),
                SelectableText(widget.item.body!,
                    style: BambooFonts.ui(12, color: BambooInk.ink700)),
              ],
              const SizedBox(height: AppSpace.md),
              DropdownButtonFormField<String>(
                initialValue: available.any((c) => c.id == _cardId) ? _cardId : null,
                decoration: const InputDecoration(labelText: 'Card'),
                items: [
                  for (final card in available)
                    DropdownMenuItem(
                      value: card.id,
                      child: Text('${card.nickname ?? card.cardName}'
                          '${card.last4 == null ? '' : ' · •••• ${card.last4}'}'),
                    ),
                ],
                onChanged: (value) => setState(() => _cardId = value),
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                controller: _amount,
                decoration: const InputDecoration(labelText: 'Amount due (₹)'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                controller: _due,
                readOnly: true,
                onTap: () => _pickDate(_due),
                decoration: const InputDecoration(
                  labelText: 'Payment due date',
                  hintText: 'Choose date',
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                controller: _statement,
                readOnly: true,
                onTap: () => _pickDate(_statement),
                decoration: const InputDecoration(
                  labelText: 'Bill generated date (optional)',
                  hintText: 'Choose date',
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpace.sm),
                Text(_error!, style: BambooFonts.ui(12, color: BambooInk.clay)),
              ],
              const SizedBox(height: AppSpace.md),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save bill and card'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
