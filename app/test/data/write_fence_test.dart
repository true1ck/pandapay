import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/connectivity/write_fence.dart';

void main() {
  group('WriteFence', () {
    test(
      'a read begun after the last write is current; one begun before is not',
      () {
        final fence = WriteFence();
        final early = fence.begin();
        expect(fence.changedSince(early), isFalse);

        fence.markAcked();
        expect(fence.changedSince(early), isTrue);

        final late = fence.begin();
        expect(
          fence.changedSince(late),
          isFalse,
          reason: 'began after the write',
        );
      },
    );

    test('two writes in the same millisecond are still ordered', () {
      final fixed = DateTime(2026, 11, 18, 9);
      final fence = WriteFence(now: () => fixed);
      final token = fence.begin();
      fence.markAcked();
      fence.markAcked();
      expect(fence.changedSince(token), isTrue);
    });

    test('a snapshot stored before the last acknowledged write is stale', () {
      var clock = DateTime(2026, 11, 18, 9);
      final fence = WriteFence(now: () => clock);
      final storedEarlier = DateTime(2026, 11, 18, 8, 59);
      expect(
        fence.isSnapshotStale(storedEarlier),
        isFalse,
        reason: 'no write yet',
      );

      fence.markAcked();
      expect(fence.isSnapshotStale(storedEarlier), isTrue);

      clock = DateTime(2026, 11, 18, 9, 5);
      expect(fence.isSnapshotStale(clock), isFalse, reason: 'stored after it');
    });

    test('which requests count as data writes', () {
      bool counts(String m, String p) => WriteFence.countsAsDataWrite(m, p);

      // Reads never count.
      expect(counts('GET', '/transactions'), isFalse);
      expect(counts('HEAD', '/transactions'), isFalse);
      expect(counts('OPTIONS', '/transactions'), isFalse);

      // Writes to data a screen reads back do.
      expect(counts('POST', '/transactions'), isTrue);
      expect(counts('PATCH', '/transactions/abc'), isTrue);
      expect(counts('PUT', '/transactions/abc/spend-exclusion'), isTrue);
      expect(counts('DELETE', '/budgets/1'), isTrue);
      expect(
        counts('post', '/sync/push'),
        isTrue,
        reason: 'method is case-blind',
      );
      expect(counts('POST', '/sms/v2/facts:batch'), isTrue);
      // A brand new endpoint is covered without anyone listing it.
      expect(counts('POST', '/some-new-thing'), isTrue);

      // Bookkeeping that changes nothing a screen reads must not make every
      // read in flight look out of date.
      expect(counts('POST', '/analytics/events'), isFalse);
      expect(counts('POST', '/sync/ack'), isFalse);
      expect(counts('POST', '/sync/register-device'), isFalse);
      expect(counts('POST', '/notification-devices'), isFalse);
      expect(counts('POST', '/sms/v2/client-metrics'), isFalse);
      // A prefix is a path segment, not a string prefix.
      expect(counts('POST', '/analytics-export'), isTrue);
    });
  });

  group('readFenced / readAfterWrites', () {
    test('an answer with no write meanwhile is current, read once', () async {
      final fence = WriteFence();
      var calls = 0;
      final answer = await readFenced(() async => ++calls, fence: fence);
      expect(answer.current, isTrue);
      expect(answer.value, 1);
      expect(calls, 1);
    });

    test(
      'a write during the read makes it ask again and return the newer answer',
      () async {
        final fence = WriteFence();
        var calls = 0;
        final answer = await readFenced(() async {
          calls++;
          if (calls == 1) fence.markAcked(); // acknowledged while in flight
          return calls;
        }, fence: fence);
        expect(calls, 2);
        expect(answer.current, isTrue);
        expect(answer.value, 2);
      },
    );

    test(
      'writes during every attempt: not current, after retries+1 reads',
      () async {
        final fence = WriteFence();
        var calls = 0;
        final answer = await readFenced(() async {
          fence.markAcked();
          return ++calls;
        }, fence: fence);
        expect(calls, WriteFence.defaultRetries + 1);
        expect(answer.current, isFalse);
        expect(
          answer.value,
          calls,
          reason: 'the last answer, to show never store',
        );
      },
    );

    test('readAfterWrites is null when it could not be made certain', () async {
      final fence = WriteFence();
      final value = await readAfterWrites(() async {
        fence.markAcked();
        return 7;
      }, fence: fence);
      expect(value, isNull);

      expect(await readAfterWrites(() async => 7, fence: fence), 7);
    });

    test('a read that is itself null is told apart from a stale one', () async {
      final fence = WriteFence();
      final none = await readFenced<int?>(() async => null, fence: fence);
      expect(none.current, isTrue);
      expect(none.value, isNull);
    });

    test('an error from the read is not swallowed', () async {
      final fence = WriteFence();
      await expectLater(
        readFenced<int>(() async => throw StateError('offline'), fence: fence),
        throwsStateError,
      );
    });
  });
}
