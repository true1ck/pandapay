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
    'resolved Person handle reaches strict intake and preserves conversion evidence',
    () {
      final session = IosSenderProbeSession();
      addTearDown(session.dispose);
      session.process([
        {
          ...input('resolved', 'AD-UBINBK-S'),
          'origin': 'live',
          'handler': 'person_sender',
          'senderDiagnostics': {
            'action': 'existing_single_message',
            'parameter_id': 'senderPerson',
            'conversion': 'intent_person_resolver_v1',
            'parameter_state': 'person_handle',
            'text': null,
            'person': {
              'present': true,
              'handle': 'AD-UBINBK-S',
              'handle_type': 'application_defined',
              'name': 'Synthetic contact display',
              'alias_count': 2,
            },
          },
        },
      ]);
      final raw = session.events.single['input'] as Map;
      final actual = session.events.single['direct'] as Map;
      expect(raw['capturedSender'], 'AD-UBINBK-S');
      expect(raw['sender_text'], isNull);
      expect(raw['sender_conversion'], 'intent_person_resolver_v1');
      expect(raw['sender_parameter_state'], 'person_handle');
      expect(
        (raw['sender_person'] as Map)['handle_type'],
        'application_defined',
      );
      expect(actual['effectiveSender'], 'AD-UBINBK-S');
      expect(actual['senderInferred'], false);
      expect(actual['transactionsAdded'], 1);
      expect(
        session.bodyEvidence.records.single['captured_sender'],
        'AD-UBINBK-S',
      );
      final exportedInput =
          ((session.exportJournal['records'] as List).single as Map)['input']
              as Map;
      expect(exportedInput['sender_conversion'], 'intent_person_resolver_v1');
    },
  );

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
    'pins a live reference and reports missing historical sender without filling it',
    () {
      final session = IosSenderProbeSession();
      addTearDown(session.dispose);
      session.process([
        {...input('live', 'AD-UBINBK-S'), 'origin': 'live'},
      ]);
      session.beginHistoryComparison('selected-run');
      expect(session.comparison['status'], 'waiting_for_history');
      session.process([
        {...input('history', ''), 'runId': 'selected-run'},
      ]);
      expect(session.comparison['status'], 'history_missing_sender');
      expect(
        (session.comparison['live'] as Map)['capturedSender'],
        'AD-UBINBK-S',
      );
      expect((session.comparison['history'] as Map)['capturedSender'], isNull);
      expect(
        (session.events.first['direct'] as Map)['outcome'],
        'needs_review',
      );
      expect((session.events.first['inferred'] as Map)['senderInferred'], true);
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

  test('raw missing sender stays separate from the body-only guess', () {
    final session = IosSenderProbeSession();
    addTearDown(session.dispose);
    final row = input('missing', '')
      ..['senderEvidence'] = 'missing_person'
      ..['senderDiagnostics'] = {
        'action': 'person_and_text',
        'text': null,
        'shortcuts_type': 'Contact',
        'person': {'present': false, 'alias_count': 0},
      };
    session.process([row]);
    final event = session.events.single;
    final raw = event['input'] as Map;
    final direct = event['direct'] as Map;
    final inferred = event['inferred'] as Map;
    expect(raw['sender_text'], isNull);
    expect(raw['receiver'], 'person_and_text');
    expect(raw['sender_shortcuts_type'], 'Contact');
    expect((raw['sender_person'] as Map)['present'], false);
    expect(raw['native_sender_value'], '');
    expect(direct['effectiveSender'], '');
    expect(direct['senderInferred'], false);
    expect(direct['outcome'], 'needs_review');
    expect(direct['intakeReason'], 'sender_unavailable');
    expect(inferred['effectiveSender'], 'VM-UBINBK');
    expect(inferred['senderInferred'], true);
    expect(inferred['transactionsAdded'], 1);
    expect(session.direct.intake.transactions, 0);
    expect(session.direct.intake.reviewCount, 1);
    expect(session.inferred.intake.transactions, 1);
    expect(() => jsonEncode(event), returnsNormally);
    session.process([row]);
    expect(session.events, hasLength(1));
    expect(session.inferred.intake.transactions, 1);
    session.process([
      {...row, 'id': 'missing-again'},
    ]);
    expect((session.events.first['direct'] as Map)['outcome'], 'needs_review');
    expect(session.direct.intake.reviewCount, 1);
    expect(session.inferred.intake.transactions, 1);
  });

  test(
    'text-only receiver records actual text independently of the Person action',
    () {
      final session = IosSenderProbeSession();
      addTearDown(session.dispose);
      final row = input('text-only', 'AD-UBINBK-S')
        ..['senderEvidence'] = 'text'
        ..['senderDiagnostics'] = {
          'action': 'text_only',
          'text': 'AD-UBINBK-S',
          'person': {'present': false, 'input_available': false},
          'shortcuts_type': null,
        };
      session.process([row]);
      final event = session.events.single;
      expect((event['input'] as Map)['receiver'], 'text_only');
      expect((event['input'] as Map)['sender_text'], 'AD-UBINBK-S');
      expect((event['direct'] as Map)['effectiveSender'], 'AD-UBINBK-S');
      expect((event['direct'] as Map)['senderInferred'], false);
      expect((event['inferred'] as Map)['effectiveSender'], 'VM-UBINBK');
      expect((event['inferred'] as Map)['senderInferred'], true);
      expect(session.direct.intake.transactions, 1);
    },
  );

  test(
    'actual personal number and inference can produce different shared decisions',
    () {
      final session = IosSenderProbeSession();
      addTearDown(session.dispose);
      session.process([input('personal', '+919000000001')]);
      final event = session.events.single;
      expect(event['senderPresent'], true);
      expect((event['direct'] as Map)['triageReason'], 'p2p_mobile_number');
      expect((event['direct'] as Map)['outcome'], 'ignored');
      expect((event['inferred'] as Map)['effectiveSender'], 'VM-UBINBK');
      expect((event['inferred'] as Map)['transactionsAdded'], 1);
      expect(session.direct.intake.transactions, 0);
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
