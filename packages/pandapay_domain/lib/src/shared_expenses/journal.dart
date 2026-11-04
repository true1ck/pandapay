import 'domain.dart';
import 'validation.dart' as v;

/// Pure deltas are not replay-safe by themselves. Persistence must apply each
/// approved immutable effect once, atomically with its durable operation receipt.
class _State {
  final String contextId;
  final members = <String, BigInt>{};
  final pairs = <(String, String), BigInt>{};
  _State(this.contextId);
}

final _zero = BigInt.zero;

BigInt _bounded(BigInt value, String field) {
  if (value > v.maxAggregateMinor || value < -v.maxAggregateMinor) {
    v.fail('AGGREGATE_LIMIT_EXCEEDED', field);
  }
  return value;
}

BigInt _signed(Object? value, String field) {
  if (value is! String ||
      value.length > 17 ||
      !v.matches(RegExp(r'^(0|-?[1-9][0-9]*)$'), value)) {
    v.fail('INVALID_BALANCE', field);
  }
  return _bounded(BigInt.parse(value), field);
}

void _scope(Map<String, Object?> input) {
  v.member(input['contextId'], 'contextId');
  v.currency(input['currency']);
}

void _addMember(_State state, String id, BigInt amount) {
  state.members[id] = _bounded(
    (state.members[id] ?? _zero) + amount,
    'members',
  );
}

void _addPair(_State state, String creditor, String debtor, BigInt amount) {
  final low = creditor.compareTo(debtor) < 0 ? creditor : debtor;
  final high = creditor.compareTo(debtor) < 0 ? debtor : creditor;
  final key = (low, high), delta = creditor == low ? amount : -amount;
  state.pairs[key] = _bounded((state.pairs[key] ?? _zero) + delta, 'pairs');
}

Map<String, Object?> _output(_State state, {bool omitZeroMembers = false}) {
  _bounded(
    state.pairs.values.fold<BigInt>(_zero, (sum, amount) => sum + amount.abs()),
    'grossMinor',
  );
  final pairs = state.pairs.entries.where((row) => row.value != _zero).toList()
    ..sort((a, b) {
      final first = a.key.$1.compareTo(b.key.$1);
      return first != 0 ? first : a.key.$2.compareTo(b.key.$2);
    });
  final paired = {
    for (final row in pairs) ...[row.key.$1, row.key.$2],
  };
  final members = state.members.keys.toList()..sort();
  return {
    'contextId': state.contextId,
    'currency': 'INR',
    'members': [
      for (final id in members)
        if (!omitZeroMembers ||
            state.members[id] != _zero ||
            paired.contains(id))
          {'memberId': id, 'balanceMinor': state.members[id].toString()},
    ],
    'pairs': [
      for (final row in pairs)
        {
          'lowMemberId': row.key.$1,
          'highMemberId': row.key.$2,
          'balanceMinor': row.value.toString(),
        },
    ],
  };
}

_State _parseEnvelope(Object? value, String field) {
  final input = v.record(value, [
    'contextId',
    'currency',
    'members',
    'pairs',
  ], field: field);
  _scope(input);
  final members = input['members'], pairs = input['pairs'];
  if (members is! List || members.length > 200) {
    v.fail('INVALID_PARTICIPANT_COUNT', '$field.members');
  }
  if (pairs is! List || pairs.length > 19900) {
    v.fail('INVALID_BALANCE_PAIR', '$field.pairs');
  }
  final state = _State(input['contextId'] as String),
      incidence = <String, BigInt>{};
  for (var i = 0; i < members.length; i++) {
    final path = '$field.members[$i]',
        row = v.record(members[i], [
          'memberId',
          'balanceMinor',
        ], field: '$field.members[$i]');
    final id = v.member(row['memberId'], '$path.memberId');
    if (state.members.containsKey(id)) {
      v.fail('DUPLICATE_MEMBER', '$path.memberId');
    }
    state.members[id] = _signed(row['balanceMinor'], '$path.balanceMinor');
  }
  for (var i = 0; i < pairs.length; i++) {
    final path = '$field.pairs[$i]',
        row = v.record(pairs[i], [
          'lowMemberId',
          'highMemberId',
          'balanceMinor',
        ], field: '$field.pairs[$i]');
    final low = v.member(row['lowMemberId'], '$path.lowMemberId'),
        high = v.member(row['highMemberId'], '$path.highMemberId');
    if (low.compareTo(high) >= 0) v.fail('INVALID_BALANCE_PAIR', path);
    final key = (low, high),
        amount = _signed(row['balanceMinor'], '$path.balanceMinor');
    if (state.pairs.containsKey(key)) v.fail('INVALID_BALANCE_PAIR', path);
    state.pairs[key] = amount;
    incidence[low] = (incidence[low] ?? _zero) + amount;
    incidence[high] = (incidence[high] ?? _zero) - amount;
  }
  for (final id in {...incidence.keys, ...state.members.keys}) {
    if (!state.members.containsKey(id) ||
        (incidence[id] ?? _zero) != state.members[id]) {
      v.fail('BALANCE_MISMATCH', field);
    }
  }
  _bounded(
    state.pairs.values.fold<BigInt>(_zero, (sum, amount) => sum + amount.abs()),
    'grossMinor',
  );
  return state;
}

/// New accepted expense snapshot minus the prior immutable accepted snapshot.
/// Null next represents an approved void, never deletion of a bank purchase.
Map<String, Object?> expenseRevisionDelta(Object? value) {
  final input = v.record(value, ['contextId', 'currency', 'previous', 'next']);
  _scope(input);
  if (input['previous'] == null && input['next'] == null) {
    v.fail('INVALID_INPUT', r'$');
  }
  final result = _State(input['contextId'] as String);
  for (final entry in [
    (input['previous'], -BigInt.one),
    (input['next'], BigInt.one),
  ]) {
    if (entry.$1 == null) continue;
    final projected = projectSharedExpense(entry.$1);
    for (final row in projected['positions'] as List) {
      _addMember(
        result,
        row['memberId'] as String,
        BigInt.parse(row['balanceMinor'] as String) * entry.$2,
      );
    }
    for (final edge in projected['obligations'] as List) {
      _addPair(
        result,
        edge['creditorId'] as String,
        edge['debtorId'] as String,
        BigInt.parse(edge['amountMinor'] as String) * entry.$2,
      );
    }
  }
  return _output(result, omitZeroMembers: true);
}

/// Exact effect of an independently confirmed payment or approved reversal.
/// Does not establish consent, payment evidence or idempotency.
Map<String, Object?> settlementDelta(Object? value) {
  final input = v.record(value, [
    'contextId',
    'currency',
    'payerId',
    'receiverId',
    'amountMinor',
    'direction',
  ]);
  _scope(input);
  final payer = v.member(input['payerId'], 'payerId'),
      receiver = v.member(input['receiverId'], 'receiverId');
  if (payer == receiver) v.fail('INVALID_SETTLEMENT', 'receiverId');
  if (!['confirm', 'reverse'].contains(input['direction'])) {
    v.fail('INVALID_SETTLEMENT_DIRECTION', 'direction');
  }
  final amount =
      v.amount(input['amountMinor'], 'amountMinor', positive: true) *
      (input['direction'] == 'confirm' ? BigInt.one : -BigInt.one);
  final result = _State(input['contextId'] as String);
  _addMember(result, payer, amount);
  _addMember(result, receiver, -amount);
  _addPair(result, payer, receiver, amount);
  return _output(result, omitZeroMembers: true);
}

/// Applies one effect to one bounded current context projection. Opposite debts
/// offset only within the same identity pair; circular debts remain visible.
Map<String, Object?> applyBalanceDelta(Object? value) {
  final input = v.record(value, ['current', 'delta']);
  final current = _parseEnvelope(input['current'], 'current'),
      delta = _parseEnvelope(input['delta'], 'delta');
  if (current.contextId != delta.contextId) {
    v.fail('CONTEXT_MISMATCH', 'delta.contextId');
  }
  for (final entry in delta.members.entries) {
    _addMember(current, entry.key, entry.value);
  }
  if (current.members.length > 200) {
    v.fail('INVALID_PARTICIPANT_COUNT', 'members');
  }
  for (final entry in delta.pairs.entries) {
    _addPair(current, entry.key.$1, entry.key.$2, entry.value);
  }
  return _output(current);
}

/// Allocates to an authorized selected pair/context in persisted order. Excess
/// is explicit pair credit; it is never redirected to another friend or group.
Map<String, Object?> allocateSettlement(Object? value) {
  final input = v.record(value, [
    'amountMinor',
    'obligations',
    'allocationOrder',
  ]);
  final total = v.amount(input['amountMinor'], 'amountMinor', positive: true);
  final items = v.count(
    input['obligations'],
    100,
    'INVALID_OBLIGATION_COUNT',
    'obligations',
  );
  final rows = <String, BigInt>{};
  for (var i = 0; i < items.length; i++) {
    final path = 'obligations[$i]',
        row = v.record(items[i], [
          'obligationId',
          'outstandingMinor',
        ], field: 'obligations[$i]');
    final id = v.member(row['obligationId'], '$path.obligationId');
    if (rows.containsKey(id)) v.fail('DUPLICATE_MEMBER', '$path.obligationId');
    rows[id] = v.amount(
      row['outstandingMinor'],
      '$path.outstandingMinor',
      max: v.maxAggregateMinor,
      overflow: 'AGGREGATE_LIMIT_EXCEEDED',
    );
  }
  v.order(input['allocationOrder'], rows.keys.toSet(), 'allocationOrder');
  var remaining = total;
  final allocations = <Map<String, String>>[];
  for (final id in (input['allocationOrder'] as List).cast<String>()) {
    final available = rows[id]!,
        amount = available < remaining ? available : remaining;
    if (amount > _zero) {
      allocations.add({'obligationId': id, 'amountMinor': amount.toString()});
    }
    remaining -= amount;
  }
  return {'allocations': allocations, 'creditMinor': remaining.toString()};
}
