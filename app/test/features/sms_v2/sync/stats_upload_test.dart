import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/stats_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/stats_upload.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late StatsStore stats;
  late SyncStateStore state;
  final first = DateTime.utc(2026, 11, 4, 8);
  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    stats = StatsStore(db, namespace: 'a');
    state = SyncStateStore(db, namespace: 'a');
  });
  tearDown(() => db.dispose());

  test('closed daily snapshot includes hits after the first upload', () async {
    final payloads = <Map<String, dynamic>>[];
    final upload = StatsUpload(
      stats: stats,
      state: state,
      client: MockClient((request) async {
        payloads.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{}', 202);
      }),
      baseUri: Uri.parse('https://api.invalid'),
      headers: () async => {},
      accountIsCurrent: () => true,
    );
    void record() => stats.record(at: first, ruleId: 'BANK', ruleVersion: 2);
    record();
    await upload.send(first, appVersion: '1', bundleVersion: 2);
    record();
    stats.correction(at: first, ruleId: 'BANK', ruleVersion: 2);
    StatsStore(
      db,
      namespace: 'b',
    ).record(at: first, ruleId: 'OTHER-ACCOUNT', ruleVersion: 1);
    await upload.send(
      first.add(const Duration(hours: 2)),
      appVersion: '1',
      bundleVersion: 2,
    );
    expect(payloads, hasLength(1));
    await upload.send(
      first.add(const Duration(days: 1)),
      appVersion: '1',
      bundleVersion: 2,
    );
    expect(payloads.last['day'], '2026-11-04');
    expect(payloads.last['stats'], [
      {
        'ruleId': 'BANK',
        'ruleVersion': 2,
        'hits': 2,
        'toReview': 0,
        'corrected': 1,
      },
    ]);
  });

  test(
    'failed upload stays retryable and token refresh fences account changes',
    () async {
      stats.record(at: first, ruleId: 'BANK', ruleVersion: 1);
      var current = true, switchOnRefresh = false;
      var calls = 0;
      final upload = StatsUpload(
        stats: stats,
        state: state,
        client: MockClient((request) async {
          calls++;
          return http.Response('{}', 503);
        }),
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async {
          if (switchOnRefresh) current = false;
          return {};
        },
        accountIsCurrent: () => current,
      );
      await upload.send(first, appVersion: '1', bundleVersion: 1);
      expect(calls, 1);
      expect(state.get('stats:last-sent'), isNull);
      switchOnRefresh = true;
      await upload.send(first, appVersion: '1', bundleVersion: 1);
      expect(calls, 1);
      expect(state.get('stats:last-sent'), isNull);
    },
  );

  test('personal and private rules do not affect shared correction rates', () {
    for (final id in ['PERSONAL-private', 'PRIVATE:local:hash']) {
      stats.record(at: first, ruleId: id, ruleVersion: 1);
      stats.correction(at: first, ruleId: id, ruleVersion: 1);
    }
    final payload = stats.payload(first, appVersion: '1', bundleVersion: 1)!;
    expect((payload['stats'] as List).map((row) => (row as Map)['corrected']), [
      0,
      0,
    ]);
  });
  group('private AI rules', main2);
}

// ---- learning loop B6: a private AI rule reports under its layout's AI id

void main2() {
  late Database db;
  late StatsStore stats;
  final day = DateTime.utc(2026, 11, 4, 8);
  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    stats = StatsStore(db, namespace: 'a');
  });
  tearDown(() => db.dispose());

  test('only a private AI rule maps to a shared id; personal and other private rules do not', () {
    final hash = 'c' * 64;
    expect(StatsStore.reportedRuleId('AI-$hash:local:${'d' * 64}'), 'AI-$hash');
    expect(StatsStore.reportedRuleId('AI-$hash'), 'AI-$hash');
    expect(StatsStore.reportedRuleId('HDFC-CARD-SPEND-03'), 'HDFC-CARD-SPEND-03');
    expect(StatsStore.reportedRuleId('PERSONAL-1:local:x'), isNull);
    expect(StatsStore.reportedRuleId('PRIVATE:local:hash'), isNull);
    expect(StatsStore.reportedRuleId('SOMETHING-ELSE:local:hash'), isNull);
  });

  test('a correction on a private AI rule counts against the AI id', () {
    final hash = 'c' * 64;
    stats.record(at: day, ruleId: 'AI-$hash', ruleVersion: 1, toReview: true);
    stats.record(at: day, ruleId: 'AI-$hash', ruleVersion: 1, toReview: true);
    stats.correction(at: day, ruleId: 'AI-$hash:local:${'d' * 64}', ruleVersion: 1);
    final payload = stats.payload(day, appVersion: '1', bundleVersion: 1)!;
    expect(payload['stats'], [
      {'ruleId': 'AI-$hash', 'ruleVersion': 1, 'hits': 2, 'toReview': 2, 'corrected': 1},
    ]);
  });
}
