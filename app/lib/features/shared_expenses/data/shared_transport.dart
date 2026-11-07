import 'shared_commands.dart';

final class SharedCommitResponse {
  final SharedOperationReceipt receipt;
  final List<SharedProjection> records;
  SharedCommitResponse({
    required this.receipt,
    List<SharedProjection> records = const [],
  }) : records = List.unmodifiable(records) {
    if (records.length > 100) {
      throw const FormatException('Commit projection limit exceeded');
    }
  }
}

/// Implementations must use the account-bound authenticated HTTP owner. A
/// missing lookup means unknown, never permission to create a new operation ID.
abstract interface class SharedExpensesTransport {
  Future<SharedCommitResponse?> lookupOperation(String operationId);
  Future<SharedCommitResponse> execute(SharedCommand command);
  Future<SharedChangePage> pull({String? cursor, int limit = 100});
}

class SharedTransportException implements Exception {
  final int? statusCode;
  final String? code;
  final bool retryable;

  /// Set with `friend_name_taken`: the chat the person already has.
  final String? existingContextId;
  const SharedTransportException({
    this.statusCode,
    this.code,
    this.retryable = false,
    this.existingContextId,
  });
  @override
  String toString() => 'Shared request unavailable';
}
