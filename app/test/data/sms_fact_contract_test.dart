import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/sms_fact_contract.dart';

Map<String, Object?> spendFact({double amount = 250, String merchant = 'SWIGGY'}) => {
  'amountRole': 'posted',
  'amountInr': amount,
  'entryKind': 'spend',
  'merchant': merchant,
  'occurredAt': '2026-10-16T10:00:00.000Z',
  'instrument': 'upi_bank',
};

final Map<String, Object?> billTotalPayload = {
  'amountRole': 'due_total',
  'amountDueInr': 3000,
  'dueDate': '2026-11-05T00:00:00.000Z',
  'statementDate': '2026-10-12T00:00:00.000Z',
};

final Map<String, Object?> mandatePayload = {
  'mandateStatus': 'registered',
  'limitInr': 2000,
  'merchant': 'NETFLIX',
  'asOfAt': '2026-10-16T10:00:00.000Z',
};

void main() {
  test('valid multi-fact set passes validation', () {
    for (final entry in [
      SmsFactValidationEntry(
        factType: 'posted_movement',
        payload: spendFact(amount: 1250.5, merchant: 'UPI-P2M to GROCERY_M'),
      ),
      SmsFactValidationEntry(
        factType: 'balance_snapshot',
        payload: {
          'availableBalanceInr': 8750.25,
          'asOfAt': '2026-10-16T10:00:00.000Z',
        },
      ),
      SmsFactValidationEntry(
        factType: 'bill_obligation',
        payload: billTotalPayload,
      ),
      SmsFactValidationEntry(
        factType: 'mandate_lifecycle',
        payload: mandatePayload,
      ),
    ]) {
      final result = validateSmsFact(entry);
      expect(result.valid, isTrue, reason: result.errors.join('; '));
    }
  });

  test('amount/date role consistency matches the server', () {
    final noDueDate = validateSmsFact(
      SmsFactValidationEntry(
        factType: 'bill_obligation',
        payload: {...billTotalPayload}..remove('dueDate'),
      ),
    );
    expect(noDueDate.valid, isFalse);
    expect(
      noDueDate.errors.any((e) => e.contains("'due_total' requires dueDate")),
      isTrue,
    );

    final ceilingOmitted = validateSmsFact(
      SmsFactValidationEntry(
        factType: 'mandate_lifecycle',
        payload: {'mandateStatus': 'registered', 'asOfAt': '2026-10-16T10:00:00.000Z'},
      ),
    );
    expect(ceilingOmitted.valid, isTrue);
  });

  test('a mandate ceiling can never be booked as posted money', () {
    final result = validateSmsFact(
      SmsFactValidationEntry(
        factType: 'mandate_lifecycle',
        payload: {...mandatePayload, 'amountRole': 'posted', 'amountInr': 2000},
      ),
    );
    expect(result.valid, isFalse);
  });

  test('a verification alert carries no posted amount', () {
    final clean = validateSmsFact(
      SmsFactValidationEntry(
        factType: 'security_or_service_alert',
        payload: {
          'alertKind': 'verification',
          'occurredAt': '2026-10-16T10:00:00.000Z',
        },
      ),
    );
    expect(clean.valid, isTrue);
    final withAmount = validateSmsFact(
      SmsFactValidationEntry(
        factType: 'security_or_service_alert',
        payload: {
          'alertKind': 'otp',
          'occurredAt': '2026-10-16T10:00:00.000Z',
          'amountRole': 'posted',
          'amountInr': 2000,
        },
      ),
    );
    expect(withAmount.valid, isFalse);
  });

  test('body hash matches the pinned Node parity value', () {
    expect(
      smsBodyHash(
        'HDFCBK',
        'INR 1,250.50 debited from your A/c XX1234 on 16-10-26 for UPI-P2M to GROCERY_M. Avl bal Rs.8,750.25.',
      ),
      '28dd854f5c943a06f19a390121698bbf9e62f563585fcb3c0382b166f44558d5',
    );
  });

  test('fact indices are deterministic and match the server ordering', () {
    final setA = [
      SmsFactValidationEntry(
        factType: 'posted_movement',
        payload: spendFact(amount: 1250.5),
      ),
      SmsFactValidationEntry(
        factType: 'balance_snapshot',
        payload: {
          'availableBalanceInr': 8750.25,
          'asOfAt': '2026-10-16T10:00:00.000Z',
        },
      ),
    ];
    final setB = setA.reversed.toList();
    final ia = assignDeterministicSmsFactIndices(setA);
    final ib = assignDeterministicSmsFactIndices(setB);
    final byType = (List<SmsFactValidationEntry> facts) =>
        facts.map((f) => [f.factIndex, f.factType]).toList()..sort((x, y) => (x[1] as String).compareTo(y[1] as String));
    // Node reference ordering: [0] balance_snapshot, [1] posted_movement.
    expect(
      byType(ia),
      [
        [0, 'balance_snapshot'],
        [1, 'posted_movement'],
      ],
    );
    expect(byType(ia), byType(ib));
    expect(ia.map((f) => f.factIndex).toList(), [0, 1]);
  });

  test('user override merges over the parser payload and wins', () {
    final merged = applySmsFactOverride(
      spendFact(amount: 250),
      {'amountInr': 350.0, 'merchant': 'Blaack Forest Restaurant'},
    );
    expect(merged['amountInr'], 350.0);
    expect(merged['merchant'], 'Blaack Forest Restaurant');
    expect(merged['occurredAt'], spendFact()['occurredAt']);
  });
}
