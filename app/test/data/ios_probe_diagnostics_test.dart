import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_device_probe_session.dart';
import 'package:pandapay/data/ios_sender_probe_session.dart';
import 'package:pandapay/data/ios_probe_diagnostics.dart';
import 'package:pandapay/data/ios_live_probe_session.dart';
import 'package:pandapay/data/local/app_database.dart';

Map<Object?, Object?> row(int i) => {
  'id': 'input-$i',
  'runId': 'test-run',
  'sender': 'TESTBK-S',
  'senderEvidence': 'text',
  'body': 'Hello fixture $i',
  'receivedAt': '2026-11-01T08:00:00Z',
};

void main() {
  test('processing failures and retries remain in the export journal', () {
    final intake = IosDeviceProbeSession(
      openInMemoryForTesting(),
      allowSenderInference: false,
    );
    var fail = true;
    final direct = IosLiveProbeSession.withIntake(
      intake,
      capture: (rows) {
        if (fail) throw StateError('Synthetic failure');
        intake.accept(rows);
      },
    );
    final sender = IosSenderProbeSession(directSession: direct);
    addTearDown(sender.dispose);
    sender.process([row(0)]);
    final failed = (sender.exportJournal['records'] as List).single as Map;
    expect((failed['direct'] as Map)['outcome'], 'processing_error');
    expect((failed['direct'] as Map)['error_type'], 'StateError');
    expect(failed['processing_complete'], false);
    fail = false;
    sender.process([row(0)]);
    expect(sender.exportJournal['records'], hasLength(2));
    expect(sender.events, hasLength(1));
    expect(sender.events.single['processing_complete'], true);
  });

  test(
    'export contains all session comparisons, not only the last 30 shown',
    () {
      final sender = IosSenderProbeSession();
      final range = IosDeviceProbeSession(
        openInMemoryForTesting(),
        allowSenderInference: false,
      );
      final single = IosDeviceProbeSession(
        openInMemoryForTesting(),
        allowSenderInference: false,
      );
      addTearDown(() {
        sender.dispose();
        range.dispose();
        single.dispose();
      });
      final rows = [for (var i = 0; i < 35; i++) row(i)];
      sender.process(rows);
      sender.process(rows);
      range.accept(rows);
      final report = buildIosProbeDiagnostics(
        shortcut: 'PANDAPAY SENDER CHECK',
        startedAt: DateTime.utc(2026, 11, 1),
        exportedAt: DateTime.utc(2026, 11, 1, 8),
        selection: {
          'request': {'run_id': 'test-run'},
        },
        nativeSnapshot: {},
        sender: sender,
        rangeSession: range,
        singleSession: single,
        processing: false,
        errors: {},
      );
      expect(sender.events, hasLength(30));
      final journal = report['capture_journal'] as Map;
      expect(journal['records'], hasLength(35));
      expect(journal['complete'], true);
      expect(
        (journal['records'] as List).first['input']['message_body'],
        'Hello fixture 0',
      );
      expect(
        (journal['records'] as List).first['direct']['effectiveSender'],
        'TESTBK-S',
      );
      expect(
        (journal['records'] as List).first['inferred']['inference_basis'],
        'body_text_only',
      );
      expect(report['selected_shortcut'], 'PANDAPAY SENDER CHECK');
      expect(jsonDecode(jsonEncode(report))['schema_version'], 1);
    },
  );

  test(
    'excluded security content never leaks through native attempt snapshots',
    () {
      final sender = IosSenderProbeSession();
      final range = IosDeviceProbeSession(openInMemoryForTesting());
      final single = IosDeviceProbeSession(openInMemoryForTesting());
      addTearDown(() {
        sender.dispose();
        range.dispose();
        single.dispose();
      });
      sender.process([
        {...row(1), 'body': 'OTP 123456. Do not share.'},
      ]);
      final report = buildIosProbeDiagnostics(
        shortcut: 'PANDAPAY SENDER CHECK',
        startedAt: DateTime.utc(2026),
        exportedAt: DateTime.utc(2026),
        selection: {},
        nativeSnapshot: {
          'pending_records': [
            row(99),
            {...row(100), 'body': 'OTP 123456. Do not share.'},
          ],
          'live': {
            'counts': {'sensitive': 1},
            'events': [
              {
                'id': 'security',
                'state': 'sensitive',
                'inputBody': 'OTP 123456. Do not share.',
                'inputSender': 'PRIVATE-SENDER',
                'parserOutput': 'OTP 123456',
              },
              {
                'id': 'safe',
                'state': 'ignored',
                'inputBody': 'Hello fixture',
                'inputSender': 'TESTBK-S',
              },
            ],
          },
        },
        sender: sender,
        rangeSession: range,
        singleSession: single,
        processing: true,
        errors: {'range': 'Synthetic launch failure'},
      );
      final encoded = jsonEncode(report);
      expect(encoded, isNot(contains('123456')));
      expect(encoded, isNot(contains('PRIVATE-SENDER')));
      expect(encoded, contains('Hello fixture'));
      expect(encoded, contains('TESTBK-S'));
      expect(encoded, contains('Hello fixture 99'));
      expect(report['processing_in_progress'], true);
      expect((report['capture_journal'] as Map)['records'], isEmpty);
    },
  );

  test(
    'capacity limits are explicit rather than silently truncating an export',
    () {
      final sender = IosSenderProbeSession(exportLimit: 2);
      addTearDown(sender.dispose);
      sender.process([for (var i = 0; i < 4; i++) row(i)]);
      expect(sender.exportJournal['record_count'], 2);
      expect(sender.exportJournal['omitted_records'], 2);
      expect(sender.exportJournal['complete'], false);
      final tiny = IosSenderProbeSession(exportByteLimit: 1);
      addTearDown(tiny.dispose);
      tiny.process([row(0)]);
      expect(tiny.exportJournal['record_count'], 0);
      expect(tiny.exportJournal['omitted_records'], 1);
    },
  );
}
