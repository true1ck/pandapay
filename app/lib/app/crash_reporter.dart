import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'env.dart';
import 'obfuscated_trace.dart';

/// Privacy-safe crash and error reports, sent to GlitchTip (or Sentry) in the
/// Sentry envelope format. Off unless the build passes
/// `--dart-define=PANDAPAY_ERROR_REPORTING_DSN=https://<key>@<host>/<project>`.
///
/// A report says WHAT broke and WHERE in our code, never with what data:
/// the error's class name, code locations (file:line:function), the app
/// version, the platform and which handler caught it. Obfuscated release
/// builds print no file names, so their reports carry the build id and the
/// per-frame instruction offsets instead (see [ObfuscatedTrace] and
/// docs/release/symbolication.md). The error message is
/// never sent, because messages can contain SMS text, amounts, merchant
/// names or account numbers (a FormatException quotes its input). No user
/// id, device id, screen content or network data is included.
///
/// The DSN key is public by design: it can only submit reports. Abuse is
/// limited by the server's per-project rate limit and the ingestion proxy,
/// which accepts nothing else. No endpoint is added to PandaPay's own API.
class CrashReporter {
  CrashReporter({
    required String dsn,
    required this.environment,
    http.Client? client,
    Future<String> Function()? release,
    Future<SharedPreferences> Function()? preferences,
    DateTime Function()? clock,
    bool allowInsecureLocalhost = !kReleaseMode,
  }) : _target = parseDsn(dsn, allowInsecureLocalhost: allowInsecureLocalhost),
       _injectedClient = client,
       _release = release ?? _packageRelease,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now;

  /// The app-wide reporter, configured from the build's defines.
  factory CrashReporter.fromEnvironment() => CrashReporter(
    dsn: Env.errorReportingDsn,
    environment: Env.environment.name,
  );

  static const maxPerSession = 25;
  static const maxPerMinute = 10;
  static const maxQueued = 20;
  static const maxEventBytes = 32 * 1024;
  static const maxAttempts = 5;
  static const maxAge = Duration(days: 7);
  static const _queueKey = 'crash_reporter.queue.v1';
  static const _appPackage = 'package:pandapay/';

  final String environment;
  final ReportTarget? _target;
  final http.Client? _injectedClient;
  final Future<String> Function() _release;
  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _clock;

  final Set<String> _seen = {};
  final List<DateTime> _recent = [];
  List<_Queued>? _queue;
  Future<void>? _flushing;
  Future<void> _last = Future.value();
  bool _busy = false;
  int _sent = 0;

  bool get enabled => _target != null;

  /// Completes when the latest report or retry pass has finished.
  @visibleForTesting
  Future<void> drain() => _last;

  /// Sends anything left from a previous run (offline, or the app closed).
  void start() {
    if (!enabled) return;
    unawaited(_last = _guard(_flush));
  }

  /// Records one error. Never throws and never blocks the caller.
  void report(Object error, StackTrace? stack, {required String source}) {
    if (!enabled || _busy) return;
    _busy = true;
    try {
      final now = _clock();
      final frames = parseFrames(stack);
      final obfuscated = obfuscatedTraceOf(stack);
      final fingerprint = fingerprintFor(
        error,
        frames,
        source,
        buildId: obfuscated?.buildId,
      );
      if (!_admit(fingerprint.join('|'), now)) return;
      unawaited(
        _last = _guard(() async {
          final event = buildEvent(
            error: error,
            frames: frames,
            source: source,
            fingerprint: fingerprint,
            release: await _release(),
            environment: environment,
            platform: defaultTargetPlatform.name.toLowerCase(),
            now: now,
            eventId: _eventId(),
            obfuscated: obfuscated,
          );
          await _enqueue(event, now);
          await _flush();
        }),
      );
    } catch (_) {
      // Reporting must never become a second error.
    } finally {
      _busy = false;
    }
  }

  bool _admit(String key, DateTime now) {
    _recent.removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
    if (_seen.contains(key) ||
        _sent >= maxPerSession ||
        _recent.length >= maxPerMinute) {
      return false;
    }
    _seen.add(key);
    _recent.add(now);
    _sent++;
    return true;
  }

  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } catch (_) {
      // Swallowed on purpose: a failing reporter must not report itself.
    }
  }

  Future<List<_Queued>> _load() async {
    if (_queue != null) return _queue!;
    final prefs = await _preferences();
    final raw = prefs.getStringList(_queueKey) ?? const [];
    _queue = [for (final item in raw) ?_Queued.tryDecode(item)];
    return _queue!;
  }

  Future<void> _save() async {
    final prefs = await _preferences();
    await prefs.setStringList(_queueKey, [
      for (final q in _queue ?? const <_Queued>[]) q.encode(),
    ]);
  }

  Future<void> _enqueue(Map<String, Object?> event, DateTime now) async {
    final body = encodeEnvelope(event, now);
    if (utf8.encode(body).length > maxEventBytes) return;
    final queue = await _load();
    queue.add(_Queued(body: body, firstQueuedAt: now, attempts: 0));
    if (queue.length > maxQueued) {
      queue.removeRange(0, queue.length - maxQueued);
    }
    await _save();
  }

  Future<void> _flush() {
    // One delivery pass at a time; a report during a pass waits for it.
    return _flushing ??= _flushOnce().whenComplete(() => _flushing = null);
  }

  Future<void> _flushOnce() async {
    final target = _target;
    if (target == null) return;
    final queue = await _load();
    if (queue.isEmpty) return;
    final now = _clock();
    final client = _injectedClient ?? http.Client();
    try {
      for (final item in List.of(queue)) {
        if (now.difference(item.firstQueuedAt) > maxAge ||
            item.attempts >= maxAttempts) {
          queue.remove(item);
          continue;
        }
        int? status;
        try {
          final response = await client
              .post(
                target.envelopeUri,
                headers: {
                  'content-type': 'application/x-sentry-envelope',
                  'x-sentry-auth': target.authHeader,
                },
                body: item.body,
              )
              .timeout(const Duration(seconds: 10));
          status = response.statusCode;
        } catch (_) {
          status = null;
        }
        final retry = status == null || status == 429 || status >= 500;
        if (retry) {
          item.attempts++;
          break; // Offline or throttled: keep the rest for later.
        }
        queue.remove(item); // Delivered, or refused for good (4xx).
      }
      await _save();
    } finally {
      if (_injectedClient == null) client.close();
    }
  }

  static Future<String> _packageRelease() async {
    final info = await PackageInfo.fromPlatform();
    return 'pandapay@${info.version}+${info.buildNumber}';
  }

  static String _eventId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  // ------------------------------------------------------------- pure parts

  /// Code locations only. Paths outside packages are cut to the file name.
  /// A trace from an obfuscated build has no file names; its frames become
  /// instruction offsets ([ObfuscatedTrace]), which the build's `.symbols`
  /// file turns back into file:line.
  static List<Map<String, Object?>> parseFrames(StackTrace? stack) {
    if (stack == null) return const [];
    final text = stack.toString();
    final symbolic = _symbolicFrames(text);
    if (symbolic.isNotEmpty) return symbolic;
    final obfuscated = ObfuscatedTrace.parse(text);
    if (obfuscated == null) return const [];
    return [
      for (final frame in obfuscated.frames.reversed)
        {
          if (frame.location != null) 'function': frame.location,
          if (frame.instructionAddress != null)
            'instruction_addr': frame.instructionAddress,
        },
    ]; // Oldest first, like the symbolic frames.
  }

  /// The obfuscated-build trace in [stack], or null for a normal trace.
  static ObfuscatedTrace? obfuscatedTraceOf(StackTrace? stack) {
    if (stack == null) return null;
    final text = stack.toString();
    return _symbolicFrames(text).isEmpty ? ObfuscatedTrace.parse(text) : null;
  }

  static List<Map<String, Object?>> _symbolicFrames(String text) {
    final pattern = RegExp(r'^#\d+\s+(.+?) \((.+?):(\d+)(?::(\d+))?\)$');
    final frames = <Map<String, Object?>>[];
    for (final line in text.split('\n')) {
      final m = pattern.firstMatch(line.trim());
      if (m == null) continue;
      var file = m.group(2)!;
      if (!file.startsWith('package:') && !file.startsWith('dart:')) {
        file = file.split('/').last;
      }
      frames.add({
        'filename': _cut(file, 200),
        'function': _cut(m.group(1)!, 120),
        'lineno': int.parse(m.group(3)!),
        if (m.group(4) != null) 'colno': int.parse(m.group(4)!),
        'in_app': file.startsWith(_appPackage),
      });
      if (frames.length >= 50) break;
    }
    return frames.reversed.toList(); // Sentry expects the oldest frame first.
  }

  static String errorType(Object error) =>
      _cut(error.runtimeType.toString(), 80);

  static Map<String, Object?>? _topAppFrame(List<Map<String, Object?>> frames) {
    for (final f in frames.reversed) {
      if (f['in_app'] == true) return f;
    }
    return frames.isEmpty ? null : frames.last;
  }

  /// `file:line` for a symbolic frame, the instruction offset otherwise.
  static String _where(Map<String, Object?> frame) => frame['filename'] != null
      ? '${frame['filename']}:${frame['lineno']}'
      : '${frame['function'] ?? frame['instruction_addr']}';

  static List<String> fingerprintFor(
    Object error,
    List<Map<String, Object?>> frames,
    String source, {
    String? buildId,
  }) {
    final top = _topAppFrame(frames);
    return [
      'app',
      errorType(error),
      source,
      top == null ? '-' : _where(top),
      // Offsets only mean something within one build.
      ?buildId,
    ];
  }

  static Map<String, Object?> buildEvent({
    required Object error,
    required List<Map<String, Object?>> frames,
    required String source,
    required List<String> fingerprint,
    required String release,
    required String environment,
    required String platform,
    required DateTime now,
    required String eventId,
    ObfuscatedTrace? obfuscated,
  }) {
    final top = _topAppFrame(frames);
    final where = top == null
        ? source
        : _where(top).replaceFirst(_appPackage, '');
    final buildId = obfuscated?.buildId;
    return {
      'event_id': eventId,
      'timestamp': now.toUtc().millisecondsSinceEpoch / 1000,
      'platform': 'dart',
      'level': 'error',
      'logger': 'app',
      'release': release,
      'environment': environment,
      'fingerprint': fingerprint,
      'tags': {'source': source, 'platform': platform, 'build_id': ?buildId},
      'contexts': {
        'os': {'name': platform},
      },
      // Offsets and build id only, ready for `flutter symbolize -i`.
      if (obfuscated != null)
        'extra': {'obfuscated_trace': obfuscated.toSymbolizeInput()},
      'exception': {
        'values': [
          {
            'type': errorType(error),
            // Where it happened, never the message.
            'value': where,
            'stacktrace': {'frames': frames},
          },
        ],
      },
    };
  }

  static String encodeEnvelope(Map<String, Object?> event, DateTime now) =>
      '${jsonEncode({'event_id': event['event_id'], 'sent_at': now.toUtc().toIso8601String()})}\n'
      '${jsonEncode({'type': 'event'})}\n'
      '${jsonEncode(event)}\n';

  static String _cut(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);
}

/// Where reports go, parsed from the DSN.
class ReportTarget {
  const ReportTarget(this.envelopeUri, this.authHeader);
  final Uri envelopeUri;
  final String authHeader;
}

/// Accepts `https://<public key>@<host>/<numeric project>`. Plain http only
/// for local development hosts in non-release builds.
ReportTarget? parseDsn(String dsn, {bool allowInsecureLocalhost = false}) {
  if (dsn.trim().isEmpty) return null;
  final uri = Uri.tryParse(dsn.trim());
  if (uri == null) return null;
  final project = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final key = uri.userInfo;
  final local = const {'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host);
  final secure =
      uri.scheme == 'https' ||
      (uri.scheme == 'http' && local && allowInsecureLocalhost);
  if (!secure ||
      !RegExp(r'^[A-Za-z0-9]{16,64}$').hasMatch(key) ||
      project.length != 1 ||
      !RegExp(r'^\d{1,12}$').hasMatch(project.single) ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return ReportTarget(
    uri.replace(userInfo: '', path: '/api/${project.single}/envelope/'),
    'Sentry sentry_version=7, sentry_client=pandapay-app/1.0, sentry_key=$key',
  );
}

class _Queued {
  _Queued({
    required this.body,
    required this.firstQueuedAt,
    required this.attempts,
  });

  final String body;
  final DateTime firstQueuedAt;
  int attempts;

  String encode() => jsonEncode({
    'b': body,
    't': firstQueuedAt.toUtc().toIso8601String(),
    'a': attempts,
  });

  static _Queued? tryDecode(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return _Queued(
        body: map['b'] as String,
        firstQueuedAt: DateTime.parse(map['t'] as String),
        attempts: map['a'] as int,
      );
    } catch (_) {
      return null;
    }
  }
}

/// App-wide instance used by the global error handlers.
final CrashReporter crashReporter = CrashReporter.fromEnvironment();
