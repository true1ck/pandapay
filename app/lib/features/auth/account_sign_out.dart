import 'dart:async';

import 'package:flutter/foundation.dart';

/// What signing out would delete from this phone and has not reached the
/// server. Shown to the person before they confirm.
@immutable
class SignOutReport {
  const SignOutReport({
    required this.unsynced,
    required this.phoneOnlyReceipts,
    required this.phoneOnlyReviewItems,
  });

  /// Changes queued for the server (edits, quick adds, SMS facts, corrections).
  final int unsynced;

  /// Receipt files that only exist on this phone.
  final int phoneOnlyReceipts;

  /// Messages waiting for review that only exist on this phone.
  final int phoneOnlyReviewItems;

  bool get losesSomething =>
      unsynced + phoneOnlyReceipts + phoneOnlyReviewItems > 0;
}

/// Plain-language body of the "Sign out of PandaPay?" dialog. Clauses with a
/// zero count are left out. Empty when nothing would be lost.
String signOutWarningMessage(SignOutReport report) {
  if (!report.losesSomething) return '';
  String plural(int n, String one, String many) => n == 1 ? one : many;

  final phoneOnly = <String>[
    if (report.phoneOnlyReceipts > 0)
      '${report.phoneOnlyReceipts} ${plural(report.phoneOnlyReceipts, 'receipt', 'receipts')}',
    if (report.phoneOnlyReviewItems > 0)
      '${report.phoneOnlyReviewItems} ${plural(report.phoneOnlyReviewItems, 'message to review', 'messages to review')}',
  ];
  final phoneOnlyTotal = report.phoneOnlyReceipts + report.phoneOnlyReviewItems;

  final unsynced = report.unsynced > 0
      ? '${report.unsynced} ${plural(report.unsynced, "change hasn't", "changes haven't")} reached PandaPay yet'
      : null;
  final stored = phoneOnly.isEmpty
      ? null
      : '${phoneOnly.join(' and ')} ${phoneOnlyTotal == 1 ? 'is' : 'are'} stored only on this phone';

  final sentence = [?unsynced, ?stored].join(', and ');
  final total = report.unsynced + phoneOnlyTotal;
  return '$sentence. Signing out deletes ${total == 1 ? 'it' : 'them'} from this phone.';
}

/// Result of [AccountSignOut.run]. The session is always reset; the wipe is
/// best effort, so the caller can tell the person if part of it failed.
@immutable
class SignOutOutcome {
  const SignOutOutcome(this.failedSteps);

  /// Names of wipe steps that threw ('keys', 'files', ...). Server steps
  /// (push, revoke) are best effort and are not listed.
  final List<String> failedSteps;

  bool get complete => failedSteps.isEmpty;
}

/// Native and storage calls that belong to the phone-storage work
/// (install key, backup-excluded storage root, home widgets). They are kept
/// behind this interface so sign-out can be tested without them.
abstract class PhoneWipeHooks {
  const PhoneWipeHooks();

  /// Destroys the install key and clears all secure storage
  /// (`InstallGuard.clearAllSecureStorage()` plus the database key destroy).
  Future<void> destroyKeys();

  /// Deletes the private storage root (`StoragePaths.wipe()`).
  Future<void> wipeStorageRoot();

  /// Clears data shared with the home widgets (`HomeWidgetService.clearAll()`).
  Future<void> clearHomeWidgets();

  /// Preference keys that survive sign-out (`InstallGuard.markerKey`).
  Set<String> get preservedPreferenceKeys;
}

/// Used until the storage hooks are wired.
class NoPhoneWipeHooks extends PhoneWipeHooks {
  const NoPhoneWipeHooks();

  @override
  Future<void> destroyKeys() async {}

  @override
  Future<void> wipeStorageRoot() async {}

  @override
  Future<void> clearHomeWidgets() async {}

  @override
  Set<String> get preservedPreferenceKeys => const {};
}

/// Order matters: server calls need the refresh token; keys are destroyed
/// before files so a crash mid-wipe leaves only unreadable ciphertext.
class AccountSignOut {
  AccountSignOut({
    required this.flushOutboxes,
    required this.report,
    required this.unregisterPush,
    required this.revokeSession,
    required this.closeDatabases,
    required this.destroyKeysAndTokens,
    required this.deleteFiles,
    required this.clearWidgetsAndNotifications,
    required this.clearPreferences,
    required this.resetSession,
    this.serverStepTimeout = const Duration(seconds: 8),
  });

  final Future<void> Function() flushOutboxes;
  final Future<SignOutReport> Function() report;
  final Future<void> Function() unregisterPush;
  final Future<void> Function() revokeSession;
  final Future<void> Function() closeDatabases;
  final Future<void> Function() destroyKeysAndTokens;
  final Future<void> Function() deleteFiles;
  final Future<void> Function() clearWidgetsAndNotifications;
  final Future<void> Function() clearPreferences;
  final void Function() resetSession;
  final Duration serverStepTimeout;

  /// Uploads what can be uploaded, then counts what would still be lost.
  Future<SignOutReport> prepare({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      await flushOutboxes().timeout(timeout);
    } catch (_) {
      // Offline or slow: report what is still pending.
    }
    return report();
  }

  /// Revokes the session on the server (best effort), then wipes the phone.
  /// A failing wipe step never stops the next one, and the session is always
  /// reset at the end.
  Future<SignOutOutcome> run() async {
    for (final step in [unregisterPush, revokeSession]) {
      try {
        await step().timeout(serverStepTimeout);
      } catch (_) {
        // Best effort. The phone is wiped regardless.
      }
    }
    final failed = <String>[];
    Future<void> wipe(String name, Future<void> Function() step) async {
      try {
        await step();
      } catch (_) {
        failed.add(name);
      }
    }

    await wipe('databases', closeDatabases);
    await wipe('keys', destroyKeysAndTokens);
    await wipe('files', deleteFiles);
    await wipe('widgets', clearWidgetsAndNotifications);
    await wipe('preferences', clearPreferences);
    resetSession();
    return SignOutOutcome(failed);
  }
}
