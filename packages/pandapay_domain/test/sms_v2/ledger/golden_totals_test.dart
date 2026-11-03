import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';
import '../support/rules.dart';

void main() {
  test(
    'every golden scenario has exact totals and valid ledger JSON after reload',
    () {
      final bundle = testRuleBundle();
      final engine = RuleEngine();
      for (final file in Directory(
        '../../tools/sms_golden/scenarios',
      ).listSync().whereType<File>()) {
        if (!file.path.endsWith('.json')) continue;
        final scenario =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final facts = <Map<String, dynamic>>[];
        final senders = <String, String>{};
        var n = 0;
        for (final m in scenario['messages'] as List) {
          final key = 'golden:${scenario['id']}:${n++}';
          senders[key] = normalizeSenderBrand(
            m['sender'] as String,
            bundle.senders,
          ).brand;
          final r = engine.interpret(
            SmsMessage(
              sender: m['sender'] as String,
              body: m['body'] as String,
              observedAt: DateTime.parse(m['observedAt'] as String),
              sourceKey: key,
            ),
            bundle,
            appVersion: 'test',
          );
          facts.addAll(
            r.facts
                .where((f) => f.factType != FactType.info)
                .map((f) => f.toJson()),
          );
        }
        final resolved = resolveInstrumentsForGolden(
          facts: facts,
          knownInstruments: [
            for (final i in scenario['knownInstruments'] as List? ?? [])
              (i as Map).cast<String, dynamic>(),
          ],
          bundle: bundle,
        );
        final events = linkForGolden(
          facts: [for (final f in resolved.facts) f.cast<String, dynamic>()],
          instruments: [
            for (final i in resolved.instruments) i.cast<String, dynamic>(),
          ],
          bundle: bundle,
        ).map(Event.fromJson).toList();
        final parsed = <String, Fact>{};
        final ids = <String, String>{};
        for (final f in resolved.facts) {
          final copy = Map<String, Object?>.from(f);
          final id = copy.remove('instrumentId') as String?;
          final fact = Fact.fromJson(copy);
          parsed[fact.factId] = fact;
          if (id != null) ids[fact.factId] = id;
        }
        final snapshot = LedgerSnapshot.project(
          events: events,
          factsById: parsed,
          instrumentsById: {
            for (final i in resolved.instruments)
              i['instrumentId'] as String: Instrument.fromJson(i),
          },
          bundle: bundle,
          instrumentIdByFactId: ids,
          senderBySource: senders,
        );
        for (final row in snapshot.entries) {
          expect(row.validate().ok, isTrue, reason: scenario['id'] as String);
        }
        final reloaded = LedgerSnapshot(
          entries: snapshot.entries.map(
            (r) => LedgerEntry.fromJson(r.toJson()),
          ),
          events: events,
          categoryByEvent: snapshot.categoryByEvent,
        );
        final expected = scenario['expect']['totals'] as Map;
        final t = reloaded.totals(
          DateTime.parse(expected['from'] as String),
          DateTime.parse(expected['to'] as String),
        );
        expect(
          [t.spendMinor, t.incomeMinor, t.investmentMinor, t.transactionCount],
          [
            expected['spendMinor'],
            expected['incomeMinor'],
            expected['investmentMinor'],
            expected['transactionCount'],
          ],
          reason: scenario['id'] as String,
        );
      }
    },
  );
}
