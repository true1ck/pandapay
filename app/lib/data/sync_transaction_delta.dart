import 'dart:async';

import 'api_exception.dart';
import 'user_cards_repository.dart';

class SyncTransactionDelta {
  final List<TransactionEntry> rows;
  final Set<String> deletedIds;
  SyncTransactionDelta(List<TransactionEntry> rows, Set<String> deletedIds)
    : rows = List.unmodifiable(rows),
      deletedIds = Set.unmodifiable(deletedIds);
}

/// Fetches current affected rows rather than materializing all history. A 404
/// is deletion evidence only when the pull explicitly named a delete. Other
/// failures leave the caller's durable cursor unchanged for replay.
Future<SyncTransactionDelta> fetchSyncTransactionDelta(
  Iterable<Map<String, dynamic>> changes, {
  required Future<TransactionEntry> Function(String id) fetch,
  required bool Function() isCurrent,
  int maxIds = 100,
  int concurrency = 4,
}) async {
  void check() {
    if (!isCurrent()) throw StateError('Account changed during sync');
  }

  check();
  if (maxIds < 1 || concurrency < 1) {
    throw ArgumentError('Invalid delta bounds');
  }
  final operations = <String, String>{};
  for (final change in changes) {
    final id = change['entity_id'];
    final op = change['op'];
    if (id is! String || id.isEmpty ||
        (op != 'insert' && op != 'update' && op != 'delete')) {
      throw const FormatException('Invalid transaction sync change');
    }
    operations[id] = op as String;
    if (operations.length > maxIds) {
      throw StateError('Transaction delta exceeds bound');
    }
  }
  final ids = operations.keys.toList();
  final rows = <TransactionEntry>[];
  final deleted = <String>{};
  for (var offset = 0; offset < ids.length; offset += concurrency) {
    check();
    final group = ids.skip(offset).take(concurrency);
    final fetched = await Future.wait(
      group.map((id) async {
        try {
          final row = await fetch(id);
          if (row.id != id) {
            throw const FormatException('Transaction ID mismatch');
          }
          return row;
        } on ApiException catch (error) {
          if (error.statusCode != 404 || operations[id] != 'delete') rethrow;
          deleted.add(id);
          return null;
        }
      }),
    );
    check();
    rows.addAll(fetched.whereType<TransactionEntry>());
    if (offset + concurrency < ids.length) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return SyncTransactionDelta(rows, deleted);
}
