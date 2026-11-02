import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

Map<String, Object?> _fixture(String rel) {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final f = File('${dir.path}/contracts/sms/v2/fixtures/valid/$rel');
    if (f.existsSync()) return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    dir = dir.parent;
  }
  throw StateError('fixture $rel not found');
}

void main() {
  test('Fact is sealed over the 10 fact types and exposes typed attrs', () {
    final f = Fact.fromJson(_fixture('fact/movement.card_spend.json'));
    expect(f, isA<MovementFact>());
    final m = f as MovementFact;
    expect(m.direction, Direction.debit);
    expect(m.purpose, MovementPurpose.purchase);
    expect(m.rail, Rail.card);
    expect(m.amount(AmountRole.posted)?.minor, 49900);
    expect(m.amount(AmountRole.held), isNull);
    expect(m.instrument?.maskDigits, '5678');
    String kind(Fact f) => switch (f) {
          MovementFact() => 'movement',
          AttemptFact() => 'attempt',
          HoldFact() => 'hold',
          BalanceSnapshotFact() => 'balance_snapshot',
          LimitChangeFact() => 'limit_change',
          BillDueFact() => 'bill_due',
          MandateFact() => 'mandate',
          RewardFact() => 'reward',
          InstrumentHintFact() => 'instrument_hint',
          InfoFact() => 'info',
        };
    expect(kind(f), f.factType.wire);
  });

  test('value equality, hash and toJson immutability', () {
    final a = Fact.fromJson(_fixture('fact/hold.ipo_placed.json'));
    final b = Fact.fromJson(_fixture('fact/hold.ipo_placed.json'));
    final c = Fact.fromJson(_fixture('fact/hold.ipo_released.json'));
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(equals(c)));
    expect(() => a.amounts.add(a.amounts.first), throwsUnsupportedError);
    // Mutating the returned JSON must not change the object.
    final json = a.toJson();
    (json['amounts'] as List).clear();
    expect(a.amounts, hasLength(1));
  });

  test('validate() on typed objects returns the contract result', () {
    final f = Fact.fromJson(_fixture('fact/movement.card_spend.json')) as MovementFact;
    expect(f.validate().ok, isTrue);
    final bad = MovementFact(
      FactEnvelope(
        factId: f.factId,
        sourceKey: f.sourceKey,
        observedAt: f.observedAt,
        provenance: f.provenance,
        confidence: 0.9,
        amounts: const [], // a movement needs exactly one posted amount
      ),
      direction: Direction.debit,
      purpose: MovementPurpose.purchase,
      rail: Rail.card,
    );
    expect(bad.validate().codes, ['fact.movement.posted_required']);
  });

  test('fromJson throws ContractException with codes', () {
    final json = _fixture('fact/movement.card_spend.json')..['factType'] = 'nope';
    expect(
      () => Fact.fromJson(json),
      throwsA(isA<ContractException>().having((e) => e.errors.first.code, 'code', 'fact.type_unknown')),
    );
  });

  test('canonical JSON sorts keys and strips whitespace', () {
    expect(canonicalJson({'b': 1, 'a': [true, null, 'x'], 'c': 2.0}), '{"a":[true,null,"x"],"b":1,"c":2}');
  });

  test('RuleBundle signed payload excludes the signature', () {
    final b = RuleBundle.fromJson(_fixture('bundle/full.json'));
    expect(b.signature, isNotNull);
    expect(b.signedPayload.contains('"signature"'), isFalse);
    expect(b.isPlaceholder, isFalse);
    final zero = RuleBundle.fromJson(_fixture('bundle/baseline_version_0.json'));
    expect(zero.isPlaceholder, isTrue);
    expect(zero.signature, isNull);
    expect(zero.rules, isEmpty);
  });

  test('interfaces and value types are exported', () {
    final msg = SmsMessage(
      sender: 'VM-HDFCBK-S',
      body: 'synthetic',
      observedAt: DateTime.utc(2026, 11, 1),
      sourceKey: 'sms:synthetic:0001',
      iosFilter: 'smsft_fi',
    );
    expect(msg.iosFilter, 'smsft_fi');
    expect(InterpretOutcome.values, hasLength(3));
    final r = InterpretResult(outcome: InterpretOutcome.unknown, facts: const [], templateHash: 'x');
    expect(r.facts, isEmpty);
    const decision = CategoryDecision(slug: 'food', source: CategorySource.catalogue, confidence: 0.9);
    expect(decision.slug, 'food');
    const totals = Totals(
      spendMinor: 0, refundMinor: 0, incomeMinor: 0, investmentMinor: 0, transactionCount: 0, byCategory: {});
    expect(totals.byCategory, isEmpty);
    final ctx = LinkContext(recentFacts: const [], openEvents: const [], instrumentsById: const {});
    expect(ctx.openEvents, isEmpty);
    expect(const LinkResult(created: [], updated: [], ambiguous: []).created, isEmpty);
    expect(const ReviewItem(kind: ReviewKind.template, payload: {}).kind, ReviewKind.template);
    // Interfaces are abstract and implementable.
    expect(_StubInterpreter(), isA<SmsInterpreter>());
  });
}

class _StubInterpreter implements SmsInterpreter {
  @override
  InterpretResult interpret(SmsMessage message, RuleBundle bundle, {required String appVersion}) =>
      const InterpretResult(outcome: InterpretOutcome.unknown, facts: [], templateHash: '');
}
