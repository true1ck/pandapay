// CCR-002: an info fact may carry attrs.amountMinor. It is informational only
// and must never reach the linker, ledger or totals as money.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

import 'linker/helpers.dart' as h;

Map<String, Object?> _fixture(String name) {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final f = File('${dir.path}/contracts/sms/v2/fixtures/$name');
    if (f.existsSync())
      return (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
    dir = dir.parent;
  }
  throw StateError('fixture $name not found');
}

InfoFact _info({int? amountMinor, String at = '2026-11-05T12:00:00Z'}) {
  final j = _fixture('valid/fact/info.ipo_application_amount.json');
  j['observedAt'] = at;
  j['occurredAt'] = at;
  j['attrs'] = {'category': 'service', 'amountMinor': ?amountMinor};
  j['factId'] = h.hex64('info:$at:$amountMinor');
  return Fact.fromJson(j) as InfoFact;
}

void main() {
  final at = DateTime.utc(2026, 11, 5, 12);

  group('contract', () {
    test('the amount fixture validates and round-trips', () {
      final j = _fixture('valid/fact/info.ipo_application_amount.json');
      expect(validateFactJson(j).ok, isTrue);
      final f = Fact.fromJson(j) as InfoFact;
      expect(f.amountMinor, 1500000);
      expect(f.amounts, isEmpty);
      expect(f.toJson()['attrs'], {
        'category': 'service',
        'amountMinor': 1500000,
      });
    });

    test('an old info payload without the field still validates', () {
      final j = _fixture('valid/fact/info.service.json');
      expect(validateFactJson(j).ok, isTrue);
      final f = Fact.fromJson(j) as InfoFact;
      expect(f.amountMinor, isNull);
      expect((f.toJson()['attrs'] as Map).containsKey('amountMinor'), isFalse);
    });

    test('a non-positive or non-integer amountMinor is rejected', () {
      final base = _fixture('valid/fact/info.ipo_application_amount.json');
      for (final bad in <Object>[0, -5, 'x', 1.5]) {
        final j = {
          ...base,
          'attrs': {'category': 'service', 'amountMinor': bad},
        };
        final r = validateFactJson(j);
        expect(r.ok, isFalse, reason: '$bad');
        expect(r.codes, contains('fact.info.amountMinor_invalid'));
      }
    });

    test('the amount may not be carried in the amounts list', () {
      final base = _fixture('valid/fact/info.ipo_application_amount.json');
      final j = {
        ...base,
        'amounts': [
          {'role': 'informational', 'minor': 1500000, 'unit': 'INR'},
        ],
      };
      final r = validateFactJson(j);
      expect(r.ok, isFalse);
      expect(r.codes, contains('fact.info.amount_count'));
    });
  });

  group('never money', () {
    test('the linker makes no event from an info fact with an amount', () {
      final r = h.linkAll([_info(amountMinor: 1500000)]);
      expect(h.eventsOf(r), isEmpty);
    });

    test('beside a debit, the linker events and totals are unchanged', () {
      final debit = h.debit(
        'purchase',
        10000,
        at: at.toIso8601String(),
        inst: h.hdfcCard,
        counterparty: h.party(name: 'SWIGGY', kind: 'merchant'),
      );
      final withInfo = h.linkAll([debit, _info(amountMinor: 10000)]);
      final alone = h.linkAll([debit]);
      expect(h.shapes(withInfo), h.shapes(alone));
      final events = h.eventsOf(withInfo);
      expect(events, hasLength(1));
      expect(events.single.legs.map((l) => l.factId), [debit.factId]);
      expect(events.single.amountMinor, 10000);

      final projector = DefaultLedgerProjector();
      final byId = {
        debit.factId: debit as Fact,
        for (final f in [_info(amountMinor: 99999999)]) f.factId: f,
      };
      final entries = projector.project(
        events.single,
        byId,
        h.allInstruments,
        null,
      );
      expect(entries.single.amountMinor, 10000);
      final totals = projector.totals(
        entries,
        events,
        at.subtract(const Duration(days: 1)),
        at.add(const Duration(days: 1)),
      );
      expect(totals.spendMinor, 10000);
    });

    test('an info fact forced in as a leg projects no entry and no totals', () {
      final info = _info(amountMinor: 1500000);
      final event = Event(
        eventId: info.factId,
        type: EventType.purchase,
        status: EventStatus.complete,
        legs: [EventLeg(factId: info.factId, role: LegRole.debitLeg)],
        confidence: .99,
        occurredAt: at,
        amountMinor: 1500000,
      );
      final projector = DefaultLedgerProjector();
      final entries = projector.project(
        event,
        {info.factId: info},
        h.allInstruments,
        null,
      );
      expect(entries, isEmpty);
      final totals = projector.totals(
        entries,
        [event],
        at.subtract(const Duration(days: 1)),
        at.add(const Duration(days: 1)),
      );
      expect(totals.spendMinor, 0);
      expect(totals.incomeMinor, 0);
      expect(totals.investmentMinor, 0);
    });
  });

  group('engine', () {
    test(
      'a rule can emit amountMinor on an info fact, without an amounts entry',
      () {
        final j = _fixture('valid/bundle/full.json');
        j['ignoreRules'] = <Object?>[];
        j['counterpartyPurposes'] = <Object?>[];
        final rules = (j['rules'] as List).cast<Map<String, Object?>>();
        final rule = {...rules.first};
        rule['id'] = 'TEST-IPO-INFO';
        rule['match'] = {
          'pattern': r'IPO application of Rs\.(?<amt>[\d,.]+)',
          'flags': 'i',
        };
        rule['senders'] = ['HDFCBK'];
        rule['priority'] = 900;
        rule['emit'] = [
          {
            'factType': 'info',
            'attrs': {
              'category': 'service',
              'amountMinor': {'from': 'amt'},
            },
          },
        ];
        rule['examples'] = [
          {
            'sender': 'VM-HDFCBK-S',
            'body': 'IPO application of Rs.15,000.00 received',
            'expectFactTypes': ['info'],
          },
          {
            'sender': 'VM-HDFCBK-S',
            'body': 'hello',
            'expectFactTypes': <String>[],
          },
        ];
        j['rules'] = [rule];
        final bundle = RuleBundle.fromJson(j);
        final r = RuleEngine().interpret(
          SmsMessage(
            sender: 'VM-HDFCBK-S',
            body: 'IPO application of Rs.15,000.00 received',
            observedAt: DateTime.utc(2026, 11, 1, 8),
            sourceKey: 'src-ipo',
          ),
          bundle,
          appVersion: '1',
        );
        final f = r.facts.single as InfoFact;
        expect(f.amountMinor, 1500000);
        expect(f.amounts, isEmpty);
        expect(f.validate().ok, isTrue);
      },
    );
  });
}
