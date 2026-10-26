import 'dart:async';

import 'import_repository.dart';
import 'local/statement_import_outbox.dart';
import 'portable_backup/account_recovery_operation_gate.dart';
import 'transaction_import_pipeline.dart' show ImportProgress;

/// Explicit, foreground-only continuation of prepared statement POSTs.
/// Payloads are encrypted by [outbox] before the first send. A batch remains
/// pending until a settled response carries the server's receiptVersion 1.
class StatementImportContinuation {
  final StatementImportOutbox outbox;
  final void Function() checkAccountUnchanged;
  final Future<StatementImport> Function(Map<String, dynamic>) sendPrepared;
  final AccountRecoveryOperationGate gate;
  bool _running = false;

  StatementImportContinuation({
    required this.outbox,
    required this.checkAccountUnchanged,
    required this.sendPrepared,
    AccountRecoveryOperationGate? gate,
  }) : gate = gate ?? AccountRecoveryOperationGate.process;

  /// Persists the complete immutable plan, then runs pending batches in order.
  /// Calling this again with the same session id and body is replay-safe.
  Future<ImportProgress> prepareAndRun({
    required String sessionId,
    required List<Map<String, dynamic>> payloads,
    void Function(ImportProgress)? onProgress,
  }) async {
    return _exclusive(() async {
      checkAccountUnchanged();
      await outbox.prepare(sessionId: sessionId, payloads: payloads);
      checkAccountUnchanged();
      return _drain(sessionId: sessionId, onProgress: onProgress);
    });
  }

  /// Runs only when explicitly called by the foreground UI. The outbox is
  /// already bound to the account namespace, so another account's rows cannot
  /// be discovered or sent by this continuation.
  Future<ImportProgress> resume({
    void Function(ImportProgress)? onProgress,
  }) async => _exclusive(() => _drain(onProgress: onProgress));

  /// User-confirmed resume for one session that was retained for review after
  /// its TTL. It preserves all original encrypted batch bodies and importKeys.
  Future<ImportProgress> resumeReviewedSession(
    String sessionId, {
    void Function(ImportProgress)? onProgress,
  }) async => _exclusive(() async {
    checkAccountUnchanged();
    outbox.markExpiredForReview();
    outbox.resumeReview(sessionId);
    checkAccountUnchanged();
    return _drain(sessionId: sessionId, onProgress: onProgress);
  });

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    if (_running) {
      throw StateError('A statement continuation is already running.');
    }
    _running = true;
    try {
      return await gate.run(operation);
    } finally {
      _running = false;
    }
  }

  Future<ImportProgress> _drain({
    String? sessionId,
    void Function(ImportProgress)? onProgress,
  }) async {
    checkAccountUnchanged();
    final sessions = outbox
        .listSessions(includeTerminal: sessionId != null)
        .where((row) => sessionId == null || row.sessionId == sessionId)
        .toList(growable: false);
    final totalBatches = sessions.fold<int>(
      0,
      (sum, row) => sum + row.batchCount,
    );
    final persistedCompleted = sessions.fold<int>(
      0,
      (sum, row) => sum + row.completedBatches,
    );
    var completedThisRun = 0;
    var importedThisRun = sessions.fold<int>(
      0,
      (sum, row) => sum + row.imported,
    );
    var duplicatesThisRun = sessions.fold<int>(
      0,
      (sum, row) => sum + row.pendingDuplicates,
    );
    var retriesThisRun = sessions.fold<int>(
      0,
      (sum, row) => sum + row.exactRetries,
    );

    ImportProgress progress() => ImportProgress(
      added: importedThisRun,
      duplicates: duplicatesThisRun,
      alreadyImported: retriesThisRun,
      completedBatches: persistedCompleted + completedThisRun,
      totalBatches: totalBatches,
    );
    void report() => onProgress?.call(progress());

    report();
    while (true) {
      checkAccountUnchanged();
      final lease = await outbox.readNext(sessionId: sessionId);
      if (lease == null) {
        if ((sessionId == null
                ? outbox.pendingCount
                : outbox.pendingCountFor(sessionId)) >
            0) {
          throw StatementImportOutboxException(
            outbox.hasLiveLease ? 'continuation_busy' : 'needs_review',
          );
        }
        break;
      }

      var settled = false;
      var requestStarted = false;
      var leaseStillOwned = true;
      try {
        final result = await _sendAndRenew(
          lease,
          () {
            settled = true;
          },
          () {
            requestStarted = true;
          },
          (owned) {
            leaseStillOwned = owned;
          },
        );
        checkAccountUnchanged();
        if (!leaseStillOwned) {
          throw const StatementImportOutboxException('lease_lost');
        }
        outbox.acknowledge(
          sessionId: lease.sessionId,
          leaseToken: lease.leaseToken,
          // The repository only returns on HTTP 200/201 with receiptVersion 1.
          httpStatus: 200,
          summary: {
            'imported': result.addedCount,
            'pendingDuplicates': result.pendingDuplicateCount,
            'exactRetries': result.exactRetryCount,
          },
        );
        importedThisRun += result.addedCount;
        duplicatesThisRun += result.pendingDuplicateCount;
        retriesThisRun += result.exactRetryCount;
        completedThisRun++;
        checkAccountUnchanged();
        report();
      } catch (_) {
        // Never release a lease while its HTTP future is still running. If it
        // settled but account/lease fencing failed, preserve the same payload
        // for a later replay using the stable server importKey.
        if (settled || !requestStarted) {
          try {
            outbox.releaseLease(
              sessionId: lease.sessionId,
              leaseToken: lease.leaseToken,
            );
          } catch (_) {}
        }
        rethrow;
      }
    }
    return progress();
  }

  Future<StatementImport> _sendAndRenew(
    StatementImportLease lease,
    void Function() markSettled,
    void Function() markStarted,
    void Function(bool) setLeaseOwnership,
  ) async {
    checkAccountUnchanged();
    if (!outbox.renewLease(
      sessionId: lease.sessionId,
      leaseToken: lease.leaseToken,
    )) {
      setLeaseOwnership(false);
      throw const StatementImportOutboxException('lease_lost');
    }
    markStarted();
    final request = Future<StatementImport>.sync(
      () => sendPrepared(lease.payload),
    );
    var settled = false;
    request.then(
      (_) {
        settled = true;
        markSettled();
      },
      onError: (_, _) {
        settled = true;
        markSettled();
      },
    );

    while (true) {
      final timerDone = Completer<void>();
      final timer = Timer(const Duration(seconds: 20), timerDone.complete);
      Object? winner;
      try {
        winner = await Future.any<Object?>([
          request.then<Object?>(
            (value) => value,
            onError: (Object error, StackTrace stack) =>
                _SettledError(error, stack),
          ),
          timerDone.future,
        ]);
      } catch (error, stack) {
        // Once a request has started, no local error may release its slot or
        // gate admission until the actual HTTP Future has settled.
        try {
          await request;
        } catch (_) {}
        markSettled();
        Error.throwWithStackTrace(error, stack);
      } finally {
        timer.cancel();
      }
      if (winner is StatementImport) {
        return winner;
      }
      if (winner is _SettledError) {
        Error.throwWithStackTrace(winner.error, winner.stackTrace);
      }
      if (settled) {
        // The request may have settled between the timer and this check.
        return await request;
      }
      // A failed account check cannot abandon an in-flight request. Remember
      // it, let the actual future settle, then keep the local payload pending.
      Object? accountError;
      try {
        checkAccountUnchanged();
      } catch (error) {
        accountError = error;
      }
      if (accountError != null) {
        try {
          await request;
        } catch (_) {}
        markSettled();
        Error.throwWithStackTrace(accountError, StackTrace.current);
      }
      bool renewed;
      try {
        renewed = outbox.renewLease(
          sessionId: lease.sessionId,
          leaseToken: lease.leaseToken,
        );
      } catch (error, stack) {
        try {
          await request;
        } catch (_) {}
        markSettled();
        Error.throwWithStackTrace(error, stack);
      }
      if (!renewed) {
        setLeaseOwnership(false);
        try {
          await request;
        } catch (_) {}
        markSettled();
        throw const StatementImportOutboxException('lease_lost');
      }
    }
  }
}

class _SettledError {
  final Object error;
  final StackTrace stackTrace;
  const _SettledError(this.error, this.stackTrace);
}
