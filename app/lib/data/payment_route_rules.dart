import 'package:pandapay_domain/pandapay_domain.dart';

import 'user_cards_repository.dart';

/// The payment routes that make sense for how something was paid. "Unknown"
/// is always allowed: not knowing the route is better than a wrong one.
List<TxnRail> railsForInstrument(TxnInstrument? instrument) {
  const unknown = TxnRail.unknown;
  return switch (instrument) {
    null => TxnRail.values,
    TxnInstrument.creditCard => const [
      unknown,
      TxnRail.swipe,
      TxnRail.online,
      TxnRail.contactless,
      TxnRail.emi,
      TxnRail.upiQr,
      TxnRail.atm,
    ],
    TxnInstrument.debitCard => const [
      unknown,
      TxnRail.swipe,
      TxnRail.online,
      TxnRail.contactless,
      TxnRail.atm,
      TxnRail.upiQr,
    ],
    TxnInstrument.cash => const [unknown, TxnRail.atm],
    TxnInstrument.upiBank || TxnInstrument.wallet => const [
      unknown,
      TxnRail.upiQr,
      TxnRail.online,
    ],
    TxnInstrument.other => TxnRail.values,
  };
}

bool railFitsInstrument(TxnRail rail, TxnInstrument? instrument) =>
    railsForInstrument(instrument).contains(rail);

/// Whether a card of [cardType] can back a [instrument] payment. A card with
/// no recorded type keeps working for either, as elsewhere in the app.
bool cardFitsInstrument(String? cardType, TxnInstrument? instrument) {
  final type = cardType?.toLowerCase();
  if (type == null || type.isEmpty) return true;
  return switch (instrument) {
    TxnInstrument.creditCard => type == 'credit',
    TxnInstrument.debitCard => type == 'debit',
    _ => true,
  };
}
