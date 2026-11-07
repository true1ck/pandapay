// The "Refresh rules and re-sort" button: it must fetch the rules now (not
// after the six-hour wait), say what happened in words, and never let one
// failing step stop the rest, in the button or in the ordinary sync.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _ns = 'user:test';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late String encoded;
  late String encodedNewer;
  late RuleBundle bundle;
  late RuleBundle newer;
  final now = DateTime.utc(2026, 11, 1, 7);

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    encoded = File(
      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
    ).readAsStringSync();
    final json = (jsonDecode(encoded) as Map).cast<String, Object?>();
    bundle = RuleBundle.fromJson(json);
    final higher = {...json, 'bundleVersion': bundle.bundleVersion + 1};
    encodedNewer = jsonEncode(higher);
    newer = RuleBundle.fromJson(higher);
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  SmsV2Runtime runtime(
    List<String> paths, {
    int rulesStatus = 304,
    String rulesBody = '',
    int syncStatus = 200,
    bool badSync = false,
  }) {
    return SmsV2Runtime(
      financial: financial,
      namespace: _ns,
      client: MockClient((request) async {
        paths.add(request.url.path);
        switch (request.url.path) {
          case '/sms/v2/rules':
            return http.Response(rulesBody, rulesStatus);
          case '/sms/v2/rule-stats:batch':
            return http.Response('{}', 202);
          case '/sms/v2/sync':
            if (badSync) {
              // A 200 that is not a sync answer: the pull refuses it.
              return http.Response('{"not":"a sync answer"}', 200);
            }
            return http.Response(
              syncStatus == 200
                  ? jsonEncode({
                      'cursor': 'one',
                      'instruments': [],
                      'events': [],
                      'ledger': [],
                      'facts': [],
                      'aiResults': [],
                      'corrections': [],
                      'latestBundleVersion': 1,
                    })
                  : '{}',
              syncStatus,
            );
          default:
            return http.Response('{}', 200);
        }
      }),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'test-device',
      appVersion: '2',
      headers: () async => {'Authorization': 'Bearer fixture'},
      verify: (raw) async => raw == encoded
          ? bundle
          : raw == encodedNewer
          ? newer
          : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
      clock: () => now,
    );
  }

  test(
    'the button asks for the rules at once, even right after a normal sync',
    () async {
      final paths = <String>[];
      final r = runtime(paths);
      await r.sync();
      expect(paths.where((p) => p == '/sms/v2/rules'), hasLength(1));
      await r.sync();
      // The ordinary pass waits six hours between rule checks.
      expect(paths.where((p) => p == '/sms/v2/rules'), hasLength(1));

      final report = await r.refreshRulesAndReanalyze();
      expect(paths.where((p) => p == '/sms/v2/rules'), hasLength(2));
      expect(report.rulesProblem, isNull);
      expect(report.gotNewRules, isFalse);
      expect(report.hasProblem, isFalse);
      expect(report.lines.first, contains('already the latest'));
    },
  );

  test('a newer rule set is installed and reported', () async {
    final paths = <String>[];
    final r = runtime(paths, rulesStatus: 200, rulesBody: encodedNewer);
    final report = await r.refreshRulesAndReanalyze();
    expect(report.versionBefore, bundle.bundleVersion);
    expect(report.versionAfter, newer.bundleVersion);
    expect(report.gotNewRules, isTrue);
    expect(report.ruleCount, newer.rules.length);
    expect(report.lines.first, contains('Got new rules'));
    expect(report.lines.first, contains('version ${newer.bundleVersion}'));
  });

  test(
    'a refused download is said in words and the other steps still run',
    () async {
      final paths = <String>[];
      final r = runtime(paths, rulesStatus: 403);
      final report = await r.refreshRulesAndReanalyze();
      expect(report.rulesProblem, contains('could not confirm the app'));
      expect(report.hasProblem, isTrue);
      expect(report.lines.first, report.rulesProblem);
      // The re-sort still ran (nothing to move on an empty phone).
      expect(report.resortProblem, isNull);
      expect(report.resorted, 0);
      expect(
        SyncStateStore(
          financial.database.db,
          namespace: _ns,
        ).get('rules:last-refresh'),
        isNotNull,
      );
    },
  );

  test('no connection: the button reports it and does not throw', () async {
    final r = SmsV2Runtime(
      financial: financial,
      namespace: _ns,
      client: MockClient((_) async => throw const SocketException('offline')),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'test-device',
      appVersion: '2',
      headers: () async => {'Authorization': 'Bearer fixture'},
      verify: (raw) async => raw == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
      clock: () => now,
    );
    final report = await r.refreshRulesAndReanalyze();
    expect(report.rulesProblem, contains('Could not reach'));
    expect(report.versionAfter, report.versionBefore);
  });

  test(
    'a failing step in the ordinary sync no longer stops the re-sort',
    () async {
      final paths = <String>[];
      final r = runtime(paths, badSync: true);
      // The pull fails and is reported...
      await expectLater(r.sync(), throwsA(anything));
      // ...but everything after it still ran: the rule-chosen categories were
      // checked and marked as applied for this rule set.
      expect(paths, contains('/sms/v2/sync'));
      expect(
        SyncStateStore(
          financial.database.db,
          namespace: _ns,
        ).get('pipeline:category-revision'),
        isNotNull,
      );
    },
  );
}
