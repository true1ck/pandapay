import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../data/portable_backup/account_recovery_operation_gate.dart';
import 'ios_sms_intake_service.dart';

typedef IosSmsCapture =
    Future<List<Map<String, Object?>>> Function(
      String namespace,
      String generation,
      List<Map<Object?, Object?>> records,
    );

class IosSmsIntakeState {
  final Map<String, Object?> snapshot;
  final bool processing;
  final bool launching;
  final String? error;
  const IosSmsIntakeState({
    this.snapshot = const {},
    this.processing = false,
    this.launching = false,
    this.error,
  });
  bool get enabled => snapshot['enabled'] == true;
  int get pending => snapshot['pending'] as int? ?? 0;
  String? get generation => snapshot['generation'] as String?;
  List<Map<String, Object?>> get jobs => _rows(snapshot['jobs']);
  List<Map<String, Object?>> get windows => _rows(snapshot['windows']);
  Map<String, Object?>? get activeJob {
    for (final job in jobs) {
      if (const ['active', 'paused', 'partial'].contains(job['state'])) {
        return job;
      }
    }
    return null;
  }

  List<Map<String, Object?>> get currentWindows => windows
      .where((row) => row['job_id'] == activeJob?['id'])
      .toList(growable: false);
  List<Map<String, Object?>> get latestWindows => windows
      .where((row) => row['job_id'] == (activeJob ?? jobs.firstOrNull)?['id'])
      .toList(growable: false);

  String countsFor(Iterable<Map<String, Object?>> rows) {
    int sum(String key) =>
        rows.fold(0, (total, window) => total + (window[key] as int? ?? 0));
    return '${sum('enumerated')} received · ${sum('processed')} processed · ${sum('needs_review')} need review';
  }

  int get completed =>
      currentWindows.where((w) => w['state'] == 'complete').length;
  int get monthCount =>
      currentWindows.map((w) => w['logical_id'] ?? w['id']).toSet().length;
  int get completedMonths {
    final groups = <Object?, List<Map<String, Object?>>>{};
    for (final window in currentWindows) {
      groups
          .putIfAbsent(window['logical_id'] ?? window['id'], () => [])
          .add(window);
    }
    return groups.values
        .where((group) => group.every((w) => w['state'] == 'complete'))
        .length;
  }

  bool get partial => currentWindows.any((w) => w['state'] == 'partial');
  int get missingSenders => currentWindows.fold(
    0,
    (total, window) => total + (window['missing_sender'] as int? ?? 0),
  );
  bool get waiting => currentWindows.any(
    (w) => const ['waiting', 'running', 'finished'].contains(w['state']),
  );
  bool get paused => activeJob?['state'] == 'paused';
  bool get visible =>
      enabled &&
      (processing || activeJob != null || error != null || pending > 0);
  String get label {
    if (error != null) return 'Message update needs attention';
    if (paused) return 'Message update paused';
    if (partial) {
      return missingSenders > 0
          ? 'Messages need sender details'
          : 'Some dates need another check';
    }
    if (waiting) {
      return activeJob?['kind'] == 'history'
          ? 'Importing history · $completedMonths of $monthCount months checked'
          : 'Waiting for message import…';
    }
    if (activeJob != null) {
      return activeJob?['kind'] == 'history'
          ? 'Importing history · $completedMonths of $monthCount months checked'
          : 'Recent-message check pending';
    }
    if (processing) return 'Updating recent activity…';
    return 'Recent messages checked';
  }

  static List<Map<String, Object?>> _rows(Object? value) => value is List
      ? value
            .map((e) => Map<String, Object?>.from(e as Map))
            .toList(growable: false)
      : const [];
}

/// Serial controller. It observes native durable authority; losing this Dart
/// object or navigating away does not cancel/acknowledge native work.
class IosSmsIntakeController extends ChangeNotifier {
  final IosSmsIntakeService service;
  final String Function() namespace;
  final IosSmsCapture capture;
  final DateTime Function() now;
  final void Function() requestUpload;
  IosSmsIntakeState _state = const IosSmsIntakeState();
  IosSmsIntakeState get state => _state;
  Future<void> _tail = Future.value();
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  bool _disposed = false;
  String? _automaticJob;
  String? _automaticShortcut;
  String? _issuedAttempt;
  String? _returnedAttempt;
  bool get automaticallyAdvancing => _automaticJob != null;
  int _revision = 0;
  Timer? _handoffTimer;
  String? _resumedAttempt;
  Timer? _idleTimer;
  String? _idleProgress;
  String? _idleResumedProgress;

  void _endAutomaticSession() {
    _automaticJob = null;
    _handoffTimer?.cancel();
    _handoffTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _idleProgress = null;
    _idleResumedProgress = null;
  }

  void _watchCaptureInactivity(
    String expected,
    int revision,
    String job,
    String attempt,
    Map<String, Object?> window,
  ) {
    if (!const ['waiting', 'running', 'finished'].contains(window['state'])) {
      return;
    }
    final received = window['enumerated'] as int? ?? 0;
    final progress = '$attempt:$received';
    if (_idleProgress != progress) {
      _idleTimer?.cancel();
      _idleTimer = null;
      _idleProgress = progress;
    }
    if (_idleTimer != null || _idleResumedProgress == progress) return;
    _idleTimer = Timer(const Duration(seconds: 5), () {
      _idleTimer = null;
      unawaited(
        _serialize(() async {
          if (_disposed ||
              revision != _revision ||
              namespace() != expected ||
              _automaticJob != job ||
              _issuedAttempt != attempt ||
              _returnedAttempt == attempt ||
              !state.enabled ||
              state.paused ||
              state.partial) {
            return;
          }
          final current = state.currentWindows
              .where((w) => w['attempt'] == attempt)
              .firstOrNull;
          if (current == null ||
              !const [
                'waiting',
                'running',
                'finished',
              ].contains(current['state']) ||
              (current['enumerated'] as int? ?? 0) != received) {
            return;
          }
          if (await service.call('isForeground') != true) return;
          _check(expected, revision);
          if (_automaticJob != job ||
              _issuedAttempt != attempt ||
              _returnedAttempt == attempt) {
            return;
          }
          _idleResumedProgress = progress;
          // Resume only the existing runner after five seconds without capture
          // progress. This is not Finish, a new attempt, or next-month evidence.
          // Native rechecks the same count/state before opening Shortcuts.
          await service.call('resumeShortcut', {
            'attempt': attempt,
            'stalled': true,
            'received': received,
          });
          unawaited(refresh());
        }).catchError((Object _) {
          if (!_disposed &&
              revision == _revision &&
              namespace() == expected &&
              _automaticJob == job) {
            _endAutomaticSession();
            _publish(
              IosSmsIntakeState(
                snapshot: state.snapshot,
                error: 'Import paused. Resume when you’re ready.',
              ),
            );
          }
        }),
      );
    });
  }

  void _scheduleShortcutReturn(
    String expected,
    int revision,
    String job,
    String attempt,
  ) {
    if (_handoffTimer != null || _resumedAttempt == attempt) return;
    _handoffTimer = Timer(const Duration(milliseconds: 800), () {
      _handoffTimer = null;
      unawaited(
        _serialize(() async {
          if (_disposed ||
              revision != _revision ||
              namespace() != expected ||
              _automaticJob != job ||
              _issuedAttempt != attempt ||
              _returnedAttempt == attempt ||
              !state.enabled ||
              state.paused ||
              state.partial ||
              state.currentWindows
                      .where((w) => w['attempt'] == attempt)
                      .firstOrNull?['state'] !=
                  'complete') {
            return;
          }
          if (await service.call('isForeground') != true) return;
          _check(expected, revision);
          if (_automaticJob != job ||
              _issuedAttempt != attempt ||
              _returnedAttempt == attempt) {
            return;
          }
          // Once per issued attempt. This opens the existing Shortcuts run; it
          // cannot issue the next window or treat a timer as successful intake.
          _resumedAttempt = attempt;
          await service.call('resumeShortcut', {'attempt': attempt});
          // A real return may have raced this check. Consume it through the
          // normal receipt/callback/foreground guards, never by launching here.
          unawaited(refresh());
        }).catchError((Object _) {
          if (!_disposed &&
              revision == _revision &&
              namespace() == expected &&
              _automaticJob == job) {
            _endAutomaticSession();
            _publish(
              IosSmsIntakeState(
                snapshot: state.snapshot,
                error:
                    'Return to Shortcuts to finish this month, then resume in PandaPay.',
              ),
            );
          }
        }),
      );
    });
  }

  IosSmsIntakeController({
    required this.service,
    required this.namespace,
    required this.capture,
    required this.requestUpload,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    if (service.supported) service.listen(refresh);
  }

  void _publish(IosSmsIntakeState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  void _check(String expected, int revision) {
    if (_disposed ||
        revision != _revision ||
        namespace() != expected ||
        !expected.startsWith('user:')) {
      throw StateError('SMS account changed');
    }
  }

  Future<void> _serialize(Future<void> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _load() async {
    final value = await service.call('snapshot');
    if (value is Map && value['namespace'] == namespace()) {
      _publish(IosSmsIntakeState(snapshot: Map<String, Object?>.from(value)));
    }
  }

  Future<void> refresh() {
    if (!service.supported || _disposed || !namespace().startsWith('user:')) {
      return Future.value();
    }
    if (_refreshing != null) {
      _refreshAgain = true;
      return _refreshing!;
    }
    return _refreshing =
        _serialize(() async {
          final expected = namespace(), revision = _revision;
          try {
            final returned = await service.call('takeShortcutReturn');
            if (returned is Map &&
                returned['attempt'] == _issuedAttempt &&
                returned['status'] == 'success') {
              _returnedAttempt = _issuedAttempt;
            }
            String? returnError;
            if (returned is Map &&
                returned['attempt'] == _issuedAttempt &&
                returned['status'] != 'success') {
              _endAutomaticSession();
              returnError = returned['status'] == 'cancel'
                  ? 'Import paused. Resume when you’re ready.'
                  : 'Shortcuts stopped. Check its setup, then resume.';
            }
            await AccountRecoveryOperationGate.process.run(() async {
              _check(expected, revision);
              final snapshot = await service.configure(expected);
              _check(expected, revision);
              _publish(IosSmsIntakeState(snapshot: snapshot));
              if (!state.enabled) return;
              final generation = state.generation!;
              do {
                _refreshAgain = false;
                while (true) {
                  _check(expected, revision);
                  final pending = await service.call('pending', {
                    'generation': generation,
                  });
                  final rows = (pending! as List)
                      .map((row) => Map<Object?, Object?>.from(row as Map))
                      .toList();
                  if (rows.isEmpty) break;
                  _publish(
                    IosSmsIntakeState(
                      snapshot: state.snapshot,
                      processing: true,
                    ),
                  );
                  final outcomes = await capture(expected, generation, rows);
                  _check(expected, revision);
                  if (outcomes.length != rows.length) {
                    throw StateError('Incomplete SMS processing receipt');
                  }
                  await service.call('acknowledge', {
                    'generation': generation,
                    'outcomes': outcomes,
                  });
                  _check(expected, revision);
                  requestUpload();
                  await Future<void>.delayed(Duration.zero);
                }
              } while (_refreshAgain);
              await _load();
              _check(expected, revision);
              // Queue catch-up without launching another app. An active historical
              // job takes precedence, and resume joins its issued attempt.
              if (state.activeJob == null && _automaticJob == null) {
                await service.call('prepareCatchup');
                _check(expected, revision);
                await _load();
              }
            });
            if (returnError != null) {
              _publish(
                IosSmsIntakeState(snapshot: state.snapshot, error: returnError),
              );
            } else {
              await _advance(expected, revision);
            }
          } catch (_) {
            _endAutomaticSession();
            if (!_disposed &&
                namespace() == expected &&
                revision == _revision) {
              _publish(
                IosSmsIntakeState(
                  snapshot: state.snapshot,
                  error:
                      'Saved messages remain pending. Retry when storage and your account are available.',
                ),
              );
            }
          }
        }).whenComplete(() {
          _refreshing = null;
          if (_refreshAgain && !_disposed) {
            _refreshAgain = false;
            unawaited(refresh());
          }
        });
  }

  Future<void> setEnabled(bool enabled) => _serialize(() async {
    if (!enabled) _endAutomaticSession();
    final expected = namespace(), revision = _revision;
    _check(expected, revision);
    final snapshot = await service.configure(expected, enabled: enabled);
    _check(expected, revision);
    _publish(IosSmsIntakeState(snapshot: snapshot));
  });

  /// Called synchronously on an account transition, before asynchronous native
  /// revocation completes, so an in-flight drain cannot acknowledge another owner.
  Future<void> accountChanged() {
    _endAutomaticSession();
    _issuedAttempt = null;
    _returnedAttempt = null;
    _revision++;
    _publish(const IosSmsIntakeState());
    return _serialize(() async {
      if (!service.supported) return;
      await service.configure(namespace());
      await _load();
    });
  }

  Future<void> startHistory(
    DateTime start,
    DateTime end, {
    String? replacingJobId,
  }) => _serialize(() async {
    final expected = namespace(), revision = _revision;
    _check(expected, revision);
    if (!state.enabled) throw StateError('Enable SMS Shortcuts first.');
    final currentJobId = state.activeJob?['id'];
    if (currentJobId != replacingJobId) {
      throw StateError(
        'Finish or stop the current check before starting another period.',
      );
    }
    final windows = iosSmsWindows(start, end, monthly: true);
    await service.call('createJob', {
      'generation': state.generation,
      'id': const Uuid().v4(),
      'kind': 'history',
      'replacingJobID': ?replacingJobId,
      'zone': start.timeZoneName,
      'windows': windows.map((w) => w.toJson()).toList(),
    });
    _check(expected, revision);
    _endAutomaticSession();
    _issuedAttempt = null;
    _returnedAttempt = null;
    await _load();
  });

  Future<void> control(String command) {
    _endAutomaticSession();
    return _serialize(() async {
      final expected = namespace(), revision = _revision;
      _check(expected, revision);
      await service.call('control', {
        'generation': state.generation,
        'command': command,
      });
      _check(expected, revision);
      await _load();
    });
  }

  Future<void> continueImport(String shortcutName) => _serialize(() async {
    final expected = namespace(), revision = _revision;
    _check(expected, revision);
    if (!state.enabled || state.activeJob == null) return;
    // A user-started session is bounded to this job and account. It does not
    // survive process death or admit unrelated app-open/daily jobs.
    if (state.paused || state.waiting || state.partial) {
      await service.call('control', {
        'generation': state.generation,
        'command': 'retry',
      });
      _check(expected, revision);
      await _load();
    }
    _automaticJob = state.activeJob?['id'] as String?;
    _automaticShortcut = shortcutName.trim();
    _issuedAttempt = null;
    _returnedAttempt = null;
    try {
      await _launch(expected, revision);
    } catch (_) {
      _endAutomaticSession();
      rethrow;
    }
  });

  Future<void> _advance(String expected, int revision) async {
    final job = _automaticJob;
    if (job == null) return;
    if (state.activeJob?['id'] != job ||
        state.paused ||
        state.partial ||
        state.error != null) {
      _endAutomaticSession();
      return;
    }
    if (_issuedAttempt == null) return;
    final previous = state.currentWindows
        .where((w) => w['attempt'] == _issuedAttempt)
        .firstOrNull;
    // A successful URL return alone is never an import receipt. Wait for
    // native counts and the shared processing acknowledgements to commit.
    if (previous?['state'] != 'complete') {
      if (previous != null && _returnedAttempt != _issuedAttempt) {
        _watchCaptureInactivity(
          expected,
          revision,
          job,
          _issuedAttempt!,
          previous,
        );
      }
      if (_returnedAttempt == _issuedAttempt) {
        _endAutomaticSession();
        _publish(
          IosSmsIntakeState(
            snapshot: state.snapshot,
            error:
                'This month did not finish. Check the Shortcut, then resume.',
          ),
        );
      }
      return;
    }
    _idleTimer?.cancel();
    _idleTimer = null;
    // A foreground Finish can resume PandaPay before the Shortcut reaches
    // Stop and Output. Wait for its matching URL return as well as receipts,
    // so a new launch cannot race the previous Shortcut's final callback.
    if (_returnedAttempt != _issuedAttempt) {
      _scheduleShortcutReturn(expected, revision, job, _issuedAttempt!);
      return;
    }
    _handoffTimer?.cancel();
    _handoffTimer = null;
    if (await service.call('isForeground') != true) return;
    _check(expected, revision);
    if (_automaticJob != job) return;
    await _launch(expected, revision);
  }

  Future<void> _launch(String expected, int revision) async {
    final job = _automaticJob;
    if (job == null) return;
    final generation = state.generation;
    final request = await service.call('issue', {'generation': generation});
    _check(expected, revision);
    if (_automaticJob != job) return;
    if (request is! String || request.isEmpty) {
      _endAutomaticSession();
      return;
    }
    final attempt = (jsonDecode(request) as Map)['attempt'];
    if (attempt is! String || attempt == _issuedAttempt) {
      _endAutomaticSession();
      throw StateError('Import has not advanced');
    }
    _handoffTimer?.cancel();
    _handoffTimer = null;
    _resumedAttempt = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _idleProgress = null;
    _idleResumedProgress = null;
    _issuedAttempt = attempt;
    _returnedAttempt = null;
    _publish(IosSmsIntakeState(snapshot: state.snapshot, launching: true));
    final launched = await service.call('runShortcut', {
      'name': _automaticShortcut,
      'request': request,
    });
    _check(expected, revision);
    await _load();
    if (launched == true) {
      final current = state.currentWindows
          .where((w) => w['attempt'] == attempt)
          .firstOrNull;
      if (current != null) {
        _watchCaptureInactivity(expected, revision, job, attempt, current);
      }
    }
    if (launched != true) {
      _endAutomaticSession();
      _publish(
        IosSmsIntakeState(
          snapshot: state.snapshot,
          error:
              'Could not open Shortcuts. Check the history Shortcut name and try again.',
        ),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _endAutomaticSession();
    _revision++;
    if (service.supported) service.listen(null);
    super.dispose();
  }
}
