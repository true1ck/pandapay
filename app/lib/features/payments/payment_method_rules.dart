import '../../data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument;
import 'payment_method_catalogue.dart';

/// Smart "Paid with" rules. A PURE function of its input: no providers, no I/O,
/// no history scan, 13 catalogue rows. Safe to call from `build`.
///
/// Three tiers, from `docs/implementation/payment-methods/SPEC.md`:
///  * hidden (impossible): cash / card / wallet never offer bank-only methods,
///    cash offers no method at all, income / transfer / investment never offer
///    the credit-card instrument, RTGS is hidden below its minimum amount.
///  * suggested: rent / emi / insurance / education / government on a
///    UPI-bank payment move Cheque / NEFT / Net banking first. Never hides.
///  * more: every method that is not a main chip lives behind "More".
/// The entry's CURRENT saved value (and the live selection) is always
/// included even when a rule would hide it.

/// What the form currently holds.
class PaymentSelection {
  final TxnInstrument? instrument;
  final String? method;
  const PaymentSelection({this.instrument, this.method});

  @override
  bool operator ==(Object other) =>
      other is PaymentSelection &&
      other.instrument == instrument &&
      other.method == method;

  @override
  int get hashCode => Object.hash(instrument, method);

  @override
  String toString() => 'PaymentSelection($instrument, $method)';
}

/// Category slugs for which Cheque / NEFT / Net banking are suggested first.
const Set<String> kPaymentSuggestCategorySlugs = {
  'rent',
  'emi',
  'insurance',
  'education',
  'government',
};

/// The order suggested methods are put in.
const List<String> kSuggestedBankMethods = ['cheque', 'neft', 'net_banking'];

class PaymentRulesInput {
  final TxnEntryKind entryKind;
  final TxnInstrument? instrument;
  final String? method;
  final double? amountInr;
  final String? categorySlug;
  final bool hasCreditCards;
  final bool hasDebitCards;

  /// A card is already chosen for the selected card instrument. A method that
  /// would force a different instrument is then not offered, so a selected card
  /// is never silently dropped.
  final bool cardSelected;

  /// What is saved on the entry being edited (null/null when adding).
  final TxnInstrument? savedInstrument;
  final String? savedMethod;

  const PaymentRulesInput({
    required this.entryKind,
    required this.instrument,
    this.method,
    this.amountInr,
    this.categorySlug,
    this.hasCreditCards = false,
    this.hasDebitCards = false,
    this.cardSelected = false,
    this.savedInstrument,
    this.savedMethod,
  });
}

enum PaymentChipKind { instrument, method }

/// One chip in the main row.
class PaymentChipSpec {
  final PaymentChipKind kind;
  final TxnInstrument? instrument;
  final PaymentMethod? method;
  final String label;
  final bool selected;

  const PaymentChipSpec.instrument(
    TxnInstrument this.instrument, {
    required this.label,
    required this.selected,
  }) : kind = PaymentChipKind.instrument,
       method = null;

  const PaymentChipSpec.method(
    PaymentMethod this.method, {
    required this.label,
    required this.selected,
  }) : kind = PaymentChipKind.method,
       instrument = null;
}

/// One group of the "More" sheet.
class PaymentMoreGroup {
  final PaymentMethodGroup group;
  final List<PaymentMethod> methods;
  const PaymentMoreGroup(this.group, this.methods);
}

class PaymentOptions {
  /// Ordered main chips: instruments, then the main-chip methods (Cheque).
  final List<PaymentChipSpec> mainChips;

  /// Grouped "More" options; empty means the More chip is not shown.
  final List<PaymentMoreGroup> more;

  /// Wire values that are suggested for this category (empty when none).
  final List<String> suggested;

  /// The credit/debit card picker applies.
  final bool cardPicker;

  /// The user has no card of the selected kind (the picker explains it).
  final bool cardPickerEmpty;

  /// A bank account follow-up applies (a bank method on a UPI/bank payment).
  /// No screen renders one today; it is reported so the rules stay complete.
  final bool bankAccount;

  const PaymentOptions({
    required this.mainChips,
    required this.more,
    required this.suggested,
    required this.cardPicker,
    required this.cardPickerEmpty,
    required this.bankAccount,
  });

  bool get showMore => more.isNotEmpty;
}

/// The chip label for an instrument (the existing Quick Add wording).
String paymentInstrumentChipLabel(TxnInstrument instrument) =>
    switch (instrument) {
      TxnInstrument.creditCard => 'Credit card',
      TxnInstrument.debitCard => 'Debit',
      TxnInstrument.upiBank => 'UPI / bank',
      TxnInstrument.cash => 'Cash',
      TxnInstrument.wallet => 'Wallet',
      TxnInstrument.other => 'Other',
    };

bool _isCardInstrument(TxnInstrument? instrument) =>
    instrument == TxnInstrument.creditCard ||
    instrument == TxnInstrument.debitCard;

/// Whether the credit-card instrument may be chosen for [kind] (existing rule).
bool paymentInstrumentAllowedForKind(
  TxnInstrument instrument,
  TxnEntryKind kind,
) => instrument != TxnInstrument.creditCard || kind == TxnEntryKind.spend;

bool _methodOffered(PaymentMethod method, PaymentRulesInput input) {
  final instrument = input.instrument;
  // Cash has no method at all.
  if (instrument == TxnInstrument.cash) return false;
  // Cards and wallets never offer bank-only methods.
  if ((_isCardInstrument(instrument) || instrument == TxnInstrument.wallet) &&
      method.bankOnly) {
    return false;
  }
  // RTGS below its minimum, only when an amount is entered.
  final min = method.minAmountInr;
  final amount = input.amountInr;
  if (min != null && amount != null && amount < min) return false;
  // A chosen card is never dropped: no method that forces another instrument.
  if (input.cardSelected &&
      _isCardInstrument(instrument) &&
      !method.instruments.contains(instrument)) {
    return false;
  }
  return true;
}

/// The instrument chosen when [method] is picked and the current instrument is
/// not valid for it: the first valid instrument that the entry kind allows.
TxnInstrument? firstValidInstrument(PaymentMethod method, TxnEntryKind kind) {
  for (final instrument in method.instruments) {
    if (paymentInstrumentAllowedForKind(instrument, kind)) return instrument;
  }
  return null;
}

/// Ordered chips, grouped More options and follow-up panels for [input].
PaymentOptions paymentOptionsFor(PaymentRulesInput input) {
  final instrument = input.instrument;
  final kind = input.entryKind;
  final selectedWire = input.method;

  // Wire values that must stay visible regardless of the rules.
  final keep = <String>{?selectedWire, ?input.savedMethod};
  bool shown(PaymentMethod method) =>
      keep.contains(method.wire) || _methodOffered(method, input);

  final suggest =
      instrument == TxnInstrument.upiBank &&
      input.categorySlug != null &&
      kPaymentSuggestCategorySlugs.contains(input.categorySlug);
  final suggested = suggest ? kSuggestedBankMethods : const <String>[];

  final instrumentChips = <PaymentChipSpec>[];
  for (final candidate in kPaymentInstruments) {
    if (paymentInstrumentAllowedForKind(candidate, kind) ||
        candidate == instrument ||
        candidate == input.savedInstrument) {
      instrumentChips.add(
        PaymentChipSpec.instrument(
          candidate,
          label: paymentInstrumentChipLabel(candidate),
          selected: instrument == candidate,
        ),
      );
    }
  }

  final methodChips = <PaymentChipSpec>[
    for (final method in kPaymentMethods)
      if (method.mainChip && shown(method))
        PaymentChipSpec.method(
          method,
          label: method.shortLabel,
          selected: selectedWire == method.wire,
        ),
  ];
  if (suggest) {
    methodChips.sort(
      (a, b) => _suggestRank(a.method!.wire) - _suggestRank(b.method!.wire),
    );
  }

  // Method chips go after the instrument chips; when suggested they sit right
  // after the UPI / bank chip instead.
  final mainChips = <PaymentChipSpec>[];
  if (suggest) {
    for (final chip in instrumentChips) {
      mainChips.add(chip);
      if (chip.instrument == TxnInstrument.upiBank) mainChips.addAll(methodChips);
    }
  } else {
    mainChips
      ..addAll(instrumentChips)
      ..addAll(methodChips);
  }

  final more = <PaymentMoreGroup>[];
  for (final group in kPaymentMethodGroups) {
    final methods = [
      for (final method in kPaymentMethods)
        if (method.group == group && !method.mainChip && shown(method)) method,
    ];
    if (methods.isEmpty) continue;
    if (suggest && group == PaymentMethodGroup.bank) {
      methods.sort((a, b) => _suggestRank(a.wire) - _suggestRank(b.wire));
    }
    more.add(PaymentMoreGroup(group, methods));
  }

  final cardPicker = _isCardInstrument(instrument);
  final method = paymentMethodByWire(selectedWire);
  return PaymentOptions(
    mainChips: mainChips,
    more: more,
    suggested: suggested,
    cardPicker: cardPicker,
    cardPickerEmpty:
        cardPicker &&
        !(instrument == TxnInstrument.creditCard
            ? input.hasCreditCards
            : input.hasDebitCards),
    bankAccount:
        instrument == TxnInstrument.upiBank && (method?.bankOnly ?? false),
  );
}

/// Stable sort key: suggested methods first, in [kSuggestedBankMethods] order,
/// everything else keeps its catalogue order (List.sort is not stable in all
/// cases, so ties are broken by catalogue index).
int _suggestRank(String wire) {
  final index = kSuggestedBankMethods.indexOf(wire);
  if (index >= 0) return index - 1000;
  return kPaymentMethods.indexWhere((m) => m.wire == wire);
}

/// The person tapped an instrument chip: selecting an instrument clears a
/// method that is not valid for it. Re-selecting the same instrument changes
/// nothing (as today).
PaymentSelection selectPaymentInstrument(
  PaymentSelection current,
  TxnInstrument next,
) {
  if (current.instrument == next) return current;
  final keepMethod =
      next != TxnInstrument.cash && paymentMethodValidFor(current.method, next);
  return PaymentSelection(
    instrument: next,
    method: keepMethod ? current.method : null,
  );
}

/// The person chose a method: keep the instrument when it is valid for it
/// (so a chosen card stays), otherwise move to the first valid instrument.
PaymentSelection selectPaymentMethod(
  PaymentSelection current,
  String wire,
  TxnEntryKind kind,
) {
  final method = paymentMethodByWire(wire);
  if (method == null) return current;
  final instrument = current.instrument;
  if (instrument != null && method.instruments.contains(instrument)) {
    return PaymentSelection(instrument: instrument, method: wire);
  }
  final next = firstValidInstrument(method, kind);
  if (next == null) return current;
  return PaymentSelection(instrument: next, method: wire);
}

/// Back to "no specific method", keeping the instrument.
PaymentSelection clearPaymentMethod(PaymentSelection current) =>
    PaymentSelection(instrument: current.instrument);
