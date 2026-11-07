import '../../../data/portable_backup/account_recovery_operation_gate.dart';
import '../data/shared_transport.dart';
import '../storage/shared_store.dart';

/// One bounded account generation. Root owns scheduling, HTTP and lifecycle;
/// this worker never signs in, regenerates IDs, changes sources or coalesces.
class SharedExpensesSync {
  final SharedExpensesStore store;
  final SharedExpensesTransport remote;
  final bool Function() isCurrent;
  final int Function() now;
  final String leaseId;
  bool _running = false;
  SharedExpensesSync({
    required this.store,
    required this.remote,
    required this.isCurrent,
    required this.now,
    required this.leaseId,
  });

  Future<void> flush({int maxCommands = 20}) async {
    if (_running || !isCurrent()) return;
    if (maxCommands < 1 || maxCommands > 100) {
      throw ArgumentError.value(maxCommands, 'maxCommands');
    }
    _running = true;
    try {
      await store.recoveryGate.run(() async {
        for (var index = 0; index < maxCommands && isCurrent(); index++) {
          final claim = await store.claim(now: now(), leaseId: leaseId);
          if (claim == null) break;
          try {
            final known = await remote.lookupOperation(
              claim.command.operationId,
            );
            if (!isCurrent()) break;
            final response = known ?? await remote.execute(claim.command);
            if (!isCurrent()) break;
            await store.complete(claim, response.receipt, response.records);
          } catch (error) {
            if (!isCurrent()) break;
            if (error is AccountRecoveryBusy) rethrow;
            if (error is SharedLocalException) {
              await store.fail(claim, statusCode: 422, now: now());
              break;
            }
            final status = error is SharedTransportException
                ? error.statusCode
                : null;
            await store.fail(
              claim,
              statusCode: status,
              retryable: error is SharedTransportException && error.retryable,
              serverCode: error is SharedTransportException ? error.code : null,
              existingContextId: error is SharedTransportException
                  ? error.existingContextId
                  : null,
              now: now(),
            );
            if (status == null ||
                status == 401 ||
                status == 408 ||
                status == 429 ||
                status >= 500) {
              break;
            }
          }
        }
      });
    } finally {
      _running = false;
    }
  }

  Future<void> pull() async {
    if (!isCurrent()) return;
    await store.recoveryGate.run(() async {
      final cursor = store.cursor;
      final page = await remote.pull(cursor: cursor, limit: 100);
      if (!isCurrent()) return;
      await store.applyPage(page, expectedCursor: cursor);
    });
  }
}
