import '../api_exception.dart';

/// Replay-safe outcomes for queued commands (SRV-17).
///
/// A command may be sent twice (the reply was lost, or another device already
/// did it). The server answers the second call with an error even though the
/// state the person wanted is already in place. These helpers turn exactly
/// those answers into success, so the command leaves the queue instead of
/// being parked as a "refusal" the person cannot act on.

/// Runs [call]; a 404 means the target is already gone, which is what a delete
/// wanted anyway.
Future<void> goneIsDone(Future<void> Function() call) async {
  try {
    await call();
  } on ApiException catch (error) {
    if (!_serverSaid404(error)) rethrow;
  }
}

/// `POST /transactions/:id/ignore`. A second call answers 409
/// `transaction is already '<status>'`; that is success when the status is
/// the one this reason produces (`transfer` soft-deletes, every other reason
/// ignores). A 404 means the transaction no longer exists. A 409 for the other
/// status is kept as the error it is.
Future<void> ignoreAlreadyDoneIsDone(
  Future<void> Function() call, {
  required String reason,
}) async {
  try {
    await call();
  } on ApiException catch (error) {
    final status = error.statusCode;
    if (_serverSaid404(error)) return;
    if (status == 409 && _alreadyHas(error, reason == 'transfer' ? 'deleted' : 'ignored')) {
      return;
    }
    rethrow;
  }
}

/// `POST /transactions/:id/restore`. The server only restores rows that are
/// ignored or deleted, so a second call (or a call after another device
/// restored it) answers 404, which means it is already active or gone.
Future<void> restoreAlreadyDoneIsDone(Future<void> Function() call) =>
    goneIsDone(call);

/// A 404 only counts when it carries the server's own JSON error; a proxy or
/// captive-portal page also answers 404 and must not delete the command.
bool _serverSaid404(ApiException error) =>
    error.statusCode == 404 && error.errorCode != null;

bool _alreadyHas(ApiException error, String state) {
  final text = (error.errorCode ?? '').toLowerCase();
  return text.contains("already '$state'") ||
      text.contains('already "$state"') ||
      text.contains('already $state');
}
