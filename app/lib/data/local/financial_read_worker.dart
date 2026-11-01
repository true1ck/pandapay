import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import '../portable_backup/account_recovery_operation_gate.dart';
import '../user_cards_repository.dart';
import 'app_database.dart';
import 'financial_store.dart';

/// A bounded view of one local query. [hasStoredCoverage] describes the saved
/// query, not completeness of this page. A keyset traversal is not a snapshot
/// across requests and must never be used to infer missing/deleted records.
class LocalTransactionPage {
  final List<TransactionEntry> rows;
  final DateTime? fetchedAt;
  final bool hasStoredCoverage;
  final bool hasMore;
  final String? nextCursor;
  final List<String> changedEntities;

  LocalTransactionPage._(List<dynamic> values)
    : rows = List.unmodifiable(
        (values[0] as List).map(
          (row) =>
              TransactionEntry.fromJson(Map<String, dynamic>.from(row as Map)),
        ),
      ),
      fetchedAt = values[1] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(values[1] as int),
      hasStoredCoverage = values[2] as bool,
      hasMore = values[3] as bool,
      nextCursor = values[4] as String?,
      changedEntities = List.unmodifiable((values[5] as List).cast<String>());
}

/// Serial file-backed query owner. SQL, historical repairs, pending-edit
/// overlay, JSON decoding, filtering and sorting execute on its own isolate.
/// Only at most 200 transaction DTOs cross back to the caller per request.
/// The current compatible query still scans its full history in the worker;
/// adopting this page API does not make that scan a bounded SQL query.
///
/// Existing FinancialStore reads can repair historical rows, so recovery
/// admission is retained until the reply/worker exit, including during close.
/// Callers must forward [LocalTransactionPage.changedEntities] to their live
/// store and discard results when their account/session generation changes.
class FinancialReadWorker {
  final String databasePath;
  final AccountRecoveryOperationGate recoveryGate;
  final int maxPendingRequests;
  final _responses = ReceivePort();
  final _pending = <int, Completer<List<dynamic>>>{};
  final _exited = Completer<void>();
  Completer<SendPort>? _ready;
  Future<SendPort>? _startup;
  SendPort? _commands;
  Object? _terminalError;
  var _sequence = 0;
  var _closed = false;

  FinancialReadWorker(
    this.databasePath, {
    AccountRecoveryOperationGate? recoveryGate,
    this.maxPendingRequests = 2,
  }) : recoveryGate = recoveryGate ?? AccountRecoveryOperationGate.process {
    if (maxPendingRequests < 1) {
      _responses.close();
      throw ArgumentError.value(maxPendingRequests, 'maxPendingRequests');
    }
    _responses.listen((message) {
      if (message is SendPort) {
        _commands = message;
        _ready!.complete(message);
        if (_closed) message.send(null);
      } else if (message is List && message.isNotEmpty && message[0] is int) {
        final id = message[0] as int;
        final error = message[2] as String?;
        if (id == -1) {
          _fail(StateError(error ?? 'Local query worker unavailable'));
        } else {
          final reply = _pending.remove(id);
          if (error != null) {
            reply?.completeError(StateError(error));
          } else {
            reply?.complete(message[1] as List<dynamic>);
          }
        }
      } else if (message == null) {
        _fail(_terminalError ?? StateError('Local query worker stopped'));
        if (!_exited.isCompleted) _exited.complete();
        _responses.close();
      } else {
        // onError can precede onExit. Native reads/repairs are settled only
        // after exit, so retain pending admissions until that event arrives.
        _terminalError = StateError('Local query worker stopped');
      }
    });
  }

  void _fail(Object error) {
    _terminalError = error;
    if (!(_ready?.isCompleted ?? true)) _ready!.completeError(error);
    for (final reply in _pending.values) {
      reply.completeError(error);
    }
    _pending.clear();
  }

  Future<SendPort> _start() {
    final ready = _ready = Completer<SendPort>();
    unawaited(
      Isolate.spawn(
        _run,
        [_responses.sendPort, databasePath],
        onError: _responses.sendPort,
        onExit: _responses.sendPort,
        debugName: 'pandapay-financial-read',
      ).then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _fail(StateError('Local query worker could not start'));
          if (!_exited.isCompleted) _exited.complete();
          _responses.close();
        },
      ),
    );
    return ready.future;
  }

  Future<LocalTransactionPage> readTransactions(
    String namespace,
    TransactionQuery query, {
    int limit = 100,
    String? cursor,
    bool Function()? isCurrent,
  }) async {
    if (limit < 1 || limit > 200) throw ArgumentError.value(limit, 'limit');
    if (namespace.isEmpty) throw ArgumentError.value(namespace, 'namespace');
    final after = _decodeCursor(namespace, query, cursor);
    if (_closed) throw StateError('Local query worker closed');
    if (_terminalError != null) throw _terminalError!;
    void checkCurrent() {
      if (isCurrent != null && !isCurrent()) {
        throw StateError('Local query account/session changed');
      }
    }

    checkCurrent();
    return recoveryGate.run(() async {
      final commands = await (_startup ??= _start());
      if (_closed) throw StateError('Local query worker closed');
      checkCurrent();
      if (_pending.length >= maxPendingRequests) {
        throw StateError('Local query worker queue is full');
      }
      final id = ++_sequence;
      final reply = Completer<List<dynamic>>();
      _pending[id] = reply;
      commands.send([id, namespace, query.key, limit, after]);
      final values = await reply.future;
      checkCurrent();
      return LocalTransactionPage._(values);
    });
  }

  /// Gracefully queues shutdown behind admitted native reads/repairs.
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      if (_startup == null) {
        _responses.close();
        if (!_exited.isCompleted) _exited.complete();
      } else {
        _commands?.send(null);
      }
    }
    await _exited.future;
  }

  static List<dynamic>? _decodeCursor(
    String namespace,
    TransactionQuery query,
    String? cursor,
  ) {
    if (cursor == null) return null;
    try {
      if (cursor.length > 8192) throw const FormatException();
      final values =
          jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(cursor))))
              as List;
      if (values.length != 4 ||
          values[0] != namespace ||
          values[1] != query.key ||
          values[2] is! int ||
          values[3] is! String) {
        throw const FormatException();
      }
      return [values[2], values[3]];
    } catch (_) {
      throw ArgumentError.value(cursor, 'cursor', 'Invalid local query cursor');
    }
  }

  static void _run(List<Object?> arguments) {
    final replies = arguments[0] as SendPort;
    AppDatabase? database;
    FinancialStore? store;
    try {
      database = AppDatabase.openFile(arguments[1] as String);
      var changed = <String>{};
      store = FinancialStore(
        database,
        onEntityChanged: (change) => changed.add(change.entity),
      );
      final owner = store;
      final commands = ReceivePort();
      replies.send(commands.sendPort);
      commands.listen((command) {
        if (command == null) {
          owner.dispose();
          database!.close();
          commands.close();
          return;
        }
        final values = command as List;
        final id = values[0] as int;
        try {
          final namespace = values[1] as String;
          final query = TransactionQuery.fromKey(values[2] as String);
          final limit = values[3] as int;
          final after = values[4] as List?;
          changed = <String>{};
          // Legacy response snapshots are still present on upgraded devices.
          // Migrate them beside the query so the caller isolate does not have
          // to decode and rewrite the complete historical snapshot first.
          owner.migrateLegacy(namespace);
          final snapshot = owner.transactions(namespace, query);
          final rows = snapshot?.rows ?? <TransactionEntry>[];
          rows.sort((a, b) {
            final byDate = b.occurredAt.compareTo(a.occurredAt);
            return byDate == 0 ? b.id.compareTo(a.id) : byDate;
          });
          final page = rows
              .where((row) {
                if (after == null) return true;
                final at = row.occurredAt.microsecondsSinceEpoch;
                return at < (after[0] as int) ||
                    (at == after[0] &&
                        row.id.compareTo(after[1] as String) < 0);
              })
              .take(limit + 1)
              .toList();
          final hasMore = page.length > limit;
          if (hasMore) page.removeLast();
          final last = page.isEmpty ? null : page.last;
          final cursor = !hasMore || last == null
              ? null
              : base64Url.encode(
                  utf8.encode(
                    jsonEncode([
                      namespace,
                      query.key,
                      last.occurredAt.microsecondsSinceEpoch,
                      last.id,
                    ]),
                  ),
                );
          replies.send([
            id,
            [
              [for (final row in page) row.toJson()],
              snapshot?.fetchedAt.millisecondsSinceEpoch,
              snapshot?.complete ?? false,
              hasMore,
              cursor,
              changed.toList(),
            ],
            null,
          ]);
        } catch (_) {
          replies.send([id, null, 'Local transaction query failed']);
        }
      });
    } catch (_) {
      store?.dispose();
      database?.close();
      replies.send([-1, null, 'Local transaction storage unavailable']);
    }
  }
}
