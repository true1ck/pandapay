import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument;
import 'package:pandapay/features/payments/payment_method_catalogue.dart';
import 'package:pandapay/features/payments/payment_method_rules.dart';

const _spend = TxnEntryKind.spend;
const _credit = TxnInstrument.creditCard;
const _debit = TxnInstrument.debitCard;
const _cash = TxnInstrument.cash;
const _bank = TxnInstrument.upiBank;
const _wallet = TxnInstrument.wallet;
const _other = TxnInstrument.other;

const _allInstrumentLabels = [
  'Credit card',
  'Debit',
  'Cash',
  'UPI / bank',
  'Wallet',
  'Other',
];

PaymentOptions _options({
  TxnEntryKind kind = _spend,
  TxnInstrument? instrument = _credit,
  String? method,
  double? amount,
  String? category,
  bool hasCredit = false,
  bool hasDebit = false,
  bool cardSelected = false,
  TxnInstrument? savedInstrument,
  String? savedMethod,
}) => paymentOptionsFor(
  PaymentRulesInput(
    entryKind: kind,
    instrument: instrument,
    method: method,
    amountInr: amount,
    categorySlug: category,
    hasCreditCards: hasCredit,
    hasDebitCards: hasDebit,
    cardSelected: cardSelected,
    savedInstrument: savedInstrument,
    savedMethod: savedMethod,
  ),
);

List<String> _chips(PaymentOptions o) => [for (final c in o.mainChips) c.label];
Set<String> _moreWires(PaymentOptions o) => {
  for (final g in o.more)
    for (final m in g.methods) m.wire,
};
List<String> _bankMore(PaymentOptions o) => [
  for (final g in o.more)
    if (g.group == PaymentMethodGroup.bank)
      for (final m in g.methods) m.wire,
];

void main() {
  group('main chips', () {
    test('default Quick Add (credit card, spend) keeps today\'s six chips', () {
      final o = _options();
      expect(_chips(o), _allInstrumentLabels);
      expect(o.mainChips.where((c) => c.selected).map((c) => c.label), [
        'Credit card',
      ]);
    });

    test('UPI / bank adds the Cheque chip after the instruments', () {
      final o = _options(instrument: _bank);
      expect(_chips(o), [..._allInstrumentLabels, 'Cheque']);
    });

    test('cards, cash and wallet never offer the Cheque chip', () {
      for (final instrument in [_credit, _debit, _cash, _wallet]) {
        expect(
          _chips(_options(instrument: instrument)),
          _allInstrumentLabels,
          reason: '$instrument',
        );
      }
    });

    test('Other offers Cheque (choosing it moves to UPI / bank)', () {
      expect(_chips(_options(instrument: _other)), contains('Cheque'));
    });

    test('unknown instrument (edit of a row with none) offers everything', () {
      final o = _options(instrument: null);
      expect(_chips(o), [..._allInstrumentLabels, 'Cheque']);
      expect(o.mainChips.where((c) => c.selected), isEmpty);
      expect(o.cardPicker, isFalse);
    });

    for (final kind in [
      TxnEntryKind.income,
      TxnEntryKind.transfer,
      TxnEntryKind.investment,
    ]) {
      test('$kind never offers the credit-card instrument', () {
        final chips = _chips(_options(kind: kind, instrument: _bank));
        expect(chips, isNot(contains('Credit card')));
        expect(chips, containsAll(['Debit', 'Cash', 'UPI / bank']));
      });
    }

    test('refund keeps the existing rule (credit card only for spend)', () {
      expect(
        _chips(_options(kind: TxnEntryKind.refund, instrument: _bank)),
        isNot(contains('Credit card')),
      );
    });

    test('a saved credit-card instrument stays on an income entry', () {
      final o = _options(
        kind: TxnEntryKind.income,
        instrument: _credit,
        savedInstrument: _credit,
      );
      expect(_chips(o), contains('Credit card'));
      expect(o.mainChips.firstWhere((c) => c.label == 'Credit card').selected,
          isTrue);
    });

    test('a saved credit card stays even once another instrument is selected',
        () {
      final o = _options(
        kind: TxnEntryKind.income,
        instrument: _bank,
        savedInstrument: _credit,
      );
      expect(_chips(o), contains('Credit card'));
    });
  });

  group('More options (hard-hidden tier)', () {
    test('UPI / bank offers every bank method, RTGS included with no amount',
        () {
      final o = _options(instrument: _bank);
      expect(
        _bankMore(o),
        ['upi', 'net_banking', 'neft', 'imps', 'rtgs', 'demand_draft', 'auto_debit'],
      );
      expect(_moreWires(o), containsAll(['emi', 'pay_later', 'prepaid_card']));
      // Cheque is a main chip, never inside More.
      expect(_moreWires(o), isNot(contains('cheque')));
    });

    test('groups come in contract order and only when non-empty', () {
      final o = _options(instrument: _bank);
      expect(o.more.map((g) => g.group.wire), [
        'bank',
        'credit',
        'cards',
        'other',
      ]);
      final cash = _options(instrument: _cash);
      expect(cash.more, isEmpty);
      expect(cash.showMore, isFalse);
    });

    test('credit card, debit, wallet never offer bank-only methods', () {
      const bankOnly = {
        'net_banking',
        'neft',
        'imps',
        'rtgs',
        'cheque',
        'demand_draft',
        'auto_debit',
      };
      for (final instrument in [_credit, _debit, _wallet]) {
        final wires = _moreWires(_options(instrument: instrument));
        expect(wires.intersection(bankOnly), isEmpty, reason: '$instrument');
      }
    });

    test('credit card and debit still offer UPI and EMI', () {
      for (final instrument in [_credit, _debit]) {
        expect(
          _moreWires(_options(instrument: instrument)),
          containsAll(['upi', 'emi']),
        );
      }
    });

    test('wallet offers prepaid card', () {
      expect(_moreWires(_options(instrument: _wallet)), contains('prepaid_card'));
    });

    test('cash offers no method and no card picker', () {
      final o = _options(instrument: _cash);
      expect(o.more, isEmpty);
      expect(o.cardPicker, isFalse);
      expect(o.bankAccount, isFalse);
      expect(_chips(o), isNot(contains('Cheque')));
    });

    test('RTGS: hidden below 200000 once an amount is entered', () {
      expect(_moreWires(_options(instrument: _bank, amount: 199999)),
          isNot(contains('rtgs')));
      expect(_moreWires(_options(instrument: _bank, amount: 0.01)),
          isNot(contains('rtgs')));
      expect(_moreWires(_options(instrument: _bank, amount: 200000)),
          contains('rtgs'));
      expect(_moreWires(_options(instrument: _bank, amount: 5000000)),
          contains('rtgs'));
      expect(_moreWires(_options(instrument: _bank)), contains('rtgs'));
    });

    test('a selected chosen card is never dropped: only valid methods offered',
        () {
      final o = _options(instrument: _credit, cardSelected: true);
      expect(_moreWires(o), {'upi', 'emi'});
      // Every offered method keeps the card instrument when chosen.
      for (final wire in _moreWires(o)) {
        final next = selectPaymentMethod(
          const PaymentSelection(instrument: _credit),
          wire,
          _spend,
        );
        expect(next.instrument, _credit, reason: wire);
      }
      final debit = _options(instrument: _debit, cardSelected: true);
      expect(_moreWires(debit), {'upi', 'emi'});
    });

    test('with no card chosen, other methods are still offered', () {
      expect(
        _moreWires(_options(instrument: _credit)),
        containsAll(['upi', 'emi', 'pay_later', 'prepaid_card', 'gift_card']),
      );
    });
  });

  group('suggested tier (orders, never hides)', () {
    const suggestedCategories = [
      'rent',
      'emi',
      'insurance',
      'education',
      'government',
    ];
    final plain = _options(instrument: _bank);

    for (final category in suggestedCategories) {
      test('$category on UPI / bank puts Cheque / NEFT / Net banking first',
          () {
        final o = _options(instrument: _bank, category: category);
        expect(o.suggested, ['cheque', 'neft', 'net_banking']);
        // Cheque sits right after the UPI / bank chip.
        final labels = _chips(o);
        expect(
          labels,
          ['Credit card', 'Debit', 'Cash', 'UPI / bank', 'Cheque', 'Wallet', 'Other'],
        );
        // NEFT and Net banking lead the Bank group.
        expect(_bankMore(o).take(2), ['neft', 'net_banking']);
        // Nothing is hidden: same set as with no category.
        expect(_moreWires(o), _moreWires(plain));
        expect(labels.toSet(), _chips(plain).toSet());
      });
    }

    test('other categories do not reorder', () {
      for (final category in ['groceries', 'food', 'shopping', 'rental']) {
        final o = _options(instrument: _bank, category: category);
        expect(o.suggested, isEmpty, reason: category);
        expect(_chips(o), _chips(plain), reason: category);
        expect(_bankMore(o), _bankMore(plain), reason: category);
      }
    });

    test('suggestions only apply to a UPI / bank payment', () {
      for (final instrument in [_credit, _debit, _cash, _wallet, _other, null]) {
        final o = _options(instrument: instrument, category: 'rent');
        expect(o.suggested, isEmpty, reason: '$instrument');
        expect(
          _chips(o),
          _chips(_options(instrument: instrument)),
          reason: '$instrument',
        );
      }
    });

    test('cash on delivery (Cash) stays selectable for every category', () {
      for (final category in [...suggestedCategories, 'groceries', null]) {
        for (final instrument in [_bank, _credit, _cash, _wallet, _other]) {
          final o = _options(instrument: instrument, category: category);
          expect(_chips(o), contains('Cash'),
              reason: '$category / $instrument');
        }
      }
      // And choosing it after a suggested category is not blocked.
      final next = selectPaymentInstrument(
        const PaymentSelection(instrument: _bank, method: 'cheque'),
        _cash,
      );
      expect(next, const PaymentSelection(instrument: _cash));
    });

    test('suggested methods respect hard rules (RTGS is never suggested)', () {
      final o = _options(instrument: _bank, category: 'rent', amount: 1000);
      expect(_moreWires(o), isNot(contains('rtgs')));
    });
  });

  group('current saved value is always included', () {
    test('a saved RTGS stays even though the amount is below the minimum', () {
      final o = _options(
        instrument: _bank,
        method: 'rtgs',
        amount: 5000,
        savedInstrument: _bank,
        savedMethod: 'rtgs',
      );
      expect(_moreWires(o), contains('rtgs'));
    });

    test('a saved RTGS stays even when not currently selected', () {
      final o = _options(
        instrument: _bank,
        amount: 5000,
        savedInstrument: _bank,
        savedMethod: 'rtgs',
      );
      expect(_moreWires(o), contains('rtgs'));
    });

    test('a selected RTGS stays when the amount is edited below the minimum',
        () {
      final o = _options(instrument: _bank, method: 'rtgs', amount: 10);
      expect(_moreWires(o), contains('rtgs'));
    });

    test('a saved bank-only method stays on an instrument that hides it', () {
      final o = _options(
        instrument: _credit,
        savedInstrument: _credit,
        savedMethod: 'neft',
      );
      expect(_moreWires(o), contains('neft'));
    });

    test('a saved Cheque keeps its chip even on cash', () {
      final o = _options(
        instrument: _cash,
        method: 'cheque',
        savedInstrument: _cash,
        savedMethod: 'cheque',
      );
      expect(_chips(o), contains('Cheque'));
      expect(o.mainChips.firstWhere((c) => c.label == 'Cheque').selected,
          isTrue);
    });

    test('a saved method is shown on cash although cash offers none', () {
      final o = _options(
        instrument: _cash,
        savedInstrument: _cash,
        savedMethod: 'emi',
      );
      expect(_moreWires(o), {'emi'});
    });

    test('an unknown saved wire value never crashes or appears', () {
      final o = _options(
        instrument: _bank,
        method: 'bitcoin',
        savedMethod: 'bitcoin',
      );
      expect(_moreWires(o), isNot(contains('bitcoin')));
      expect(_chips(o), [..._allInstrumentLabels, 'Cheque']);
    });
  });

  group('existing entries', () {
    test('an entry with no method renders exactly as a fresh entry', () {
      for (final instrument in TxnInstrument.values) {
        final fresh = _options(instrument: instrument);
        final saved = _options(
          instrument: instrument,
          savedInstrument: instrument,
        );
        expect(_chips(saved), _chips(fresh), reason: '$instrument');
        expect(_moreWires(saved), _moreWires(fresh), reason: '$instrument');
        expect(saved.mainChips.where((c) => c.selected).length, 1,
            reason: '$instrument');
      }
    });

    test('legacy SMS entry: upi_bank + upi shows UPI selected in More', () {
      final o = _options(
        instrument: _bank,
        method: 'upi',
        savedInstrument: _bank,
        savedMethod: 'upi',
      );
      expect(o.mainChips.where((c) => c.selected).map((c) => c.label),
          ['UPI / bank']);
      expect(_bankMore(o).first, 'upi');
      expect(o.bankAccount, isFalse, reason: 'plain UPI is not a bank method');
    });

    test('legacy credit card + upi (SMS) keeps Credit card and the card picker',
        () {
      final o = _options(
        instrument: _credit,
        method: 'upi',
        savedInstrument: _credit,
        savedMethod: 'upi',
        hasCredit: true,
      );
      expect(o.mainChips.where((c) => c.selected).map((c) => c.label),
          ['Credit card']);
      expect(o.cardPicker, isTrue);
    });
  });

  group('follow-up panels', () {
    test('card picker for credit and debit only', () {
      for (final instrument in TxnInstrument.values) {
        expect(
          _options(instrument: instrument).cardPicker,
          instrument == _credit || instrument == _debit,
          reason: '$instrument',
        );
      }
    });

    test('card picker reports when the user has no card of that kind', () {
      expect(_options(instrument: _credit).cardPickerEmpty, isTrue);
      expect(_options(instrument: _credit, hasCredit: true).cardPickerEmpty,
          isFalse);
      expect(_options(instrument: _credit, hasDebit: true).cardPickerEmpty,
          isTrue);
      expect(_options(instrument: _debit, hasDebit: true).cardPickerEmpty,
          isFalse);
      expect(_options(instrument: _bank).cardPickerEmpty, isFalse);
    });

    test('bank account follow-up for a bank method on UPI / bank only', () {
      for (final method in ['cheque', 'neft', 'net_banking', 'imps', 'rtgs',
        'demand_draft', 'auto_debit']) {
        expect(_options(instrument: _bank, method: method).bankAccount, isTrue,
            reason: method);
      }
      expect(_options(instrument: _bank).bankAccount, isFalse);
      expect(_options(instrument: _bank, method: 'upi').bankAccount, isFalse);
      expect(_options(instrument: _bank, method: 'emi').bankAccount, isFalse);
      expect(_options(instrument: _cash, method: 'cheque').bankAccount, isFalse);
    });

    test('selected chips follow the selection', () {
      final o = _options(instrument: _bank, method: 'cheque');
      expect(
        o.mainChips.where((c) => c.selected).map((c) => c.label).toSet(),
        {'UPI / bank', 'Cheque'},
      );
    });
  });

  group('selection transitions', () {
    test('choosing Cheque moves to UPI / bank from every other instrument', () {
      for (final instrument in [null, _other, _credit, _debit, _cash, _wallet]) {
        final next = selectPaymentMethod(
          PaymentSelection(instrument: instrument),
          'cheque',
          _spend,
        );
        expect(next, const PaymentSelection(instrument: _bank, method: 'cheque'),
            reason: '$instrument');
      }
    });

    test('choosing a method keeps the instrument when it is valid for it', () {
      expect(
        selectPaymentMethod(
          const PaymentSelection(instrument: _credit),
          'emi',
          _spend,
        ),
        const PaymentSelection(instrument: _credit, method: 'emi'),
      );
      expect(
        selectPaymentMethod(
          const PaymentSelection(instrument: _bank),
          'neft',
          _spend,
        ),
        const PaymentSelection(instrument: _bank, method: 'neft'),
      );
    });

    test('choosing a method with no valid instrument chosen picks the first', () {
      final expected = {
        'emi': _credit,
        'pay_later': _other,
        'prepaid_card': _wallet,
        'gift_card': _other,
        'reward_points': _other,
        'upi': _bank,
        'net_banking': _bank,
        'rtgs': _bank,
      };
      expected.forEach((wire, instrument) {
        expect(
          selectPaymentMethod(
            const PaymentSelection(instrument: null),
            wire,
            _spend,
          ).instrument,
          instrument,
          reason: wire,
        );
      });
    });

    test('first valid instrument skips the credit card for non-spend entries',
        () {
      for (final kind in [
        TxnEntryKind.income,
        TxnEntryKind.transfer,
        TxnEntryKind.investment,
      ]) {
        expect(
          selectPaymentMethod(
            const PaymentSelection(instrument: _cash),
            'emi',
            kind,
          ).instrument,
          _debit,
          reason: '$kind',
        );
      }
    });

    test('choosing an unknown method changes nothing', () {
      const current = PaymentSelection(instrument: _bank, method: 'neft');
      expect(selectPaymentMethod(current, 'bitcoin', _spend), current);
    });

    test('selecting an instrument clears a method invalid for it', () {
      expect(
        selectPaymentInstrument(
          const PaymentSelection(instrument: _bank, method: 'cheque'),
          _cash,
        ),
        const PaymentSelection(instrument: _cash),
      );
      expect(
        selectPaymentInstrument(
          const PaymentSelection(instrument: _bank, method: 'neft'),
          _credit,
        ),
        const PaymentSelection(instrument: _credit),
      );
      expect(
        selectPaymentInstrument(
          const PaymentSelection(instrument: _other, method: 'pay_later'),
          _bank,
        ),
        const PaymentSelection(instrument: _bank),
      );
    });

    test('selecting an instrument keeps a method valid for it', () {
      expect(
        selectPaymentInstrument(
          const PaymentSelection(instrument: _credit, method: 'emi'),
          _debit,
        ),
        const PaymentSelection(instrument: _debit, method: 'emi'),
      );
      expect(
        selectPaymentInstrument(
          const PaymentSelection(instrument: _credit, method: 'upi'),
          _bank,
        ),
        const PaymentSelection(instrument: _bank, method: 'upi'),
      );
    });

    test('cash never keeps a method', () {
      expect(
        selectPaymentInstrument(
          const PaymentSelection(instrument: _bank, method: 'emi'),
          _cash,
        ).method,
        isNull,
      );
    });

    test('re-selecting the same instrument changes nothing', () {
      const current = PaymentSelection(instrument: _bank, method: 'cheque');
      expect(identical(selectPaymentInstrument(current, _bank), current), isTrue);
    });

    test('an instrument with no method stays method-free', () {
      expect(
        selectPaymentInstrument(const PaymentSelection(instrument: _credit), _cash),
        const PaymentSelection(instrument: _cash),
      );
    });

    test('clearing a method keeps the instrument', () {
      expect(
        clearPaymentMethod(
          const PaymentSelection(instrument: _bank, method: 'cheque'),
        ),
        const PaymentSelection(instrument: _bank),
      );
    });
  });
}
