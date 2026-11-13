import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/duplicate_resolution_outbox.dart';
import 'package:pandapay/data/user_cards_repository.dart';

class _FakeUserCardsRepository extends UserCardsRepository {
  _FakeUserCardsRepository({this.failure})
    : super(apiBaseUrl: 'http://test', accessToken: 'tok');

  final Object? failure;
  final List<Map<String, String?>> sent = [];
  var calls = 0;

  @override
  Future<void> resolveDuplicateCandidate(
    String id, {
    required String resolution,
    String? keepTransactionId,
  }) async {
    calls++;
    if (failure != null) throw failure!;
    sent.add({
      'id': id,
      'resolution': resolution,
      'keepTransactionId': keepTransactionId,
    });
  }
}

void main() {
  late AppDatabase appDb;
  late DuplicateResolutionOutboxRepository outbox;

  setUp(() {
    appDb = openInMemoryForTesting();
    outbox = DuplicateResolutionOutboxRepository(appDb, namespace: 'user:a');
  });

  tearDown(() => appDb.close());

  test('coalesces a changed decision for the same candidate', () {
    outbox.enqueue(
      candidateId: 'pair-1',
      resolution: 'merged',
      keepTransactionId: 'txn-a',
    );
    outbox.enqueue(candidateId: 'pair-1', resolution: 'kept_both');

    final pending = outbox.pending();
    expect(pending, hasLength(1));
    expect(pending.single.resolution, 'kept_both');
    expect(pending.single.keepTransactionId, isNull);
  });

  test('flush removes successful resolutions', () async {
    outbox.enqueue(
      candidateId: 'pair-1',
      resolution: 'merged',
      keepTransactionId: 'txn-a',
    );
    final repo = _FakeUserCardsRepository();

    expect(await outbox.flush(repo), 1);
    expect(outbox.pending(), isEmpty);
    expect(repo.sent.single['keepTransactionId'], 'txn-a');
  });

  test('flush bounds a large backlog and resumes oldest intents', () async {
    for (var i = 0; i < 25; i++) {
      outbox.enqueue(candidateId: 'pair-$i', resolution: 'kept_both');
    }
    final repo = _FakeUserCardsRepository();

    expect(await outbox.flush(repo, maxEntries: 20), 20);
    expect(repo.sent, hasLength(20));
    expect(outbox.pending(), hasLength(5));
    expect(await outbox.flush(repo, maxEntries: 20), 5);
    expect(outbox.pending(), isEmpty);
  });

  test(
    'already-resolved responses are treated as successful retries',
    () async {
      outbox.enqueue(candidateId: 'pair-1', resolution: 'kept_both');
      final repo = _FakeUserCardsRepository(
        failure: ApiException(
          'POST /duplicate-candidates/pair-1/resolve failed: 409 '
          '{"error":"already resolved (merged)"}',
        ),
      );

      expect(await outbox.flush(repo), 1);
      expect(outbox.pending(), isEmpty);
    },
  );

  test('stale missing candidates are treated as successful retries', () async {
    outbox.enqueue(candidateId: 'pair-1', resolution: 'kept_both');
    final repo = _FakeUserCardsRepository(
      failure: ApiException(
        'POST /duplicate-candidates/pair-1/resolve failed: 404 '
        '{"error":"duplicate_candidate not found"}',
      ),
    );

    expect(await outbox.flush(repo), 1);
    expect(outbox.pending(), isEmpty);
  });

  test('failed resolutions remain durable for a later retry', () async {
    outbox.enqueue(candidateId: 'pair-1', resolution: 'kept_both');
    final repo = _FakeUserCardsRepository(failure: StateError('offline'));

    expect(await outbox.flush(repo), 0);
    final pending = outbox.pending();
    expect(pending, hasLength(1));
    expect(pending.single.attempts, 1);
    expect(pending.single.lastError, contains('offline'));
  });

  test('blocked resolutions wait for an explicit retry', () async {
    outbox.enqueue(candidateId: 'pair-1', resolution: 'kept_both');
    final repo = _FakeUserCardsRepository(failure: StateError('offline'));

    for (var attempt = 0; attempt < 5; attempt++) {
      await outbox.flush(repo);
    }
    expect(repo.calls, 5);
    expect(outbox.pending().single.attempts, 5);

    expect(await outbox.flush(repo), 0);
    expect(repo.calls, 5);
    expect(outbox.resetBlocked(), 1);
    await outbox.flush(repo);
    expect(repo.calls, 6);
  });

  group('queue hygiene (Q-02)', () {
    for (final error in <Object>[
      const SocketException('no route'),
      TimeoutException('slow'),
      http.ClientException('closed'),
      ApiException('failed: 401 {"error":"unauthorized"}'),
    ]) {
      test('${error.runtimeType} never counts toward the 5-attempt block',
          () async {
        outbox.enqueue(candidateId: 'pair-1', resolution: 'kept_both');
        final offline = _FakeUserCardsRepository(failure: error);
        for (var i = 0; i < 12; i++) {
          expect(await outbox.flush(offline), 0);
        }
        final entry = outbox.pending().single;
        expect(entry.attempts, 0);
        expect(entry.lastError, isNotNull);
        // Back online: it is still deliverable without an explicit retry.
        final online = _FakeUserCardsRepository();
        expect(await outbox.flush(online), 1);
        expect(outbox.pending(), isEmpty);
      });
    }

    test('a network failure ends the pass instead of timing out per entry',
        () async {
      for (var i = 0; i < 5; i++) {
        outbox.enqueue(candidateId: 'pair-$i', resolution: 'kept_both');
      }
      final offline = _FakeUserCardsRepository(
        failure: const SocketException('offline'),
      );
      await outbox.flush(offline);
      expect(offline.calls, 1);
    });

    test('a permanent 4xx blocks immediately, not after five tries', () async {
      outbox.enqueue(candidateId: 'pair-1', resolution: 'kept_both');
      final refusing = _FakeUserCardsRepository(
        failure: ApiException(
          'POST /duplicate-candidates/pair-1/resolve failed: 400 '
          '{"error":"bad resolution"}',
        ),
      );
      await outbox.flush(refusing);
      expect(refusing.calls, 1);
      expect(outbox.pending().single.attempts, greaterThanOrEqualTo(5));
      await outbox.flush(refusing);
      expect(refusing.calls, 1, reason: 'blocked until an explicit retry');
      expect(outbox.resetBlocked(), 1);
      await outbox.flush(refusing);
      expect(refusing.calls, 2);
    });

    test('server errors still count and block after five', () async {
      outbox.enqueue(candidateId: 'pair-1', resolution: 'kept_both');
      final failing = _FakeUserCardsRepository(
        failure: ApiException('POST failed: 503 {"error":"unavailable"}'),
      );
      for (var i = 0; i < 7; i++) {
        await outbox.flush(failing);
      }
      expect(failing.calls, 5);
      expect(outbox.pending().single.attempts, 5);
    });
  });
}
