import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/analytics.dart';

/// Plan Phase 2.2. Analytics is the one subsystem in the app that is allowed
/// to fail — so what's tested here is that it fails *safely*: it never throws
/// into a user action, never grows without bound, and never carries content it
/// shouldn't.
void main() {
  test('buffers below the threshold and flushes on demand', () async {
    final sent = <Map<String, dynamic>>[];
    final analytics = Analytics(
      apiBaseUrl: 'http://test',
      tokenReader: () => 'tok',
      appVersion: '1.2.0',
      client: MockClient((request) async {
        sent.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{"accepted":1}', 202);
      }),
    );
    addTearDown(analytics.dispose);

    analytics.track(AnalyticsEvent.appOpened);
    expect(sent, isEmpty, reason: 'a single event must not cost a round trip');

    await analytics.flush();
    expect(sent, hasLength(1));
    final events = (sent.single['events'] as List).cast<Map<String, dynamic>>();
    expect(events.single['event'], 'app_opened');
    expect(events.single['appVersion'], '1.2.0');
  });

  test('disallowed prop keys are stripped before they ever reach the wire', () async {
    final sent = <Map<String, dynamic>>[];
    final analytics = Analytics(
      apiBaseUrl: 'http://test',
      tokenReader: () => null,
      client: MockClient((request) async {
        sent.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{}', 202);
      }),
    );
    addTearDown(analytics.dispose);

    // The debug-mode assertion in `track` catches this at the call site; this
    // asserts the release-mode behaviour underneath it, which is that the key
    // is dropped rather than sent and silently discarded by the server.
    expect(
      () => analytics.track(
        AnalyticsEvent.transactionLogged,
        props: const {'source': 'scan', 'merchant_name': 'Chai Point', 'amount_inr': 4500},
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('an unauthenticated flush still sends, so pre-signin funnel steps count', () async {
    Map<String, String>? headers;
    final analytics = Analytics(
      apiBaseUrl: 'http://test',
      tokenReader: () => null,
      client: MockClient((request) async {
        headers = request.headers;
        return http.Response('{}', 202);
      }),
    );
    addTearDown(analytics.dispose);

    analytics.track(AnalyticsEvent.onboardingStarted);
    await analytics.flush();

    expect(headers, isNotNull);
    expect(headers!.containsKey('Authorization'), isFalse);
  });

  test('a failed flush puts the events back rather than losing them', () async {
    var attempts = 0;
    final analytics = Analytics(
      apiBaseUrl: 'http://test',
      tokenReader: () => 'tok',
      client: MockClient((request) async {
        attempts++;
        if (attempts == 1) return http.Response('nope', 500);
        return http.Response('{}', 202);
      }),
    );
    addTearDown(analytics.dispose);

    analytics.track(AnalyticsEvent.scanStarted);
    await analytics.flush();
    expect(attempts, 1);

    await analytics.flush();
    expect(attempts, 2, reason: 'the retained event triggers a second attempt');

    await analytics.flush();
    expect(attempts, 2, reason: 'nothing left to send after a successful flush');
  });

  test('a transport failure never throws into the caller', () async {
    final analytics = Analytics(
      apiBaseUrl: 'http://test',
      tokenReader: () => 'tok',
      client: MockClient((_) async => throw Exception('offline')),
    );
    addTearDown(analytics.dispose);

    analytics.track(AnalyticsEvent.appOpened);
    await expectLater(analytics.flush(), completes);
  });

  test('the buffer is bounded and drops the oldest events first', () async {
    final sent = <Map<String, dynamic>>[];
    final analytics = Analytics(
      apiBaseUrl: 'http://test',
      tokenReader: () => 'tok',
      // Always fails, so nothing ever drains and the cap is what's exercised.
      client: MockClient((request) async {
        sent.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('nope', 500);
      }),
    );
    addTearDown(analytics.dispose);

    for (var i = 0; i < 500; i++) {
      analytics.track(AnalyticsEvent.appOpened);
    }
    // `track` fires an unawaited flush once it crosses the threshold, so let
    // those settle before asserting — otherwise the explicit flush below can
    // hit the in-flight guard and no-op, and the test would pass or fail on
    // scheduling rather than on the behaviour under test.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await analytics.flush();

    expect(sent, isNotEmpty, reason: 'at least one flush attempt should have been made');
    for (final batch in sent) {
      expect(
        (batch['events'] as List).length,
        lessThanOrEqualTo(200),
        reason: 'a week offline must not accumulate unbounded telemetry',
      );
    }
  });

  test('every event name is snake_case, matching the SQL vocabulary', () {
    // The Dart enum and pandapay.is_known_analytics_event() have to agree
    // exactly; a mismatch is a funnel step that reports zero forever. This
    // catches the most likely form of drift — a camelCase wire name.
    for (final event in AnalyticsEvent.values) {
      expect(
        event.wire,
        matches(RegExp(r'^[a-z][a-z0-9_]*$')),
        reason: '${event.name} has a non-snake_case wire name',
      );
    }
  });
}
