import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/connectivity/server_backoff.dart';
import 'package:pandapay/data/local/queue_retry_policy.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 14, 12);

  test('parses seconds and HTTP dates, ignores junk', () {
    expect(ServerBackoff.parseRetryAfter('7', t0), const Duration(seconds: 7));
    expect(ServerBackoff.parseRetryAfter(' 0 ', t0), isNull);
    expect(ServerBackoff.parseRetryAfter('soon', t0), isNull);
    expect(ServerBackoff.parseRetryAfter(null, t0), isNull);
    expect(
      ServerBackoff.parseRetryAfter('Sat, 14 Nov 2026 12:00:30 GMT', t0),
      const Duration(seconds: 30),
    );
    expect(
      ServerBackoff.parseRetryAfter('Sat, 14 Nov 2026 11:00:00 GMT', t0),
      isNull,
    );
  });

  test('only 429 and 503 pause; delay is header + <=25% jitter, capped', () {
    final b = ServerBackoff.test(now: () => t0, random: Random(1));
    b.noteResponse(500, '5');
    b.noteResponse(200, '5');
    expect(b.isPaused, isFalse);
    b.noteResponse(503, '10');
    expect(b.isPaused, isTrue);
    expect(b.remaining, greaterThanOrEqualTo(const Duration(seconds: 10)));
    expect(b.remaining, lessThanOrEqualTo(const Duration(milliseconds: 12500)));
    b.noteResponse(429, '99999');
    expect(b.remaining, ServerBackoff.maxDelay);
    b.resetForTest();
    b.noteResponse(429, null);
    expect(b.remaining, greaterThanOrEqualTo(ServerBackoff.defaultDelay));
    b.resetForTest();
  });

  test('a shorter later hint never shortens the pause', () {
    final b = ServerBackoff.test(now: () => t0, random: Random(1));
    b.noteResponse(503, '100');
    final first = b.remaining;
    b.noteResponse(503, '1');
    expect(b.remaining, first);
    b.resetForTest();
  });

  test('queue backoff jitter stays within +20%', () {
    for (var i = 1; i <= 8; i++) {
      final base = queueBackoff(i);
      final j = queueBackoffJittered(i, random: Random(i));
      expect(j, greaterThanOrEqualTo(base));
      expect(
        j.inMilliseconds,
        lessThanOrEqualTo((base.inMilliseconds * 1.2).ceil()),
      );
    }
  });
}
