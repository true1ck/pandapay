import 'package:flutter_test/flutter_test.dart';
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
}
