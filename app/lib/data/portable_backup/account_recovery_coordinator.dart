import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../local/app_database.dart';
import '../local/recovery_deferred_sms.dart';
import '../../features/sms_import/ios_sms_intake_service.dart';
import 'account_recovery_local_snapshot.dart';
import 'account_recovery_operation_gate.dart';
import 'account_recovery_repository.dart';

/// A token produced by the existing OTP flow. The backend independently
/// verifies its account, device and recent phone/email factor on every call.
class AccountRecoveryVerifiedSession {
  final String accountId;
  final String accessToken;
  const AccountRecoveryVerifiedSession(this.accountId, this.accessToken);
  @override
  String toString() => 'AccountRecoveryVerifiedSession(redacted)';
}

/// Coordinates explicit operations only; construction never reads or uploads
/// account data. Every repository produced by [repository] owns its HTTP client.
class AccountRecoveryCoordinator {
  final AppDatabase database;
  final String accountId;
  final Directory attachmentsDirectory;
  final Future<AccountRecoveryVerifiedSession?> Function() verifyExistingOtp;
  final AccountRecoveryRepository Function(AccountRecoveryVerifiedSession)
  repository;
  final void Function() checkAccountUnchanged;
  final AccountRecoveryOperationGate gate;
  final bool enabled;
  bool _busy = false;

  AccountRecoveryCoordinator({
    required this.database,
    required this.accountId,
    required this.attachmentsDirectory,
    required this.verifyExistingOtp,
    required this.repository,
    required this.checkAccountUnchanged,
    AccountRecoveryOperationGate? gate,
    this.enabled = false,
  }) : gate = gate ?? AccountRecoveryOperationGate.process;

  String get namespace => 'user:${accountId.toLowerCase()}';

  Future<T?> _run<T>(
    Future<T> Function(AccountRecoveryRepository) operation,
  ) async {
    if (!enabled) throw StateError('Account data recovery is not enabled');
    if (_busy) throw const AccountRecoveryBusy();
    _busy = true;
    AccountRecoveryRepository? remote;
    try {
      checkAccountUnchanged();
      final verified = await verifyExistingOtp();
      if (verified == null) return null; // Cancelling OTP is a normal exit.
      if (verified.accountId.toLowerCase() != accountId.toLowerCase() ||
          verified.accessToken.isEmpty) {
        throw StateError('Recovery verification belongs to another account');
      }
      checkAccountUnchanged();
      // Reconcile crash leftovers only after the existing account verification,
      // operation gate, and native SQLite writer lease are all held.
      await gate.exclusive(() {
        checkAccountUnchanged();
        return database.withRecoveryDatabase((lease) {
          checkAccountUnchanged();
          return AccountRecoveryLocalSnapshot.reconcileOrphanedReceipts(
            lease: lease,
            attachmentsDirectory: attachmentsDirectory,
            checkStillCurrent: checkAccountUnchanged,
          );
        });
      });
      checkAccountUnchanged();
      remote = repository(verified);
      if (remote.accountId != accountId || !remote.enabled) {
        throw StateError('Recovery repository account is not configured');
      }
      return await operation(remote);
    } finally {
      try {
        remote?.client.close();
      } finally {
        _busy = false;
      }
    }
  }

  Future<List<AccountRecoverySnapshotInfo>?> list() => _run((remote) async {
    final snapshots = await remote.list();
    checkAccountUnchanged();
    return snapshots;
  });

  Future<String?> create(
    AccountRecoveryConsent consent, {
    bool Function(Uint8List)? shouldUpload,
    void Function(Uint8List)? onVerifiedUpload,
  }) {
    if (!consent.explicitlyApproved || !consent.includeUnsynced) {
      return Future.error(
        StateError('Explicit pending-data approval is required'),
      );
    }
    return _run<String?>((remote) async {
      final snapshotId = const Uuid().v4();
      final payload = await gate.exclusive(() {
        checkAccountUnchanged();
        RecoveryDeferredSms.drainFor(database);
        return database.withRecoveryDatabase((lease) {
          checkAccountUnchanged();
          return AccountRecoveryLocalSnapshot.capture(
            lease: lease,
            accountId: accountId,
            namespace: namespace,
            includeReceipts: consent.includeReceipts,
          );
        });
      });
      try {
        checkAccountUnchanged();
        if (shouldUpload != null && !shouldUpload(payload)) return null;
        await remote.upload(
          snapshotId: snapshotId,
          plaintextArchive: payload,
          consent: consent,
        );
        checkAccountUnchanged();
        onVerifiedUpload?.call(payload);
        return snapshotId;
      } finally {
        payload.fillRange(0, payload.length, 0);
      }
    });
  }

  Future<bool?> setAutomatic({
    required bool enabled,
    required bool includeReceipts,
  }) => _run((remote) async {
    await remote.automaticSettings(
      enable: enabled,
      includeReceipts: includeReceipts,
    );
    return true;
  });

  Future<bool?> restore(String snapshotId, {required bool explicitlyApproved}) {
    if (!explicitlyApproved) {
      return Future.error(StateError('Explicit restore approval is required'));
    }
    return _run((remote) async {
      final payload = await remote.downloadAndDecrypt(snapshotId);
      try {
        checkAccountUnchanged();
        await gate.exclusive(() async {
          await IosSmsIntakeService().revoke(namespace);
          return database.withRecoveryDatabase((lease) async {
            checkAccountUnchanged();
            await AccountRecoveryLocalSnapshot.restoreFresh(
              lease: lease,
              payload: payload,
              accountId: accountId,
              namespace: namespace,
              attachmentsDirectory: attachmentsDirectory,
            );
            checkAccountUnchanged();
          });
        });
        return true;
      } finally {
        payload.fillRange(0, payload.length, 0);
      }
    });
  }

  Future<int?> discard({required bool explicitlyApproved}) {
    if (!explicitlyApproved) {
      return Future.error(StateError('Explicit discard approval is required'));
    }
    return _run((remote) async {
      final removed = await remote.removeAll(explicitlyApproved: true);
      checkAccountUnchanged();
      return removed;
    });
  }
}
