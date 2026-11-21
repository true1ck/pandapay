import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local_first/pending_overlays.dart';
import 'package:pandapay/data/user_cards_repository.dart';

class _Repo extends UserCardsRepository {
  _Repo() : super(apiBaseUrl: 'http://localhost', accessToken: 't');
  final calls = <String>[];

  @override
  Future<void> logLoungeVisit({
    required String userCardId,
    required String benefitId,
    required DateTime usedOn,
    String? airport,
    String? clientMutationId,
  }) async => calls.add('lounge $userCardId $benefitId $clientMutationId');

  @override
  Future<void> adjustPointsBalance(
    String userCardId, {
    required double newBalance,
    DateTime? expiresOn,
    String? reason,
    String? clientMutationId,
  }) async => calls.add('points $userCardId $newBalance $clientMutationId');
}

/// Records the time each delete / restore / leave-out was sent with, and
/// answers "stale" (a newer choice stands) when [stale] is true.
class _TxnRepo extends UserCardsRepository {
  _TxnRepo({this.stale = false})
    : super(apiBaseUrl: 'http://localhost', accessToken: 't');
  final bool stale;
  final calls = <String>[];

  @override
  Future<void> ignoreTransaction(
    String id, {
    required String reason,
    DateTime? editedAt,
    void Function()? onStale,
  }) async {
    calls.add('ignore $id $reason ${editedAt?.toIso8601String()}');
    if (stale) onStale?.call();
  }

  @override
  Future<void> restoreTransaction(
    String id, {
    DateTime? editedAt,
    void Function()? onStale,
  }) async {
    calls.add('restore $id ${editedAt?.toIso8601String()}');
    if (stale) onStale?.call();
  }

  @override
  Future<void> setSpendExclusion(
    String id, {
    required bool excluded,
    DateTime? editedAt,
    void Function()? onStale,
  }) async {
    calls.add('exclude $id $excluded ${editedAt?.toIso8601String()}');
    if (stale) onStale?.call();
  }
}

void main() {
  test('delete, restore and leave out are sent with the time the person acted', () async {
    final repo = _TxnRepo();
    final handlers = commandHandlersFor(repo);
    await handlers[OutboxCommand.ignoreTransaction]!({
      'id': 't1',
      'reason': 'refund',
      'editedAt': '2026-11-20T09:00:00.000Z',
    });
    await handlers[OutboxCommand.restoreTransaction]!({
      'id': 't1',
      'editedAt': '2026-11-20T09:01:00.000Z',
    });
    await handlers[OutboxCommand.setSpendExclusion]!({
      'id': 't1',
      'excluded': true,
      'editedAt': '2026-11-20T09:02:00.000Z',
    });
    expect(repo.calls, [
      'ignore t1 refund 2026-11-20T09:00:00.000Z',
      'restore t1 2026-11-20T09:01:00.000Z',
      'exclude t1 true 2026-11-20T09:02:00.000Z',
    ]);
  });

  test('a command queued before the time existed is still sent, without one', () async {
    final repo = _TxnRepo();
    final handlers = commandHandlersFor(repo);
    await handlers[OutboxCommand.ignoreTransaction]!({'id': 't1', 'reason': 'refund'});
    await handlers[OutboxCommand.restoreTransaction]!({'id': 't1'});
    await handlers[OutboxCommand.setSpendExclusion]!({'id': 't1', 'excluded': false});
    expect(repo.calls, ['ignore t1 refund null', 'restore t1 null', 'exclude t1 false null']);
  });

  test('when the server kept a newer choice, the transaction is reported to be re-read', () async {
    final repo = _TxnRepo(stale: true);
    final stale = <String>[];
    final handlers = commandHandlersFor(repo, onStaleTransactionEdit: stale.add);
    await handlers[OutboxCommand.ignoreTransaction]!({'id': 'a', 'reason': 'refund'});
    await handlers[OutboxCommand.restoreTransaction]!({'id': 'b'});
    await handlers[OutboxCommand.setSpendExclusion]!({'id': 'c', 'excluded': true});
    expect(stale, ['a', 'b', 'c']);

    final fresh = <String>[];
    final ordinary = commandHandlersFor(_TxnRepo(), onStaleTransactionEdit: fresh.add);
    await ordinary[OutboxCommand.ignoreTransaction]!({'id': 'a', 'reason': 'refund'});
    expect(fresh, isEmpty);
  });

  test('queued lounge visits and point corrections carry their request id', () async {
    final repo = _Repo();
    final handlers = commandHandlersFor(repo);

    await handlers[OverlayCommand.loungeVisit]!({
      'userCardId': 'c1',
      'benefitId': 'b1',
      'usedOn': '2026-11-09',
      'airport': null,
      'clientMutationId': 'm-lounge',
    });
    await handlers[OverlayCommand.pointsAdjust]!({
      'userCardId': 'c1',
      'newBalance': 1200.0,
      'clientMutationId': 'm-points',
    });

    expect(repo.calls, ['lounge c1 b1 m-lounge', 'points c1 1200.0 m-points']);
  });
}
