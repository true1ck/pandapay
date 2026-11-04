// Lane P: replaying the same input twice changes nothing. No duplicate facts,
// evidence counts, ledger rows, queued uploads or earned rewards.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../support/rules.dart';
import '../support/sync_harness.dart';

/// Every row of every table the pipeline writes, in a canonical order.
Map<String, List<Object?>> dump(Device device) {
  const queries = {
    'facts': 'SELECT fact_id, source_key, payload FROM v2_facts ORDER BY fact_id',
    'instruments':
        'SELECT instrument_id, status, payload FROM v2_instruments ORDER BY instrument_id',
    'events': 'SELECT event_id, status, payload FROM v2_events ORDER BY event_id',
    'ledger': 'SELECT entry_id, payload FROM v2_ledger ORDER BY entry_id',
    'outbox': 'SELECT id, kind, payload FROM v2_outbox ORDER BY id',
    'review':
        'SELECT review_id, kind, status, payload FROM v2_review_items ORDER BY review_id',
    'display':
        'SELECT id, entity, payload, pending FROM financial_entities ORDER BY entity, id',
    'decisions':
        'SELECT source_key, decision, bundle_version FROM sms_source_decisions ORDER BY source_key',
    'stats': 'SELECT day, rule_id, hits, to_review FROM v2_rule_stats ORDER BY day, rule_id',
    'state': 'SELECT key, value FROM v2_sync_state ORDER BY key',
  };
  final tables = {
    for (final row in device.db.select("SELECT name FROM sqlite_master WHERE type='table'"))
      row['name'],
  };
  return {
    for (final e in queries.entries)
      if (e.key != 'decisions' || tables.contains('sms_source_decisions'))
      e.key: [
        for (final row in device.db.select(e.value))
          jsonEncode([for (final v in row.values) v]),
      ],
  };
}

void main() {
  final bundle = testRuleBundle();
  late Device device;
  setUp(() => device = Device('phone'));
  tearDown(() => device.dispose());

  test('capturing the same messages again changes no row', () {
    final history = sharedHistory(bundle, synthetic: 300);
    device.capture(bundle, history);
    final first = dump(device);
    expect(first['facts']!.length, greaterThan(200));
    expect(first['ledger']!.length, greaterThan(100));
    // An earned reward and a note live on the display row; replay must keep them.
    final rows = device.financial.entities(harnessNamespace, 'transactions');
    final target = rows.first;
    device.db.execute(
      "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
      [
        jsonEncode({...target, 'expected_value_inr': 12.5, 'note': 'kept'}),
        harnessNamespace,
        target['id'],
      ],
    );
    final withReward = dump(device);

    device.capture(bundle, history); // a fresh pipeline, the same source keys
    expect(dump(device), withReward);
    // Reward and the user's note survive, and nothing was queued twice.
    final after = device.financial.entities(harnessNamespace, 'transactions');
    expect(after.firstWhere((r) => r['id'] == target['id'])['expected_value_inr'], 12.5);
    expect(after.length, rows.length);
    expect(first['outbox']!.length, withReward['outbox']!.length);
  });

  test('one batch and one-at-a-time agree on every non-IPO event', () {
    final history = sharedHistory(bundle, synthetic: 120);
    final other = Device('other');
    addTearDown(other.dispose);
    device.capture(bundle, history);
    // Same messages, one at a time, in a second store.
    for (final message in history) {
      other.capture(bundle, [message]);
    }
    Map<String, int> kinds(Map<String, Object?> v) {
      final out = <String, int>{};
      for (final e in v['events'] as List) {
        final type = (e as Map)['type'] as String;
        if (type == 'ipo_application') continue;
        final k = '$type/${e['status']}';
        out[k] = (out[k] ?? 0) + 1;
      }
      return out;
    }

    // Known difference, reported in LANE-P.md: with several IPO blocks and
    // releases for different applications in one batch the linker marks some
    // applications ambiguous, where sequential processing links them.
    final a = digest(device), b = digest(other);
    expect(kinds(a), kinds(b));
    final ta = a['totals'] as Map, tb = b['totals'] as Map;
    expect(ta['spend'], tb['spend']);
    expect(ta['income'], tb['income']);
    expect(ta['refund'], tb['refund']);
  });

  test('re-running the runtime capture over a history is a no-op', () async {
    final encoded = jsonEncode(bundle.toJson());
    final runtime = SmsV2Runtime(
      financial: device.financial,
      namespace: harnessNamespace,
      client: MockClient((_) async => throw StateError('offline')),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'idempotency',
      appVersion: '2',
      headers: () async => {},
      verify: (value) async => value == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
      clock: () => DateTime.utc(2026, 11, 30),
    );
    final messages = [
      for (final m in sharedHistory(bundle, synthetic: 200))
        QueuedSms(sender: m.sender, body: m.body, receivedAt: m.at),
    ];
    await runtime.capture(messages, backfill: true);
    // The legacy one-time repair runs on the first entities() read; let it finish.
    device.financial.entities(harnessNamespace, 'cards');
    final first = dump(device);
    expect(first['facts']!.length, greaterThan(150));
    await runtime.capture(messages, backfill: true);
    await runtime.capture(messages.reversed.toList(), backfill: true);
    expect(dump(device), first);
    // The intake keeps one raw copy per message.
    final captured = device.db
        .select('SELECT COUNT(*) AS n FROM sms_captured_messages')
        .single['n'];
    expect(captured, lessThanOrEqualTo(messages.length));
    expect(SmsIntakeRepository(device.database).pending(harnessNamespace), isEmpty);
  });

  test('receiving the same sync pages twice changes nothing', () async {
    final uploader = Device('uploader');
    addTearDown(uploader.dispose);
    uploader.capture(bundle, sharedHistory(bundle, synthetic: 150));
    final server = ServerLog()..ingest(uploader);
    final pages = server.pages(size: 20);
    await device.receive(bundle, pages);
    final first = dump(device);
    final view = digest(device);
    await device.receive(bundle, pages);
    await device.receive(bundle, shuffledWithDuplicates(pages, 5));
    final second = dump(device);
    // The cursor moves; every other table is untouched.
    second['state'] = first['state']!;
    expect(second, first);
    expect(digest(device), view);
    expect(device.outbox.due(DateTime.utc(2100)), isEmpty);
  });
}
