import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart' show TxnInstrument;
import 'package:pandapay/features/payments/payment_method_catalogue.dart';

/// The Dart catalogue must equal the frozen contract fixture shared with the
/// API (`payment_methods_v1.json`). A method added here but not in the
/// contract (or the reverse) fails this test.
void main() {
  final fixture =
      jsonDecode(File('test/fixtures/payment_methods_v1.json').readAsStringSync())
          as Map<String, dynamic>;
  final methods = (fixture['methods'] as List).cast<Map<String, dynamic>>();

  test('has exactly the contract methods, in the contract order', () {
    expect(kPaymentMethods.map((m) => m.wire).toList(), [
      for (final m in methods) m['wire'],
    ]);
  });

  test('every method matches the contract: label, group, instruments, chip, min', () {
    expect(kPaymentMethods.length, methods.length);
    for (var i = 0; i < methods.length; i++) {
      final expected = methods[i];
      final actual = kPaymentMethods[i];
      final wire = expected['wire'];
      expect(actual.wire, wire);
      expect(actual.label, expected['label'], reason: '$wire label');
      expect(actual.group.wire, expected['group'], reason: '$wire group');
      expect(
        actual.instruments.map((instrument) => instrument.wireValue).toList(),
        expected['instruments'],
        reason: '$wire instruments',
      );
      expect(actual.mainChip, expected['mainChip'], reason: '$wire mainChip');
      expect(
        actual.minAmountInr,
        expected['minAmountInr'],
        reason: '$wire minAmountInr',
      );
    }
  });

  test('groups and instruments match the contract', () {
    expect(kPaymentMethodGroups.map((g) => g.wire).toList(), fixture['groups']);
    expect(
      kPaymentInstruments.map((i) => i.wireValue).toList(),
      fixture['instruments'],
    );
    // The stored instrument vocabulary is untouched.
    expect(
      TxnInstrument.values.map((i) => i.wireValue).toList(),
      fixture['instruments'],
    );
  });

  test('bank-only methods are exactly the ones the hidden rule names', () {
    final rule = (fixture['hardHiddenRules'] as List).cast<String>().first;
    final named = RegExp(r'\(([^)]*)\)').firstMatch(rule)!.group(1)!;
    expect(
      {for (final m in kPaymentMethods) if (m.bankOnly) m.wire},
      named.split(',').map((w) => w.trim()).toSet(),
    );
  });

  test('lookup by wire value', () {
    expect(paymentMethodByWire('cheque')!.label, 'Cheque');
    expect(paymentMethodByWire('cheque')!.mainChip, isTrue);
    expect(paymentMethodByWire(null), isNull);
    expect(paymentMethodByWire('bitcoin'), isNull);
    expect(paymentMethodValidFor('cheque', TxnInstrument.upiBank), isTrue);
    expect(paymentMethodValidFor('cheque', TxnInstrument.cash), isFalse);
    expect(paymentMethodValidFor('cheque', null), isFalse);
  });

  test('short label drops the parenthetical', () {
    expect(paymentMethodByWire('auto_debit')!.shortLabel, 'Auto-debit');
    expect(paymentMethodByWire('neft')!.shortLabel, 'NEFT');
  });
}
