import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../data/user_cards_repository.dart' show TxnEntryKind, TxnInstrument;
import '../insights/spending_visuals.dart' show spendingInstrumentVisual;
import 'payment_method_catalogue.dart';
import 'payment_method_rules.dart';

/// The "Paid with" chips: the six instruments, Cheque, and a "More" chip that
/// opens a bottom sheet of every other method grouped Bank / Credit / Cards /
/// Other. Choosing an instrument chip behaves exactly as it always has.
///
/// Stateless and cheap: the options come from the pure
/// [paymentOptionsFor], so `build` does a fixed, tiny amount of work.
class PaymentMethodPicker extends StatelessWidget {
  final TxnEntryKind entryKind;
  final PaymentSelection selection;
  final ValueChanged<PaymentSelection> onChanged;

  /// What is saved on the entry being edited; always shown even if a rule
  /// would hide it.
  final TxnInstrument? savedInstrument;
  final String? savedMethod;

  /// The amount entered, for the RTGS minimum. Pass [amountController] instead
  /// to follow what is being typed; the picker then rebuilds on each keystroke
  /// (it is a handful of chips, so that is cheap).
  final double? amountInr;
  final TextEditingController? amountController;
  final String? categorySlug;
  final bool hasCreditCards;
  final bool hasDebitCards;
  final bool cardSelected;

  /// False shows the instrument chips only (no Cheque, no More). Used where a
  /// method cannot be stored (an SMS-ledger row is edited through the SMS
  /// ledger, which has no method field).
  final bool methodsEnabled;

  /// Key of the horizontally scrolling row (tests and Quick Add look it up).
  final Key? rowKey;

  /// Shown under the chips while no instrument is known.
  final String? unknownHint;

  const PaymentMethodPicker({
    super.key,
    required this.entryKind,
    required this.selection,
    required this.onChanged,
    this.savedInstrument,
    this.savedMethod,
    this.amountInr,
    this.amountController,
    this.categorySlug,
    this.hasCreditCards = false,
    this.hasDebitCards = false,
    this.cardSelected = false,
    this.methodsEnabled = true,
    this.rowKey,
    this.unknownHint,
  });

  @override
  Widget build(BuildContext context) {
    final controller = amountController;
    if (controller == null) return _buildRow(context, amountInr);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) =>
          _buildRow(context, double.tryParse(controller.text.trim())),
    );
  }

  Widget _buildRow(BuildContext context, double? amount) {
    final options = paymentOptionsFor(
      PaymentRulesInput(
        entryKind: entryKind,
        instrument: selection.instrument,
        method: methodsEnabled ? selection.method : null,
        amountInr: amount,
        categorySlug: categorySlug,
        hasCreditCards: hasCreditCards,
        hasDebitCards: hasDebitCards,
        cardSelected: cardSelected,
        savedInstrument: savedInstrument,
        savedMethod: methodsEnabled ? savedMethod : null,
      ),
    );
    final chips = methodsEnabled
        ? options.mainChips
        : [
            for (final chip in options.mainChips)
              if (chip.kind == PaymentChipKind.instrument) chip,
          ];
    final selectedMethod = methodsEnabled
        ? paymentMethodByWire(selection.method)
        : null;
    final moreSelected = selectedMethod != null && !selectedMethod.mainChip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          key: rowKey,
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final chip in chips)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: switch (chip.kind) {
                    PaymentChipKind.instrument => PaymentChoiceChip(
                      key: ValueKey(
                        'payment-chip-instrument-${chip.instrument!.wireValue}',
                      ),
                      label: chip.label,
                      icon: spendingInstrumentVisual(
                        chip.instrument!.wireValue,
                      ).icon,
                      selected: chip.selected,
                      onTap: () => onChanged(
                        selectPaymentInstrument(selection, chip.instrument!),
                      ),
                    ),
                    PaymentChipKind.method => PaymentChoiceChip(
                      key: ValueKey('payment-chip-method-${chip.method!.wire}'),
                      label: chip.label,
                      icon: Icons.edit_note_rounded,
                      selected: chip.selected,
                      onTap: () => onChanged(
                        chip.selected
                            ? clearPaymentMethod(selection)
                            : selectPaymentMethod(
                                selection,
                                chip.method!.wire,
                                entryKind,
                              ),
                      ),
                    ),
                  },
                ),
              if (methodsEnabled && options.showMore)
                PaymentChoiceChip(
                  key: const ValueKey('payment-more-chip'),
                  label: moreSelected ? selectedMethod.shortLabel : 'More',
                  icon: Icons.more_horiz_rounded,
                  selected: moreSelected,
                  onTap: () => _openMore(context, options),
                ),
            ],
          ),
        ),
        if (unknownHint != null && selection.instrument == null) ...[
          const SizedBox(height: 6),
          Text(
            unknownHint!,
            style: BambooFonts.ui(12, color: BambooInk.ink700),
          ),
        ],
      ],
    );
  }

  Future<void> _openMore(BuildContext context, PaymentOptions options) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BambooInk.paper,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Text(
                'How was it paid?',
                style: BambooFonts.heading(18, color: BambooInk.ink900),
              ),
            ),
            if (selection.method != null)
              ListTile(
                key: const ValueKey('payment-more-clear'),
                leading: const Icon(
                  Icons.close_rounded,
                  color: BambooInk.ink700,
                ),
                title: const Text('No specific method'),
                onTap: () => Navigator.of(sheetContext).pop(_clearToken),
              ),
            for (final group in options.more) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 14, 8, 2),
                child: Text(
                  group.group.label,
                  style: BambooFonts.ui(
                    12,
                    weight: FontWeight.w600,
                    color: BambooInk.ink700,
                  ),
                ),
              ),
              for (final method in group.methods)
                ListTile(
                  key: ValueKey('payment-more-option-${method.wire}'),
                  title: Text(method.label),
                  trailing: selection.method == method.wire
                      ? const Icon(
                          Icons.check_circle,
                          color: BambooInk.slate,
                          semanticLabel: 'Selected',
                        )
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(method.wire),
                ),
            ],
          ],
        ),
      ),
    );
    if (picked == null) return;
    onChanged(
      picked == _clearToken
          ? clearPaymentMethod(selection)
          : selectPaymentMethod(selection, picked, entryKind),
    );
  }

  static const _clearToken = '__clear__';
}

/// The Quick Add chip look (rounded 10, lime wash when selected), public so the
/// Edit screen uses the identical control.
class PaymentChoiceChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const PaymentChoiceChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected
          ? BambooInk.lime.withValues(alpha: 0.28)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? BambooInk.lime : BambooInk.hairlineOnPaper,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? BambooInk.ink900 : BambooInk.ink700,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(
                    11.5,
                    weight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: BambooInk.ink900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
