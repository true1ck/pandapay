import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/main_ios_history_device_probe.dart';
import '../data/ios_main_sender_card_intake_test.dart' as fixture;

void main() {
  for (final startup in ['ready', 'not_staged', 'locked']) {
    testWidgets(
      'diagnostic replay recovers from $startup without running a shortcut',
      (tester) async {
        const channel = MethodChannel('pandapay/ios_history_device_probe');
        final calls = <String>[];
        Map? acknowledged;
        var retrying = false;
        final report = jsonEncode({
          'format': 'pandapay.sender_probe_diagnostics',
          'schema_version': 1,
          'native_app': {'build': '7'},
          'capture_journal': {
            'records': [
              for (final receiver in [
                'existing_single_message',
                'main_app_contract',
              ])
                {
                  'input': {
                    'receiver': receiver,
                    'message_body': fixture.posted,
                    'native_sender_value': '',
                    'original_receive_date': '2026-11-01T08:00:00Z',
                  },
                },
            ],
          },
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call.method);
            if (call.method == 'readDiagnosticReplay') {
              if (!retrying && startup == 'not_staged') return null;
              if (!retrying && startup == 'locked') {
                throw PlatformException(code: 'replay_failed');
              }
              return {'json': report, 'fingerprint': 'synthetic-fingerprint'};
            }
            if (call.method == 'completeDiagnosticReplay') {
              acknowledged = call.arguments as Map;
            }
            if (call.method == 'readPending') {
              return {
                'records': [],
                'runs': [],
                'live': {'records': [], 'events': [], 'counts': {}},
              };
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          const MaterialApp(home: DeviceHistoryProbeScreen()),
        );
        await tester.pumpAndSettle();
        if (startup != 'ready') {
          expect(acknowledged, isNull);
          retrying = true;
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();
        }
        expect(find.text('PandaPay Sender Probe · 12'), findsOneWidget);
        expect(
          find.text(
            'Replayed your exported session. No new Shortcut run was needed.',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            '1 messages · 0 transaction candidates · 0 payment requests',
          ),
          findsOneWidget,
        );
        expect(acknowledged?['fingerprint'], 'synthetic-fingerprint');
        expect(acknowledged?['counts'], {
          'input_records': 2,
          'unique_message_inputs': 1,
          'transaction_candidates': 0,
          'payment_requests': 0,
          'omitted_inputs': 0,
        });
        expect(calls, [
          if (startup != 'ready') ...['readDiagnosticReplay', 'readPending'],
          'readDiagnosticReplay',
          'completeDiagnosticReplay',
          'readPending',
        ]);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(
          calls.where((method) => method == 'completeDiagnosticReplay'),
          hasLength(1),
        );
        expect(calls.contains('runShortcut'), false);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
