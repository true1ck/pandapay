// "Refresh rules and re-sort" pressed again on a rule set that is already
// applied must not offer to apply it again; a newer rule set must still be
// downloaded, previewed and applied.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:test-reapply';
// The contract fixtures' synthetic signature: the runtime's own check is
// replaced by `verify` below, the bundle only has to parse.
const _signature = {
  'alg': 'Ed25519',
  'keyId': 'sms-rules-2026-11',
  'value': 'c3ludGhldGljLXNpZ25hdHVyZS1ub3QtcmVhbA==',
};

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late RuleBundle v1;
  late RuleBundle v2;
  late String raw1, raw2, raw3;
  late RuleBundle v3;
  final now = DateTime.utc(2026, 11, 14, 7);

  Map<String, Object?> withSwiggy(
    Map<String, Object?> json,
    String category,
    int version,
  ) => {
    ...json,
    'bundleVersion': version,
    'signature': _signature,
    'categoryRules': [
      {
        'merchantKey': 'SWIGGY',
        'match': 'token',
        'senders': ['*'],
        'context': <Object?>[],
        'category': category,
        'priority': 100,
        'source': 'shared',
      },
    ],
  };

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    final base = testRuleBundle().toJson();
    base['categoryRules'] = <Object?>[];
    final j1 = {...base, 'bundleVersion': 1, 'signature': _signature};
    final j2 = withSwiggy(base, 'dining', 2);
    final j3 = withSwiggy(base, 'groceries', 3);
    v1 = RuleBundle.fromJson(j1);
    v2 = RuleBundle.fromJson(j2);
    v3 = RuleBundle.fromJson(j3);
    raw1 = jsonEncode(j1);
    raw2 = jsonEncode(j2);
    raw3 = jsonEncode(j3);
    for (var i = 0; i < 6; i++) {
      SmsV2Pipeline(
        financial: financial,
        namespace: _ns,
        bundle: v1,
        appVersion: '2.0.0',
      ).process(
        SmsMessage(
          sourceKey: '${i + 1}'.padLeft(64, '0'),
          sender: 'VM-HDFCBK-S',
          body:
              'Sent Rs.${499 + i}.00 From HDFC Bank A/C **1797 to SWIGGY UPI on 10-11-26. Avl Bal Rs.12,345.67',
          observedAt: DateTime.utc(2026, 11, 10, 7, i),
        ),
        backfill: true,
      );
    }
    // A card purchase and its refund: the refund keeps its category only as the
    // two wire fields, which is what made a finished re-sort offer itself again.
    SmsV2Pipeline(
      financial: financial,
      namespace: _ns,
      bundle: v1,
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
    // As after a normal upload: nothing is waiting to be sent, and the one-time
    // re-send of set-aside records has already happened.
    db.db.execute('DELETE FROM v2_outbox');
    db.db.execute(
      "UPDATE v2_facts SET uploaded_at='2026-11-10T08:00:00Z' WHERE namespace=?",
      [_ns],
    );
    SyncStateStore(
      db.db,
      namespace: _ns,
    ).put('upload:resent-set-aside-v1', '2026-11-10T08:00:00Z');
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  // What the "server" hands out for the rules request.
  var served = '';
  SmsV2Runtime runtime() => SmsV2Runtime(
    financial: financial,
    namespace: _ns,
    client: MockClient((request) async {
      switch (request.url.path) {
        case '/sms/v2/rules':
          return served.isEmpty
              ? http.Response('', 304)
              : http.Response.bytes(utf8.encode(served), 200);
        case '/sms/v2/rule-stats:batch':
          return http.Response('{}', 202);
        case '/sms/v2/sync':
          return http.Response(
            jsonEncode({
              'cursor': 'one',
              'instruments': [],
              'events': [],
              'ledger': [],
              'facts': [],
              'aiResults': [],
              'corrections': [],
              'latestBundleVersion': 1,
            }),
            200,
          );
        default:
          return http.Response('{}', 200);
      }
    }),
    baseUri: Uri.parse('https://api.invalid'),
    deviceId: 'test-device',
    appVersion: '2',
    headers: () async => {'Authorization': 'Bearer fixture'},
    verify: (text) async => text == raw1
        ? v1
        : text == raw2
        ? v2
        : text == raw3
        ? v3
        : null,
    loadShippedBundle: () async => raw1,
    accountIsCurrent: () => true,
    clock: () => now,
  );

  test('apply, then refresh again on the same rules: nothing to apply', () async {
    final r = runtime();
    served = raw2;
    final first = await r.refreshRulesAndReanalyze();
    expect(first.gotNewRules, isTrue);
    expect(first.resortWouldMove, 8);
    expect(first.canApply, isTrue);

    final applied = await r.applyResort();
    expect(applied.resorted, 8);

    served = '';
    final second = await r.refreshRulesAndReanalyze();
    expect(second.gotNewRules, isFalse);
    expect(second.resortWouldMove, 0);
    expect(second.canApply, isFalse);
  });

  test(
    'a re-sort that could not mark the rule set done still finds nothing to apply the next time',
    () async {
      // An Apply that skips a spend (one it could not look at, or one still
      // waiting to be sent) does not record the rule set as done. The next
      // Refresh then looks at every spend again, and it must find the spends
      // that were moved already moved: not offer the same ones again.
      final r = runtime();
      served = raw2;
      await r.refreshRulesAndReanalyze();
      expect((await r.applyResort()).resorted, 8);
      db.db.execute(
        "DELETE FROM v2_sync_state WHERE namespace=? AND key='pipeline:category-revision'",
        [_ns],
      );
      served = '';
      final second = await r.refreshRulesAndReanalyze();
      expect(second.gotNewRules, isFalse);
      expect(second.resortWouldMove, 0);
      expect(second.canApply, isFalse);
      // Nothing was offered, so the rule set is now recorded as done.
      expect(
        SyncStateStore(db.db, namespace: _ns).get('pipeline:category-revision'),
        isNotNull,
      );
      expect((await r.refreshRulesAndReanalyze()).canApply, isFalse);
    },
  );

  test('a newer rule set after an applied one is still offered', () async {
    final r = runtime();
    served = raw2;
    await r.refreshRulesAndReanalyze();
    await r.applyResort();
    served = '';
    expect((await r.refreshRulesAndReanalyze()).canApply, isFalse);

    served = raw3;
    final third = await r.refreshRulesAndReanalyze();
    expect(third.gotNewRules, isTrue);
    expect(third.resortWouldMove, 8);
    expect(third.canApply, isTrue);
    expect((await r.applyResort()).resorted, 8);
    expect(
      SyncStateStore(db.db, namespace: _ns).get('pipeline:category-revision'),
      isNotNull,
    );
  });

  test('"Not now" leaves the rule set unapplied, so the next refresh offers it again', () async {
    final r = runtime();
    served = raw2;
    final first = await r.refreshRulesAndReanalyze();
    expect(first.canApply, isTrue);
    served = '';
    final second = await r.refreshRulesAndReanalyze();
    expect(second.gotNewRules, isFalse);
    expect(second.resortWouldMove, 8);
    expect(second.canApply, isTrue);
  });
}
