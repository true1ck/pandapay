import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/connectivity/known_connectivity.dart';
import '../../data/local/queue_registry.dart';
import '../../data/local/transaction_attachments_repository.dart';
import '../../data/portable_backup/account_recovery_operation_gate.dart';
import '../../data/session_end_reason.dart';
import 'account_sign_out.dart';
import 'sign_out_queues.dart';
import 'storage_phone_wipe_hooks.dart';

/// The storage-security hooks (install key, storage root, home widgets).
/// Tests override this with fakes.
final phoneWipeHooksProvider = Provider<PhoneWipeHooks>(
  (ref) => StoragePhoneWipeHooks(),
);

/// Counts of phone-only data, read straight from SQLite. Tables that do not
/// exist yet count as zero.
class PhoneOnlyCounts {
  const PhoneOnlyCounts({
    required this.smsOutbox,
    required this.receipts,
    required this.reviewItems,
    this.messages = 0,
  });
  final int smsOutbox;
  final int receipts;
  final int reviewItems;
  final int messages;
}

/// Receipt rows that may belong to [namespace]. The table has no namespace
/// column; the account is the first folder of the stored path (see
/// [TransactionAttachmentsRepository.storedPathMayBelongTo]), so another
/// account's receipts on a shared phone are not reported as this one's.
int _receiptsOfAccount(Database db, String namespace, bool tableExists) {
  if (!tableExists) return 0;
  var count = 0;
  for (final row in db.select('SELECT local_path FROM transaction_attachments')) {
    if (TransactionAttachmentsRepository.storedPathMayBelongTo(
      row['local_path'] as String,
      namespace,
    )) {
      count++;
    }
  }
  return count;
}

PhoneOnlyCounts readPhoneOnlyCounts(Database db, String namespace) {
  bool exists(String table) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
    [table],
  ).isNotEmpty;
  int count(String table, String where, List<Object?> args) => !exists(table)
      ? 0
      : db
                .select('SELECT COUNT(*) AS n FROM $table WHERE $where', args)
                .single['n']
            as int;
  return PhoneOnlyCounts(
    smsOutbox: count('v2_outbox', 'namespace=?', [namespace]),
    receipts: _receiptsOfAccount(db, namespace, exists('transaction_attachments')),
    reviewItems: count('v2_review_items', "namespace=? AND status='open'", [
      namespace,
    ]),
    messages: count('sms_captured_messages', 'namespace=?', [namespace]),
  );
}

/// Deletes files from where account data lives today (the database in the
/// documents folder, receipt files, caches). The private storage root is
/// wiped separately through [PhoneWipeHooks.wipeStorageRoot].
Future<void> wipeAccountFiles({
  required Directory documents,
  required Directory cache,
}) async {
  Future<void> remove(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } on FileSystemException {
      // Best effort: the remaining steps still run.
    }
  }

  for (final suffix in const ['', '-wal', '-shm', '-journal']) {
    await remove(File(p.join(documents.path, 'pandapay.sqlite$suffix')));
  }
  await remove(Directory(p.join(documents.path, 'transaction_attachments')));
  if (await cache.exists()) {
    await for (final entity in cache.list(followLinks: false)) {
      await remove(entity);
    }
  }
}

/// Removes every preference except [preserve].
Future<void> clearPreferencesExcept(
  SharedPreferences prefs,
  Set<String> preserve,
) async {
  for (final key in prefs.getKeys().toList()) {
    if (!preserve.contains(key)) await prefs.remove(key);
  }
}

final accountSignOutProvider = Provider<AccountSignOut>((ref) {
  final hooks = ref.read(phoneWipeHooksProvider);

  Future<void> attempt(Future<void> Function() step) async {
    try {
      await step();
    } catch (_) {
      // One failed upload must not stop the others.
    }
  }

  // Set when the last flush did not complete (an error, or the caller's
  // timeout abandoned it) so `report()` can say the send did not work.
  var flushCompleted = true;

  bool offlineNow() =>
      KnownConnectivity.knownOffline ||
      ref.read(isOnlineProvider).valueOrNull == false;

  Future<void> flushOutboxes() async {
    final namespace = ref.read(cacheNamespaceProvider);
    if (namespace == 'signed-out') return;
    flushCompleted = false;
    // Every registered queue, not a hand-kept list (WP-C3, L-02): the command
    // outbox, Split commands and documents, statement imports, tags and
    // foreign payments are flushed along with the edits and SMS uploads.
    final database = await ref.read(appDatabaseProvider.future);
    final report = await flushSignOutQueues(
      ref,
      registry: QueueRegistry(database),
      namespace: namespace,
    );
    flushCompleted = report.failures.isEmpty;
  }

  Future<SignOutReport> report() async {
    final namespace = ref.read(cacheNamespaceProvider);
    if (namespace == 'signed-out') {
      return const SignOutReport(
        unsynced: 0,
        phoneOnlyReceipts: 0,
        phoneOnlyReviewItems: 0,
      );
    }
    var scan = const SignOutQueueScan(unsent: 0, pending: 0, kinds: []);
    var counts = const PhoneOnlyCounts(
      smsOutbox: 0,
      receipts: 0,
      reviewItems: 0,
    );
    await attempt(() async {
      final database = await ref.read(appDatabaseProvider.future);
      scan = scanSignOutQueues(QueueRegistry(database), namespace);
      counts = readPhoneOnlyCounts(database.db, namespace);
    });
    // Waiting rows are what a connection would have delivered. Parked ones
    // were refused for good and are lost either way, so they say nothing
    // about the connection.
    final connection = scan.unsent == 0
        ? SignOutConnection.ok
        : offlineNow()
        ? SignOutConnection.offline
        : (!flushCompleted || scan.pending > 0)
        ? SignOutConnection.unreachable
        : SignOutConnection.ok;
    return SignOutReport(
      unsynced: scan.unsent,
      phoneOnlyReceipts: counts.receipts,
      phoneOnlyReviewItems: counts.reviewItems,
      phoneOnlyMessages: counts.messages,
      pendingKinds: scan.kinds,
      connection: connection,
    );
  }

  Future<void> unregisterPush() async {
    await ref.read(pushNotificationServiceProvider)?.unregister();
  }

  Future<void> revokeSession() async {
    final store = await ref.read(tokenStoreProvider.future);
    final refreshToken = store.refreshToken;
    if (refreshToken == null) return;
    final authApi = ref.read(authApiProvider);
    final coordinator = ref.read(sessionRefreshCoordinatorProvider);
    final accessToken =
        ref.read(accessTokenProvider) ?? await coordinator.refresh();
    if (accessToken == null) return;
    try {
      await authApi.logout(
        accessToken: accessToken,
        refreshToken: store.refreshToken ?? refreshToken,
      );
    } on ApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      // The access token expired. Refreshing rotates the refresh token, so
      // read it again from the store.
      final fresh = await coordinator.refresh();
      final rotated = store.refreshToken;
      if (fresh == null || rotated == null) return;
      await authApi.logout(accessToken: fresh, refreshToken: rotated);
    }
  }

  Future<void> closeDatabases() async {
    // Leave the account first so nothing starts new work on the database.
    ref.read(accessTokenProvider.notifier).state = null;
    await Future<void>.delayed(Duration.zero);
    await AccountRecoveryOperationGate.process.exclusive(() async {
      final cache = ref.read(responseCacheProvider).valueOrNull;
      if (cache != null) {
        await cache.financialReadWorker?.close();
        cache.financialStore.dispose();
      }
      ref.read(appDatabaseProvider).valueOrNull?.close();
    });
  }

  Future<void> destroyKeysAndTokens() async {
    final store = await ref.read(tokenStoreProvider.future);
    try {
      await store.clear();
    } finally {
      await hooks.destroyKeys();
    }
  }

  Future<void> deleteFiles() async {
    try {
      await hooks.wipeStorageRoot();
    } finally {
      await wipeAccountFiles(
        documents: await getApplicationDocumentsDirectory(),
        cache: await getApplicationCacheDirectory(),
      );
    }
  }

  Future<void> clearWidgetsAndNotifications() async {
    try {
      await hooks.clearHomeWidgets();
    } finally {
      await ref.read(localNotificationsPluginProvider).cancelAll();
    }
  }

  Future<void> clearPreferences() async {
    await clearPreferencesExcept(
      await SharedPreferences.getInstance(),
      hooks.preservedPreferenceKeys,
    );
  }

  void resetSession() {
    ref.read(accessTokenProvider.notifier).state = null;
    // The next sign-in opens a fresh database.
    ref.invalidate(responseCacheProvider);
    ref.invalidate(appDatabaseProvider);
    ref.invalidate(tokenStoreProvider);
  }

  return AccountSignOut(
    flushOutboxes: flushOutboxes,
    report: report,
    unregisterPush: unregisterPush,
    revokeSession: revokeSession,
    closeDatabases: closeDatabases,
    destroyKeysAndTokens: destroyKeysAndTokens,
    deleteFiles: deleteFiles,
    clearWidgetsAndNotifications: clearWidgetsAndNotifications,
    clearPreferences: clearPreferences,
    resetSession: resetSession,
    onSignOutStarted: () =>
        ref.read(sessionEndReasonProvider).markUserSignedOut(),
  );
});
