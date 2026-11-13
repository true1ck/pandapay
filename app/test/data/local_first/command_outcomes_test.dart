import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/user_cards_repository.dart';

/// Records the calls and answers ignore/restore with a canned error.
class _Server extends UserCardsRepository {
  _Server({this.ignoreError, this.restoreError})
    : super(apiBaseUrl: 'http://test', accessToken: 'tok');
  final Object? ignoreError;
  final Object? restoreError;
  final List<String> calls = [];

  @override
  Future<void> ignoreTransaction(String id, {required String reason}) async {
    calls.add('ignore $id $reason');
    if (ignoreError != null) throw ignoreError!;
  }

  @override
  Future<void> restoreTransaction(String id) async {
    calls.add('restore $id');
    if (restoreError != null) throw restoreError!;
  }
}

ApiException _http(String route, int status, String error) =>
    ApiException('POST $route failed: $status {"error":"$error"}');

void main() {
  Future<void> run(_Server server, String kind, Map<String, Object?> payload) =>
      commandHandlersFor(server)[kind]!(payload);

  group('ignore replays (SRV-17)', () {
    test('409 already ignored is success for a plain ignore', () async {
      final server = _Server(
        ignoreError: _http('ignore', 409, "transaction is already 'ignored'"),
      );
      await run(server, OutboxCommand.ignoreTransaction, {
        'id': 't1',
        'reason': 'refund',
      });
      expect(server.calls, ['ignore t1 refund']);
    });

    test('409 already deleted is success for a delete (reason transfer)',
        () async {
      final server = _Server(
        ignoreError: _http('ignore', 409, "transaction is already 'deleted'"),
      );
      await run(server, OutboxCommand.ignoreTransaction, {
        'id': 't1',
        'reason': 'transfer',
      });
    });

    test('409 with a different state is still an error', () async {
      final server = _Server(
        ignoreError: _http('ignore', 409, "transaction is already 'deleted'"),
      );
      await expectLater(
        run(server, OutboxCommand.ignoreTransaction, {
          'id': 't1',
          'reason': 'refund',
        }),
        throwsA(isA<ApiException>()),
      );
    });

    test('404 means the transaction is gone, which is done', () async {
      final server = _Server(
        ignoreError: _http('ignore', 404, 'transaction not found'),
      );
      await run(server, OutboxCommand.ignoreTransaction, {
        'id': 't1',
        'reason': 'refund',
      });
    });

    test('other failures still propagate', () async {
      for (final status in [400, 500, 503]) {
        final server = _Server(ignoreError: _http('ignore', status, 'x'));
        await expectLater(
          run(server, OutboxCommand.ignoreTransaction, {
            'id': 't1',
            'reason': 'refund',
          }),
          throwsA(isA<ApiException>()),
          reason: '$status',
        );
      }
    });
  });

  group('restore replays (SRV-17)', () {
    test('404 (already active or gone) is success', () async {
      final server = _Server(
        restoreError: _http('restore', 404, 'deleted transaction not found'),
      );
      await run(server, OutboxCommand.restoreTransaction, {'id': 't1'});
      expect(server.calls, ['restore t1']);
    });

    test('other failures still propagate', () async {
      final server = _Server(restoreError: _http('restore', 500, 'x'));
      await expectLater(
        run(server, OutboxCommand.restoreTransaction, {'id': 't1'}),
        throwsA(isA<ApiException>()),
      );
    });

    test('a first-time restore succeeds normally', () async {
      final server = _Server();
      await run(server, OutboxCommand.restoreTransaction, {'id': 't1'});
      expect(server.calls, ['restore t1']);
    });
  });
}
