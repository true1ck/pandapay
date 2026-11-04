// Lane P: behaviour pinned for the two hot-spot fixes that made a long history
// import quadratic. The timing proof is in history_stage_benchmark_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

RuleBundle _bundle(String path) => RuleBundle.fromJson(
  (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>(),
);

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  test('saving a confirmed row removes only its own provisional copy', () {
    TransactionEntry row(String id, String source, {bool provisional = false}) =>
        TransactionEntry(
          id: id,
          amount: Money.fromPaise(10000),
          occurredAt: DateTime.utc(2026, 10, 18),
          sourceKey: source,
          merchantName: 'Shop',
          source: 'sms',
          status: 'active',
        );
    for (final source in ['one', 'two']) {
      financial.saveProvisional('ns', row('local-sms:$source', source));
    }
    expect(financial.entities('ns', 'transactions'), hasLength(2));
    financial.saveTransactions('ns', [row('server-1', 'one')]);
    final ids = financial.entities('ns', 'transactions').map((r) => r['id']);
    expect(ids, unorderedEquals(['server-1', 'local-sms:two']));
  });

  test('a matched message resolves its own open template review only', () {
    final bundle = _bundle('../contracts/sms/v2/fixtures/valid/bundle/full.json');
    final empty = _bundle('assets/sms_rules/baseline_bundle.json');
    SmsV2Pipeline pipelineFor(RuleBundle b) => SmsV2Pipeline(
      financial: financial,
      namespace: 'user:test',
      bundle: b,
      appVersion: '2',
    );
    SmsMessage message(String key, String body) => SmsMessage(
      sender: 'VM-HDFCBK-S',
      body: body,
      sourceKey: key * 64,
      observedAt: DateTime.utc(2026, 11, 1, 7),
    );
    final matching = message('a', bundle.rules.first.examples.first.body);
    final other = message('b', 'An unrecognised financial alert Rs.250.');
    final blank = pipelineFor(empty);
    expect(blank.processBatch([matching, other]), 2);
    Set<Object?> status(String key) => {
      for (final row in db.db.select(
        "SELECT status FROM v2_review_items WHERE namespace='user:test' AND kind='template' AND json_extract(payload,'\$.sourceKey')=?",
        [key * 64],
      ))
        row['status'],
    };
    expect(status('a'), {'open'});
    expect(status('b'), {'open'});
    expect(pipelineFor(bundle).processBatch([matching, other]), 2);
    expect(status('a'), {'resolved'});
    expect(status('b'), {'open'});
  });
}
