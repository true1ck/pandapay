import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/migration/history_category_recheck.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _namespace = 'user:automatic-recheck';
final _now = DateTime.utc(2026, 11, 20);

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle before;
  late RuleBundle after;
  final eventBySource = <CategorySource, String>{};

  LedgerStore ledger() => LedgerStore(database.db, namespace: _namespace);

  HistoryCategoryRecheck pass({bool Function()? current}) =>
      HistoryCategoryRecheck.automaticChoices(
        financial: financial,
        namespace: _namespace,
        bundle: after,
        accountIsCurrent: current ?? () => true,
        now: _now,
      );

  setUp(() {
    eventBySource.clear();
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    before = testRuleBundle();
    final json = before.toJson();
    json['categoryRules'] = <Object?>[];
    before = RuleBundle.fromJson(json);
    // The next rule set: SWIGGY is Dining, for everyone.
    after = RuleBundle.fromJson({
      ...json,
      'categoryRules': [
        {
          'merchantKey': 'SWIGGY',
          'match': 'token',
          'senders': ['*'],
          'context': <Object?>[],
          'category': 'dining',
          'priority': 100,
          'source': 'shared',
        },
      ],
    });
    const sources = [
      CategorySource.fallback,
      CategorySource.catalogue,
      CategorySource.shared,
      CategorySource.ai,
      CategorySource.user,
      CategorySource.historyConfirmed,
    ];
    for (var index = 0; index < sources.length; index++) {
      SmsV2Pipeline(
        financial: financial,
        namespace: _namespace,
        bundle: before,
        appVersion: '2.0.0',
      ).process(
        SmsMessage(
          sourceKey: '${index + 1}'.padLeft(64, '0'),
          sender: 'VM-HDFCBK-S',
          body:
              'Sent Rs.${499 + index}.00 From HDFC Bank A/C **1797 to SWIGGY UPI on 10-11-26. Avl Bal Rs.12,345.67',
          observedAt: DateTime.utc(2026, 11, 10, 7, index),
        ),
        backfill: true,
      );
    }
    // Give each spend the category source under test, as if an earlier pass,
    // the user, or their confirmed history had chosen it.
    final events = <String>[
      for (final row in database.db.select(
        'SELECT DISTINCT event_id FROM v2_ledger WHERE namespace=? ORDER BY occurred_at',
        [_namespace],
      ))
        row['event_id'] as String,
    ];
    expect(events, hasLength(sources.length));
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      eventBySource[source] = events[index];
      ledger().replaceForEvent(
        events[index],
        ledger().forEvent(events[index]),
        category: CategoryDecision(
          slug: source == CategorySource.fallback ? 'other' : 'groceries',
          source: source,
          confidence: source == CategorySource.user ? 1 : 0.6,
        ),
      );
    }
    database.db.execute('DELETE FROM v2_outbox');
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  test(
    'rule-chosen categories become the new shared category; the user\'s own and confirmed ones stay',
    () async {
      final report = await pass().run(chunkSize: 50);
      expect(report.complete, isTrue);
      final decisions = ledger().categoryDecisions();
      for (final source in [
        CategorySource.fallback,
        CategorySource.catalogue,
        CategorySource.shared,
        CategorySource.ai,
      ]) {
        final decision = decisions[eventBySource[source]]!;
        expect(
          decision.slug,
          'dining',
          reason: '${source.wire} spends follow the new rule',
        );
        expect(decision.source, CategorySource.shared, reason: source.wire);
      }
      for (final source in [
        CategorySource.user,
        CategorySource.historyConfirmed,
      ]) {
        final decision = decisions[eventBySource[source]]!;
        expect(
          decision.slug,
          'groceries',
          reason: '${source.wire} is never touched',
        );
        expect(decision.source, source);
      }
      expect(report.changed, 4);
      // The money is untouched and the display rows follow the ledger.
      final names = {
        for (final row in financial.entities(_namespace, 'transactions'))
          row['event_id']: row['category_name'],
      };
      expect(names[eventBySource[CategorySource.fallback]], 'Dining');
      expect(names[eventBySource[CategorySource.user]], isNot('Dining'));
    },
  );

  test(
    'the source filter is part of the job identity, so a plain pass is not skipped',
    () async {
      await pass().run(chunkSize: 50);
      expect(pass().onlySources, automaticCategorySources);
      final plain = HistoryCategoryRecheck(
        financial: financial,
        namespace: _namespace,
        bundle: after,
        from: DateTime.utc(1970),
        to: _now.add(const Duration(days: 2)),
        accountIsCurrent: () => true,
      );
      // Without a filter the history-confirmed spend is re-evaluated as before.
      final report = await plain.run(chunkSize: 50);
      expect(report.data['alreadyApplied'], isNot(true));
    },
  );

  test('a second pass for the same rule set changes nothing', () async {
    await pass().run(chunkSize: 50);
    final second = await pass().run(chunkSize: 50);
    expect(second.data['alreadyApplied'], isTrue);
    expect(second.changed, 0);
  });

  test(
    'a forced pass looks at every spend again even for a rule set already applied',
    () async {
      await pass().run(chunkSize: 50);
      final plainSecond = await pass().run(chunkSize: 50);
      expect(plainSecond.data['alreadyApplied'], isTrue);
      final forced = await pass().run(chunkSize: 50, restart: true);
      expect(forced.data['alreadyApplied'], isNot(true));
      expect(forced.complete, isTrue);
      // Nothing left to change, and the person's own choices are still untouched.
      expect(forced.changed, 0);
      final decisions = ledger().categoryDecisions();
      for (final source in [
        CategorySource.user,
        CategorySource.historyConfirmed,
      ]) {
        expect(decisions[eventBySource[source]]!.source, source);
      }
    },
  );

  test('the account is checked between batches', () async {
    var checks = 0;
    await expectLater(
      pass(current: () => ++checks < 4).run(chunkSize: 1),
      throwsStateError,
    );
    expect(
      ledger()
          .categoryDecisions()
          .values
          .where((d) => d.slug == 'dining')
          .length,
      lessThan(4),
    );
  });

  test('money waiting for the server holds the pass back', () async {
    final entry = ledger().list().first;
    database.db.execute(
      "INSERT INTO v2_outbox(namespace,id,kind,payload) VALUES(?,?,?,?)",
      [
        _namespace,
        'ledger:${entry.entryId}',
        'ledger',
        jsonEncode(entry.toJson()),
      ],
    );
    final report = await pass().run(chunkSize: 50);
    expect(report.awaitingSync, 1);
  });
}
