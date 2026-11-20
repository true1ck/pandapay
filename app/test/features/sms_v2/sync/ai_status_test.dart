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

  test('a format sent a moment ago and not answered is waited for, and stops once answered or old', () {
    final now = DateTime.utc(2026, 11, 20, 12);
    expect(hasFormatWaitingForAnswer(state, now: now), isFalse, reason: 'nothing sent');
    state.put('template:sent:$remote', now.subtract(const Duration(minutes: 2)).toIso8601String());
    expect(hasFormatWaitingForAnswer(state, now: now), isTrue, reason: 'sent, no answer yet');
    state.put('ai:$remote', jsonEncode({'templateHash': remote, 'status': 'pending'}));
    expect(hasFormatWaitingForAnswer(state, now: now), isTrue, reason: 'the server has it queued');
    state.put('ai:$remote', jsonEncode({'templateHash': remote, 'status': 'ready'}));
    expect(hasFormatWaitingForAnswer(state, now: now), isFalse, reason: 'answered');
    state.put('ai:$remote', jsonEncode({'templateHash': remote, 'status': 'failed'}));
    expect(hasFormatWaitingForAnswer(state, now: now), isFalse, reason: 'a failure is an answer too');
    // Pending for ever (a layout a rule already covers) is only waited for ten minutes.
    state.put('ai:$remote', jsonEncode({'templateHash': remote, 'status': 'pending'}));
    expect(hasFormatWaitingForAnswer(state, now: now.add(const Duration(minutes: 7))), isTrue, reason: 'sent 9 minutes ago');
    expect(hasFormatWaitingForAnswer(state, now: now.add(const Duration(minutes: 9))), isFalse, reason: 'sent 11 minutes ago');
    // Another account's formats are not ours.
    expect(hasFormatWaitingForAnswer(SyncStateStore(db, namespace: 'user:2'), now: now), isFalse);
  });

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

  group('what this phone holds (the "phone details" line)', () {
    String h(String c) => c * 64;

    void answer(String hash, String status, {bool rule = true}) => state.put(
      'ai:$hash',
      jsonEncode({
        'templateHash': hash,
        'status': status,
        if (rule) 'rule': {'id': 'AI-$hash'},
      }),
    );

    void link(String remoteHash) => state.put(
      'template:origins:$remoteHash',
      jsonEncode({'senderBrand': 'HDFCBK', 'localHashes': [h('f')]}),
    );

    void decision(String source, String decision, {bool text = false}) {
      db.execute(
        'CREATE TABLE IF NOT EXISTS sms_source_decisions (namespace TEXT, source_key TEXT, decision TEXT)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS sms_captured_messages (namespace TEXT, id TEXT)',
      );
      db.execute('INSERT INTO sms_source_decisions VALUES (?,?,?)', ['user:1', source, decision]);
      if (text) db.execute('INSERT INTO sms_captured_messages VALUES (?,?)', ['user:1', source]);
    }

    test('the erase time and restore tries are reported', () {
      state.put('wipe:ai:at', '2026-11-19T10:00:00Z');
      state.put('restore:ai:count', '2');
      final d = AiStatusReader(state).diagnostics();
      expect(d.lastErasedAt, '2026-11-19T10:00:00Z');
      expect(d.restoresTried, 2);
      expect(d.withActiveAiRules(3).lastErasedAt, '2026-11-19T10:00:00Z');
    });

    test('the last sync problem is reported with when it happened', () {
      expect(AiStatusReader(state).diagnostics().lastPullProblem, isNull);
      state.put(
        'pull:error',
        jsonEncode({
          'at': '2026-11-20T16:01:00Z',
          'type': 'FormatException',
          'message': 'Unexpected end of input',
        }),
      );
      final d = AiStatusReader(state).diagnostics();
      expect(d.lastPullProblem, 'FormatException: Unexpected end of input');
      expect(d.lastPullProblemAt, '2026-11-20T16:01:00Z');
      expect(
        d.withActiveAiRules(2).lastPullProblem,
        'FormatException: Unexpected end of input',
      );
    });

    test('a problem record that cannot be read is ignored', () {
      state.put('pull:error', 'not json');
      final d = AiStatusReader(state).diagnostics();
      expect(d.lastPullProblem, isNull);
      expect(d.answersReady, 0);
    });

    test('an empty phone reports zeros', () {
      final d = AiStatusReader(state).diagnostics();
      expect(
        [d.answersReady, d.answersFailed, d.linksSaved, d.readyWithLink, d.unknownMessages, d.unknownWithText, d.readByAiRule],
        everyElement(0),
      );
    });

    test('counts answers, links, unknown messages and messages an AI rule read', () {
      answer(h('1'), 'ready');
      answer(h('2'), 'ready');
      answer(h('3'), 'ready', rule: false); // no rule in it: not usable
      answer(h('4'), 'failed', rule: false);
      answer(h('5'), 'rejected', rule: false);
      state.put('ai:resend:at', DateTime.utc(2026, 11, 20).toIso8601String()); // a timestamp, not an answer
      link(h('1')); // only one of the usable answers has its link back to a local format
      link(h('9')); // a link without an answer
      decision('s1', 'unknown', text: true);
      decision('s2', 'unknown');
      decision('s3', 'matched', text: true);
      state.put('trace:s3', jsonEncode({'ruleId': 'AI-${h('1')}:local:${h('f')}'}));
      state.put('trace:s4', jsonEncode({'ruleId': 'HDFC-SPEND-01'}));
      state.put('trace:s5', 'not json');

      final d = AiStatusReader(state).diagnostics();
      expect(d.answersReady, 2);
      expect(d.answersFailed, 2);
      expect(d.linksSaved, 2);
      expect(d.readyWithLink, 1);
      expect(d.unknownMessages, 2);
      expect(d.unknownWithText, 1);
      expect(d.readByAiRule, 1);
    });

    test('another account\'s state is not counted', () {
      answer(h('1'), 'ready');
      link(h('1'));
      final d = AiStatusReader(SyncStateStore(db, namespace: 'user:2')).diagnostics();
      expect(d.answersReady, 0);
      expect(d.linksSaved, 0);
    });

    test('a database without the message tables still answers', () {
      answer(h('1'), 'ready');
      final d = AiStatusReader(state).diagnostics();
      expect(d.answersReady, 1);
      expect(d.unknownMessages, 0);
      expect(d.unknownWithText, 0);
    });
  });
}
