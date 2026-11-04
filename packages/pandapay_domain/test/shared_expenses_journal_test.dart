import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/shared_expenses.dart';
import 'package:test/test.dart';

void main() {
  test('gross circular balances are bounded despite zero member nets', () {
    final current = {
      'contextId': 'home',
      'currency': 'INR',
      'members': [
        {'memberId': 'a', 'balanceMinor': '0'},
        {'memberId': 'b', 'balanceMinor': '0'},
        {'memberId': 'c', 'balanceMinor': '0'},
      ],
      'pairs': [
        {
          'lowMemberId': 'a',
          'highMemberId': 'b',
          'balanceMinor': '4503599627370496',
        },
        {
          'lowMemberId': 'a',
          'highMemberId': 'c',
          'balanceMinor': '-4503599627370496',
        },
        {
          'lowMemberId': 'b',
          'highMemberId': 'c',
          'balanceMinor': '4503599627370496',
        },
      ],
    };
    expect(
      () => applyBalanceDelta({
        'current': current,
        'delta': {
          'contextId': 'home',
          'currency': 'INR',
          'members': [],
          'pairs': [],
        },
      }),
      throwsA(
        isA<SharedExpenseException>().having(
          (e) => e.code,
          'code',
          'AGGREGATE_LIMIT_EXCEEDED',
        ),
      ),
    );
  });
  final fixtures =
      jsonDecode(
            File(
              '../../contracts/shared_expenses/v1/journal_vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final vector in fixtures['cases'] as List) {
    test(vector['id'] as String, () {
      Map<String, Object?> current = {
        'contextId': vector['contextId'],
        'currency': 'INR',
        'members': [],
        'pairs': [],
      };
      for (final step in vector['steps'] as List) {
        final before = jsonEncode(step['input']);
        final delta = step['kind'] == 'revision'
            ? expenseRevisionDelta(step['input'])
            : settlementDelta(step['input']);
        expect(jsonEncode(step['input']), before);
        final currentBefore = jsonEncode(current);
        final next = applyBalanceDelta({'current': current, 'delta': delta});
        expect(jsonEncode(current), currentBefore);
        current = next;
      }
      expect(current, vector['expected']);
    });
  }
  for (final vector in fixtures['allocations'] as List) {
    test(
      vector['id'] as String,
      () => expect(allocateSettlement(vector['input']), vector['expected']),
    );
  }
  Map<String, Object?> payment() => {
    'contextId': 'home',
    'currency': 'INR',
    'payerId': 'a',
    'receiverId': 'b',
    'amountMinor': '100',
    'direction': 'confirm',
  };
  Map<String, Object?> empty() => {
    'contextId': 'home',
    'currency': 'INR',
    'members': [],
    'pairs': [],
  };
  Matcher failure(String code) =>
      isA<SharedExpenseException>().having((e) => e.code, 'code', code);
  test(
    'settlement requires exact positive amount, distinct identities and explicit direction',
    () {
      expect(
        () => settlementDelta({...payment(), 'receiverId': 'a'}),
        throwsA(failure('INVALID_SETTLEMENT')),
      );
      expect(
        () => settlementDelta({...payment(), 'direction': 'paid'}),
        throwsA(failure('INVALID_SETTLEMENT_DIRECTION')),
      );
      for (final value in <Object?>['0', '-1', '1.1', 100, null, '01']) {
        expect(
          () => settlementDelta({...payment(), 'amountMinor': value}),
          throwsA(failure('INVALID_AMOUNT')),
        );
      }
      expect(
        () => settlementDelta({...payment(), 'currency': 'USD'}),
        throwsA(failure('UNSUPPORTED_CURRENCY')),
      );
      expect(
        () => settlementDelta({...payment(), 'proof': 'screenshot'}),
        throwsA(failure('INVALID_INPUT')),
      );
    },
  );
  test('cross-context, unbalanced and malformed projections fail closed', () {
    final delta = settlementDelta(payment());
    expect(
      () => applyBalanceDelta({
        'current': {...empty(), 'contextId': 'other'},
        'delta': delta,
      }),
      throwsA(failure('CONTEXT_MISMATCH')),
    );
    expect(
      () => applyBalanceDelta({
        'current': empty(),
        'delta': {...delta, 'members': []},
      }),
      throwsA(failure('BALANCE_MISMATCH')),
    );
    for (final value in <Object?>['-0', '01', '+1', '1\n', 1]) {
      expect(
        () => applyBalanceDelta({
          'current': empty(),
          'delta': {
            ...delta,
            'members': [
              {'memberId': 'a', 'balanceMinor': value},
            ],
          },
        }),
        throwsA(failure('INVALID_BALANCE')),
      );
    }
    expect(
      () => applyBalanceDelta({
        'current': empty(),
        'delta': {
          ...delta,
          'pairs': [
            {'lowMemberId': 'b', 'highMemberId': 'a', 'balanceMinor': '100'},
          ],
        },
      }),
      throwsA(failure('INVALID_BALANCE_PAIR')),
    );
    expect(
      () => expenseRevisionDelta({
        'contextId': 'home',
        'currency': 'INR',
        'previous': null,
        'next': null,
      }),
      throwsA(failure('INVALID_INPUT')),
    );
  });
  test(
    'aggregate overflow is rejected; confirmation and reversal cancel exactly',
    () {
      final delta = settlementDelta(payment());
      final current = {
        'contextId': 'home',
        'currency': 'INR',
        'members': [
          {'memberId': 'a', 'balanceMinor': '9007199254740990'},
          {'memberId': 'b', 'balanceMinor': '-9007199254740990'},
        ],
        'pairs': [
          {
            'lowMemberId': 'a',
            'highMemberId': 'b',
            'balanceMinor': '9007199254740990',
          },
        ],
      };
      expect(
        () => applyBalanceDelta({'current': current, 'delta': delta}),
        throwsA(failure('AGGREGATE_LIMIT_EXCEEDED')),
      );
      final paid = applyBalanceDelta({'current': empty(), 'delta': delta});
      final restored = applyBalanceDelta({
        'current': paid,
        'delta': settlementDelta({...payment(), 'direction': 'reverse'}),
      });
      expect(restored['pairs'], isEmpty);
      expect(
        (restored['members'] as List).every(
          (row) => row['balanceMinor'] == '0',
        ),
        isTrue,
      );
    },
  );
  test(
    'settlement allocation rejects missing, duplicate and changed obligations',
    () {
      expect(
        () => allocateSettlement({
          'amountMinor': '1',
          'obligations': [],
          'allocationOrder': [],
        }),
        throwsA(failure('INVALID_OBLIGATION_COUNT')),
      );
      expect(
        () => allocateSettlement({
          'amountMinor': '1',
          'obligations': [
            {'obligationId': 'o', 'outstandingMinor': '1'},
            {'obligationId': 'o', 'outstandingMinor': '1'},
          ],
          'allocationOrder': ['o', 'o'],
        }),
        throwsA(failure('DUPLICATE_MEMBER')),
      );
      expect(
        () => allocateSettlement({
          'amountMinor': '1',
          'obligations': [
            {'obligationId': 'o', 'outstandingMinor': '1'},
          ],
          'allocationOrder': ['other'],
        }),
        throwsA(failure('INVALID_TIE_ORDER')),
      );
    },
  );
}
