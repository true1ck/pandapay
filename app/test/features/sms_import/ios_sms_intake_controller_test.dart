import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_controller.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_service.dart';

class MemoryBridge extends IosSmsIntakeService {
  final calls = <String>[];
  final createdJobs = <Map<String, Object?>>[];
  final rows = <Map<Object?, Object?>>[];
  bool failAck = false;
  bool foreground = true;
  Map<String, Object?>? shortcutReturn;
  int issued = 0;
  void Function(String attempt)? onShortcutResume;
  final resumedRequests = <Map<String, Object?>>[];
  Map<String, Object?> snapshot = {
    'namespace': 'user:a',
    'generation': 'g1',
    'enabled': true,
    'pending': 0,
    'jobs': <Object?>[],
    'windows': <Object?>[],
  };
  @override
  bool get supported => true;
  @override
  void listen(Future<void> Function()? callback) {}
  @override
  Future<Object?> call(String method, [Map<String, Object?>? arguments]) async {
    calls.add(method);
    switch (method) {
      case 'configure':
        snapshot['namespace'] = arguments!['namespace'];
        if (arguments.containsKey('enabled')) {
          snapshot['enabled'] = arguments['enabled'];
        }
        return jsonDecode(jsonEncode(snapshot));
      case 'snapshot':
        return jsonDecode(jsonEncode(snapshot));
      case 'pending':
        return rows.take(50).map(Map<Object?, Object?>.from).toList();
      case 'acknowledge':
        if (failAck) throw StateError('Simulated write failure');
        final ids = (arguments!['outcomes'] as List)
            .map((e) => (e as Map)['id'])
            .toSet();
        rows.removeWhere((r) => ids.contains(r['id']));
        return null;
      case 'issue':
        final windows = (snapshot['windows'] as List).cast<Map>();
        final pending = windows
            .where((w) => w['state'] != 'complete')
            .firstOrNull;
        if (pending == null) return null;
        pending['attempt'] ??= 'attempt-${++issued}';
        pending['state'] = 'waiting';
        return jsonEncode({'attempt': pending['attempt']});
      case 'createJob':
        createdJobs.add(Map<String, Object?>.from(arguments!));
        final id = arguments['id'];
        snapshot['jobs'] = [
          {'id': id, 'kind': arguments['kind'], 'state': 'active'},
        ];
        snapshot['windows'] = [
          for (final (index, window) in (arguments['windows'] as List).indexed)
            {
              ...window as Map,
              'id': 'window-$index',
              'logical_id': 'month-$index',
              'job_id': id,
              'state': 'queued',
            },
        ];
        return null;
      case 'control':
        final job = (snapshot['jobs'] as List).cast<Map>().firstOrNull;
        if (job == null) return null;
        final command = arguments!['command'];
        if (command == 'retry') {
          job['state'] = 'active';
          for (final w in (snapshot['windows'] as List).cast<Map>().where(
            (w) => w['state'] != 'complete',
          )) {
            w['state'] = 'queued';
            w.remove('attempt');
          }
        } else {
          job['state'] = command == 'pause'
              ? 'paused'
              : command == 'stop'
              ? 'stopped'
              : 'active';
        }
        return null;
      case 'takeShortcutReturn':
        final value = shortcutReturn;
        shortcutReturn = null;
        return value;
      case 'isForeground':
        return foreground;
      case 'runShortcut':
        return true;
      case 'resumeShortcut':
        resumedRequests.add(Map<String, Object?>.from(arguments!));
        onShortcutResume?.call(arguments['attempt'] as String);
        return true;
      default:
        return null;
    }
  }
}

void main() {
  testWidgets(
    'five-second inactivity nudges the same run without completing or reissuing it',
    (tester) async {
      final service = MemoryBridge();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 3));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      final window = (service.snapshot['windows'] as List).first as Map;
      window['state'] = 'running';
      window['enumerated'] = 1;
      await controller.refresh();
      await tester.pump(const Duration(milliseconds: 4999));
      expect(service.resumedRequests, isEmpty);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pump();
      expect(service.resumedRequests, [
        {'attempt': window['attempt'], 'stalled': true, 'received': 1},
      ]);
      expect(window['state'], 'running');
      expect(controller.state.completedMonths, 0);
      expect(service.calls.where((c) => c == 'issue'), hasLength(1));
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(1));
      await tester.pump(const Duration(seconds: 20));
      await controller.refresh();
      expect(
        service.resumedRequests,
        hasLength(1),
        reason: 'No switch loop without new capture progress',
      );
      window['enumerated'] = 2;
      await controller.refresh();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(service.resumedRequests, hasLength(2));
      expect(service.resumedRequests.last['received'], 2);
      window['state'] = 'complete';
      service.shortcutReturn = {
        'attempt': window['attempt'],
        'status': 'success',
      };
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(2));
      await controller.control('pause');
    },
  );

  testWidgets(
    'incoming capture progress resets inactivity instead of bouncing a busy run',
    (tester) async {
      final service = MemoryBridge();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 3));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      final window = (service.snapshot['windows'] as List).first as Map;
      window['state'] = 'running';
      for (var received = 1; received <= 4; received++) {
        window['enumerated'] = received;
        await controller.refresh();
        await tester.pump(const Duration(seconds: 4));
        expect(service.resumedRequests, isEmpty);
      }
      service.foreground = false;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(
        service.resumedRequests,
        isEmpty,
        reason: 'Never pull user away from another app',
      );
      service.foreground = true;
      await controller.refresh();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(service.resumedRequests.single['received'], 4);
    },
  );

  for (final interruption in [
    'pause',
    'account',
    'cancel',
    'error',
    'dispose',
  ]) {
    testWidgets('$interruption cancels in-progress inactivity recovery', (
      tester,
    ) async {
      final service = MemoryBridge();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      if (interruption != 'dispose') addTearDown(controller.dispose);
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 3));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      final window = (service.snapshot['windows'] as List).first as Map;
      window['state'] = 'running';
      await controller.refresh();
      if (interruption == 'pause') {
        await controller.control('pause');
      } else if (interruption == 'account') {
        await controller.accountChanged();
      } else if (interruption == 'dispose') {
        controller.dispose();
      } else {
        service.shortcutReturn = {
          'attempt': window['attempt'],
          'status': interruption,
        };
        await controller.refresh();
      }
      await tester.pump(const Duration(seconds: 6));
      expect(service.resumedRequests, isEmpty);
    });
  }

  testWidgets(
    'completed month resumes the existing runner then waits for its real callback',
    (tester) async {
      final service = MemoryBridge();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 3));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      final windows = (service.snapshot['windows'] as List).cast<Map>();
      final first = windows[0]['attempt'];
      windows[0]['state'] = 'complete';
      await controller.refresh();
      await tester.pump(const Duration(milliseconds: 799));
      expect(service.calls, isNot(contains('resumeShortcut')));
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pump();
      expect(service.calls.where((c) => c == 'resumeShortcut'), hasLength(1));
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(1));
      await controller.refresh();
      await tester.pump(const Duration(seconds: 5));
      expect(
        service.calls.where((c) => c == 'resumeShortcut'),
        hasLength(1),
        reason: 'No app-switch loop if the callback is absent',
      );
      service.shortcutReturn = {'attempt': first, 'status': 'success'};
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(2));
      await controller.control('pause');
    },
  );

  testWidgets(
    'a resumed Shortcuts callback advances without a manual app switch',
    (tester) async {
      final service = MemoryBridge();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      addTearDown(controller.dispose);
      service.onShortcutResume = (attempt) {
        service.shortcutReturn = {'attempt': attempt, 'status': 'success'};
      };
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 4));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      final windows = (service.snapshot['windows'] as List).cast<Map>();
      windows[0]['state'] = 'complete';
      await controller.refresh();
      await tester.pump(const Duration(milliseconds: 801));
      await tester.pump();
      expect(service.calls.where((c) => c == 'resumeShortcut'), hasLength(1));
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(2));
      await controller.control('pause');
    },
  );

  for (final interruption in [
    'pause',
    'account',
    'cancel',
    'error',
    'dispose',
  ]) {
    testWidgets('$interruption cancels a scheduled return to Shortcuts', (
      tester,
    ) async {
      final service = MemoryBridge();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      if (interruption != 'dispose') addTearDown(controller.dispose);
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 3));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      final window = (service.snapshot['windows'] as List).first as Map;
      window['state'] = 'complete';
      await controller.refresh();
      if (interruption == 'pause') {
        await controller.control('pause');
      } else if (interruption == 'account') {
        await controller.accountChanged();
      } else if (interruption == 'dispose') {
        controller.dispose();
      } else {
        service.shortcutReturn = {
          'attempt': window['attempt'],
          'status': interruption,
        };
        await controller.refresh();
      }
      await tester.pump(const Duration(seconds: 2));
      expect(service.calls, isNot(contains('resumeShortcut')));
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(1));
    });
  }

  testWidgets(
    'background and unfinished windows never trigger a return handoff',
    (tester) async {
      final service = MemoryBridge();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 3));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      await controller.refresh();
      await tester.pump(const Duration(seconds: 2));
      expect(service.calls, isNot(contains('resumeShortcut')));
      final window = (service.snapshot['windows'] as List).first as Map;
      window['state'] = 'complete';
      service.foreground = false;
      await controller.refresh();
      await tester.pump(const Duration(seconds: 2));
      expect(service.calls, isNot(contains('resumeShortcut')));
      service.foreground = true;
      await controller.refresh();
      await tester.pump(const Duration(milliseconds: 801));
      await tester.pump();
      expect(service.calls.where((c) => c == 'resumeShortcut'), hasLength(1));
    },
  );

  test(
    'a selected history period explicitly replaces the observed catch-up',
    () async {
      final service = MemoryBridge();
      service.snapshot['jobs'] = [
        {'id': 'old-catchup', 'kind': 'catchup', 'state': 'active'},
      ];
      service.snapshot['windows'] = [
        {'id': 'old-window', 'job_id': 'old-catchup', 'state': 'partial'},
      ];
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await expectLater(
        controller.startHistory(DateTime(2024, 1), DateTime(2024, 4)),
        throwsStateError,
      );
      await expectLater(
        controller.startHistory(
          DateTime(2024, 1),
          DateTime(2024, 4),
          replacingJobId: 'stale-job',
        ),
        throwsStateError,
      );
      expect(service.createdJobs, isEmpty);
      await controller.startHistory(
        DateTime(2024, 1),
        DateTime(2024, 4),
        replacingJobId: 'old-catchup',
      );
      final request = service.createdJobs.single;
      expect(request['replacingJobID'], 'old-catchup');
      expect(request['kind'], 'history');
      expect(request['windows'], hasLength(3));
      expect(controller.state.activeJob?['kind'], 'history');
      expect(service.calls, isNot(contains('control')));
      expect(service.calls, isNot(contains('runShortcut')));
    },
  );

  test(
    'one user start advances completed windows once, only in foreground',
    () async {
      final service = MemoryBridge();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 4));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(1));
      final windows = (service.snapshot['windows'] as List).cast<Map>();
      windows[0]['state'] = 'complete';
      service.shortcutReturn = {
        'attempt': windows[0]['attempt'],
        'status': 'success',
      };
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(2));
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(2));
      windows[1]['state'] = 'complete';
      service.shortcutReturn = {
        'attempt': windows[1]['attempt'],
        'status': 'success',
      };
      service.foreground = false;
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(2));
      service.foreground = true;
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(3));
      (service.snapshot['jobs'] as List).first['state'] = 'complete';
      windows[2]['state'] = 'complete';
      await controller.refresh();
      expect(controller.automaticallyAdvancing, isFalse);
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(3));
    },
  );

  test(
    'foreground Finish waits for its own Shortcut return before the next window',
    () async {
      final service = MemoryBridge();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 4));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      final windows = (service.snapshot['windows'] as List).cast<Map>();
      final firstAttempt = windows[0]['attempt'];
      windows[0]['state'] = 'complete';
      // Native Finish has opened the app and committed, but Shortcuts is still
      // running its final action. Ready/resume events must not race its return.
      await controller.refresh();
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(1));
      service.shortcutReturn = {'attempt': firstAttempt, 'status': 'success'};
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(2));
      windows[1]['state'] = 'complete';
      service.shortcutReturn = {'attempt': firstAttempt, 'status': 'success'};
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(2));
      service.shortcutReturn = {
        'attempt': windows[1]['attempt'],
        'status': 'success',
      };
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(3));
    },
  );

  test(
    'interactive capture processes input without reopening Shortcuts mid-window',
    () async {
      final service = MemoryBridge();
      var uploads = 0;
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, rows) async =>
            rows.map((r) => {'id': r['id']}).toList(),
        requestUpload: () => uploads++,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 3));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      final windows = (service.snapshot['windows'] as List).cast<Map>();
      windows[0]['state'] = 'running';
      service.rows.add({'id': 'synthetic-message'});
      // Interactive Capture foregrounds the app and sends ready while the
      // Repeat loop is still active. Intake can drain, but no window advances.
      await controller.refresh();
      await controller.refresh();
      expect(service.rows, isEmpty);
      expect(uploads, 1);
      expect(controller.state.error, isNull);
      expect(controller.automaticallyAdvancing, isTrue);
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(1));
      windows[0]['state'] = 'complete';
      service.shortcutReturn = {
        'attempt': windows[0]['attempt'],
        'status': 'success',
      };
      await controller.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(2));
    },
  );

  for (final status in ['cancel', 'error', 'success']) {
    test(
      'callback $status cannot advance unfinished input or restart on refresh',
      () async {
        final service = MemoryBridge();
        final controller = IosSmsIntakeController(
          service: service,
          namespace: () => 'user:a',
          capture: (_, _, _) async => [],
          requestUpload: () {},
        );
        addTearDown(controller.dispose);
        await controller.refresh();
        await controller.startHistory(DateTime(2024, 1), DateTime(2024, 3));
        await controller.continueImport('PANDAPAY SMS HISTORY');
        final window = (service.snapshot['windows'] as List).first as Map;
        service.shortcutReturn = {
          'attempt': window['attempt'],
          'status': status,
        };
        await controller.refresh();
        await controller.refresh();
        expect(controller.automaticallyAdvancing, isFalse);
        expect(service.calls.where((c) => c == 'runShortcut'), hasLength(1));
      },
    );
  }

  test(
    'pause and a new controller never resurrect a previous automatic session',
    () async {
      final service = MemoryBridge();
      IosSmsIntakeController make() => IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
      final controller = make();
      await controller.refresh();
      await controller.startHistory(DateTime(2024, 1), DateTime(2024, 3));
      await controller.continueImport('PANDAPAY SMS HISTORY');
      await controller.control('pause');
      await controller.refresh();
      expect(controller.automaticallyAdvancing, isFalse);
      controller.dispose();
      final replacement = make();
      addTearDown(replacement.dispose);
      await replacement.refresh();
      expect(service.calls.where((c) => c == 'runShortcut'), hasLength(1));
    },
  );

  test('split windows retain a single logical month in progress', () {
    const state = IosSmsIntakeState(
      snapshot: {
        'jobs': [
          {'id': 'history', 'kind': 'history', 'state': 'active'},
        ],
        'windows': [
          {
            'id': 'a1',
            'logical_id': 'month-a',
            'job_id': 'history',
            'state': 'complete',
          },
          {
            'id': 'a2',
            'logical_id': 'month-a',
            'job_id': 'history',
            'state': 'running',
          },
          {
            'id': 'b',
            'logical_id': 'month-b',
            'job_id': 'history',
            'state': 'complete',
          },
        ],
      },
    );
    expect(state.currentWindows, hasLength(3));
    expect(state.monthCount, 2);
    expect(state.completedMonths, 1);
    expect(state.label, 'Importing history · 1 of 2 months checked');
  });
  test(
    'drain is bounded, acknowledges shared receipts, never auto-opens Shortcuts',
    () async {
      final service = MemoryBridge();
      service.rows.addAll(List.generate(103, (i) => {'id': '$i'}));
      final batches = <int>[];
      var uploads = 0;
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        requestUpload: () => uploads++,
        capture: (_, _, rows) async {
          batches.add(rows.length);
          return rows.map((r) => {'id': r['id']}).toList();
        },
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(batches, [50, 50, 3]);
      expect(uploads, 3);
      expect(service.rows, isEmpty);
      expect(service.calls, isNot(contains('runShortcut')));
      expect(controller.state.error, isNull);
    },
  );

  test(
    'failed capture or native ack retains pending input and can retry',
    () async {
      final service = MemoryBridge()..rows.add({'id': 'one'});
      var failCapture = true;
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        requestUpload: () {},
        capture: (_, _, rows) async {
          if (failCapture) throw StateError('Storage unavailable');
          return [
            {'id': 'one'},
          ];
        },
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(service.calls, isNot(contains('acknowledge')));
      expect(service.rows, hasLength(1));
      expect(controller.state.error, isNotNull);
      failCapture = false;
      service.failAck = true;
      await controller.refresh();
      expect(service.rows, hasLength(1));
      service.failAck = false;
      await controller.refresh();
      expect(service.rows, isEmpty);
    },
  );

  test(
    'an account change during parsing cannot acknowledge old input',
    () async {
      final service = MemoryBridge()..rows.add({'id': 'one'});
      var namespace = 'user:a';
      final started = Completer<void>(), finish = Completer<void>();
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => namespace,
        requestUpload: () {},
        capture: (_, _, _) async {
          started.complete();
          await finish.future;
          return [
            {'id': 'one'},
          ];
        },
      );
      addTearDown(controller.dispose);
      final work = controller.refresh();
      await started.future;
      expect(controller.state.processing, isTrue);
      namespace = 'user:b';
      final change = controller.accountChanged();
      finish.complete();
      await work;
      await change;
      expect(service.calls, isNot(contains('acknowledge')));
      expect(service.rows, hasLength(1));
    },
  );

  test(
    'a partially processed batch cannot acknowledge any native item',
    () async {
      final service = MemoryBridge()
        ..rows.addAll([
          {'id': 'one'},
          {'id': 'two'},
        ]);
      final controller = IosSmsIntakeController(
        service: service,
        namespace: () => 'user:a',
        requestUpload: () {},
        capture: (_, _, _) async => [
          {'id': 'one'},
        ],
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(service.calls, isNot(contains('acknowledge')));
      expect(service.rows, hasLength(2));
    },
  );

  test(
    'history periods freeze adjacent calendar windows and clamp leap days',
    () {
      final cutoff = DateTime(2026, 10, 29, 22, 40);
      final start = iosSmsMonthsAgo(cutoff, 24);
      final windows = iosSmsWindows(start, cutoff, monthly: true);
      expect(windows, hasLength(25));
      expect(windows.first.start, start);
      expect(windows.first.end, DateTime(2024, 11));
      expect(windows.last.end, cutoff);
      for (var i = 1; i < windows.length; i++) {
        expect(windows[i - 1].end, windows[i].start);
      }
      expect(
        iosSmsMonthsAgo(DateTime(2024, 2, 29, 12), 12),
        DateTime(2023, 2, 28, 12),
      );
      expect(iosSmsMonthsAgo(DateTime(2026, 3, 31), 1), DateTime(2026, 2, 28));
      final days = iosSmsWindows(
        DateTime(2026, 3, 7, 12),
        DateTime(2026, 3, 10, 12),
        monthly: false,
      );
      expect(days, hasLength(4));
      for (var i = 1; i < days.length; i++) {
        expect(days[i - 1].end, days[i].start);
      }
      expect(days.last.end, DateTime(2026, 3, 10, 12));
    },
  );
}
