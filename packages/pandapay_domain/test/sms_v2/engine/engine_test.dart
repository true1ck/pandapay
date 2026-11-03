import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

const _spendBody =
    'Rs.499.00 spent on HDFC Bank Card x5678 at SWIGGY on 2026-11-01:12:30:11. Avl Lmt: Rs.45,000.00';

Map<String, Object?> _fixture() =>
    jsonDecode(File('../../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> _rule({
  required String id,
  List<String> senders = const ['HDFCBK'],
  int priority = 500,
  required String pattern,
  String flags = 'i',
  List<String>? requireAll,
  List<String>? rejectAny,
  String? templateHash,
  String status = 'active',
  String createdBy = 'baseline',
  List<Map<String, Object?>>? emit,
  List<Map<String, Object?>>? examples,
}) =>
    {
      'id': id,
      'version': 1,
      'family': 'test',
      'senders': senders,
      'priority': priority,
      'match': {
        'pattern': pattern,
        'flags': flags,
        if (requireAll != null) 'requireAll': requireAll,
        if (rejectAny != null) 'rejectAny': rejectAny,
        if (templateHash != null) 'templateHash': templateHash,
      },
      'emit': emit ??
          [
            {
              'factType': 'movement',
              'attrs': {'direction': 'debit', 'purpose': 'purchase', 'rail': 'card'},
              'amounts': [
                {'role': 'posted', 'from': 'amt', 'unit': 'INR'},
              ],
            },
          ],
      'confidence': 0.9,
      'examples': examples ??
          [
            {'sender': 'VM-HDFCBK-S', 'body': 'pos', 'expectFactTypes': ['movement']},
            {'sender': 'VM-HDFCBK-S', 'body': 'neg', 'expectFactTypes': <String>[]},
          ],
      'status': status,
      'createdBy': createdBy,
      'updatedAt': '2026-11-20T00:00:00Z',
    };

RuleBundle _bundle(List<Map<String, Object?>> rules,
    {List<Map<String, Object?>> ignore = const [],
    List<Map<String, Object?>> purposes = const [],
    String minEngine = '2.0.0'}) {
  final j = _fixture();
  j['rules'] = rules;
  j['ignoreRules'] = ignore;
  j['counterpartyPurposes'] = purposes;
  j['minEngineVersion'] = minEngine;
  return RuleBundle.fromJson(j);
}

SmsMessage _msg(String sender, String body, {String key = 'src1', DateTime? at}) => SmsMessage(
      sender: sender,
      body: body,
      observedAt: at ?? DateTime.utc(2026, 11, 1, 8),
      sourceKey: key,
    );

const _amt = r'Rs\.(?<amt>[\d,.]+)';

void main() {
  final engine = RuleEngine();
  InterpretResult run(RuleBundle b, SmsMessage m) => engine.interpret(m, b, appVersion: '1.2.3');

  group('baseline fixture', () {
    final bundle = RuleBundle.fromJson(_fixture());
    test('spend message yields movement and balance with full detail', () {
      final r = run(bundle, _msg('VM-HDFCBK-S', _spendBody));
      expect(r.outcome, InterpretOutcome.matched);
      expect(r.ruleId, 'HDFC-CARD-SPEND-03');
      expect(r.ruleVersion, 4);
      expect(r.facts.map((f) => f.factType), [FactType.movement, FactType.balanceSnapshot]);
      final mv = r.facts[0] as MovementFact;
      expect(mv.amount(AmountRole.posted)!.minor, 49900);
      expect(mv.instrument!.kind, InstrumentKind.creditCard);
      expect(mv.instrument!.issuerSlug, 'hdfc');
      expect(mv.instrument!.maskDigits, '5678');
      expect(mv.instrument!.raw, '5678');
      expect(mv.counterparty!.name, 'SWIGGY');
      expect(mv.counterparty!.kind, CounterpartyKind.merchant);
      // 12:30:11 IST = 07:00:11 UTC
      expect(mv.occurredAt, DateTime.utc(2026, 11, 1, 7, 0, 11));
      expect(mv.provenance.ruleId, 'HDFC-CARD-SPEND-03');
      expect(mv.provenance.ruleVersion, 4);
      expect(mv.provenance.bundleVersion, 1);
      expect(mv.provenance.engineVersion, smsEngineVersion);
      expect(mv.provenance.appVersion, '1.2.3');
      final bal = r.facts[1] as BalanceSnapshotFact;
      expect(bal.amount(AmountRole.availableCredit)!.minor, 4500000);
      expect(bal.asOf, DateTime.utc(2026, 11, 1, 7, 0, 11));
      expect(bal.instrument!.maskDigits, '5678');
      // evidence offsets point at the captured text
      for (final s in mv.evidence) {
        expect(_spendBody.substring(s.start, s.end), isNotEmpty);
      }
      final amtSpan = mv.evidence.firstWhere((s) => s.field == 'amounts.posted');
      expect(_spendBody.substring(amtSpan.start, amtSpan.end), '499.00');
      final maskSpan = mv.evidence.firstWhere((s) => s.field == 'instrument.maskDigits');
      expect(_spendBody.substring(maskSpan.start, maskSpan.end), '5678');
      expect(r.templateHash, hasLength(64));
    });

    test('every rule example in the bundle holds', () {
      expect(runRuleExamples(bundle).where((f) => f.ruleId == 'HDFC-CARD-SPEND-03'), isEmpty);
    });

    test('ignore rule wins first and yields one info fact', () {
      final r = run(bundle, _msg('VM-HDFCBK-S', 'You are eligible for a credit limit increase'));
      expect(r.outcome, InterpretOutcome.ignored);
      expect(r.facts, hasLength(1));
      expect((r.facts.single as InfoFact).category, InfoCategory.promotion);
      expect(r.ruleId, 'IGN-LIMIT-OFFER');
    });

    test('no rule: unknown with a reason', () {
      final o = engine.interpretDetailed(_msg('VM-HDFCBK-S', 'hello there'), bundle, appVersion: '1');
      expect(o.result.outcome, InterpretOutcome.unknown);
      expect(o.result.facts, isEmpty);
      expect(o.reason, 'no_rule_matched');
      expect(o.result.templateHash, hasLength(64));
    });

    test('alias sender resolves to the same brand rules', () {
      final r = run(bundle, _msg('VM-HDFCCC-S', _spendBody));
      expect(r.outcome, InterpretOutcome.matched);
    });

    test('iOS filter tag does not break matching', () {
      final r = run(bundle, _msg('VM-HDFCBK-S (smsft_fi)', _spendBody));
      expect(r.outcome, InterpretOutcome.matched);
    });
  });

  group('ordering', () {
    test('ignore rules run before rules', () {
      final b = _bundle(
        [_rule(id: 'R1', pattern: '^$_amt')],
        ignore: [
          {'id': 'IGN-1', 'senders': ['*'], 'pattern': 'rs', 'flags': 'i', 'reason': 'promotion'},
        ],
      );
      expect(run(b, _msg('VM-HDFCBK-S', 'Rs.5.00 hi')).outcome, InterpretOutcome.ignored);
    });

    test('higher priority wins, then id', () {
      final b = _bundle([
        _rule(id: 'B-LOW', priority: 100, pattern: '^$_amt'),
        _rule(id: 'C-HIGH', priority: 900, pattern: '^$_amt'),
        _rule(id: 'A-HIGH', priority: 900, pattern: '^$_amt'),
      ]);
      expect(run(b, _msg('VM-HDFCBK-S', 'Rs.5.00')).ruleId, 'A-HIGH');
    });

    test('brand rule comes before generic at equal priority', () {
      final b = _bundle([
        _rule(id: 'A-GENERIC', senders: ['*'], priority: 300, pattern: '^$_amt'),
        _rule(id: 'Z-BRAND', senders: ['HDFCBK'], priority: 300, pattern: '^$_amt'),
      ]);
      expect(run(b, _msg('VM-HDFCBK-S', 'Rs.5.00')).ruleId, 'Z-BRAND');
      expect(run(b, _msg('VM-UNKNWN-S', 'Rs.5.00')).ruleId, 'A-GENERIC');
    });

    test('a higher-priority generic rule beats a brand rule', () {
      final b = _bundle([
        _rule(id: 'GEN', senders: ['*'], priority: 800, pattern: '^$_amt'),
        _rule(id: 'BRAND', senders: ['HDFCBK'], priority: 300, pattern: '^$_amt'),
      ]);
      expect(run(b, _msg('VM-HDFCBK-S', 'Rs.5.00')).ruleId, 'GEN');
    });

    test('retired and draft rules are skipped', () {
      final b = _bundle([
        _rule(id: 'OLD', priority: 900, pattern: '^$_amt', status: 'retired'),
        _rule(id: 'NEW', priority: 100, pattern: '^$_amt'),
      ]);
      expect(run(b, _msg('VM-HDFCBK-S', 'Rs.5.00')).ruleId, 'NEW');
    });
  });

  group('requireAll and rejectAny', () {
    final b = _bundle([
      _rule(id: 'R', pattern: '^$_amt', requireAll: ['spent', 'card'], rejectAny: ['declined', 'failed']),
    ]);
    test('all required words present', () {
      expect(run(b, _msg('VM-HDFCBK-S', 'Rs.5.00 SPENT on your Card')).outcome, InterpretOutcome.matched);
    });
    test('a missing required word blocks', () {
      expect(run(b, _msg('VM-HDFCBK-S', 'Rs.5.00 spent')).outcome, InterpretOutcome.unknown);
    });
    test('a rejected word blocks', () {
      expect(run(b, _msg('VM-HDFCBK-S', 'Rs.5.00 spent on card but Declined')).outcome, InterpretOutcome.unknown);
    });
  });

  group('safety checks', () {
    test('invalid emit drops all facts, returns unknown, is counted, never throws', () {
      final e = RuleEngine();
      final b = _bundle([
        _rule(id: 'ZERO', pattern: '^$_amt'), // posted 0 is invalid
      ]);
      final o = e.interpretDetailed(_msg('VM-HDFCBK-S', 'Rs.0.00 spent'), b, appVersion: '1');
      expect(o.result.outcome, InterpretOutcome.unknown);
      expect(o.result.facts, isEmpty);
      expect(o.reason, 'rule_emitted_invalid');
      expect(o.winnerId, 'ZERO');
      expect(e.stats.invalidEmits['ZERO'], 1);
      expect(e.stats.unknownReasons['rule_emitted_invalid'], 1);
    });

    test('an unparseable amount is an invalid emit', () {
      final b = _bundle([_rule(id: 'BAD', pattern: r'^(?<amt>\w+)')]);
      final o = engine.interpretDetailed(_msg('VM-HDFCBK-S', 'hello'), b, appVersion: '1');
      expect(o.reason, 'rule_emitted_invalid');
    });

    test('a mask that overlaps the date span is dropped (card 2026 bug)', () {
      final e = RuleEngine();
      final b = _bundle([
        _rule(
          id: 'YEAR',
          pattern: r'^Rs\.(?<amt>[\d.]+) on (?<date>\d{2}-\d{2}-(?<mask>\d{4}))',
          emit: [
            {
              'factType': 'movement',
              'attrs': {'direction': 'debit', 'purpose': 'purchase', 'rail': 'card'},
              'amounts': [
                {'role': 'posted', 'from': 'amt', 'unit': 'INR'},
              ],
              'occurredAt': {'from': 'date', 'formats': ['dd-MM-yyyy']},
              'instrument': {'kind': 'credit_card', 'issuerSlug': 'hdfc', 'maskFrom': 'mask'},
            },
          ],
        ),
      ]);
      final r = e.interpret(_msg('VM-HDFCBK-S', 'Rs.10.00 on 01-11-2026'), b, appVersion: '1');
      expect(r.outcome, InterpretOutcome.matched);
      expect(r.facts.single.instrument?.maskDigits, isNull);
      expect(e.stats.maskDateOverlaps, 1);
    });

    test('occurredAt more than 1 day after observedAt becomes null', () {
      final b = _bundle([
        _rule(
          id: 'FUTURE',
          pattern: r'^Rs\.(?<amt>[\d.]+) on (?<date>\d{2}-\d{2}-\d{4})',
          emit: [
            {
              'factType': 'movement',
              'attrs': {'direction': 'debit', 'purpose': 'purchase', 'rail': 'card'},
              'amounts': [
                {'role': 'posted', 'from': 'amt', 'unit': 'INR'},
              ],
              'occurredAt': {'from': 'date', 'formats': ['dd-MM-yyyy']},
            },
          ],
        ),
      ]);
      final near = run(b, _msg('VM-HDFCBK-S', 'Rs.10.00 on 01-11-2026'));
      expect(near.facts.single.occurredAt, isNotNull);
      final far = run(b, _msg('VM-HDFCBK-S', 'Rs.10.00 on 09-11-2026'));
      expect(far.facts.single.occurredAt, isNull);
    });

    test('a bundle that needs a newer engine is refused', () {
      final b = _bundle([_rule(id: 'R', pattern: '^$_amt')], minEngine: '99.0.0');
      expect(() => CompiledBundle.compile(b), throwsA(isA<BundleRefusedException>()));
      final o = engine.interpretDetailed(_msg('VM-HDFCBK-S', 'Rs.5.00'), b, appVersion: '1');
      expect(o.result.outcome, InterpretOutcome.unknown);
      expect(o.reason, 'bundle_refused');
    });

    test('an engine at the minimum version accepts the bundle', () {
      final b = _bundle([_rule(id: 'R', pattern: '^$_amt')], minEngine: '2.0.0');
      expect(() => CompiledBundle.compile(b, engineVersion: '2.0.0'), returnsNormally);
      expect(() => CompiledBundle.compile(b, engineVersion: '1.9.9'), throwsA(isA<BundleRefusedException>()));
    });
  });

  group('factId and determinism', () {
    final bundle = RuleBundle.fromJson(_fixture());
    test('factId = sha256(sourceKey|ruleId|emitIndex)', () {
      final r = run(bundle, _msg('VM-HDFCBK-S', _spendBody, key: 'key-9'));
      for (var i = 0; i < r.facts.length; i++) {
        expect(
          r.facts[i].factId,
          sha256.convert(utf8.encode('key-9|HDFC-CARD-SPEND-03|$i')).toString(),
        );
      }
      expect(r.facts[0].factId, isNot(r.facts[1].factId));
    });
    test('factId is stable across runs and engines', () {
      final a = run(bundle, _msg('VM-HDFCBK-S', _spendBody)).facts.map((f) => f.factId).toList();
      final b = RuleEngine().interpret(_msg('VM-HDFCBK-S', _spendBody), bundle, appVersion: '1.2.3');
      expect(b.facts.map((f) => f.factId).toList(), a);
    });
    test('same input gives byte-identical JSON', () {
      String once() => canonicalJson({
            'facts': [
              for (final f in RuleEngine().interpret(_msg('VM-HDFCBK-S', _spendBody), bundle, appVersion: '1').facts)
                f.toJson(),
            ],
          });
      expect(utf8.encode(once()), utf8.encode(once()));
    });
  });

  group('counterparty purposes and references', () {
    final purposes = [
      {
        'id': 'CPP-CRED',
        'vpaPattern': r'^cred\.club@',
        'namePattern': r'^CRED(?: CLUB)?$',
        'purpose': 'card_payment',
        'targetInstrument': {'kind': 'credit_card'},
      },
    ];
    List<Map<String, Object?>> rules() => [
          _rule(
            id: 'UPI-DEBIT',
            pattern: r'^Rs\.(?<amt>[\d.]+) sent to (?<payee>[A-Za-z ]+?) \((?<vpa>\S+)\) Ref (?<ref_upiRef>\d+)',
            emit: [
              {
                'factType': 'movement',
                'attrs': {'direction': 'debit', 'purpose': 'p2p', 'rail': 'upi'},
                'amounts': [
                  {'role': 'posted', 'from': 'amt', 'unit': 'INR'},
                ],
                'counterparty': {'nameFrom': 'payee', 'vpaFrom': 'vpa', 'kind': 'person'},
              },
            ],
          ),
        ];

    test('purpose is replaced and counterparty becomes own', () {
      final b = _bundle(rules(), purposes: purposes);
      final r = run(b, _msg('VM-HDFCBK-S', 'Rs.100.00 sent to CRED (cred.club@axisb) Ref 412345678901'));
      final mv = r.facts.single as MovementFact;
      expect(mv.purpose, MovementPurpose.cardPayment);
      expect(mv.counterparty!.kind, CounterpartyKind.own);
      expect(mv.references['upiRef'], '412345678901');
      expect(mv.counterparty!.vpa, 'cred.club@axisb');
    });
    test('purposes do not touch other payees', () {
      final b = _bundle(rules(), purposes: purposes);
      final r = run(b, _msg('VM-HDFCBK-S', 'Rs.100.00 sent to Ravi Kumar (ravi@okaxis) Ref 412345678901'));
      final mv = r.facts.single as MovementFact;
      expect(mv.purpose, MovementPurpose.p2p);
      expect(mv.counterparty!.kind, CounterpartyKind.person);
    });
  });

  group('provisional template-hash rules', () {
    test('apply only to messages with that hash', () {
      const body = 'Rs.5.00 something';
      final hash = run(_bundle([_rule(id: 'X', pattern: '^$_amt')]), _msg('VM-HDFCBK-S', body)).templateHash;
      final b = _bundle([
        _rule(id: 'PROV', pattern: '^$_amt', status: 'provisional', createdBy: 'ai:test', templateHash: hash),
      ]);
      expect(run(b, _msg('VM-HDFCBK-S', body)).ruleId, 'PROV');
      expect(run(b, _msg('VM-HDFCBK-S', 'Rs.5.00 totally different words here now')).outcome,
          InterpretOutcome.unknown);
    });
  });

  group('lint', () {
    List<String> codes(String p, [String f = 'i']) => lintRegexDialect(p, f).map((i) => i.code).toList();
    test('clean pattern', () => expect(codes(r'^(?<a>\d+)\s+(?:x|y)*$'), isEmpty));
    test('backreference', () {
      expect(codes(r'(a)\1'), contains('lint.regex.backreference'));
      expect(codes(r'(?<n>a)\k<n>'), contains('lint.regex.backreference'));
    });
    test('nested quantifier', () {
      expect(codes(r'(a+)+'), contains('lint.regex.nested_quantifier'));
      expect(codes(r'(?:\d+,?)*'), contains('lint.regex.nested_quantifier'));
      expect(codes(r'(?:\d{2},)*\d{3}'), isEmpty);
    });
    test('variable lookbehind', () {
      expect(codes(r'(?<=ab+)c'), contains('lint.regex.lookbehind_variable'));
      expect(codes(r'(?<=a|bc)d'), contains('lint.regex.lookbehind_variable'));
      expect(codes(r'(?<=ab)c'), isEmpty);
    });
    test('flags, length, syntax', () {
      expect(codes('a', 'x'), contains('lint.regex.flags'));
      expect(codes('a' * 2001), contains('lint.regex.too_long'));
      expect(codes('(a'), isNotEmpty);
      expect(codes(r'(?i)a'), contains('lint.regex.unsupported'));
      expect(codes(r'\Aa'), contains('lint.regex.unsupported'));
    });
    test('character classes and escapes are not mistaken for groups', () {
      expect(codes(r'[()+*]+\(\d+\)'), isEmpty);
    });

    test('shadowing is reported with both rule ids', () {
      final b = _bundle([
        _rule(
          id: 'GENERAL',
          priority: 900,
          pattern: '^$_amt',
          examples: [
            {'sender': 'VM-HDFCBK-S', 'body': 'Rs.5.00 spent', 'expectFactTypes': ['movement']},
            {'sender': 'VM-HDFCBK-S', 'body': 'nothing', 'expectFactTypes': <String>[]},
          ],
        ),
        _rule(
          id: 'SPECIFIC',
          priority: 100,
          pattern: r'^Rs\.(?<amt>[\d,.]+) spent at',
          examples: [
            {'sender': 'VM-HDFCBK-S', 'body': 'Rs.5.00 spent at X', 'expectFactTypes': ['movement']},
            {'sender': 'VM-HDFCBK-S', 'body': 'nothing', 'expectFactTypes': <String>[]},
          ],
        ),
      ]);
      final issues = lintBundle(b).where((i) => i.code == 'lint.shadowed').toList();
      expect(issues, hasLength(1));
      expect(issues.single.ruleId, 'SPECIFIC');
      expect(issues.single.message, contains('GENERAL'));
    });

    test('unknown sender is reported', () {
      final j = _fixture();
      final r = _rule(
        id: 'ONLY-POS',
        senders: ['NOSUCH'],
        pattern: '^$_amt',
        examples: [
          {'sender': 'VM-NOSUCH-S', 'body': 'Rs.5.00', 'expectFactTypes': ['movement']},
          {'sender': 'VM-NOSUCH-S', 'body': 'zzz', 'expectFactTypes': <String>[]},
        ],
      );
      j['rules'] = [r];
      final codes2 = lintBundle(RuleBundle.fromJson(j)).map((i) => i.code).toSet();
      expect(codes2, contains('lint.sender.unknown'));
    });

    test('example mismatch is reported by runRuleExamples', () {
      final b = _bundle([
        _rule(
          id: 'WRONG',
          pattern: '^$_amt',
          examples: [
            {'sender': 'VM-HDFCBK-S', 'body': 'Rs.5.00', 'expectFactTypes': ['hold']},
            {'sender': 'VM-HDFCBK-S', 'body': 'Rs.7.00', 'expectFactTypes': <String>[]},
          ],
        ),
      ]);
      final kinds = runRuleExamples(b).map((f) => f.kind).toList();
      expect(kinds, containsAll(['positive_wrong_facts', 'negative_matched']));
    });
  });
}
