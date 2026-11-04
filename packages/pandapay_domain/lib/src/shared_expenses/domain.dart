import '../money/money.dart';
import 'validation.dart' as v;

class _Allocation {
  final String id;
  BigInt value;
  final BigInt remainder;
  _Allocation(this.id, this.value, this.remainder);
}

List<({String id, BigInt value})> _allocationRows(Map<String, Object?> input) {
  final rows = v.count(
    input['participants'],
    50,
    'INVALID_PARTICIPANT_COUNT',
    'participants',
  );
  final exact = input['mode'] == 'exact', equal = input['mode'] == 'equal';
  final ids = <String>{};
  final result = <({String id, BigInt value})>[];
  for (var index = 0; index < rows.length; index++) {
    final field = 'participants[$index]';
    final row = v.record(
      rows[index],
      equal ? ['memberId'] : ['memberId', exact ? 'amountMinor' : 'weight'],
      field: field,
    );
    final id = v.member(row['memberId'], '$field.memberId');
    if (!ids.add(id)) v.fail('DUPLICATE_MEMBER', '$field.memberId');
    if (exact) {
      result.add((
        id: id,
        value: v.amount(row['amountMinor'], '$field.amountMinor'),
      ));
      continue;
    }
    if (equal) {
      result.add((id: id, value: BigInt.one));
      continue;
    }
    final weight = row['weight'];
    if (weight is! String ||
        weight.length > 7 ||
        !v.matches(RegExp(r'^(0|[1-9][0-9]*)$'), weight)) {
      v.fail('INVALID_WEIGHT', '$field.weight');
    }
    final parsed = BigInt.parse(weight);
    if (parsed > BigInt.from(input['mode'] == 'percentage' ? 10000 : 1000000)) {
      v.fail('INVALID_WEIGHT', '$field.weight');
    }
    result.add((id: id, value: parsed));
  }
  return result;
}

/// Allocates whole paise with largest remainders and persisted tie order.
/// Input and output follow contracts/shared_expenses/v1; no input is mutated.
Map<String, Object?> allocateSharedExpense(Object? value) {
  final input = v.record(value, [
    'currency',
    'totalMinor',
    'mode',
    'participants',
    'tieOrder',
  ]);
  v.currency(input['currency']);
  final total = v.amount(input['totalMinor'], 'totalMinor', positive: true);
  if (!['equal', 'exact', 'percentage', 'shares'].contains(input['mode'])) {
    v.fail('INVALID_MODE', 'mode');
  }
  final rows = _allocationRows(input);
  final ranks = v.order(
    input['tieOrder'],
    rows.map((row) => row.id).toSet(),
    'tieOrder',
  );
  final sum = rows.fold<BigInt>(BigInt.zero, (s, row) => s + row.value);
  List<Map<String, String>> allocations;
  if (input['mode'] == 'exact') {
    if (sum != total) v.fail('ALLOCATION_TOTAL_MISMATCH', 'participants');
    rows.sort((a, b) => a.id.compareTo(b.id));
    allocations = [
      for (final row in rows)
        {'memberId': row.id, 'amountMinor': row.value.toString()},
    ];
  } else {
    if (sum == BigInt.zero ||
        (input['mode'] == 'percentage' && sum != BigInt.from(10000))) {
      v.fail('INVALID_WEIGHT', 'participants');
    }
    final calculated = [
      for (final row in rows)
        _Allocation(row.id, total * row.value ~/ sum, total * row.value % sum),
    ];
    final remaining =
        total - calculated.fold<BigInt>(BigInt.zero, (s, row) => s + row.value);
    calculated.sort(
      (a, b) => a.remainder == b.remainder
          ? ranks[a.id]!.compareTo(ranks[b.id]!)
          : b.remainder.compareTo(a.remainder),
    );
    // Remainder is less than the bounded participant count, regardless of total.
    for (var i = 0; i < remaining.toInt(); i++) {
      calculated[i].value += BigInt.one;
    }
    calculated.sort((a, b) => a.id.compareTo(b.id));
    allocations = [
      for (final row in calculated)
        {'memberId': row.id, 'amountMinor': row.value.toString()},
    ];
  }
  return {
    'currency': 'INR',
    'totalMinor': total.toString(),
    'allocations': allocations,
  };
}

Map<String, BigInt> _moneyRows(
  Object? value,
  String field,
  int max,
  String code,
) {
  final rows = v.count(value, max, code, field);
  final result = <String, BigInt>{};
  for (var i = 0; i < rows.length; i++) {
    final row = v.record(rows[i], [
      'memberId',
      'amountMinor',
    ], field: '$field[$i]');
    final id = v.member(row['memberId'], '$field[$i].memberId');
    if (result.containsKey(id)) {
      v.fail('DUPLICATE_MEMBER', '$field[$i].memberId');
    }
    result[id] = v.amount(row['amountMinor'], '$field[$i].amountMinor');
  }
  return result;
}

/// Balanced one-expense preview. This does not accept debt or net across groups.
Map<String, Object?> projectSharedExpense(Object? value) {
  final input = v.record(value, [
    'currency',
    'totalMinor',
    'contributions',
    'shares',
    'memberOrder',
  ]);
  v.currency(input['currency']);
  final total = v.amount(input['totalMinor'], 'totalMinor', positive: true);
  final paid = _moneyRows(
    input['contributions'],
    'contributions',
    8,
    'INVALID_PAYER_COUNT',
  );
  final shares = _moneyRows(
    input['shares'],
    'shares',
    50,
    'INVALID_PARTICIPANT_COUNT',
  );
  if (paid.values.fold<BigInt>(BigInt.zero, (a, b) => a + b) != total) {
    v.fail('CONTRIBUTION_TOTAL_MISMATCH', 'contributions');
  }
  if (shares.values.fold<BigInt>(BigInt.zero, (a, b) => a + b) != total) {
    v.fail('ALLOCATION_TOTAL_MISMATCH', 'shares');
  }
  final members = {...paid.keys, ...shares.keys};
  v.order(input['memberOrder'], members, 'memberOrder');
  BigInt balance(String id) =>
      (paid[id] ?? BigInt.zero) - (shares[id] ?? BigInt.zero);
  final sorted = members.toList()..sort();
  final positions = [
    for (final id in sorted)
      {
        'memberId': id,
        'paidMinor': (paid[id] ?? BigInt.zero).toString(),
        'shareMinor': (shares[id] ?? BigInt.zero).toString(),
        'balanceMinor': balance(id).toString(),
      },
  ];
  final creditors = <_Allocation>[], debtors = <_Allocation>[];
  for (final id in (input['memberOrder'] as List).cast<String>()) {
    final net = balance(id);
    if (net > BigInt.zero) creditors.add(_Allocation(id, net, BigInt.zero));
    if (net < BigInt.zero) debtors.add(_Allocation(id, -net, BigInt.zero));
  }
  final obligations = <Map<String, String>>[];
  var d = 0, c = 0;
  while (d < debtors.length && c < creditors.length) {
    final debit = debtors[d], credit = creditors[c];
    final amount = debit.value < credit.value ? debit.value : credit.value;
    obligations.add({
      'debtorId': debit.id,
      'creditorId': credit.id,
      'amountMinor': amount.toString(),
    });
    debit.value -= amount;
    credit.value -= amount;
    if (debit.value == BigInt.zero) d++;
    if (credit.value == BigInt.zero) c++;
  }
  return {
    'currency': 'INR',
    'totalMinor': total.toString(),
    'positions': positions,
    'obligations': obligations,
  };
}

/// Residual owned bank spend plus separately recognized personal share. Caller
/// supplies source scope and recognition; this function cannot authorize either.
Map<String, String> sharedPersonalCost(Object? value) {
  final input = v.record(value, [
    'sourceAmountMinor',
    'linkedAmountMinor',
    'shareMinor',
  ]);
  final source = v.amount(input['sourceAmountMinor'], 'sourceAmountMinor');
  final linked = v.amount(input['linkedAmountMinor'], 'linkedAmountMinor');
  final share = v.amount(
    input['shareMinor'],
    'shareMinor',
    max: v.maxAggregateMinor,
    overflow: 'AGGREGATE_LIMIT_EXCEEDED',
  );
  if (linked > source) v.fail('SOURCE_OVERALLOCATED', 'linkedAmountMinor');
  final residual = source - linked, cost = residual + share;
  if (cost > v.maxAggregateMinor) {
    v.fail('AGGREGATE_LIMIT_EXCEEDED', 'shareMinor');
  }
  return {'residualMinor': residual.toString(), 'costMinor': cost.toString()};
}

/// Converts an already interpreted source Amount.minor integer to shared wire
/// units. No coercion, source-schema mutation or funding authorization occurs.
String sourceIntToSharedMinor(Object? value) {
  if (value is! int || value < 0) v.fail('INVALID_AMOUNT', 'sourceMinor');
  return v.amount(value.toString(), 'sourceMinor').toString();
}

/// Converts canonical unsigned minor units to existing Money without doubles.
Money sharedMoneyFromMinor(Object? value) => Money.fromPaise(
  v
      .amount(
        value,
        'amountMinor',
        max: v.maxAggregateMinor,
        overflow: 'AGGREGATE_LIMIT_EXCEEDED',
      )
      .toInt(),
);
