import '../../data/reward_counting.dart';
import '../../data/user_cards_repository.dart';

/// What the transaction screen says about the reward a spend earned.
///
/// Every spend gets an honest line, never a blank and never a made-up number:
/// a payment that cannot earn card rewards says why, a card that is not in the
/// wallet says so, and a figure the server has not priced yet is "being
/// calculated" rather than ₹0.
class TransactionRewardLabel {
  const TransactionRewardLabel(this.value, {this.note});

  /// The short line shown as the row's value.
  final String value;

  /// Optional second line that explains the value.
  final String? note;
}

/// Null when the row has no reward line at all (income, transfers, a refund,
/// an ignored or deleted row).
TransactionRewardLabel? transactionRewardLabel(
  TransactionEntry entry, {
  DateTime? now,
}) {
  if (entry.entryKind != TxnEntryKind.spend || entry.status != 'active') {
    return null;
  }
  switch (entry.instrument) {
    case TxnInstrument.creditCard:
      break;
    case TxnInstrument.debitCard:
      return const TransactionRewardLabel(
        'Not tracked',
        note: 'Debit card rewards are not calculated.',
      );
    case TxnInstrument.upiBank:
      return const TransactionRewardLabel(
        'None',
        note: 'Paid from a bank account by UPI, so no card reward applies.',
      );
    case TxnInstrument.wallet:
      return const TransactionRewardLabel(
        'None',
        note: 'Paid from a wallet, so no card reward applies.',
      );
    case TxnInstrument.cash:
      return const TransactionRewardLabel(
        'None',
        note: 'Paid in cash, so no card reward applies.',
      );
    case TxnInstrument.other:
      return const TransactionRewardLabel(
        'None',
        note: 'This payment method does not earn a card reward.',
      );
  }
  final methodNote = noRewardPaymentMethodNotes[entry.paymentMethod];
  if (methodNote != null) {
    return TransactionRewardLabel('None', note: methodNote);
  }
  if (entry.userCardId == null) {
    return const TransactionRewardLabel(
      'Not counted',
      note:
          'This card is not in your wallet yet. Add it, and this spend is counted.',
    );
  }
  final reward = entry.rewardValue;
  if (reward == null) {
    // A fresh spend is priced within moments of syncing. One that is still
    // unpriced after a few days is not "being calculated": say what is true
    // and what to check (an archived card is never priced). Opening Cards does
    // nothing for this, so it is not offered as the fix: the server prices the
    // spend when it next syncs with this phone.
    final age = (now ?? DateTime.now()).difference(entry.occurredAt);
    if (age > const Duration(days: 3)) {
      return const TransactionRewardLabel(
        'Not calculated',
        note:
            'This card is linked, but no reward has been worked out for this '
            'spend yet. It is filled in when your phone next syncs. If it '
            'stays, check that the card is still in your wallet.',
      );
    }
    return const TransactionRewardLabel(
      'Being calculated',
      note: 'It appears once this spend has synced.',
    );
  }
  if (reward.paise <= 0) {
    return const TransactionRewardLabel(
      '₹0',
      note:
          'This spend earns nothing on this card (an excluded category or '
          'below the minimum), or it was refunded.',
    );
  }
  return TransactionRewardLabel(
    '≈ ${reward.format()}',
    // reward_state 'confirmed' only says the spend itself came from a card
    // statement. The figure is still what the card's rules work out, not a
    // credit the bank paid (those are 'issuer credit' rows on the card's
    // points history), so it is never called confirmed here.
    note: entry.rewardState == 'confirmed'
        ? 'The spend is on your card statement. The reward is an estimate '
              'from your card\'s rules.'
        : 'Estimated from your card\'s rules.',
  );
}

/// The short chip on an activity row: "Reward ≈ ₹12" for a credit-card spend the
/// server has priced above zero, otherwise null (an unpriced, excluded or
/// non-card spend adds no clutter to the list).
String? activityRewardChip(TransactionEntry entry) {
  final reward = countedRewardValue(entry);
  if (reward == null) return null;
  return 'Reward ≈ ${reward.format(hidePaise: reward.paise % 100 == 0)}';
}
