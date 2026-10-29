import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/sms_security_policy.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/sms_gate_filter.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';
import 'package:pandapay/features/sms_import/ios_shortcut_sms.dart';
import 'package:pandapay/data/ios_live_probe_session.dart';
import 'package:pandapay/data/local/app_database.dart';

void main() {
  final corpus =
      (jsonDecode(
                File(
                  'test/fixtures/sms_security_advisory_synthetic.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map>();
  for (final row in corpus) {
    test('security policy parity across downstream gates: ${row['id']}', () {
      final body = row['body'] as String;
      final sensitive = row['sensitive'] as bool;
      expect(SmsSecurityPolicy.sensitive(body), sensitive);
      expect(LocalSmsParser.sensitive(body), sensitive);
      expect(
        SmsGateFilter.evaluate('VM-FABLEBK', body).dropReason ==
            SmsGateDropReason.otpOrSecurity,
        sensitive,
      );
      expect(
        classifySmsTriage('VM-FABLEBK', body).kind == SmsTriageKind.sensitive,
        sensitive,
      );
      if (!sensitive &&
          row['id'] != 'safe-balance' &&
          row['id'] != 'safe-statement-instruction') {
        expect(looksLikeTransactionSms(body), isTrue);
      }
      final batch = IosShortcutSmsBatch.fromRows([
        {
          'id': 'case',
          'body': body,
          'sender': 'VM-FABLEBK',
          'receivedAt': '2026-10-29T08:11:23Z',
        },
      ]);
      expect(batch.sensitive, sensitive ? 1 : 0);
      expect(batch.messages.length, sensitive ? 0 : 1);
      if (!sensitive) expect(batch.messages.single.body, body);
    });
  }
  test(
    'safe credit is retained and parsed with original receive time separate from body date',
    () {
      final live = IosLiveProbeSession(openInMemoryForTesting());
      addTearDown(live.dispose);
      final body = corpus.first['body'] as String;
      final row = <Object?, Object?>{
        'id': 'credit',
        'origin': 'live',
        'sender': '',
        'body': body,
        'receivedAt': '2026-10-29T08:11:23Z',
        'capturedAt': '2026-10-29T08:12:00Z',
      };
      expect(live.process([row]).single['outcome'], 'retained_new');
      expect(live.intake.transactionsForRun('live'), hasLength(1));
      final source = live.intake.retainedInputsForRun('live').single;
      expect(source.date, DateTime.utc(2026, 10, 29, 8, 11, 23));
      expect(source.body, body);
      expect(source.capturedAt, DateTime.utc(2026, 10, 29, 8, 12));
    },
  );
  test('safe debit and balance reach unchanged shared parsing', () {
    final live = IosLiveProbeSession(openInMemoryForTesting());
    addTearDown(live.dispose);
    final cases = corpus
        .where((r) => r['id'] == 'safe-debit' || r['id'] == 'safe-balance')
        .toList();
    final outcomes = live.process([
      for (final item in cases)
        {
          'id': item['id'],
          'origin': 'live',
          'body': item['body'],
          'sender': 'VM-ICICIB',
          'receivedAt': '2026-10-29T08:11:23Z',
        },
    ]);
    expect(outcomes.map((r) => r['outcome']), everyElement('retained_new'));
    expect(live.intake.transactions, 1);
    expect(
      live.intake.observations.map((r) => r['event_type']),
      contains('balance'),
    );
    expect(
      live.intake.retainedInputs.map((r) => r.body),
      containsAll(cases.map((r) => r['body'])),
    );
  });
  test(
    'safe advisory without original receive date is still rejected; real secrets remain excluded',
    () {
      final live = IosLiveProbeSession(openInMemoryForTesting());
      addTearDown(live.dispose);
      Map<Object?, Object?> row(String id, String body) => {
        'id': id,
        'origin': 'live',
        'body': body,
        'sender': '',
        'capturedAt': '2026-10-29T08:12:00Z',
      };
      expect(
        live.process([
          row('safe', corpus.first['body'] as String),
        ]).single['outcome'],
        'rejected_missing_date',
      );
      final unsafe =
          corpus.firstWhere((r) => r['id'] == 'security-1')['body'] as String;
      expect(
        live.process([row('unsafe', unsafe)]).single['outcome'],
        'rejected_sensitive',
      );
      expect(live.intake.counts.captured, 0);
      expect(live.intake.transactions, 0);
    },
  );
}
