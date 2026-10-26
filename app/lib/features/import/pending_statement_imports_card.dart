import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/env.dart';
import '../../app/providers.dart';
import '../../data/local/statement_import_outbox.dart';
import '../../data/portable_backup/account_recovery_operation_gate.dart';
import '../../data/statement_import_continuation.dart';
import 'statement_import_continuation_provider.dart';

/// Explicit foreground resume/cancel only. Opening this card never sends data.
class PendingStatementImportsCard extends ConsumerStatefulWidget {
  const PendingStatementImportsCard({super.key});
  @override
  ConsumerState<PendingStatementImportsCard> createState() =>
      _PendingStatementImportsCardState();
}

class _PendingStatementImportsCardState
    extends ConsumerState<PendingStatementImportsCard> {
  bool _busy = false;
  String? _message;

  void _refreshProduct() {
    ref.invalidate(statementImportsProvider);
    ref.invalidate(duplicateCandidatesProvider);
    ref.invalidate(transactionsProvider);
    ref.invalidate(utilizationTransactionsProvider);
    ref.invalidate(homeSummaryProvider);
    ref.invalidate(userCardsProvider);
  }

  Future<void> _resume(
    StatementImportContinuation continuation, {
    String? reviewSession,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final progress = reviewSession == null
          ? await continuation.resume()
          : await continuation.resumeReviewedSession(reviewSession);
      if (!mounted) return;
      _refreshProduct();
      setState(
        () => _message =
            '${progress.description}. ${progress.completedBatches} batches confirmed.',
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'This import could not finish. Its remaining encrypted batches are kept on this phone. Sign in to the same account and retry when the connection and import service are available.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(
    StatementImportContinuation continuation,
    StatementImportSessionSummary session,
  ) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard the remaining import?'),
        content: const Text(
          'Confirmed transactions stay in your account. This removes only the remaining encrypted batches from this phone. Keep the original source file if you may import them later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep import'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard remaining'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await AccountRecoveryOperationGate.process.run(() async {
        continuation.checkAccountUnchanged();
        continuation.outbox.cancel(session.sessionId);
      });
      if (mounted) {
        setState(
          () => _message =
              'Remaining batches discarded. Confirmed transactions are unchanged.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'This import is busy or unavailable. Wait for the current request to finish before discarding it.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Env.statementImportContinuationEnabled) return const SizedBox.shrink();
    return ref
        .watch(statementImportContinuationProvider)
        .when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Saved imports are temporarily unavailable. Existing encrypted work is retained on this phone.',
              ),
            ),
          ),
          data: (continuation) {
            if (continuation == null) return const SizedBox.shrink();
            final sessions = continuation.outbox.listSessions();
            if (sessions.isEmpty && _message == null) {
              return const SizedBox.shrink();
            }
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Saved file imports',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Remaining batches are encrypted on this phone. Resume only while signed in to this account. A recovery copy waits until these imports finish or are discarded.',
                    ),
                    for (final session in sessions)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${session.completedBatches} of ${session.batchCount} batches confirmed',
                        ),
                        subtitle: Text(
                          session.needsReview
                              ? 'Saved for more than 14 days. Review before continuing.'
                              : 'Ready to continue when you choose.',
                        ),
                        trailing: TextButton(
                          onPressed: _busy
                              ? null
                              : () => _cancel(continuation, session),
                          child: const Text('Discard'),
                        ),
                      ),
                    if (sessions.any((s) => !s.needsReview))
                      FilledButton(
                        onPressed: _busy ? null : () => _resume(continuation),
                        child: const Text('Resume saved imports'),
                      ),
                    for (final session in sessions.where((s) => s.needsReview))
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _resume(
                                continuation,
                                reviewSession: session.sessionId,
                              ),
                        child: const Text('Continue retained import'),
                      ),
                    if (_busy) const LinearProgressIndicator(),
                    if (_message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_message!),
                      ),
                  ],
                ),
              ),
            );
          },
        );
  }
}
