import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/ios_sms_import_screen.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_controller.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_providers.dart';
import 'package:pandapay/features/sms_import/ios_sms_sharing_setup.dart';
import 'package:pandapay/features/sms_import/sms_sync_status_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ios_sms_intake_controller_test.dart' show MemoryBridge;

class _SharingBridge extends MemoryBridge {
  bool settingsOpen = true;
  @override
  Future<Object?> call(String method, [Map<String, Object?>? arguments]) async {
    if (method == 'openSettings') {
      calls.add(method);
      return settingsOpen;
    }
    return super.call(method, arguments);
  }
}

Future<void> _pumpImport(
  WidgetTester tester,
  MemoryBridge service, {
  bool fromHub = false,
}) async {
  final controller = IosSmsIntakeController(
    service: service,
    namespace: () => 'user:a',
    requestUpload: () {},
    capture: (_, _, _) async => [],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        iosSmsIntakeServiceProvider.overrideWithValue(service),
        iosSmsIntakeControllerProvider.overrideWith((_) => controller),
      ],
      child: MaterialApp(
        home: fromHub
            ? Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const IosSmsImportScreen(),
                      ),
                    ),
                    child: const Text('Import & Sync'),
                  ),
                ),
              )
            : const IosSmsImportScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(
  WidgetTester tester,
  Finder finder, {
  double delta = 400,
}) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: find.byType(Scrollable).first,
  );
  // Expanded cards can change the scroll extent during the scroll operation.
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final status in ['active', 'paused']) {
    testWidgets(
      'history periods remain usable during a $status incomplete catch-up',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          iosSmsSharingAcknowledgementKey: true,
        });
        final service = MemoryBridge();
        service.snapshot['jobs'] = [
          {'id': 'catchup', 'kind': 'catchup', 'state': status},
        ];
        service.snapshot['windows'] = [
          {
            'id': 'w',
            'job_id': 'catchup',
            'state': 'partial',
            'missing_sender': 37,
            'enumerated': 79,
            'processed': 30,
            'needs_review': 4,
            'start': '2026-10-01T00:00:00Z',
          },
        ];
        await _pumpImport(tester, service);
        expect(
          find.text('37 messages arrived without a sender.'),
          findsOneWidget,
        );
        expect(find.text('Split busy dates'), findsNothing);
        expect(
          find.text('79 received · 30 processed · 4 need review'),
          findsOneWidget,
        );
        await _scrollTo(tester, find.text('3 months'));
        await tester.tap(find.text('3 months'));
        await tester.pumpAndSettle();
        expect(find.text('Custom dates'), findsOneWidget);
        expect(service.createdJobs, isEmpty);
        await _scrollTo(tester, find.text('Start new import'));
        await tester.tap(find.text('Start new import'));
        await tester.pumpAndSettle();
        expect(service.createdJobs.single['replacingJobID'], 'catchup');
        expect(service.createdJobs.single['kind'], 'history');
        expect(service.calls.where((c) => c == 'runShortcut'), hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'back returns to Imports and reopening keeps the history choices',
    (tester) async {
      final service = MemoryBridge();
      service.snapshot['jobs'] = [
        {'id': 'catchup', 'kind': 'catchup', 'state': 'active'},
      ];
      service.snapshot['windows'] = [
        {
          'id': 'w',
          'job_id': 'catchup',
          'state': 'partial',
          'start': '2026-10-01T00:00:00Z',
        },
      ];
      await _pumpImport(tester, service, fromHub: true);
      await tester.tap(find.text('Import & Sync'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Custom dates'));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Import & Sync'), findsOneWidget);
      await tester.tap(find.text('Import & Sync'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Custom dates'));
      expect(find.text('Start new import'), findsOneWidget);
      expect(service.calls, isNot(contains('control')));
      expect(service.calls, isNot(contains('runShortcut')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'action trace is available under import details without message contents',
    (tester) async {
      final service = MemoryBridge();
      service.snapshot['jobs'] = [
        {'id': 'diagnostic-job', 'kind': 'history', 'state': 'active'},
      ];
      service.snapshot['windows'] = [
        {
          'job_id': 'diagnostic-job',
          'id': 'diagnostic-window',
          'start': '2026-10-01T00:00:00Z',
          'end': '2026-10-02T00:00:00Z',
          'state': 'waiting',
          'last_stage': 'window_end',
          'handoff_stage': 'resume_shortcuts',
        },
      ];
      await _pumpImport(tester, service);
      expect(find.textContaining('End reached PandaPay'), findsNothing);
      await _scrollTo(tester, find.text('Import options'));
      await tester.tap(find.text('Import options'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Import details'));
      await tester.tap(find.text('Import details'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.textContaining('End reached PandaPay'));
      expect(find.textContaining('End reached PandaPay'), findsOneWidget);
      expect(
        find.textContaining('Returning to the existing Shortcuts run'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shortcut keyboard dismisses on Done, outside tap and scroll', (
    tester,
  ) async {
    await _pumpImport(tester, MemoryBridge());
    await _scrollTo(tester, find.text('Import options'));
    await tester.tap(find.text('Import options'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('ios-sms-shortcut-name'));
    await _scrollTo(tester, field);
    await tester.showKeyboard(field);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.showKeyboard(field);
    await tester.pump();
    await tester.tap(find.byTooltip('Done editing'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.showKeyboard(field);
    await tester.pump();
    await tester.tapAt(tester.getBottomLeft(field) + const Offset(5, 4));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.showKeyboard(field);
    await tester.pump();
    await tester.tap(find.text('Refresh messages'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.showKeyboard(field);
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('ios-sms-import-scroll')),
      const Offset(0, 200),
    );
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets(
    'compact screen and permission sheet fit narrow large-text layouts',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pumpImport(tester, MemoryBridge());
      await _scrollTo(tester, find.text('History permissions'));
      await tester.tap(find.text('History permissions'));
      await tester.pumpAndSettle();
      expect(find.text('Allow history sharing'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Done'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history waits for explicit sharing confirmation and saves it', (
    tester,
  ) async {
    final service = _SharingBridge();
    await _pumpImport(tester, service);
    await _scrollTo(tester, find.text('Start import'));
    FilledButton saveButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start import'),
    );
    expect(saveButton().onPressed, isNull);
    expect(service.calls, isNot(contains('createJob')));
    await _scrollTo(tester, find.text('History permissions'), delta: -400);
    await tester.tap(find.text('History permissions'));
    await tester.pumpAndSettle();
    final confirmation = find.byKey(
      const ValueKey('ios-sms-sharing-confirmation'),
    );
    await tester.ensureVisible(confirmation);
    await tester.tap(
      find.descendant(of: confirmation, matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getBool(
        iosSmsSharingAcknowledgementKey,
      ),
      isTrue,
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('Start import'));
    expect(saveButton().onPressed, isNotNull);
    await tester.tap(find.text('Start import'));
    await tester.pumpAndSettle();
    expect(service.calls.where((call) => call == 'createJob'), hasLength(1));
    expect(service.calls.where((call) => call == 'runShortcut'), hasLength(1));
  });

  testWidgets(
    'opening Settings or returning cannot confirm sharing or launch a pending import',
    (tester) async {
      final service = _SharingBridge();
      service.snapshot['jobs'] = [
        {'id': 'pending', 'kind': 'history', 'state': 'active'},
      ];
      service.snapshot['windows'] = [
        {
          'id': 'w',
          'job_id': 'pending',
          'state': 'queued',
          'start': '2024-01-01T00:00:00Z',
          'end': '2024-02-01T00:00:00Z',
        },
      ];
      await _pumpImport(tester, service);
      await tester.tap(find.text('History permissions'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Open Settings'));
      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      expect(
        service.calls.where((call) => call == 'openSettings'),
        hasLength(1),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getBool(
          iosSmsSharingAcknowledgementKey,
        ),
        isNull,
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Resume import'));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Resume import'),
            )
            .onPressed,
        isNull,
      );
      expect(service.calls, isNot(contains('runShortcut')));
      await _scrollTo(tester, find.text('History permissions'), delta: -400);
      await tester.tap(find.text('History permissions'));
      await tester.pumpAndSettle();
      final confirmation = find.byKey(
        const ValueKey('ios-sms-sharing-confirmation'),
      );
      await tester.ensureVisible(confirmation);
      await tester.tap(
        find.descendant(of: confirmation, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Resume import'));
      await tester.tap(find.text('Resume import'));
      await tester.pumpAndSettle();
      expect(
        service.calls.where((call) => call == 'runShortcut'),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'remembered acknowledgement is editable and Settings failure keeps manual instructions',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        iosSmsSharingAcknowledgementKey: true,
      });
      final service = _SharingBridge()..settingsOpen = false;
      final confirmed = <bool>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [iosSmsIntakeServiceProvider.overrideWithValue(service)],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: IosSmsSharingSetup(onConfirmedChanged: confirmed.add),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(confirmed, [true]);
      await tester.tap(find.text('History permissions'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Open Settings'));
      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Open the Settings app yourself'),
        findsOneWidget,
      );
      final checkbox = find.byType(Checkbox);
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(confirmed, [true, false]);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          iosSmsSharingAcknowledgementKey,
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'history screen offers two years and custom dates without latest-N cap',
    (tester) async {
      final service = MemoryBridge();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        requestUpload: () {},
        capture: (_, _, _) async => [],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            iosSmsIntakeServiceProvider.overrideWithValue(service),
            iosSmsIntakeControllerProvider.overrideWith((_) => controller),
          ],
          child: const MaterialApp(home: IosSmsImportScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('2 years'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.ancestor(
                of: find.text('2 years'),
                matching: find.byType(ChoiceChip),
              ),
            )
            .selected,
        isTrue,
      );
      await _scrollTo(tester, find.text('Custom dates'));
      expect(find.text('Custom dates'), findsOneWidget);
      expect(service.calls, isNot(contains('runShortcut')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('processing strip leaves normal editing and navigation usable', (
    tester,
  ) async {
    final service = MemoryBridge()..rows.add({'id': 'pending'});
    final started = Completer<void>(), finish = Completer<void>();
    final controller = IosSmsIntakeController(
      service: service,
      namespace: () => 'user:a',
      requestUpload: () {},
      capture: (_, _, _) async {
        started.complete();
        await finish.future;
        return [
          {'id': 'pending'},
        ];
      },
    );
    final text = TextEditingController();
    var navigated = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          iosSmsIntakeServiceProvider.overrideWithValue(service),
          iosSmsIntakeControllerProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SmsSyncStatusLayout(
              child: Column(
                children: [
                  TextField(controller: text),
                  TextButton(
                    onPressed: () => navigated = true,
                    child: const Text('Wallet'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final work = controller.refresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 201));
    expect(started.isCompleted, isTrue);
    expect(find.text('Updating recent activity…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      'An edit while SMS processing is pending',
    );
    await tester.tap(find.text('Wallet'));
    expect(navigated, isTrue);
    expect(text.text, 'An edit while SMS processing is pending');
    expect(service.calls, isNot(contains('runShortcut')));
    finish.complete();
    await tester.pumpAndSettle();
    await work;
    await tester.pumpWidget(const SizedBox.shrink());
    text.dispose();
    expect(tester.takeException(), isNull);
  });
}
