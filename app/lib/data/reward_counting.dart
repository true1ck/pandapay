import 'package:pandapay_domain/pandapay_domain.dart';

import 'user_cards_repository.dart';

/// Which spends and which reward figures the app counts as "card rewards".
///
/// One rule for every place that adds rewards up or shows one: the activity
/// row chip, the transaction screen, the Insights overview and the Rewards
/// page. Before this lived in one screen, so a pay-later or gift-card spend
/// showed no reward in Activity but still added to the Insights total.

/// Payment methods a credit-card spend can be marked with that do not earn the
/// card's reward (the amount was met with a gift card or reward points, or it
/// is an EMI or a pay-later purchase). The server's reward engine does not read
/// the payment method yet, so a figure may still be stored for these rows: the
/// app does not count it. Keys are the stored payment_method values.
const Map<String, String> noRewardPaymentMethodNotes = {
  'gift_card': 'Paid with a gift card, so no card reward applies.',
  'reward_points': 'Paid with reward points, so no card reward applies.',
  'emi': 'Paid as an EMI, so this spend is not counted for card rewards.',
  'pay_later': 'Paid with pay later, so no card reward applies.',
};

/// An active credit-card purchase above zero: the only rows a card reward can
/// come from. Debit cards, UPI from a bank, wallets and cash never earn a card
/// reward in this app.
bool isCardRewardSpend(TransactionEntry entry) =>
    entry.status == 'active' &&
    entry.entryKind == TxnEntryKind.spend &&
    entry.instrument == TxnInstrument.creditCard &&
    entry.amount.paise > 0;

/// The reward the app counts for [entry]: the stored figure for a credit-card
/// spend on a wallet card, above zero, paid in a way that earns rewards.
/// Null for everything else (not a card spend, a card not in the wallet, a
/// figure not worked out yet, zero, or a payment method that earns nothing).
Money? countedRewardValue(TransactionEntry entry) {
  if (!isCardRewardSpend(entry)) return null;
  if (entry.userCardId == null) return null;
  if (noRewardPaymentMethodNotes.containsKey(entry.paymentMethod)) return null;
  final reward = entry.rewardValue;
  if (reward == null || reward.paise <= 0) return null;
  return reward;
}

/// What a wallet card has earned in total, in rupees: the server's points
/// ledger plus any starting balance the person typed in. A cashback card keeps
/// its balance in rupees (1 unit = ₹1), so it is never multiplied by a point
/// value; a points card is valued at the catalogue's ₹ per point.
Money lifetimeRewardValue(UserCard card, CardProduct product) {
  final units = card.totalPointsEarned;
  final isCashbackCard =
      product.baseRewardUnit == RewardUnit.cashbackPercent ||
      product.baseRewardUnit == RewardUnit.discountPercent;
  return isCashbackCard
      ? Money.fromRupees(units)
      : Money.fromRupees(units * product.pointValueInr);
}
