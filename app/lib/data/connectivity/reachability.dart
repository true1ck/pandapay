import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../app/env.dart';
import 'known_connectivity.dart';

/// Is the PandaPay API actually reachable, as opposed to "the radio is up"
/// (WP-C1, finding C-02).
///
/// `connectivity_plus` only reports interface state. On captive or dead Wi-Fi
/// it says "online" while every request waits 15-30 s before failing, so every
/// network-first read burns that wait before its cache fallback. This class
/// answers the narrower question with one cheap, cached, never-throwing probe
/// of the existing public `GET /app-status` (no auth, no user data).
///
/// Rules:
/// * the radio down means unreachable, with no probe;
/// * a result is cached for [ttl] (success) or [failureTtl] (failure, short so
///   a recovered network is noticed quickly) and expires to "unknown" (`null`),
///   never to a stale answer;
/// * concurrent callers share one probe;
/// * a connectivity change or app resume should call [invalidate];
/// * [check] never throws and never takes longer than [timeout].
///
/// Intended use (documented in docs/offline/WP-C1.md, wired in by later
/// packages): a background, non-user-initiated read does
/// `if (reachability.shouldSkipBackgroundReads) return cached;` and a
/// user-initiated read that is about to wait on the network may
/// `await reachability.check()` first (worst case [timeout]) instead of
/// waiting 15-30 s.
class ServerReachability {
  ServerReachability({
    required Future<bool> Function() probe,
    bool Function()? radioUp,
    DateTime Function()? now,
    this.ttl = const Duration(seconds: 20),
    this.failureTtl = const Duration(seconds: 8),
    this.timeout = const Duration(milliseconds: 1800),
  }) : _probe = probe,
       _radioUp = radioUp ?? (() => !KnownConnectivity.knownOffline),
       _now = now ?? DateTime.now;

  final Future<bool> Function() _probe;
  final bool Function() _radioUp;
  final DateTime Function() _now;
  final Duration ttl;
  final Duration failureTtl;
  final Duration timeout;

  bool? _value;
  DateTime? _at;
  Future<bool>? _inFlight;
  int _generation = 0;
  bool? _lastEmitted;
  final _changes = StreamController<bool>.broadcast();

  /// Emits when the cached answer flips (first answer included).
  Stream<bool> get changes => _changes.stream;

  /// Synchronous view, safe to read from `build`. `false` when the radio is
  /// down or the last probe failed recently, `true` when it succeeded
  /// recently, `null` when unknown or expired. Never probes and never blocks.
  bool? get serverReachable {
    if (!_radioUp()) return false;
    final value = _value;
    final at = _at;
    if (value == null || at == null) return null;
    final age = _now().difference(at);
    return age < (value ? ttl : failureTtl) ? value : null;
  }

  /// True only when the server is *known* to be unreachable right now. Unknown
  /// is not a reason to skip: unprobed behaviour stays exactly as it was.
  bool get shouldSkipBackgroundReads => serverReachable == false;

  /// Probes (or reuses the cached answer). Never throws.
  Future<bool> check({bool force = false}) {
    if (!_radioUp()) return Future<bool>.value(false);
    if (!force) {
      final cached = serverReachable;
      if (cached != null) return Future<bool>.value(cached);
    }
    final running = _inFlight;
    if (running != null) return running;

    final generation = _generation;
    late final Future<bool> future;
    future = _run().then((ok) {
      if (generation == _generation) {
        _value = ok;
        _at = _now();
        _inFlight = null;
        if (_lastEmitted != ok) {
          _lastEmitted = ok;
          if (!_changes.isClosed) _changes.add(ok);
        }
      } else if (identical(_inFlight, future)) {
        _inFlight = null;
      }
      return ok;
    });
    _inFlight = future;
    return future;
  }

  Future<bool> _run() async {
    try {
      return await _probe().timeout(timeout);
    } catch (_) {
      return false;
    }
  }

  /// Forgets the cached answer (network changed, app resumed). A probe that is
  /// already running will not be cached when it lands.
  void invalidate() {
    _generation++;
    _value = null;
    _at = null;
    _inFlight = null;
  }

  void dispose() {
    invalidate();
    _changes.close();
  }
}

/// One `GET /app-status`. Reachable only when the answer is a 200 carrying a
/// JSON object: captive portals answer 200 with HTML (or redirect to one), and
/// a 5xx means the API is not serving.
Future<bool> httpServerProbe(http.Client client, String baseUrl) async {
  try {
    final response = await client.get(Uri.parse('$baseUrl/app-status'));
    if (response.statusCode != 200) return false;
    return jsonDecode(response.body) is Map;
  } catch (_) {
    return false;
  }
}

/// The app-wide probe. Override in tests with a fake [ServerReachability].
final serverReachabilityProvider = Provider<ServerReachability>((ref) {
  final client = http.Client();
  final reachability = ServerReachability(
    probe: () => httpServerProbe(client, Env.apiBaseUrl),
  );
  ref.onDispose(() {
    reachability.dispose();
    client.close();
  });
  return reachability;
});

/// Reactive view of [ServerReachability.serverReachable] for widgets:
/// `true`/`false` when known, `null` when unknown. Rebuilds on a flip or when
/// the radio state changes (the latter through `isOnlineProvider` consumers).
final serverReachableProvider = Provider<bool?>((ref) {
  final reachability = ref.watch(serverReachabilityProvider);
  final sub = reachability.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(sub.cancel);
  return reachability.serverReachable;
});
