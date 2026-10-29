import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_live_probe_session.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/main_ios_history_device_probe.dart';
import 'package:pandapay/widgets/ios_live_probe_panel.dart';
import '../data/ios_live_probe_session_test.dart' show liveRow;

void main() {
  testWidgets('ignored event exposes its input and processing reason', (
    tester,
  ) async {
    final live = IosLiveProbeSession(openInMemoryForTesting());
    addTearDown(live.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: IosLiveProbePanel(
              snapshot: {
                'counts': {'calls': 1},
                'events': [
                  {
                    'state': 'ignored',
                    'handler': 'person_sender',
                    'inputSender': '',
                    'inputBody': 'Hi there',
                    'senderEvidence': 'missing_person',
                    'effectiveSender': 'VM-BANK',
                    'senderInferred': true,
                    'triageKind': 'unrelated',
                    'triageReason': 'no_financial_signal',
                    'intakeDecision': 'ignored_unrelated',
                    'intakeReason': 'no_financial_signal',
                  },
                ],
              },
              session: live,
              onRefresh: () {},
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('Recent live events (up to 30)'));
    await tester.tap(find.text('Recent live events (up to 30)'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Processed → not retained'));
    await tester.tap(find.text('Processed → not retained'));
    await tester.pumpAndSettle();
    expect(find.text('Hi there'), findsOneWidget);
    expect(
      find.textContaining('Triage: unrelated · Reason: no_financial_signal'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Intake decision: ignored_unrelated'),
      findsOneWidget,
    );
    expect(find.text('Sender used: VM-BANK'), findsOneWidget);
  });
  testWidgets(
    'idle live panel is above history and does not claim trigger failure',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const channel = MethodChannel('pandapay/ios_history_device_probe');
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'readPending') {
          return {
            'records': [],
            'runs': [],
            'live': {'counts': {}, 'events': [], 'records': []},
          };
        }
        return null;
      });
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
      expect(find.text('Live incoming SMS'), findsOneWidget);
      expect(
        find.text('No incoming Shortcut handoff received in this app session'),
        findsOneWidget,
      );
      expect(find.textContaining('UNOBSERVED here'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Live incoming SMS')).dy,
        lessThan(
          tester
              .getTopLeft(
                find.text(
                  'Temporary local database · No account or active upload',
                ),
              )
              .dy,
        ),
      );
      expect(calls, ['readPending', 'acknowledge']);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'metadata-only rejection stays private and refresh is available',
    (tester) async {
      final live = IosLiveProbeSession(openInMemoryForTesting());
      addTearDown(live.dispose);
      var refreshed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IosLiveProbePanel(
                snapshot: {
                  'counts': {
                    'calls': 1,
                    'sensitive': 1,
                    'missing_date': 1,
                    'missing_sender': 1,
                  },
                  'lastInvokedAt': '2026-10-29T08:01:00Z',
                  'events': [
                    {
                      'id': 'event',
                      'state': 'sensitive',
                      'handler': 'person_sender',
                    },
                  ],
                },
                session: live,
                onRefresh: () => refreshed = true,
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('Sensitive rejected: 1'), findsOneWidget);
      expect(
        find.text('Latest: Rejected sensitive/security content'),
        findsOneWidget,
      );
      expect(
        find.text('Inspect retained live SMS and transactions'),
        findsNothing,
      );
      await tester.ensureVisible(find.text('Refresh / retry live handoffs'));
      await tester.tap(find.text('Refresh / retry live handoffs'));
      await tester.pump();
      expect(refreshed, isTrue);
      expect(find.byType(SelectableText), findsNothing);
    },
  );
  testWidgets(
    'acknowledgement failure retries without claiming completion or reprocessing',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const channel = MethodChannel('pandapay/ios_history_device_probe');
      var ackAttempts = 0;
      final row = liveRow('live1');
      Map<String, Object?> snapshot(bool done) => {
        'records': done ? [] : [row],
        'counts': {
          'calls': 1,
          'records_received': 1,
          'pending': done ? 0 : 1,
          'processed': done ? 1 : 0,
          'retained_new': done ? 1 : 0,
        },
        'events': [
          {
            'id': 'live1',
            'state': done ? 'retained_new' : 'pending',
            'handler': 'person_sender',
          },
        ],
      };
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'readPending') {
          return {
            'records': [],
            'runs': [],
            'live': snapshot(ackAttempts >= 2),
          };
        }
        if (call.method == 'completeLive') {
          ackAttempts++;
          expect((call.arguments as List).single['outcome'], 'retained_new');
          if (ackAttempts == 1) {
            throw PlatformException(code: 'synthetic_ack_failure');
          }
          return snapshot(true);
        }
        return null;
      });
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
      expect(
        find.text('Pending: 1 · Processed and acknowledged: 0'),
        findsOneWidget,
      );
      expect(find.textContaining('acknowledgement failed'), findsOneWidget);
      expect(
        find.textContaining('Live shared intake: 1 retained SMS'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Refresh / retry live handoffs'));
      await tester.tap(find.text('Refresh / retry live handoffs'));
      await tester.pumpAndSettle();
      expect(ackAttempts, 2);
      expect(
        find.text('Pending: 0 · Processed and acknowledged: 1'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Live shared intake: 1 retained SMS'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Cumulative session: 0 retained SMS'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'ready and app resume refresh the live receiver without history inflation',
    (tester) async {
      const channel = MethodChannel('pandapay/ios_history_device_probe');
      var reads = 0;
      var calls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'readPending') {
          reads++;
          return {
            'records': [],
            'runs': [],
            'live': {
              'counts': {
                'calls': calls,
                'records_received': calls,
                'sensitive': calls,
              },
              'records': [],
              'events': [],
            },
          };
        }
        return null;
      });
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
      expect(reads, 1);
      calls = 1;
      tester.binding.channelBuffers.push(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('ready')),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.textContaining('Sensitive rejected: 1'), findsOneWidget);
      calls = 2;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, 3);
      expect(find.textContaining('Sensitive rejected: 2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'exact action titles and missing-date hint distinguish both handlers',
    (tester) async {
      final live = IosLiveProbeSession(openInMemoryForTesting());
      addTearDown(live.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IosLiveProbePanel(
                snapshot: {
                  'counts': {'calls': 2, 'missing_date': 2},
                  'events': [
                    {
                      'handler': 'text_sender',
                      'state': 'missing_date_rejected',
                      'missingDate': true,
                    },
                    {
                      'handler': 'person_sender',
                      'state': 'missing_date_rejected',
                      'missingDate': true,
                    },
                  ],
                },
                session: live,
                onRefresh: () {},
              ),
            ),
          ),
        ),
      );
      expect(
        find.text('Action: Inspect Financial Message on iPhone'),
        findsOneWidget,
      );
      expect(
        find.text('Missing Date on: Inspect Financial Message on iPhone'),
        findsOneWidget,
      );
      expect(find.textContaining('Do not change Type to Date'), findsOneWidget);
      expect(
        find.textContaining('not the automation or trigger'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Recent live events (up to 30)'));
      await tester.tap(find.text('Recent live events (up to 30)'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Inspect Financial Message With Sender (person_sender)',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Inspect Financial Message on iPhone (text_sender)',
        ),
        findsOneWidget,
      );
    },
  );
}
