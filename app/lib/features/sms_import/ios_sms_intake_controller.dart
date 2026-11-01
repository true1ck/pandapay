import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  Map<String, Object?>? get lastCompletedJob =>
      jobs.where((job) => job['state'] == 'complete').firstOrNull;
  List<Map<String, Object?>> get lastCompletedWindows => windows
      .where((row) => row['job_id'] == lastCompletedJob?['id'])
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

  /// Every date range already imported for this account (local time).
  List<(DateTime, DateTime)> get importedRanges => [
    for (final row in _rows(snapshot['coverage']))
      if (DateTime.tryParse(row['start'] as String? ?? '') case final s?)
        if (DateTime.tryParse(row['end'] as String? ?? '') case final e?)
          (s.toLocal(), e.toLocal()),
  ];

  bool get partial => currentWindows.any((w) => w['state'] == 'partial');

  /// The active job's windows in date order. A window that hit the 500
  /// message cap is followed by its continuation.
  List<Map<String, Object?>> get orderedWindows =>
      [...currentWindows]..sort(
        (a, b) => (a['ordinal'] as int? ?? 0).compareTo(b['ordinal'] as int? ?? 0),
      );

  /// End of the unbroken run of finished date ranges from the job's start.
  DateTime? get importedThrough {
    DateTime? through;
    for (final window in orderedWindows) {
      if (window['state'] != 'complete') break;
      through = DateTime.tryParse(window['end'] as String? ?? '');
    }
    return through;
  }

  /// The date range being imported now, or the next one to import.
  Map<String, Object?>? get currentWindow =>
      orderedWindows.where((w) => w['state'] != 'complete').firstOrNull;

  /// Share of the selected period already imported, by time.
  double? get coverage {
    final start = DateTime.tryParse(activeJob?['start'] as String? ?? '');
    final end = DateTime.tryParse(activeJob?['end'] as String? ?? '');
    if (start == null || end == null || !end.isAfter(start)) return null;
    final through = importedThrough ?? start;
    return (through.difference(start).inSeconds / end.difference(start).inSeconds)
        .clamp(0.0, 1.0);
  }

  /// Why the current range stopped, in words the user can act on.
  /// A stopped range that a plain retry (or a split) can fix: the run was cut
  /// short, or a 500-message batch could not advance. Shortcut setup issues
  /// are excluded, since retrying cannot fix them.
  bool get currentStopIsRetryable {
    final window = currentWindow;
    if (window == null || window['state'] != 'partial') return false;
    if (window['limit_off'] != 1 || window['warning'] == 1) return false;
    final unusable = window['incomplete'] as int? ?? 0;
    if (unusable > 2 && unusable * 20 > (window['enumerated'] as int? ?? 0)) {
      return false;
    }
    return true;
  }

  String? get stopReason {
    final window = currentWindow;
    if (window == null || window['state'] != 'partial') return null;
    if (window['limit_off'] != 1) {
      return 'In the Shortcut, turn on “Find Messages limit is off” in Finish PandaPay History Import, then resume.';
    }
    final unusable = window['incomplete'] as int? ?? 0;
    if (unusable > 2 && unusable * 20 > (window['enumerated'] as int? ?? 0)) {
      return 'Many messages arrived without text or a date. Check the Shortcut’s Body and Date fields, then resume.';
    }
    if ((window['found'] as int? ?? 0) != (window['enumerated'] as int? ?? 0)) {
      return 'Shortcuts found ${window['found']} messages but PandaPay received ${window['enumerated']}. Resume to try this range again.';
    }
    return 'This range needs another try. Resume to import it again.';
  }
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
  /// "1 Jul – 31 Jul" for a window; the end is exclusive.
  static String rangeLabel(Map<String, Object?> window) {
    final start = DateTime.tryParse(window['start'] as String? ?? '');
    final end = DateTime.tryParse(window['end'] as String? ?? '')
        ?.subtract(const Duration(milliseconds: 1));
    if (start == null) return 'the next dates';
    // Always name the year: "2 Nov – 30 Nov 2025" must not read as this month.
    final day = DateFormat('d MMM'), dayYear = DateFormat('d MMM yyyy');
    if (end == null || end.isBefore(start)) return dayYear.format(start.toLocal());
    return '${day.format(start.toLocal())} – ${dayYear.format(end.toLocal())}';
  }

  /// "through 18 Aug" once a range is done, else the first range's start.
  String get historyPosition {
    final through = importedThrough;
    if (through != null) {
      return 'through ${DateFormat('d MMM').format(through.toLocal())}';
    }
    final start = DateTime.tryParse(currentWindow?['start'] as String? ?? '');
    return start == null
        ? 'starting'
        : 'starting ${DateFormat('d MMM').format(start.toLocal())}';
  }

  String get label {
    if (error != null) return 'Message update needs attention';
    if (paused) return 'Message update paused';
    if (partial) {
      return missingSenders > 0
          ? 'Messages need sender details'
          : 'Some dates need another check';
    }
    if (activeJob?['kind'] == 'history') {
      // One steady sentence; only the dates change, when the import moves on
      // to the next range. Per-step wording flickered as batches came in.
      final window = currentWindow;
      return window == null
          ? 'Importing history'
          : 'Importing history · ${rangeLabel(window)}';
    }
    if (waiting) return 'Waiting for message import…';
    if (activeJob != null) return 'Recent-message check pending';
    if (processing) return 'Updating recent activity…';
    return 'Recent messages checked';
  }

  /// Converted once per snapshot list. The progress card and status strip
  /// read jobs/windows many times per frame; copying every row on each read
  /// cost seconds of UI-thread time during imports.
  static final _rowsCache = Expando<List<Map<String, Object?>>>();
  static List<Map<String, Object?>> _rows(Object? value) {
    if (value is! List) return const [];
    return _rowsCache[value] ??= value
        .map((e) => Map<String, Object?>.unmodifiable(e as Map))
        .toList(growable: false);
  }
}

/// Serial controller. It observes native durable authority; losing this Dart
/// object or navigating away does not cancel/acknowledge native work.
class IosSmsIntakeController extends ChangeNotifier {
  final IosSmsIntakeService service;
  final String Function() namespace;
  final IosSmsCapture capture;
  final DateTime Function() now;
  final void Function() requestUpload;

  /// Remembers an automatic import across app restarts. iOS may close
  /// PandaPay while Shortcuts runs; the import must carry on by itself.
  final IosImportSessionStore sessionStore;
  final _autoRetries = <String, int>{};
  static const _maxAutoRetries = 2;
  ({String job, String shortcut})? _savedSession;
  bool _savedSessionLoaded = false;
  String? _lastShortcut;
  Timer? _autoResumeTimer;
  static const _autoResumeDelay = Duration(seconds: 5);
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

  void _endAutomaticSession({bool forget = true}) {
    if (forget && _automaticJob != null) unawaited(sessionStore.clear());
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
    IosImportSessionStore? sessionStore,
  }) : now = now ?? DateTime.now,
       sessionStore = sessionStore ?? const IosImportSessionStore() {
    if (service.supported) service.listen(refresh);
    // Load once, in the background; the import loop never waits on storage.
    if (service.supported) {
      unawaited(
        this.sessionStore.load().then((saved) async {
          _savedSession = saved;
          _savedSessionLoaded = true;
          // Without a saved session (for example a fresh launch), use the
          // shortcut name chosen on the import screen, or the default.
          _lastShortcut ??= saved?.shortcut ?? await this.sessionStore.shortcutName();
          if (!_disposed) unawaited(refresh());
        }),
      );
    }
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
            String? errorAttempt;
            if (returned is Map &&
                returned['attempt'] == _issuedAttempt &&
                returned['status'] != 'success') {
              if (returned['status'] == 'cancel') {
                // A cancel is the person's choice: wait for them.
                _endAutomaticSession();
                returnError = 'Import paused. Resume when you’re ready.';
              } else {
                // Decide after reading native state: an error reported after
                // the range already finished loses nothing.
                errorAttempt = _issuedAttempt;
              }
            }
            await AccountRecoveryOperationGate.process.run(() async {
              _check(expected, revision);
              final snapshot = await service.configure(expected);
              _check(expected, revision);
              _publish(IosSmsIntakeState(snapshot: snapshot));
              if (!state.enabled) return;
              final generation = state.generation!;
              var drained = false;
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
                  // Publish "processing" once; repeating it per batch rebuilds
                  // every listening screen for no visible change.
                  if (!state.processing) {
                    _publish(
                      IosSmsIntakeState(
                        snapshot: state.snapshot,
                        processing: true,
                      ),
                    );
                  }
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
                  drained = true;
                  // Let frames render between batches.
                  await Future<void>.delayed(const Duration(milliseconds: 16));
                }
              } while (_refreshAgain);
              // One upload pass for the whole drain, not one per batch.
              if (drained) requestUpload();
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
            if (errorAttempt != null) {
              final window = state.currentWindows
                  .where((w) => w['attempt'] == errorAttempt)
                  .firstOrNull;
              if (window?['state'] == 'complete') {
                _returnedAttempt = errorAttempt;
              } else {
                _endAutomaticSession();
                returnError = 'Shortcuts stopped. Check its setup, then resume.';
              }
            }
            if (returnError != null) {
              _publish(
                IosSmsIntakeState(snapshot: state.snapshot, error: returnError),
              );
            } else {
              await _advance(expected, revision);
            }
            _scheduleAutoResume(expected, revision);
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

  /// [automatic] is true for PandaPay's own auto-resume; only a person's tap
  /// resets the per-range retry limit.
  Future<void> continueImport(
    String shortcutName, {
    bool automatic = false,
  }) => _serialize(() async {
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
    _lastShortcut = _automaticShortcut;
    _issuedAttempt = null;
    _returnedAttempt = null;
    if (!automatic) _autoRetries.clear();
    if (_automaticJob != null) {
      _savedSession = null;
      unawaited(sessionStore.save(_automaticJob!, _automaticShortcut!));
    }
    try {
      await _launch(expected, revision);
    } catch (_) {
      _endAutomaticSession();
      rethrow;
    }
  });

  /// A history import that is not paused or stopped, with nothing running
  /// for a few seconds while PandaPay is on screen, continues by itself:
  /// the person should not have to tap Resume. Shortcut setup problems that
  /// a retry cannot fix are left for the person.
  bool _canAutoResume() {
    final job = state.activeJob;
    if (_disposed ||
        _automaticJob != null ||
        _lastShortcut == null ||
        !state.enabled ||
        job == null ||
        job['kind'] != 'history' ||
        job['state'] == 'paused' ||
        // A cancel in Shortcuts or a reported error waits for the person.
        state.error != null ||
        state.processing ||
        state.launching ||
        state.waiting ||
        state.pending > 0) {
      return false;
    }
    final window = state.currentWindow;
    if (window == null) return false;
    if (window['state'] == 'queued') return true;
    if (window['state'] == 'partial') {
      return state.currentStopIsRetryable &&
          (_autoRetries['${window['id']}'] ?? 0) < _maxAutoRetries;
    }
    return false;
  }

  void _scheduleAutoResume(String expected, int revision) {
    if (!_canAutoResume()) {
      _autoResumeTimer?.cancel();
      _autoResumeTimer = null;
      return;
    }
    _autoResumeTimer ??= Timer(_autoResumeDelay, () {
      _autoResumeTimer = null;
      unawaited(() async {
        try {
          if (revision != _revision ||
              namespace() != expected ||
              !_canAutoResume() ||
              await service.call('isForeground') != true ||
              !_canAutoResume()) {
            return;
          }
          final window = state.currentWindow;
          if (window?['state'] == 'partial') {
            final key = '${window!['id']}';
            _autoRetries[key] = (_autoRetries[key] ?? 0) + 1;
          }
          await continueImport(_lastShortcut!, automatic: true);
        } catch (_) {
          // The normal error state already reflects a failed launch.
        }
      }());
    });
  }

  /// After iOS restarts PandaPay mid-import, pick up the saved session for
  /// the same active job and continue from the current range.
  Future<void> _restoreSession() async {
    if (_automaticJob != null || !_savedSessionLoaded) return;
    final saved = _savedSession;
    final active = state.activeJob;
    if (saved == null) return;
    if (active == null ||
        active['id'] != saved.job ||
        state.paused ||
        state.error != null) {
      if (active == null || active['id'] != saved.job) {
        _savedSession = null;
        unawaited(sessionStore.clear());
      }
      return;
    }
    _savedSession = null;
    _automaticJob = saved.job;
    _automaticShortcut = saved.shortcut;
    final current = state.currentWindow;
    final attempt = current?['attempt'] as String?;
    _issuedAttempt = attempt;
    // A range only completes after the Shortcut's Finish ran, so it returned.
    _returnedAttempt = current?['state'] == 'complete' ? attempt : null;
  }

  Future<void> _advance(String expected, int revision) async {
    await _restoreSession();
    _check(expected, revision);
    final job = _automaticJob;
    if (job == null) return;
    if (state.activeJob?['id'] == job &&
        state.partial &&
        !state.paused &&
        state.error == null &&
        state.currentStopIsRetryable) {
      // Retry (or split a dense 500-message range) by itself a few times
      // before asking the person to step in.
      final window = state.currentWindow!;
      final key = '${window['id']}';
      final tries = _autoRetries[key] ?? 0;
      if (tries < _maxAutoRetries &&
          await service.call('isForeground') == true) {
        _autoRetries[key] = tries + 1;
        final dense = (window['found'] as int? ?? 0) >= 500;
        await service.call('control', {
          'generation': state.generation,
          'command': dense ? 'split' : 'retry',
        });
        _check(expected, revision);
        await _load();
        _check(expected, revision);
        await _launch(expected, revision);
        return;
      }
    }
    if (state.activeJob?['id'] != job ||
        state.paused ||
        state.partial ||
        state.error != null) {
      _endAutomaticSession();
      return;
    }
    if (_issuedAttempt == null) {
      // Restored before this range was issued: start it now.
      if (state.currentWindow?['state'] == 'queued' &&
          await service.call('isForeground') == true) {
        _check(expected, revision);
        await _launch(expected, revision);
      }
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
    _autoResumeTimer?.cancel();
    // Teardown is not the person stopping the import: keep the saved session.
    _endAutomaticSession(forget: false);
    _revision++;
    if (service.supported) service.listen(null);
    super.dispose();
  }
}

/// Saved "an automatic import is running" marker. Storage failures only mean
/// the person may need to tap Resume, never a wrong import.
class IosImportSessionStore {
  const IosImportSessionStore();
  static const _key = 'pandapay.ios_sms_auto_import_session_v1';
  // Same key and default as the import screen's shortcut-name field.
  static const _shortcutNameKey = 'pandapay_app.ios_history_shortcut_name_v1';
  static const defaultShortcutName = 'PANDAPAY SMS HISTORY';

  Future<String> shortcutName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_shortcutNameKey)?.trim();
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {}
    return defaultShortcutName;
  }

  Future<void> save(String job, String shortcut) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode({'job': job, 'shortcut': shortcut}));
    } catch (_) {}
  }

  Future<({String job, String shortcut})?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return null;
      final value = jsonDecode(raw);
      if (value is Map && value['job'] is String && value['shortcut'] is String) {
        return (job: value['job'] as String, shortcut: value['shortcut'] as String);
      }
    } catch (_) {}
    return null;
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
