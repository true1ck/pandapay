import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/transaction_reward_label.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry _entry({
  TxnInstrument instrument = TxnInstrument.creditCard,
  TxnEntryKind kind = TxnEntryKind.spend,
  String status = 'active',
  String? userCardId = 'card-1',
  Money? reward,
  String rewardState = 'estimated',
}) => TransactionEntry(
  id: 't1',
  amount: Money.fromRupees(1000),
  occurredAt: DateTime(2026, 11, 3),
  userCardId: userCardId,
  instrument: instrument,
  entryKind: kind,
  source: 'sms',
  status: status,
  rewardValue: reward,
  rewardState: rewardState,
);

void main() {
  group('transactionRewardLabel', () {
    test('a priced credit-card spend shows the estimate and says it is one', () {
      final label = transactionRewardLabel(_entry(reward: Money.fromRupees(50)))!;
      expect(label.value, startsWith('≈ '));
      expect(label.value, contains('50'));
      expect(label.note, contains('Estimated'));
    });

    test('a confirmed reward says it was confirmed by the statement', () {
      final label = transactionRewardLabel(
        _entry(reward: Money.fromRupees(50), rewardState: 'confirmed'),
      )!;
      expect(label.note, contains('Confirmed'));
    });

    test('an unpriced credit-card spend is being calculated, never ₹0', () {
      final label = transactionRewardLabel(
        _entry(),
        now: DateTime(2026, 11, 4),
      )!;
      expect(label.value, 'Being calculated');
    });

    test('still unpriced after a few days says so and what to check', () {
      final label = transactionRewardLabel(
        _entry(),
        now: DateTime(2026, 11, 20),
      )!;
      expect(label.value, 'Not calculated');
      expect(label.note, contains('wallet'));
    });

    test('a priced-at-zero spend explains why (excluded, minimum or refunded)', () {
      final label = transactionRewardLabel(_entry(reward: Money.zero()))!;
      expect(label.value, '₹0');
      expect(label.note, contains('refunded'));
    });

    test('a credit-card spend on a card outside the wallet says it is not counted', () {
      final label = transactionRewardLabel(_entry(userCardId: null))!;
      expect(label.value, 'Not counted');
      expect(label.note, contains('wallet'));
    });

    test('payments that are not on a credit card never claim a reward', () {
      for (final instrument in [
        TxnInstrument.upiBank,
        TxnInstrument.wallet,
        TxnInstrument.cash,
        TxnInstrument.other,
      ]) {
        final label = transactionRewardLabel(
          _entry(instrument: instrument, userCardId: null, reward: Money.fromRupees(99)),
        )!;
        expect(label.value, 'None', reason: instrument.name);
      }
      expect(
        transactionRewardLabel(_entry(instrument: TxnInstrument.debitCard))!.value,
        'Not tracked',
      );
    });

    test('income, transfers, refunds, investments and ignored rows have no reward line', () {
      for (final kind in [
        TxnEntryKind.income,
        TxnEntryKind.transfer,
        TxnEntryKind.refund,
        TxnEntryKind.investment,
        TxnEntryKind.unknown,
      ]) {
        expect(transactionRewardLabel(_entry(kind: kind)), isNull, reason: kind.name);
      }
      expect(transactionRewardLabel(_entry(status: 'ignored')), isNull);
      expect(transactionRewardLabel(_entry(status: 'deleted')), isNull);
    });
  });

  group('activityRewardChip', () {
    test('shows only for a priced, positive credit-card spend on a wallet card', () {
      expect(activityRewardChip(_entry(reward: Money.fromRupees(12))), 'Reward ≈ ₹12');
      expect(activityRewardChip(_entry()), isNull);
      expect(activityRewardChip(_entry(reward: Money.zero())), isNull);
      expect(activityRewardChip(_entry(userCardId: null, reward: Money.fromRupees(12))), isNull);
      expect(
        activityRewardChip(_entry(instrument: TxnInstrument.upiBank, reward: Money.fromRupees(12))),
        isNull,
      );
      expect(activityRewardChip(_entry(kind: TxnEntryKind.refund, reward: Money.fromRupees(12))), isNull);
    });

    test('paise are kept when the reward is not a whole rupee', () {
      expect(activityRewardChip(_entry(reward: Money.fromPaise(1250))), 'Reward ≈ ₹12.50');
    });
  });
}
