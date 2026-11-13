import '../../data/user_cards_repository.dart' show TxnInstrument;

/// The `transactions.payment_method` vocabulary, mirrored from the frozen
/// contract `app/test/fixtures/payment_methods_v1.json`.
///
/// A test loads that fixture and asserts this catalogue equals it, so a change
/// here that the contract does not know about fails the build. The stored
/// [TxnInstrument] is never changed by this vocabulary: a cheque is instrument
/// `upi_bank` + method `cheque`.
enum PaymentMethodGroup {
  bank('bank', 'Bank'),
  credit('credit', 'Credit'),
  cards('cards', 'Cards'),
  other('other', 'Other');

  final String wire;
  final String label;
  const PaymentMethodGroup(this.wire, this.label);
}

class PaymentMethod {
  final String wire;
  final String label;
  final PaymentMethodGroup group;

  /// Instruments this method is valid for, first = the one chosen when a method
  /// is picked while no valid instrument is selected.
  final List<TxnInstrument> instruments;

  /// Shown as its own chip in the main row instead of behind "More".
  final bool mainChip;

  /// Not offered below this amount (rupees) when an amount is entered.
  final int? minAmountInr;

  const PaymentMethod({
    required this.wire,
    required this.label,
    required this.group,
    required this.instruments,
    required this.mainChip,
    this.minAmountInr,
  });

  /// A label short enough for a chip: "Auto-debit (NACH ...)" -> "Auto-debit".
  String get shortLabel {
    final cut = label.indexOf(' (');
    return cut < 0 ? label : label.substring(0, cut);
  }

  /// Bank-only methods (net banking, NEFT, cheque, ...) are never offered for a
  /// card, cash or wallet payment. Plain `upi` is not bank-only.
  bool get bankOnly => group == PaymentMethodGroup.bank && wire != 'upi';
}

const List<PaymentMethod> kPaymentMethods = [
  PaymentMethod(
    wire: 'upi',
    label: 'UPI',
    group: PaymentMethodGroup.bank,
    instruments: [
      TxnInstrument.upiBank,
      TxnInstrument.creditCard,
      TxnInstrument.debitCard,
    ],
    mainChip: false,
  ),
  PaymentMethod(
    wire: 'net_banking',
    label: 'Net banking',
    group: PaymentMethodGroup.bank,
    instruments: [TxnInstrument.upiBank],
    mainChip: false,
  ),
  PaymentMethod(
    wire: 'neft',
    label: 'NEFT',
    group: PaymentMethodGroup.bank,
    instruments: [TxnInstrument.upiBank],
    mainChip: false,
  ),
  PaymentMethod(
    wire: 'imps',
    label: 'IMPS',
    group: PaymentMethodGroup.bank,
    instruments: [TxnInstrument.upiBank],
    mainChip: false,
  ),
  PaymentMethod(
    wire: 'rtgs',
    label: 'RTGS',
    group: PaymentMethodGroup.bank,
    instruments: [TxnInstrument.upiBank],
    mainChip: false,
    minAmountInr: 200000,
  ),
  PaymentMethod(
    wire: 'cheque',
    label: 'Cheque',
    group: PaymentMethodGroup.bank,
    instruments: [TxnInstrument.upiBank],
    mainChip: true,
  ),
  PaymentMethod(
    wire: 'demand_draft',
    label: 'Demand draft',
    group: PaymentMethodGroup.bank,
    instruments: [TxnInstrument.upiBank],
    mainChip: false,
  ),
  PaymentMethod(
    wire: 'auto_debit',
    label: 'Auto-debit (NACH / standing instruction)',
    group: PaymentMethodGroup.bank,
    instruments: [TxnInstrument.upiBank],
    mainChip: false,
  ),
  PaymentMethod(
    wire: 'emi',
    label: 'EMI',
    group: PaymentMethodGroup.credit,
    instruments: [
      TxnInstrument.creditCard,
      TxnInstrument.debitCard,
      TxnInstrument.upiBank,
      TxnInstrument.other,
    ],
    mainChip: false,
  ),
  PaymentMethod(
    wire: 'pay_later',
    label: 'Pay later',
    group: PaymentMethodGroup.credit,
    instruments: [TxnInstrument.other],
    mainChip: false,
  ),
  PaymentMethod(
    wire: 'prepaid_card',
    label: 'Prepaid / forex card',
    group: PaymentMethodGroup.cards,
    instruments: [TxnInstrument.wallet],
    mainChip: false,
  ),
  PaymentMethod(
    wire: 'gift_card',
    label: 'Gift card / voucher',
    group: PaymentMethodGroup.other,
    instruments: [TxnInstrument.other],
    mainChip: false,
  ),
  PaymentMethod(
    wire: 'reward_points',
    label: 'Reward points',
    group: PaymentMethodGroup.other,
    instruments: [TxnInstrument.other],
    mainChip: false,
  ),
];

/// Group order as the contract lists it (the order of the "More" sheet).
const List<PaymentMethodGroup> kPaymentMethodGroups = PaymentMethodGroup.values;

/// Instrument order as the contract lists it.
const List<TxnInstrument> kPaymentInstruments = [
  TxnInstrument.creditCard,
  TxnInstrument.debitCard,
  TxnInstrument.cash,
  TxnInstrument.upiBank,
  TxnInstrument.wallet,
  TxnInstrument.other,
];

final Map<String, PaymentMethod> _byWire = {
  for (final method in kPaymentMethods) method.wire: method,
};

/// The catalogue entry for a stored wire value, or null for null / an unknown
/// value (an older or newer client's method must never crash a screen).
PaymentMethod? paymentMethodByWire(String? wire) =>
    wire == null ? null : _byWire[wire];

/// Whether [wire] may be stored together with [instrument].
bool paymentMethodValidFor(String? wire, TxnInstrument? instrument) {
  final method = paymentMethodByWire(wire);
  if (method == null || instrument == null) return false;
  return method.instruments.contains(instrument);
}
