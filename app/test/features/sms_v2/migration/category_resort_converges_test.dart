// A re-sort that has been applied must leave nothing to apply: looking at the
// same history again with the same rules finds no change. Before this was
// fixed, refunds (which keep only a category and its source on the wire) and
// spends with no ledger row were counted as "would move" on every pass, so the
// Refresh sheet kept offering "Apply" for a rule set that was already applied.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/migration/history_category_recheck.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';
import '../support/synthetic_corpus.dart';

const _namespace = 'user:resort-converges';
final _now = DateTime.utc(2026, 12, 20);

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle rules;

  HistoryCategoryRecheck pass() => HistoryCategoryRecheck.automaticChoices(
    financial: financial,
    namespace: _namespace,
    bundle: rules,
    accountIsCurrent: () => true,
    now: _now,
  );

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    rules = testRuleBundle();
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  /// History read before the category rules existed, so every rule has
  /// something to move.
  void readHistoryWithoutCategoryRules(int count) {
    final json = rules.toJson();
    json['categoryRules'] = <Object?>[];
    json['merchantAliases'] = <Object?>[];
    final older = RuleBundle.fromJson(json);
    final pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: _namespace,
      bundle: older,
      appVersion: '2.0.0',
    );
    final messages = [
      for (final (index, m)
          in SyntheticCorpus.generate(rules, count: count, seed: 11).messages.indexed)
        SmsMessage(
          sourceKey: (index + 1).toRadixString(16).padLeft(64, '0'),
          sender: m.sender,
          body: m.body,
          observedAt: m.receivedAt,
        ),
    ];
    for (var start = 0; start < messages.length; start += 50) {
      pipeline.processBatch(messages.skip(start).take(50).toList(), backfill: true);
    }
    database.db.execute('DELETE FROM v2_outbox');
  }

  test(
    'a varied history: the preview says what Apply does, and a second look finds nothing',
    () async {
      readHistoryWithoutCategoryRules(400);

      final preview = await pass().preview(restart: true);
      expect(preview.changed, greaterThan(0), reason: 'the rules have work to do');

      final applied = await pass().run(chunkSize: 50, restart: true);
      expect(
        applied.changed,
        preview.changed,
        reason: 'the number offered is the number moved',
      );

      final again = await pass().preview(restart: true);
      expect(again.changed, 0, reason: 'nothing left to offer');
      final second = await pass().run(chunkSize: 50, restart: true);
      expect(second.changed, 0, reason: 'applying again moves nothing');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a refund counts as moved once, not on every pass', () async {
    final json = rules.toJson();
    json['categoryRules'] = <Object?>[];
    final older = RuleBundle.fromJson(json);
    SmsV2Pipeline(
      financial: financial,
      namespace: _namespace,
      bundle: older,
      appVersion: '2.0.0',
    ).processBatch([
      SmsMessage(
        sourceKey: 'a' * 64,
        sender: 'VM-HDFCBK-S',
        body:
            'Rs.499.00 spent on HDFC Bank Card x5678 at SWIGGY on 2026-11-01:12:30:11. Avl Lmt: Rs.45,000.00.',
        observedAt: DateTime.utc(2026, 11, 1, 12, 31),
      ),
      SmsMessage(
        sourceKey: 'b' * 64,
        sender: 'VM-HDFCBK-S',
        body:
            'Refund of Rs.499.00 from SWIGGY credited to your HDFC Bank Credit Card XX5678 on 03-11-26.',
        observedAt: DateTime.utc(2026, 11, 3, 10),
      ),
    ], backfill: true);
    database.db.execute('DELETE FROM v2_outbox');

    final applied = await pass().run(chunkSize: 50, restart: true);
    expect(applied.changed, greaterThan(0));
    // The refund reads back from the ledger without the rule id.
    final refund = LedgerStore(database.db, namespace: _namespace)
        .list()
        .singleWhere((entry) => !entry.isSpend);
    expect(
      LedgerStore(database.db, namespace: _namespace)
          .categoryDecisions()[refund.eventId]!
          .ruleId,
      isNull,
    );
    expect((await pass().preview(restart: true)).changed, 0);
    expect((await pass().run(chunkSize: 50, restart: true)).changed, 0);
  });
}
