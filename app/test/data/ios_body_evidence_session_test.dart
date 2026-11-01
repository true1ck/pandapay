import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_body_evidence_session.dart';
import 'ios_main_sender_card_intake_test.dart' as fixture;

Map<Object?, Object?> input(String id, String body) => {
  'id': id,
  'runId': 'test',
  'body': body,
  'sender': '',
  'senderEvidence': 'missing_text',
  'receivedAt': '2026-11-01T08:00:00Z',
};

void main() {
  test('extracts an expense with no sender and no invented bank header', () {
    final session = IosBodyEvidenceSession();
    session.process([input('completion', fixture.posted)]);
    final record = session.records.single;
    final facts = record['transaction_facts'] as Map;
    expect(record['kind'], 'transaction_candidate');
    expect(record['captured_sender'], isNull);
    expect(record['sender_status'], 'unavailable');
    expect(record['issuer_named_in_body'], 'SBI');
    expect(record['payment_app_named_in_body'], isNull);
    expect(record['posting_state'], 'not_posted');
    expect(facts['amount_inr'], 42.5);
    expect(facts['merchant_name'], 'TESTTECHNOLOGIES');
    expect(facts['card_last4'], '4242');
    expect(facts['instrument'], 'credit_card');
    expect(facts['payment_method'], 'upi');
    expect(facts.containsKey('status'), false);
    expect(facts.containsKey('source_key'), false);
    expect(jsonEncode(session.snapshot), isNot(contains('VM-')));
  });

  test('request stays separate from a completion and counts no spending', () {
    final session = IosBodyEvidenceSession();
    session.process([
      input('request', fixture.request),
      input('paid', fixture.posted),
    ]);
    expect(session.snapshot['transaction_candidates'], 1);
    expect(session.snapshot['payment_requests'], 1);
    final request = session.records.firstWhere(
      (r) => r['kind'] == 'payment_request',
    );
    expect((request['request_facts'] as Map)['completion_confirmed'], false);
    expect((request['request_facts'] as Map)['payment_app'], 'PhonePe');
    expect((request['request_facts'] as Map)['spending_added'], 0);
    expect(request['transaction_facts'], isNull);
  });

  test(
    'two receivers share one preview, while distinct receive instants remain separate',
    () {
      final session = IosBodyEvidenceSession();
      final row = input('first', fixture.posted);
      session.process([
        row,
        row,
        {...row, 'id': 'second', 'receivedAt': '2026-11-01T13:30:00+05:30'},
      ]);
      expect(session.records, hasLength(1));
      expect(session.records.single['receiver_inputs'], hasLength(2));
      session.process([
        {...row, 'id': 'different-date', 'receivedAt': '2026-11-01T08:01:00Z'},
      ]);
      expect(session.records, hasLength(2));
    },
  );

  test(
    'preserves an actual supplied sender and uses the shared saved-card match',
    () {
      final session = IosBodyEvidenceSession(cards: [fixture.card]);
      session.process([
        {
          ...input('card', fixture.posted),
          'sender': 'SBICRD-S',
          'senderEvidence': 'text',
        },
      ]);
      final record = session.records.single;
      expect(record['captured_sender'], 'SBICRD-S');
      expect(
        (record['transaction_facts'] as Map)['user_card_id'],
        fixture.card.id,
      );
      expect(
        (record['transaction_facts'] as Map)['card_name'],
        fixture.card.nickname,
      );
    },
  );

  test(
    'replay uses original fields, excluding guesses, security content and missing dates',
    () {
      final exported = jsonEncode({
        'format': 'pandapay.sender_probe_diagnostics',
        'schema_version': 1,
        'capture_journal': {
          'records': [
            {
              'input': {
                'message_body': fixture.posted,
                'native_sender_value': '',
                'original_receive_date': '2026-11-01T08:00:00Z',
              },
              'inferred': {'effectiveSender': 'FAKEBANK'},
            },
            {
              'input': {
                'message_body': 'OTP 123456. Do not share.',
                'native_sender_value': '',
                'original_receive_date': '2026-11-01T08:00:00Z',
              },
            },
            {
              'input': {
                'message_body': fixture.posted,
                'native_sender_value': '',
              },
            },
          ],
        },
      });
      final session = IosBodyEvidenceSession();
      session.process(IosBodyEvidenceSession.inputsFromExport(exported));
      expect(session.records, hasLength(1));
      expect(session.records.single['captured_sender'], isNull);
      expect(jsonEncode(session.snapshot), isNot(contains('FAKEBANK')));
      expect(jsonEncode(session.snapshot), isNot(contains('123456')));
      expect(
        () => IosBodyEvidenceSession.inputsFromExport('{}'),
        throwsFormatException,
      );
    },
  );

  test(
    'conflicting senders remain explicit and capacity omissions are counted',
    () {
      final session = IosBodyEvidenceSession(limit: 1);
      session.process([
        {
          ...input('one', fixture.posted),
          'sender': 'TEST-A',
          'senderEvidence': 'text',
        },
        {
          ...input('two', fixture.posted),
          'sender': 'TEST-B',
          'senderEvidence': 'text',
        },
        input('over-capacity', fixture.request),
      ]);
      expect(session.records.single['captured_sender'], isNull);
      expect(session.records.single['sender_status'], 'conflicting_inputs');
      expect(session.records.single['receiver_inputs'], hasLength(2));
      expect(session.snapshot['omitted_inputs'], 1);
    },
  );

  final replayFile = Platform.environment['PANDAPAY_PROBE_REPLAY_FILE'];
  test(
    'replays the provided export with no body or sender logging',
    () {
      final text = File(replayFile!).readAsStringSync();
      final previous = jsonDecode(text) as Map;
      final session = IosBodyEvidenceSession();
      session.process(IosBodyEvidenceSession.inputsFromExport(text));
      final expected =
          ((previous['sessions'] as Map)['body_inference_comparison_only']
                  as Map)['transactions']
              as List;
      expect(session.snapshot['transaction_candidates'], expected.length);
      expect(session.records.every((r) => r['captured_sender'] == null), true);
      const businessFields = [
        'amount_inr',
        'occurred_at',
        'merchant_name',
        'card_last4',
        'account_last4',
        'instrument',
        'entry_kind',
        'payment_method',
        'sms_received_at',
      ];
      // Foundation can serialize whole double amounts as JSON integers.
      Object? canonical(Object? value) =>
          value is num ? value.toDouble() : value;
      String businessFacts(Map transaction) => jsonEncode([
        for (final field in businessFields) canonical(transaction[field]),
      ]);
      final oldFacts = expected.cast<Map>().map(businessFacts).toSet();
      final newFacts = session.records
          .map((r) => r['transaction_facts'])
          .whereType<Map>()
          .map(businessFacts)
          .toSet();
      final changedFields = [
        for (final field in businessFields)
          if (jsonEncode(
                expected.cast<Map>().map((t) => canonical(t[field])).toList()
                  ..sort((a, b) => '$a'.compareTo('$b')),
              ) !=
              jsonEncode(
                session.records
                    .map((r) => r['transaction_facts'])
                    .whereType<Map>()
                    .map((t) => canonical(t[field]))
                    .toList()
                  ..sort((a, b) => '$a'.compareTo('$b')),
              ))
            field,
      ];
      // Boolean assertion keeps private facts out of assertion-failure output.
      expect(
        oldFacts.length == newFacts.length && oldFacts.containsAll(newFacts),
        true,
        reason:
            'Business facts must match the prior parser result. Different fields: $changedFields',
      );
      final summary = {...session.snapshot}..remove('records');
      // Aggregates only. Do not print customer SMS text, merchant/card data or IDs.
      // ignore: avoid_print
      print('REPLAY RESULT: ${jsonEncode(summary)}');
    },
    skip: replayFile == null
        ? 'Set PANDAPAY_PROBE_REPLAY_FILE for a private local replay.'
        : false,
  );
}
