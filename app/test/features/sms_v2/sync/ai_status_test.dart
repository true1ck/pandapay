import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/ai_status.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late SyncStateStore state;
  final remote = 'a' * 64;
  final local = 'b' * 64;
  final otherLocal = 'c' * 64;

  void origin() => state.put(
    'template:origins:$remote',
    jsonEncode({
      'senderBrand': 'HDFCBK',
      'localHashes': [local],
    }),
  );

  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    state = SyncStateStore(db, namespace: 'user:1');
  });
  tearDown(() => db.dispose());

  test('a format that was not uploaded is not "checking"', () {
    origin();
    expect(AiStatusReader(state).templateState(local), AiTemplateState.none);
    expect(
      AiStatusReader(state).templateState(otherLocal),
      AiTemplateState.none,
    );
  });

  test('uploaded and unanswered is checking; pending stays checking', () {
    origin();
    state.put('template:sent:$remote', '1');
    expect(
      AiStatusReader(state).templateState(local),
      AiTemplateState.checking,
    );
    state.put(
      'ai:$remote',
      jsonEncode({'templateHash': remote, 'status': 'pending'}),
    );
    expect(
      AiStatusReader(state).templateState(local),
      AiTemplateState.checking,
    );
  });

  test('an upload nobody answers stops saying checking after a day', () {
    origin();
    final sent = DateTime.utc(2026, 11, 20, 12);
    state.put('template:sent:$remote', sent.toIso8601String());
    AiTemplateState at(Duration later) =>
        AiStatusReader(state, now: () => sent.add(later)).templateState(local);
    expect(at(const Duration(hours: 23)), AiTemplateState.checking);
    expect(at(const Duration(hours: 25)), AiTemplateState.none);
    // A late answer still counts.
    state.put(
      'ai:$remote',
      jsonEncode({'templateHash': remote, 'status': 'ready', 'rule': {}}),
    );
    expect(at(const Duration(days: 3)), AiTemplateState.ready);
  });

  test('a ready answer, a rejection and a failure are told apart', () {
    origin();
    state.put('template:sent:$remote', '1');
    state.put(
      'ai:$remote',
      jsonEncode({'templateHash': remote, 'status': 'ready', 'rule': {}}),
    );
    expect(AiStatusReader(state).templateState(local), AiTemplateState.ready);
    for (final status in ['rejected', 'failed']) {
      state.put(
        'ai:$remote',
        jsonEncode({'templateHash': remote, 'status': status}),
      );
      expect(
        AiStatusReader(state).templateState(local),
        AiTemplateState.unavailable,
        reason: status,
      );
    }
  });

  test('revoking consent clears the state and so the checking label', () {
    origin();
    state.put('template:sent:$remote', '1');
    db.execute("DELETE FROM v2_sync_state WHERE key LIKE 'template:%'");
    expect(AiStatusReader(state).templateState(local), AiTemplateState.none);
  });

  test('resolution comes from the saved decision trace', () {
    state.put(
      'trace:s1',
      jsonEncode({'ruleId': 'AI-$remote:local:$local', 'ruleVersion': 1}),
    );
    state.put(
      'trace:s2',
      jsonEncode({'ruleId': 'BANK-DEBIT', 'ruleVersion': 3}),
    );
    state.put('trace:s3', 'not json');
    final reader = AiStatusReader(state);
    final unverified = reader.resolution('s1', sharedRuleIds: {'BANK-DEBIT'});
    expect(unverified?.verified, isFalse);
    expect(unverified?.ruleId, 'AI-$remote');
    expect(reader.resolution('s2', sharedRuleIds: {'BANK-DEBIT'}), isNull);
    expect(reader.resolution('s3', sharedRuleIds: {}), isNull);
    expect(reader.resolution('missing', sharedRuleIds: {}), isNull);
  });

  test('once the rule is published the same decision reads as verified', () {
    state.put(
      'trace:s1',
      jsonEncode({'ruleId': 'AI-$remote:local:$local', 'ruleVersion': 1}),
    );
    final verified = AiStatusReader(
      state,
    ).resolution('s1', sharedRuleIds: {'AI-$remote'});
    expect(verified?.verified, isTrue);
    // A rule read straight from the published bundle has no local suffix.
    state.put(
      'trace:s4',
      jsonEncode({'ruleId': 'AI-$remote', 'ruleVersion': 2}),
    );
    expect(
      AiStatusReader(
        state,
      ).resolution('s4', sharedRuleIds: {'AI-$remote'})?.verified,
      isTrue,
    );
  });
}
