import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../app/env.dart';
import '../../app/providers.dart';
import '../../data/authenticated_http_client.dart';
import '../../data/import_repository.dart';
import '../../data/local/statement_import_outbox.dart';
import '../../data/local/statement_import_pending.dart';
import '../../data/portable_backup/account_recovery_operation_gate.dart';
import '../../data/secure_storage/flutter_secure_key_value_store.dart';
import '../../data/secure_storage/statement_import_batch_cipher.dart';
import '../../data/statement_import_continuation.dart';

/// Constructed only by the enabled import UI. It never resumes or uploads on
/// startup, and no secret leaves Keychain/Keystore for SQLite or backup JSON.
final statementImportContinuationProvider =
    FutureProvider.autoDispose<StatementImportContinuation?>((ref) async {
      if (!Env.statementImportContinuationEnabled) return null;
      final namespace = ref.watch(cacheNamespaceProvider);
      if (!RegExp(
        r'^user:[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(namespace)) {
        return null;
      }
      var disposed = false;
      final activeClients = <http.Client>{};
      void checkAccount() {
        if (disposed ||
            ref.read(cacheNamespaceProvider) != namespace ||
            ref.read(accessTokenProvider) == null) {
          throw StateError(
            'Sign in to the same account to resume this import.',
          );
        }
      }

      ref.onDispose(() {
        disposed = true;
        for (final client in activeClients.toList()) {
          client.close();
        }
      });
      final database = await ref.watch(appDatabaseProvider.future);
      checkAccount();
      final installId = await ref.read(localDeviceIdProvider.future);
      checkAccount();
      final cipher = SecureStatementImportBatchCipher(
        secureStore: FlutterSecureKeyValueStore(
          prefix: 'pandapay.statement-import.',
        ),
        installId: installId,
        encryptedBatchesExist: (owner) async =>
            pendingStatementImportBatches(database.db, owner) > 0,
      );
      final outbox = await AccountRecoveryOperationGate.process.run(() async {
        checkAccount();
        return StatementImportOutbox(
          database.db,
          namespace: namespace.toLowerCase(),
          cipher: cipher,
        );
      });
      return StatementImportContinuation(
        outbox: outbox,
        checkAccountUnchanged: checkAccount,
        sendPrepared: (payload) async {
          checkAccount();
          final refresh = ref.read(sessionRefreshCoordinatorProvider);
          final client = AuthenticatedHttpClient(
            inner: http.Client(),
            currentAccessToken: () {
              checkAccount();
              return ref.read(accessTokenProvider);
            },
            refreshAccessToken: () async {
              checkAccount();
              final token = await refresh.refresh();
              checkAccount();
              return token;
            },
            refreshAccessTokenForToken: (rejected) async {
              checkAccount();
              final token = await refresh.refresh(
                expectedAccessToken: rejected,
              );
              checkAccount();
              return token;
            },
          );
          activeClients.add(client);
          // Close this request's OWN transport on deadline. Await the actual
          // operation afterward; never release a lease around an abandoned HTTP
          // Future or close the app's shared authenticated client.
          final deadline = Timer(const Duration(seconds: 60), client.close);
          try {
            final repository = ImportRepository(
              apiBaseUrl: Env.apiBaseUrl,
              accessToken: ref.read(accessTokenProvider)!,
              client: client,
            );
            final result = await repository.confirmPreparedStatementImport(
              payload,
            );
            checkAccount();
            return result;
          } finally {
            deadline.cancel();
            activeClients.remove(client);
            client.close();
          }
        },
      );
    });
