import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/provisional_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/stats_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/storage/template_origin_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:sqlite3/sqlite3.dart';

const _namespace = 'user:private-stats';

void main() {
  test('a hit on a private AI rule is reported under the layout AI id, as sent to review', () {
    final database = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(() {
      database.db.dispose();
    });
    final financial = FinancialStore(database);
    addTearDown(financial.dispose);
    SmsV2Schema.ensure(database.db);
    final json =
        (jsonDecode(File('../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync()) as Map)
            .cast<String, Object?>();
    final full = RuleBundle.fromJson(json);
    final rule = full.rules.firstWhere((r) => r.status == RuleStatus.provisional);
    // No shared rule competes: the private rule is the only one that can read it.
    final shared = RuleBundle.fromJson({...json, 'rules': <Object?>[]});
    final example = rule.examples.firstWhere((e) => e.expectFactTypes.isNotEmpty);
    final brand = smsTemplateBrand(example.sender);
    final localHash = smsTemplateHash(brand, smsSkeleton(example.body));

    final state = SyncStateStore(database.db, namespace: _namespace);
    TemplateOriginStore(state).remember(
      remoteHash: rule.match.templateHash!,
      localHash: localHash,
      senderBrand: rule.senders.single,
    );
    state.put(
      'ai:${rule.match.templateHash}',
      jsonEncode({'templateHash': rule.match.templateHash, 'status': 'ready', 'rule': rule.toJson()}),
    );
    final overlay = ProvisionalStore(state).overlay(shared).bundle;
    expect(overlay.rules.last.id, startsWith('${rule.id}:local:'));

    SmsV2Pipeline(
      financial: financial,
      namespace: _namespace,
      bundle: overlay,
      appVersion: '2.0.0',
    ).process(
      SmsMessage(
        sourceKey: 'a' * 64,
        sender: example.sender,
        body: example.body,
        observedAt: DateTime.utc(2026, 11, 4, 8),
      ),
    );
    final rows = database.db.select(
      'SELECT rule_id,rule_version,hits,to_review,corrected FROM v2_rule_stats_by_account WHERE namespace=?',
      [_namespace],
    );
    expect(rows.map((row) => row['rule_id']), [rule.id], reason: 'the same id on every phone');
    expect(rows.single['hits'], 1);
    expect(rows.single['to_review'], 1);
    final payload = StatsStore(database.db, namespace: _namespace)
        .payload(DateTime.utc(2026, 11, 4, 8), appVersion: '2', bundleVersion: 1)!;
    expect((payload['stats'] as List).single, containsPair('ruleId', rule.id));
  });
}
