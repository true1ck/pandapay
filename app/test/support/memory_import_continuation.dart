import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/local/statement_import_outbox.dart';
import 'package:pandapay/data/secure_storage/statement_import_batch_cipher.dart';
import 'package:pandapay/data/statement_import_continuation.dart';
import 'package:pandapay/features/import/statement_import_continuation_provider.dart';

/// Synthetic namespace; never a real account.
const memoryImportNamespace = 'user:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

class PassthroughImportCipher implements StatementImportBatchCipher {
  @override
  Future<Uint8List> encrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List plaintext,
  }) async => Uint8List.fromList(plaintext);
  @override
  Future<Uint8List> decrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List ciphertext,
  }) async => Uint8List.fromList(ciphertext);
}

/// In-memory continuation whose uploads go through [repository]. Widget tests
/// use this because the encrypted outbox is on by default (WP-C10) and the
/// real one needs Keychain/Keystore. [db] lets a test reopen the same file.
StatementImportContinuation memoryContinuation(
  ImportRepository repository, {
  Database? db,
}) => StatementImportContinuation(
  outbox: StatementImportOutbox(
    db ?? sqlite3.openInMemory(),
    namespace: memoryImportNamespace,
    cipher: PassthroughImportCipher(),
  ),
  checkAccountUnchanged: () {},
  sendPrepared: repository.confirmPreparedStatementImport,
);

Override memoryContinuationOverride(ImportRepository repository) =>
    statementImportContinuationProvider.overrideWith(
      (ref) async => memoryContinuation(repository),
    );
