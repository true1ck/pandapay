import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Plan Phase 2.2 — first-party product analytics.
///
/// The closed event vocabulary. This enum and
/// `pandapay.is_known_analytics_event()` (migration 0032) must agree: an event
/// present in only one of them is a funnel step that silently reports zero
/// forever, which is a worse failure than a loud one because nobody notices it
/// for a quarter.
///
/// Names are snake_case on the wire to match the SQL side exactly, rather than
/// relying on a camelCase→snake_case conversion that would break the moment
/// someone adds an event with a digit or an acronym in it.
enum AnalyticsEvent {
  appOpened('app_opened'),
  onboardingStarted('onboarding_started'),
  onboardingCompleted('onboarding_completed'),
  accountCreated('account_created'),
  firstCardAdded('first_card_added'),
  secondCardAdded('second_card_added'),
  recommendationViewed('recommendation_viewed'),
  scanStarted('scan_started'),
  scanCompleted('scan_completed'),
  transactionLogged('transaction_logged'),
  comparisonViewed('comparison_viewed'),
  capWarningShown('cap_warning_shown'),
  insightViewed('insight_viewed'),
  importCompleted('import_completed'),
  acceptanceReportSubmitted('acceptance_report_submitted'),
  partnerApplyTapped('partner_apply_tapped'),
  guestWalletMigrated('guest_wallet_migrated'),
  deviceRevoked('device_revoked');

  final String wire;
  const AnalyticsEvent(this.wire);
}

/// Buffers events and flushes them in batches.
///
/// Three properties matter more than throughput here, and each one is a
/// deliberate constraint rather than an optimisation:
///
/// 1. **It can never break a user action.** Every failure path swallows.
///    Telemetry that can surface an error over someone adding a card has the
///    priority backwards.
/// 2. **It can never grow without bound.** The buffer is capped and drops the
///    OLDEST events when full — a device offline for a week must not
///    accumulate megabytes of unsent telemetry, and if something has to be
///    lost, recent behaviour is the more useful half to keep.
/// 3. **It carries no content.** The `props` allowlist is enforced
///    server-side, but this class also refuses to accept anything outside a
///    small set of dimensions, so a careless call site cannot even express
///    "log the merchant name" — see [track]'s assertion.
class Analytics {
  final String apiBaseUrl;
  final http.Client _client;

  /// Read at flush time rather than captured, so events queued while signed
  /// out and flushed after sign-in are attributed correctly — and, more
  /// importantly, so a sign-out immediately stops attributing.
  final String? Function() tokenReader;
  final String? appVersion;

  static const _maxBuffer = 200;
  static const _flushThreshold = 20;

  /// The only dimension keys the server will store (see
  /// `pandapay.filter_analytics_props`). Duplicated here so a call site
  /// passing something else fails loudly in debug rather than having the key
  /// silently dropped in production and the analysis quietly come out wrong.
  static const allowedPropKeys = {'source', 'placement', 'step', 'result', 'count_bucket', 'surface'};

  final List<Map<String, Object?>> _buffer = [];
  bool _flushing = false;

  Analytics({
    required this.apiBaseUrl,
    required this.tokenReader,
    this.appVersion,
    http.Client? client,
  }) : _client = client ?? http.Client();

  String get _platform {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    return 'other';
  }

  /// Records an event. Never awaits a network call, never throws.
  void track(AnalyticsEvent event, {Map<String, Object?> props = const {}}) {
    assert(
      props.keys.every(allowedPropKeys.contains),
      'Analytics props may only use $allowedPropKeys — got ${props.keys.toList()}. '
      'Anything else is dropped server-side, so the measurement would be silently wrong. '
      'Never pass merchant names, amounts, or card names.',
    );

    _buffer.add({
      'event': event.wire,
      'props': Map<String, Object?>.fromEntries(
        props.entries.where((e) => allowedPropKeys.contains(e.key)),
      ),
      'appVersion': appVersion,
      'platform': _platform,
    });

    // Drop the oldest, not the newest. A long offline stretch should cost the
    // stale half of the buffer, not the behaviour that just happened.
    while (_buffer.length > _maxBuffer) {
      _buffer.removeAt(0);
    }

    if (_buffer.length >= _flushThreshold) {
      unawaited(flush());
    }
    // No periodic timer. An earlier version kept a 30-second `Timer` alive for
    // the life of the app, which was wrong twice over: on a phone it holds the
    // event loop awake purely for telemetry, and it leaked into widget tests
    // as "a Timer is still pending after the widget tree was disposed" —
    // caught by the existing suite the moment analytics was wired into the
    // shell. Flushing is driven by the threshold above plus the app going to
    // the background (see analyticsLifecycleProvider), which is also the more
    // reliable trigger: it catches events that would otherwise be lost when
    // the OS kills a backgrounded app.
  }

  /// Sends whatever is buffered. Safe to call at any time, including
  /// concurrently — a second call while one is in flight is a no-op rather
  /// than a double-send.
  Future<void> flush() async {
    if (_flushing || _buffer.isEmpty) return;
    _flushing = true;

    // Taken out of the buffer up front so events tracked during the request
    // aren't lost by a clear-after-send, and restored on failure.
    final batch = List<Map<String, Object?>>.from(_buffer);
    _buffer.clear();

    try {
      final token = tokenReader();
      final response = await _client.post(
        Uri.parse('$apiBaseUrl/analytics/events'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'events': batch}),
      );
      if (response.statusCode != 202) {
        _restore(batch);
      }
    } catch (_) {
      // Offline or unreachable. Put them back and try on the next flush.
      _restore(batch);
    } finally {
      _flushing = false;
    }
  }

  void _restore(List<Map<String, Object?>> batch) {
    _buffer.insertAll(0, batch);
    while (_buffer.length > _maxBuffer) {
      _buffer.removeAt(0);
    }
  }

  void dispose() {
    _buffer.clear();
  }
}
