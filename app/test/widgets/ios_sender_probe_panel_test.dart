import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/ios_sender_probe_session.dart';
import 'package:pandapay/widgets/ios_sender_probe_panel.dart';

void main() {
  testWidgets('shows whether sender reached the explicit Person converter', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: IosSenderProbePanel(
              events: const [],
              liveInput: const {
                'receiver': 'existing_single_message',
                'capturedSender': 'TESTBK-S',
                'sender_conversion': 'intent_person_resolver_v1',
                'sender_parameter_state': 'person_handle',
                'sender_person': {'present': true, 'handle': 'TESTBK-S'},
              },
            ),
          ),
        ),
      ),
    );
    expect(find.text('Sender received: TESTBK-S'), findsOneWidget);
    expect(
      find.text('Sender conversion: intent_person_resolver_v1'),
      findsOneWidget,
    );
    expect(find.text('Sender input state: person_handle'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'one-day controls show the incoming sender without requiring JSON or Quick Look',
    (tester) async {
      final session = IosSenderProbeSession();
      addTearDown(session.dispose);
      const body = 'Rs 25 spent on credit card xx1234 at TEST SHOP via UPI.';
      final live = <Object?, Object?>{
        'id': 'live',
        'origin': 'live',
        'body': body,
        'sender': 'TESTBK-S',
        'senderEvidence': 'text',
        'receivedAt': '2026-11-01T07:00:00Z',
      };
      session.process([live]);
      session.beginHistoryComparison('run');
      session.process([
        {
          ...live,
          'id': 'history',
          'origin': 'history',
          'sender': '',
          'runId': 'run',
          'senderDiagnostics': {'action': 'text_only', 'text': ''},
        },
      ]);
      var today = 0, liveDay = 0;
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                IosSenderProbePanel(
                  events: session.events,
                  liveInput: session.latestLiveInput,
                  historyInput: session.latestHistoryInput,
                  comparison: session.comparison,
                  onCheckToday: () => today++,
                  onCheckLiveDay: () => liveDay++,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Check today’s history'));
      await tester.tap(find.text('Check latest received message'));
      expect(today, 1);
      expect(liveDay, 1);
      await tester.scrollUntilVisible(
        find.text('Latest range receiver'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Sender received: Not supplied'), findsOneWidget);
      expect(find.text('Text field: empty'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Receiver comparison: range sender is missing'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Single-message sender: TESTBK-S'), findsOneWidget);
      expect(find.text('Range sender: Not supplied'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('older comparisons stay collapsed behind the latest input', (
    tester,
  ) async {
    final session = IosSenderProbeSession();
    addTearDown(session.dispose);
    session.process([
      {
        'id': 'older',
        'sender': '',
        'body': 'Hi',
        'receivedAt': '2026-10-28T17:00:00Z',
      },
      {
        'id': 'latest',
        'sender': '',
        'body': 'Hello',
        'receivedAt': '2026-10-29T17:00:00Z',
      },
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [IosSenderProbePanel(events: session.events)],
          ),
        ),
      ),
    );
    expect(find.text('2026-10-29T17:00:00Z'), findsOneWidget);
    expect(find.text('2026-10-28T17:00:00Z'), findsNothing);
    await tester.tap(find.text('Earlier comparisons (1)'));
    await tester.pumpAndSettle();
    expect(find.text('2026-10-28T17:00:00Z'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
  });
  testWidgets('raw input and both outputs are visible for an ignored message', (
    tester,
  ) async {
    final session = IosSenderProbeSession();
    addTearDown(session.dispose);
    session.process([
      {
        'id': 'hi',
        'sender': '',
        'senderEvidence': 'missing_person',
        'body': 'Hi there',
        'receivedAt': '2026-10-29T17:00:00Z',
        'senderDiagnostics': {
          'text': null,
          'person': {'present': false},
        },
      },
    ]);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [IosSenderProbePanel(events: session.events)],
          ),
        ),
      ),
    );
    await tester.tap(find.text('history receiver · sender address missing'));
    await tester.pumpAndSettle();
    for (final title in [
      'Input received from Shortcut (raw)',
      'Without sender inference',
      'Body-only inference comparison',
    ]) {
      await tester.scrollUntilVisible(
        find.text(title),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(title), findsOneWidget);
    }
    expect(find.byType(SelectableText), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}
