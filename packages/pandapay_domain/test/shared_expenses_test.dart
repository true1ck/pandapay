import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:pandapay_domain/shared_expenses.dart';
import 'package:test/test.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(
          File(
            '../../contracts/shared_expenses/v1/$name.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

void main() {
  final vectors = fixture('domain_vectors');
  for (final entry in <String, dynamic Function(Object?)>{
    'allocation': allocateSharedExpense,
    'projection': projectSharedExpense,
    'personalCost': sharedPersonalCost,
    'sourceInt': sourceIntToSharedMinor,
  }.entries) {
    for (final vector in vectors[entry.key] as List) {
      test(vector['id'] as String, () {
        final before = jsonEncode(vector['input']);
        expect(entry.value(vector['input']), vector['expected']);
        expect(jsonEncode(vector['input']), before);
      });
    }
  }
  final base = Map<String, dynamic>.from(
    (vectors['allocation'] as List).first['input'] as Map,
  );
  Matcher failure(String code) => isA<SharedExpenseException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.field, 'field', isNotEmpty);

  test(
    'canonical minor units reject coercion, malformed strings and overflow',
    () {
      for (final value in <Object?>[
        1,
        BigInt.one,
        true,
        null,
        '',
        '01',
        '+1',
        '-1',
        '1.5',
        '1e2',
        ' 1',
        '١',
        '1\n',
        '1' * 10000,
        '0',
      ]) {
        expect(
          () => allocateSharedExpense({...base, 'totalMinor': value}),
          throwsA(failure('INVALID_AMOUNT')),
        );
      }
      expect(
        () => allocateSharedExpense({...base, 'totalMinor': '1000000001'}),
        throwsA(failure('AMOUNT_LIMIT_EXCEEDED')),
      );
    },
  );
  test('unknown shapes, currencies, modes and duplicate participants fail', () {
    for (final value in <Object?>[
      null,
      [],
      1,
      {},
      {...base, 'unknown': true},
    ]) {
      expect(
        () => allocateSharedExpense(value),
        throwsA(failure('INVALID_INPUT')),
      );
    }
    expect(
      () => allocateSharedExpense({...base, 'currency': 'USD'}),
      throwsA(failure('UNSUPPORTED_CURRENCY')),
    );
    expect(
      () => allocateSharedExpense({...base, 'mode': 'other'}),
      throwsA(failure('INVALID_MODE')),
    );
    expect(
      () => allocateSharedExpense({
        ...base,
        'participants': [
          {'memberId': 'you'},
          {'memberId': 'you'},
        ],
      }),
      throwsA(failure('DUPLICATE_MEMBER')),
    );
    for (final id in ['', '__proto__', 'a' * 65, 'x\n']) {
      expect(
        () => allocateSharedExpense({
          ...base,
          'participants': [
            {'memberId': id},
          ],
        }),
        throwsA(failure('INVALID_MEMBER_ID')),
      );
    }
    for (final rows in [
      [],
      List.generate(51, (i) => {'memberId': 'm$i'}),
    ]) {
      expect(
        () => allocateSharedExpense({...base, 'participants': rows}),
        throwsA(failure('INVALID_PARTICIPANT_COUNT')),
      );
    }
    for (final order in <Object?>[
      [],
      ['you', 'you', 'priya'],
      ['you', 'rahul', 'other'],
      null,
    ]) {
      expect(
        () => allocateSharedExpense({...base, 'tieOrder': order}),
        throwsA(failure('INVALID_TIE_ORDER')),
      );
    }
  });
  test('exact, percentage and share totals are validated live', () {
    final one = {
      ...base,
      'tieOrder': ['a'],
      'participants': [
        {'memberId': 'a', 'amountMinor': '1'},
      ],
      'mode': 'exact',
    };
    expect(
      () => allocateSharedExpense(one),
      throwsA(failure('ALLOCATION_TOTAL_MISMATCH')),
    );
    for (final weight in <Object?>['0', '9999', '10001', 1, '1.5', '01']) {
      expect(
        () => allocateSharedExpense({
          ...one,
          'mode': 'percentage',
          'participants': [
            {'memberId': 'a', 'weight': weight},
          ],
        }),
        throwsA(failure('INVALID_WEIGHT')),
      );
    }
    for (final weight in ['0', '1000001']) {
      expect(
        () => allocateSharedExpense({
          ...one,
          'mode': 'shares',
          'participants': [
            {'memberId': 'a', 'weight': weight},
          ],
        }),
        throwsA(failure('INVALID_WEIGHT')),
      );
    }
  });
  test(
    'unbalanced payer/share documents and overallocated sources fail closed',
    () {
      final projection = Map<String, dynamic>.from(
        (vectors['projection'] as List).first['input'] as Map,
      );
      expect(
        () => projectSharedExpense({
          ...projection,
          'contributions': [
            {'memberId': 'you', 'amountMinor': '1'},
          ],
        }),
        throwsA(failure('CONTRIBUTION_TOTAL_MISMATCH')),
      );
      expect(
        () => projectSharedExpense({
          ...projection,
          'shares': [
            {'memberId': 'you', 'amountMinor': '1'},
          ],
        }),
        throwsA(failure('ALLOCATION_TOTAL_MISMATCH')),
      );
      expect(
        () => projectSharedExpense({
          ...projection,
          'contributions': List.generate(
            9,
            (i) => {'memberId': 'p$i', 'amountMinor': '0'},
          ),
        }),
        throwsA(failure('INVALID_PAYER_COUNT')),
      );
      expect(
        () => sharedPersonalCost({
          'sourceAmountMinor': '1',
          'linkedAmountMinor': '2',
          'shareMinor': '0',
        }),
        throwsA(failure('SOURCE_OVERALLOCATED')),
      );
      expect(
        () => sharedPersonalCost({
          'sourceAmountMinor': '1',
          'linkedAmountMinor': '0',
          'shareMinor': '9007199254740991',
        }),
        throwsA(failure('AGGREGATE_LIMIT_EXCEEDED')),
      );
    },
  );
  test(
    'source integer adapter rejects coercion, floats and capped purchases',
    () {
      for (final value in <Object?>[
        '1',
        true,
        null,
        BigInt.one,
        1.0,
        0.01,
        double.nan,
        double.infinity,
        -1,
      ]) {
        expect(
          () => sourceIntToSharedMinor(value),
          throwsA(failure('INVALID_AMOUNT')),
        );
      }
      expect(
        () => sourceIntToSharedMinor(1000000001),
        throwsA(failure('AMOUNT_LIMIT_EXCEEDED')),
      );
    },
  );
  test('checked Money adapter retains maximum safe exact paise', () {
    expect(sharedMoneyFromMinor('9007199254740991').paise, 9007199254740991);
    expect(sharedMoneyFromMinor('1').paise, 1);
    expect(
      () => sharedMoneyFromMinor('9007199254740992'),
      throwsA(failure('AGGREGATE_LIMIT_EXCEEDED')),
    );
    expect(() => sharedMoneyFromMinor(1), throwsA(failure('INVALID_AMOUNT')));
  });
  test('persisted ties survive display order changes', () {
    final reordered = {
      ...base,
      'participants': (base['participants'] as List).reversed.toList(),
    };
    expect(allocateSharedExpense(reordered), allocateSharedExpense(base));
  });
  test(
    '500 randomized allocations and multiple-payer positions conserve every paisa',
    () {
      final random = Random(73401);
      for (var trial = 0; trial < 500; trial++) {
        final count = 1 + random.nextInt(50),
            total = 1 + random.nextInt(1000000000);
        final members = List.generate(count, (i) => 'm$i');
        final allocated = allocateSharedExpense({
          'currency': 'INR',
          'totalMinor': '$total',
          'mode': 'shares',
          'participants': List.generate(
            count,
            (i) => {
              'memberId': members[i],
              'weight': '${1 + random.nextInt(1000000)}',
            },
          ),
          'tieOrder': members,
        });
        final rows = allocated['allocations'] as List;
        expect(
          rows.fold<BigInt>(
            BigInt.zero,
            (s, r) => s + BigInt.parse(r['amountMinor'] as String),
          ),
          BigInt.from(total),
        );
        final paid = total ~/ 2;
        final projected = projectSharedExpense({
          'currency': 'INR',
          'totalMinor': '$total',
          'contributions': count == 1
              ? [
                  {'memberId': 'm0', 'amountMinor': '$total'},
                ]
              : [
                  {'memberId': 'm0', 'amountMinor': '$paid'},
                  {'memberId': 'm1', 'amountMinor': '${total - paid}'},
                ],
          'shares': rows,
          'memberOrder': members,
        });
        final edges = projected['obligations'] as List;
        final reconstructed = {for (final id in members) id: BigInt.zero};
        for (final edge in edges) {
          final value = BigInt.parse(edge['amountMinor'] as String);
          expect(value, greaterThan(BigInt.zero));
          reconstructed[edge['creditorId'] as String] =
              reconstructed[edge['creditorId']]! + value;
          reconstructed[edge['debtorId'] as String] =
              reconstructed[edge['debtorId']]! - value;
        }
        for (final row in projected['positions'] as List) {
          expect(
            reconstructed[row['memberId']],
            BigInt.parse(row['balanceMinor'] as String),
          );
        }
        expect(edges.length, lessThanOrEqualTo(count - 1));
      }
    },
  );

  final sourceVectors = fixture('source_reference_vectors')['valid'] as List;
  for (final vector in sourceVectors) {
    test(vector['id'] as String, () {
      final parsed = SharedExpenseSourceReference.parse(vector['input']);
      expect(parsed.toJson(), vector['input']);
      expect(parsed.canonicalLegacySplitTarget, vector['target']);
    });
  }
  test(
    'source references enforce closed shapes, UUID admission pairs and private token limits',
    () {
      final legacy = Map<String, dynamic>.from(
        sourceVectors[0]['input'] as Map,
      );
      final pending = Map<String, dynamic>.from(
        sourceVectors[1]['input'] as Map,
      );
      for (final input in <Object?>[
        null,
        [],
        {},
        {...legacy, 'rawSms': 'secret'},
        {...legacy, 'sourceKey': 'rahul@upi'},
        {...legacy, 'sourceVersion': 'x' * 129},
        {...legacy, 'sourceVersion': 'ok\n'},
        {...legacy, 'canonicalTransactionId': pending['localProjectionId']},
        {
          ...pending,
          'canonicalTransactionId': legacy['canonicalTransactionId'],
        },
        {...pending, 'sourceVersion': '1'},
        {...pending, 'localProjectionId': 'v2:${'b' * 64}'},
        {...pending, 'eventId': 'A' * 64},
        {...legacy, 'ownerAccountId': 'not-a-uuid'},
      ]) {
        expect(
          () => SharedExpenseSourceReference.parse(input),
          throwsA(failure('INVALID_SOURCE_REFERENCE')),
        );
      }
      final parsed = SharedExpenseSourceReference.parse(legacy);
      legacy['sourceKey'] = 'changed';
      expect(parsed.toJson()['sourceKey'], 'manual:123');
      final copy = parsed.toJson();
      copy['sourceKey'] = 'changed-again';
      expect(parsed.toJson()['sourceKey'], 'manual:123');
    },
  );
}
