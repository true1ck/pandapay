import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_sender_probe_session.dart';

Map<Object?, Object?> input(String id, String sender) => {
  'id': id,
  'sender': sender,
  'senderEvidence': 'handle',
  'body':
      'Union Bank of India A/c *1234 Debited Rs:25.00 on '
      '21-10-2026 01:26:04 by Mob Bk ref no SYNTHETIC, '
      'Fvg: TEST SHOP Avl Bal Rs:1000.00',
  'receivedAt': '2026-10-29T17:00:00Z',
};

void main() {
  test(
    'same-loop original and main-contract receivers are compared without assuming a live trigger',
    () {
      final session = IosSenderProbeSession();
      addTearDown(session.dispose);
      session.beginHistoryComparison('selected-run', useLatestReference: false);
      session.process([
        {
          ...input('original', 'TESTBK-S'),
          'origin': 'live',
          'handler': 'person_sender',
        },
      ]);
      session.process([
        {
          ...input('contract', ''),
          'runId': 'selected-run',
          'senderDiagnostics': {
            'action': 'main_app_contract',
            'text': null,
            'parameter_id': 'sender',
          },
        },
      ]);
      expect(session.comparison['status'], 'history_missing_sender');
      expect(
        session.latestLiveInput?['sender_parameter'],
        'senderPerson (String)',
      );
      expect(session.latestHistoryInput?['receiver'], 'main_app_contract');
      expect(session.latestHistoryInput?['sender_parameter'], 'sender');
      expect((session.comparison['live'] as Map)['capturedSender'], 'TESTBK-S');
      expect((session.comparison['history'] as Map)['capturedSender'], isNull);
    },
  );

  test(
    'compares sender values only in the selected run and detects ambiguous text',
    () {
      final session = IosSenderProbeSession();
      addTearDown(session.dispose);
      session.process([
        {...input('live', 'AD-UBINBK-S'), 'origin': 'live'},
      ]);
      session.beginHistoryComparison('selected-run');
      session.process([
        {...input('old', 'AD-UBINBK-S'), 'runId': 'old-run'},
      ]);
      expect(session.comparison['status'], 'waiting_for_history');
      final same = {...input('same', 'AD-UBINBK-S'), 'runId': 'selected-run'};
      session.process([same, same]);
      expect(session.comparison['status'], 'same_sender');
      session.process([
        {...input('second', 'OTHERBK-S'), 'runId': 'selected-run'},
      ]);
      expect(session.comparison['status'], 'ambiguous_text');
      expect(session.comparison['history'], isNull);
    },
  );

  test(
    'finds comparison text outside the recent-30 window and retains the live input',
    () {
      final session = IosSenderProbeSession();
      addTearDown(session.dispose);
      session.process([
        {...input('live', 'AD-UBINBK-S'), 'origin': 'live'},
      ]);
      session.beginHistoryComparison('selected-run');
      session.process([
        {...input('history', ''), 'runId': 'selected-run'},
        for (var i = 0; i < 40; i++)
          {...input('hi-$i', ''), 'body': 'Hi $i', 'runId': 'selected-run'},
      ]);
      expect(session.events.length, 30);
      expect(session.latestLiveInput?['capturedSender'], 'AD-UBINBK-S');
      expect(session.comparison['status'], 'history_missing_sender');
      session.beginHistoryComparison('next-run');
      session.completeHistoryComparison('selected-run');
      expect(session.comparison['status'], 'waiting_for_history');
      session.completeHistoryComparison('next-run');
      expect(session.comparison['status'], 'no_matching_text');
    },
  );

  test(
    'records unusual sender types without converting them into an address',
    () {
      final session = IosSenderProbeSession();
      addTearDown(session.dispose);
      session.beginHistoryComparison('selected-run');
      session.process([
        {
          ...input('structured', ''),
          'sender': {'name': 'TEST'},
          'runId': 'selected-run',
        },
      ]);
      expect(session.latestHistoryInput?['capturedSender'], isNull);
      expect(
        session.latestHistoryInput?['native_sender_runtime_type'],
        contains('Map'),
      );
      expect(session.comparison['status'], 'no_live_reference');
      expect(session.latestLiveInput, isNull);
    },
  );

  test('name-only sender remains visible raw but is not an actual address', () {
    final session = IosSenderProbeSession();
    addTearDown(session.dispose);
    final row = input('name', 'Synthetic contact')
      ..['senderEvidence'] = 'name'
      ..['senderDiagnostics'] = {
        'text': null,
        'person': {
          'present': true,
          'name': 'Synthetic contact',
          'name_type': 'display_name',
        },
      };
    session.process([row]);
    final event = session.events.single;
    expect((event['input'] as Map)['native_sender_value'], 'Synthetic contact');
    expect((event['direct'] as Map)['effectiveSender'], '');
    expect(event['senderPresent'], false);
    session.process([
      {
        ...row,
        'id': 'name-as-text',
        'senderEvidence': 'text',
        'senderDiagnostics': {
          'text': 'Synthetic contact',
          'person': {'present': true, 'name': 'Synthetic contact'},
        },
      },
    ]);
    expect(
      (session.events.first['input'] as Map)['sender_text'],
      'Synthetic contact',
    );
    expect((session.events.first['direct'] as Map)['effectiveSender'], '');
  });

  test('ignored hi remains inspectable and security content is excluded', () {
    final session = IosSenderProbeSession(limit: 2);
    addTearDown(session.dispose);
    session.process([
      input('hi', 'VM-TESTBK')..['body'] = 'Hi there',
      input('otp', 'VM-TESTBK')..['body'] = 'OTP 123456 do not share',
    ]);
    expect(session.events, hasLength(1));
    expect(
      ((session.events.single['input'] as Map)['message_body']),
      'Hi there',
    );
    expect((session.events.single['direct'] as Map)['outcome'], 'ignored');
    session.process([input('two', 'VM-TESTBK'), input('three', 'VM-TESTBK')]);
    expect(session.events, hasLength(2));
    expect(jsonEncode(session.events), isNot(contains('OTP')));
    expect(jsonEncode(session.events), isNot(contains('Hi there')));
  });
}
