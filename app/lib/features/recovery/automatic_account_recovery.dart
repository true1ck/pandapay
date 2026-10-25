import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../app/env.dart';
import '../../app/providers.dart';
import '../../data/portable_backup/account_recovery_coordinator.dart';
import '../../data/portable_backup/account_recovery_repository.dart';
import '../../data/portable_backup/automatic_recovery_scheduler.dart';

/// Opt-in is authoritative on the server and bound to the active device.
/// Constructing this provider never captures local data until consent is read.
final automaticAccountRecoveryProvider = Provider.autoDispose<void>((ref) {
  if (!Env.accountDataRecoveryEnabled) return;
  final namespace = ref.watch(cacheNamespaceProvider);
  final match = RegExp(r'^user:([0-9a-fA-F-]{36})$').firstMatch(namespace);
  if (match == null) return;
  final account = match.group(1)!.toLowerCase();
  var disposed = false;
  final storage = const FlutterSecureStorage();
  final digestKey = 'pandapay.automatic_recovery.last_verified.$account';
  String token() {
    if (disposed || ref.read(cacheNamespaceProvider) != namespace) {
      throw StateError('Recovery account changed');
    }
    final value = ref.read(accessTokenProvider);
    if (value == null) throw StateError('Recovery session unavailable');
    return value;
  }

  void check() {
    token();
  }

  final scheduler = AutomaticRecoveryScheduler(
    canRun: () =>
        !disposed &&
        ref.read(isOnlineProvider).valueOrNull == true &&
        (WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed),
    attempt: () async {
      final remote = AccountRecoveryRepository(
        apiBaseUrl: Uri.parse(Env.apiBaseUrl),
        accountId: account,
        accessToken: () async => token(),
        client: http.Client(),
        enabled: true,
        automatic: true,
      );
      try {
        String? consentId;
        final receipts = await remote.automaticSettings(
          onConsentId: (value) => consentId = value,
        );
        check();
        if (receipts == null) return; // No consent: no DB/receipt capture.
        final previous = await storage.read(key: digestKey);
        check();
        final database = await ref.read(appDatabaseProvider.future);
        final root = await getApplicationDocumentsDirectory();
        check();
        String? verifiedHash;
        final coordinator = AccountRecoveryCoordinator(
          database: database,
          accountId: account,
          attachmentsDirectory: Directory(
            path.join(root.path, 'transaction_attachments', 'recovered'),
          ),
          enabled: true,
          checkAccountUnchanged: check,
          verifyExistingOtp: () async =>
              AccountRecoveryVerifiedSession(account, token()),
          repository: (_) => AccountRecoveryRepository(
            apiBaseUrl: Uri.parse(Env.apiBaseUrl),
            accountId: account,
            accessToken: () async => token(),
            client: http.Client(),
            enabled: true,
            automatic: true,
            automaticConsentId: consentId,
          ),
        );
        await coordinator.create(
          AccountRecoveryConsent(
            includeReceipts: receipts,
            includeUnsynced: true,
            explicitlyApproved: true,
          ),
          shouldUpload: (bytes) =>
              '$consentId:${sha256.convert(bytes)}' != previous,
          onVerifiedUpload: (bytes) =>
              verifiedHash = '$consentId:${sha256.convert(bytes)}',
        );
        check();
        if (verifiedHash != null) {
          await storage.write(key: digestKey, value: verifiedHash);
        }
      } finally {
        remote.client.close();
      }
    },
  );
  final timer = Timer.periodic(
    const Duration(minutes: 1),
    (_) => unawaited(scheduler.tick()),
  );
  ref.listen(isOnlineProvider, (_, next) {
    if (next.valueOrNull == true) unawaited(scheduler.tick());
  });
  unawaited(scheduler.tick());
  ref.onDispose(() {
    disposed = true;
    timer.cancel();
    scheduler.dispose();
  });
});
