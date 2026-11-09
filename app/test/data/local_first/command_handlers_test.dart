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

void main() {
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
