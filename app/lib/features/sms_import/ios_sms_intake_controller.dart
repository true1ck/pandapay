import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../data/portable_backup/account_recovery_operation_gate.dart';
import '../sms_v2/pipeline/failure_words.dart';
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
  final bool processingFailed;
  const IosSmsIntakeState({
    this.snapshot = const {},
    this.processing = false,
    this.launching = false,
    this.error,
    this.processingFailed = false,
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

  /// Messages from the current import's period that PandaPay holds. Unlike
  /// per-range counts, these never drop when Resume reads a range again.
  ({int saved, int processed, int review}) get importCounts {
    final counts = snapshot['active_counts'];
    if (counts is Map && counts['job'] == activeJob?['id']) {
      return (
        saved: counts['saved'] as int? ?? 0,
        processed: counts['processed'] as int? ?? 0,
        review: counts['review'] as int? ?? 0,
      );
    }
    int sum(String key) => currentWindows.fold(
      0,
      (total, window) => total + (window[key] as int? ?? 0),
    );
    return (
      saved: sum('enumerated'),
      processed: sum('processed'),
      review: sum('needs_review'),
    );
  }

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
  bool get acquisitionFinished =>
      currentWindows.isNotEmpty &&
      currentWindows.every(
        (w) => const ['complete', 'finished'].contains(w['state']),
      );
  bool get savingMessages =>
      pending > 0 || currentWindows.any((w) => w['state'] == 'finished');

  /// The active job's windows in date order. A window that hit the 500
  /// message cap is followed by its continuation.
  List<Map<String, Object?>> get orderedWindows => [...currentWindows]
    ..sort(
      (a, b) =>
          (a['ordinal'] as int? ?? 0).compareTo(b['ordinal'] as int? ?? 0),
    );

  /// When the live automation last handed PandaPay an incoming SMS.
  DateTime? get lastLiveAt =>
      DateTime.tryParse(snapshot['last_live_at'] as String? ?? '');

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
    final savedSeconds = currentWindows
        .where((w) => w['state'] == 'complete')
        .fold<int>(0, (total, w) {
          final from = DateTime.tryParse(w['start'] as String? ?? '');
          final to = DateTime.tryParse(w['end'] as String? ?? '');
          return total +
              (from == null || to == null ? 0 : to.difference(from).inSeconds);
        });
    return (savedSeconds / end.difference(start).inSeconds).clamp(0.0, 1.0);
  }

  /// Why the current range stopped, in words the user can act on.
  /// A stopped range that a plain retry (or a split) can fix: the run was cut
  /// short, or a 500-message batch could not advance. Shortcut setup issues
  /// are excluded, since retrying cannot fix them.
  bool get currentStopIsRetryable {
    final window = currentWindow;
    if (window == null || window['state'] != 'partial') return false;
    if (window['warning'] == 1) return false;
    final unusable = window['incomplete'] as int? ?? 0;
    if (unusable > 2 && unusable * 20 > (window['enumerated'] as int? ?? 0)) {
      return false;
    }
    return true;
  }

  String? get stopReason {
    final window = currentWindow;
    if (window == null || window['state'] != 'partial') return null;
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
    final end = DateTime.tryParse(
      window['end'] as String? ?? '',
    )?.subtract(const Duration(milliseconds: 1));
    if (start == null) return 'the next dates';
    // Always name the year: "2 Nov – 30 Nov 2025" must not read as this month.
    final day = DateFormat('d MMM'), dayYear = DateFormat('d MMM yyyy');
    if (end == null || end.isBefore(start)) {
      return dayYear.format(start.toLocal());
    }
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
    if (error != null) {
      if (processingFailed) return 'Processing needs attention';
      // Same words as the import card, so the two never disagree.
      return activeJob?['kind'] == 'history'
          ? 'Import needs a check'
          : 'Message update needs attention';
    }
    if (paused) return 'Message update paused';
    if (acquisitionFinished && savingMessages) {
      return 'Processing saved messages';
    }
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
  bool _userInitiatedLaunch = false;
  String? _returnedAttempt;
  bool get automaticallyAdvancing => _automaticJob != null;
  bool get canRetryProcessing => _drainError != null;
  bool get canResumeImport =>
      state.activeJob != null &&
      !state.processing &&
      !state.launching &&
      !state.savingMessages &&
      !state.acquisitionFinished &&
      !canRetryProcessing &&
      (state.paused || state.partial || !state.waiting || _haltError != null);
  bool _stopDrainRequested = false;

  /// Expiration stops between committed batches; it never abandons a writer.
  void stopBackgroundProcessing() {
    if (_refreshing != null) _stopDrainRequested = true;
  }

  Future<Map<String, Object?>> processInBackground() async {
    if (!namespace().startsWith('user:')) {
      return {'success': false, 'unavailable': true};
    }
    _stopDrainRequested = false;
    await refresh();
    return {'success': _drainError == null, 'pending': state.pending};
  }

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
            _halt(_pausedMessage);
          }
        }),
      );
    });
  }

  /// Messages received and ranges searched across the whole import.
  int get _importReceived => state.currentWindows.fold(
    0,
    (total, window) => total + (window['enumerated'] as int? ?? 0),
  );
  String get _importProgressKey =>
      '$_importReceived:${state.currentWindows.where((w) => const ['complete', 'finished'].contains(w['state'])).length}';
  String? _loopProgress;
  int _loopKicks = 0;

  /// While PandaPay is on screen during a looping import: when nothing new
  /// arrives for a few seconds, iOS has paused Shortcuts in the background.
  /// Kick it (Shortcuts flashes, then PandaPay comes back with the next
  /// message). If two kicks bring nothing, the run has died: start a fresh
  /// one, which carries on from the first range not yet searched.
  void _watchImportProgress(String expected, int revision, String job) {
    final key = _importProgressKey;
    if (key != _loopProgress) {
      _loopProgress = key;
      _loopKicks = 0;
      _idleTimer?.cancel();
      _idleTimer = null;
    }
    if (_idleTimer != null) return;
    _idleTimer = Timer(Duration(seconds: _loopKicks == 0 ? 5 : 8), () {
      _idleTimer = null;
      unawaited(
        _serialize(() async {
          if (_disposed ||
              revision != _revision ||
              namespace() != expected ||
              _automaticJob != job ||
              !state.enabled ||
              state.paused ||
              state.partial ||
              _returnedAttempt == _issuedAttempt) {
            return;
          }
          if (_importProgressKey != key) {
            _watchImportProgress(expected, revision, job);
            return;
          }
          // Only act while the person is looking at PandaPay; while
          // Shortcuts is in front it is working.
          if (await service.call('isForeground') != true) return;
          _check(expected, revision);
          if (_loopKicks < 2) {
            _loopKicks++;
            final kicked = await service.call('resumeShortcut', {
              'attempt': _issuedAttempt,
              'stalled': true,
              'received': _importReceived,
            });
            if (kicked == true) {
              unawaited(refresh());
              return;
            }
          }
          // Kicks didn't help (or the run is gone): start a fresh run.
          _loopKicks = 0;
          await _launch(expected, revision, allowSame: true);
        }).catchError((Object _) {
          if (!_disposed &&
              revision == _revision &&
              namespace() == expected &&
              _automaticJob == job) {
            _endAutomaticSession();
            _halt(_pausedMessage);
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
            _halt(
              'Return to Shortcuts to finish this month, then resume in PandaPay.',
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
    this.smsReadingConsent,
    DateTime Function()? now,
    IosImportSessionStore? sessionStore,
  }) : now = now ?? DateTime.now,
       sessionStore = sessionStore ?? const IosImportSessionStore() {
    if (service.supported) {
      service.listen(
        _onReady,
        onBackground: processInBackground,
        onExpiration: stopBackgroundProcessing,
      );
    }
    // Load once, in the background; the import loop never waits on storage.
    if (service.supported) {
      unawaited(
        this.sessionStore.load().then((saved) async {
          _savedSession = saved;
          _savedSessionLoaded = true;
          // Without a saved session (for example a fresh launch), use the
          // shortcut name chosen on the import screen, or the default.
          _lastShortcut ??=
              saved?.shortcut ?? await this.sessionStore.shortcutName();
          if (!_disposed) unawaited(refresh());
        }),
      );
    }
  }

  /// An error stays on screen until it is resolved. Every refresh publishes
  /// several intermediate states; carrying the error through them keeps the
  /// card and status strip from flipping between two messages.
  ///
  /// [_haltError]: the automatic import stopped and waits for the person (or
  /// for the Shortcut to show progress again). [_drainError]: saved messages
  /// could not be processed; cleared by the next successful drain.
  static const _drainRetries = 2;

  /// Pause before retrying a failed batch; zero in widget tests.
  @visibleForTesting
  static Duration drainRetryDelay = const Duration(milliseconds: 400);

  /// A running Shortcut reports every saved message. Reloading import state
  /// for each one keeps the screen busy, so reloads run at most this often.
  /// Messages wait safely in the native store meanwhile. Zero in tests.
  @visibleForTesting
  static Duration readyInterval = const Duration(milliseconds: 800);

  /// Breathing room between 50-message batches so the screen keeps drawing.
  @visibleForTesting
  static Duration batchGap = const Duration(milliseconds: 60);
  final _sinceReady = Stopwatch();
  Timer? _readyTimer;

  Future<void> _onReady() {
    if (_disposed || _readyTimer != null) return Future.value();
    final wait = _sinceReady.isRunning
        ? readyInterval - _sinceReady.elapsed
        : Duration.zero;
    if (wait <= Duration.zero) {
      _sinceReady
        ..reset()
        ..start();
      return refresh();
    }
    _readyTimer = Timer(wait, () {
      _readyTimer = null;
      if (_disposed) return;
      _sinceReady
        ..reset()
        ..start();
      unawaited(refresh());
    });
    return Future.value();
  }

  String? _haltError;
  static const _pausedMessage =
      'Import paused. Resume picks up at the current month; saved messages stay.';
  String? _haltProgress;
  String? _drainError;

  void _publish(IosSmsIntakeState value) {
    if (_disposed) return;
    final error = value.error ?? _drainError ?? _haltError;
    _state =
        identical(error, value.error) &&
            value.processingFailed == (_drainError != null)
        ? value
        : IosSmsIntakeState(
            snapshot: value.snapshot,
            processing: value.processing,
            launching: value.launching,
            error: error,
            processingFailed: _drainError != null,
          );
    notifyListeners();
  }

  void _halt(String message) {
    _haltError = message;
    _haltProgress = _importProgressKey;
    _publish(IosSmsIntakeState(snapshot: state.snapshot));
  }

  /// The person acted (resume, pause, stop, a new import): old errors go.
  void _clearErrors() {
    _haltError = null;
    _haltProgress = null;
    _drainError = null;
  }

  /// A looping Shortcut keeps importing in the background even after PandaPay
  /// lost track of it: an error report, or iOS closing PandaPay. While its
  /// ranges are running, follow it again (and restart it if it stalls)
  /// instead of offering Resume next to an import that is still moving.
  void _adoptRunningLoop() {
    final job = state.activeJob?['id'] as String?;
    if (_automaticJob != null ||
        job == null ||
        _lastShortcut == null ||
        _drainError != null ||
        !state.enabled ||
        state.paused ||
        state.partial ||
        !state.waiting ||
        state.snapshot['loop_job'] != job) {
      return;
    }
    // After a stop, only fresh progress shows the run is alive.
    if (_haltError != null && _importProgressKey == _haltProgress) return;
    _haltError = null;
    _haltProgress = null;
    _automaticJob = job;
    _automaticShortcut = _lastShortcut;
    _issuedAttempt = state.currentWindow?['attempt'] as String?;
    _returnedAttempt = null;
    _publish(IosSmsIntakeState(snapshot: state.snapshot));
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

  /// Whether the signed-in account has agreed to PandaPay reading its bank
  /// SMS (the `sms_reading` consent). Null means no check is wired in, which
  /// only tests do; the app always passes one. A failed check counts as "no".
  final Future<bool> Function()? smsReadingConsent;

  Future<bool> _hasSmsReadingConsent() async {
    final check = smsReadingConsent;
    if (check == null) return true;
    try {
      return await check();
    } catch (_) {
      return false;
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
                returnError = _pausedMessage;
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
              // Shared messages wait in the phone's spool until this account
              // has agreed to PandaPay reading them; nothing is acknowledged
              // or dropped meanwhile.
              if (!await _hasSmsReadingConsent()) return;
              _check(expected, revision);
              final generation = state.generation!;
              var drained = false;
              var nextProgress = now().add(const Duration(seconds: 2));
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
                  if (rows.isEmpty || _stopDrainRequested) break;
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
                  // The capture worker and the app share one database; a
                  // write from the app at the same moment can make a batch
                  // fail with "database is locked". Saving is idempotent
                  // (decisions and acknowledgements are keyed per message),
                  // so retry the same batch before reporting anything.
                  for (var attempt = 0; ; attempt++) {
                    try {
                      final outcomes = await capture(
                        expected,
                        generation,
                        rows,
                      );
                      _check(expected, revision);
                      if (outcomes.length != rows.length) {
                        throw StateError('Incomplete SMS processing receipt');
                      }
                      await service.call('acknowledge', {
                        'generation': generation,
                        'outcomes': outcomes,
                      });
                      _check(expected, revision);
                      break;
                    } catch (error) {
                      if (attempt >= _drainRetries ||
                          _disposed ||
                          namespace() != expected ||
                          revision != _revision) {
                        rethrow;
                      }
                      debugPrint('SMS batch retry ${attempt + 1}: $error');
                      if (drainRetryDelay > Duration.zero) {
                        await Future<void>.delayed(
                          drainRetryDelay * (attempt + 1),
                        );
                      }
                    }
                  }
                  drained = true;
                  _drainError = null;
                  // Keep the app's counts moving during a large backlog,
                  // without rebuilding every listening page for every SMS.
                  if (!now().isBefore(nextProgress)) {
                    final snapshot = await service.call('snapshot');
                    _check(expected, revision);
                    _publish(
                      IosSmsIntakeState(
                        snapshot: Map<String, Object?>.from(snapshot! as Map),
                        processing: true,
                      ),
                    );
                    nextProgress = now().add(const Duration(seconds: 2));
                  }
                  // Let frames render between batches.
                  await Future<void>.delayed(batchGap);
                }
              } while (_refreshAgain && !_stopDrainRequested);
              // One upload pass for the whole drain, not one per batch.
              if (drained) requestUpload();
              _drainError = null;
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
            // With the import finished (or stopped), an earlier stop no
            // longer applies.
            if (state.activeJob == null) {
              _haltError = null;
              _haltProgress = null;
            }
            if (errorAttempt != null) {
              final window = state.currentWindows
                  .where((w) => w['attempt'] == errorAttempt)
                  .firstOrNull;
              // A looping Shortcut that runs past the last range ends with an
              // error once the import is already complete: nothing was lost.
              if (state.paused) {
                _endAutomaticSession();
              } else if (window?['state'] == 'complete' ||
                  state.activeJob == null) {
                _returnedAttempt = errorAttempt;
              } else {
                _endAutomaticSession();
                returnError =
                    'Shortcuts stopped. Check its setup, then resume.';
              }
            }
            if (returnError != null) {
              _halt(returnError);
            } else {
              await _advance(expected, revision);
            }
            _scheduleAutoResume(expected, revision);
          } catch (error, stack) {
            debugPrint('SMS refresh failed: $error');
            _endAutomaticSession();
            if (!_disposed &&
                namespace() == expected &&
                revision == _revision) {
              // Say why, in plain words: "could not be processed" alone left
              // a stuck import with nothing to go on.
              final text = '$error';
              final why = text.startsWith('Bad state: SMS capture failed: ')
                  ? text.substring('Bad state: SMS capture failed: '.length)
                  : describeFailure(error);
              _drainError =
                  'Saved messages could not be processed ($why) [${compactStack(stack)}]. Retry processing; no new import is needed.';
              _publish(IosSmsIntakeState(snapshot: state.snapshot));
            }
          }
        }).whenComplete(() {
          _refreshing = null;
          _stopDrainRequested = false;
          if (_refreshAgain && !_disposed) {
            _refreshAgain = false;
            unawaited(refresh());
          }
        });
  }

  Future<void> setEnabled(bool enabled) => _serialize(() async {
    if (!enabled) _endAutomaticSession();
    _clearErrors();
    final expected = namespace(), revision = _revision;
    _check(expected, revision);
    if (enabled && !await _hasSmsReadingConsent()) {
      throw StateError('Agree to SMS reading first.');
    }
    _check(expected, revision);
    final snapshot = await service.configure(expected, enabled: enabled);
    _check(expected, revision);
    _publish(IosSmsIntakeState(snapshot: snapshot));
  });

  /// Called synchronously on an account transition, before asynchronous native
  /// revocation completes, so an in-flight drain cannot acknowledge another owner.
  Future<void> accountChanged() {
    _endAutomaticSession();
    _clearErrors();
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
    // Never start a history import for an account that has not agreed.
    if (!await _hasSmsReadingConsent()) {
      throw StateError('Agree to SMS reading first.');
    }
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
    _clearErrors();
    _issuedAttempt = null;
    _returnedAttempt = null;
    await _load();
  });

  Future<void> control(String command) {
    _endAutomaticSession();
    _clearErrors();
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
    if (!await _hasSmsReadingConsent()) return;
    _check(expected, revision);
    // A retry of local processing must never replace an acquisition attempt.
    if (!canResumeImport) return;
    _clearErrors();
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
    _userInitiatedLaunch = !automatic;
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
        // A cancel in Shortcuts, or saved messages that could not be
        // processed, wait for the person. Other stops retry by themselves.
        _drainError != null ||
        _haltError == _pausedMessage ||
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
    _adoptRunningLoop();
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
    // A looping Shortcut imports every range in one run while PandaPay stays
    // on screen. Watch the whole import until that run returns.
    if (state.snapshot['loop_job'] == job &&
        _returnedAttempt != _issuedAttempt) {
      _watchImportProgress(expected, revision, job);
      return;
    }
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
        _halt('This month did not finish. Check the Shortcut, then resume.');
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

  Future<void> _launch(
    String expected,
    int revision, {
    bool allowSame = false,
  }) async {
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
    if (attempt is! String || (!allowSame && attempt == _issuedAttempt)) {
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
      'userInitiated': _userInitiatedLaunch,
    });
    _userInitiatedLaunch = false;
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
      _halt(
        'Could not open Shortcuts. Check the history Shortcut name and try again.',
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _autoResumeTimer?.cancel();
    _readyTimer?.cancel();
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
      await prefs.setString(
        _key,
        jsonEncode({'job': job, 'shortcut': shortcut}),
      );
    } catch (_) {}
  }

  Future<({String job, String shortcut})?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return null;
      final value = jsonDecode(raw);
      if (value is Map &&
          value['job'] is String &&
          value['shortcut'] is String) {
        return (
          job: value['job'] as String,
          shortcut: value['shortcut'] as String,
        );
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
