import 'dart:async';

import 'package:flutter/foundation.dart';

/// How many unsent changes of one kind the phone holds, in words a person
/// understands ("3 new expenses"), not table names.
@immutable
class PendingKind {
  const PendingKind({
    required this.singular,
    required this.plural,
    required this.count,
  });

  final String singular;
  final String plural;
  final int count;

  String get text => '$count ${count == 1 ? singular : plural}';
}

/// Whether the changes that are still waiting could be sent just now.
enum SignOutConnection {
  /// Online and the send worked, or nothing is waiting.
  ok,

  /// The phone has no connection: nothing can be sent.
  offline,

  /// Connected, but PandaPay did not answer (or the send timed out) and
  /// changes are still waiting.
  unreachable,
}

/// What signing out would delete from this phone and has not reached the
/// server. Shown to the person before they confirm.
@immutable
class SignOutReport {
  const SignOutReport({
    required this.unsynced,
    required this.phoneOnlyReceipts,
    required this.phoneOnlyReviewItems,
    this.phoneOnlyMessages = 0,
    this.pendingKinds = const [],
    this.connection = SignOutConnection.ok,
  });

  /// Changes queued for the server (edits, quick adds, SMS facts, corrections),
  /// counting every queue. Changes the server already applied and that only
  /// wait for their stored copy to be refreshed are not lost, so not counted.
  final int unsynced;

  /// Receipt files that only exist on this phone.
  final int phoneOnlyReceipts;

  /// Messages waiting for review that only exist on this phone.
  final int phoneOnlyReviewItems;

  /// Original SMS stored on this phone. They are never sent to the server, so
  /// signing out deletes them for good; the history can be imported again.
  final int phoneOnlyMessages;

  /// [unsynced] split by kind, for the warning ("3 new expenses, 2 edits").
  /// Empty when the breakdown is not known.
  final List<PendingKind> pendingKinds;

  /// Whether the unsent changes could have been sent just now.
  final SignOutConnection connection;

  bool get losesSomething =>
      unsynced + phoneOnlyReceipts + phoneOnlyReviewItems + phoneOnlyMessages >
      0;

  /// Changes are waiting and could not be sent: the person is about to lose
  /// work that a connection would have saved. Needs a stronger warning.
  bool get unsentBecauseNoConnection =>
      unsynced > 0 && connection != SignOutConnection.ok;
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
    if (report.phoneOnlyMessages > 0)
      '${report.phoneOnlyMessages} ${plural(report.phoneOnlyMessages, 'original message', 'original messages')}',
  ];
  final phoneOnlyTotal =
      report.phoneOnlyReceipts +
      report.phoneOnlyReviewItems +
      report.phoneOnlyMessages;
  final stored = phoneOnly.isEmpty
      ? null
      : '${phoneOnly.join(' and ')} ${phoneOnlyTotal == 1 ? 'is' : 'are'} stored only on this phone';
  final total = report.unsynced + phoneOnlyTotal;
  final reimport = report.phoneOnlyMessages > 0
      ? ' You can import your SMS history again from Messages afterwards.'
      : '';
  final kinds = report.pendingKinds.isEmpty
      ? ''
      : ' (${report.pendingKinds.map((k) => k.text).join(', ')})';
  final changes =
      '${report.unsynced} ${plural(report.unsynced, 'change', 'changes')}';

  if (report.unsentBecauseNoConnection) {
    // Plain and direct: the phone could not send, and signing out now loses
    // the work. Say why, say how much, say what it is.
    final why = report.connection == SignOutConnection.offline
        ? 'Your phone is offline'
        : 'PandaPay could not be reached';
    final lead =
        '$why, so $changes$kinds ${report.unsynced == 1 ? "has" : "have"} not been sent and ${report.unsynced == 1 ? "will" : "will all"} be lost if you sign out now';
    final also = stored == null ? '' : ', and $stored';
    return '$lead$also. Signing out deletes ${total == 1 ? 'it' : 'them'} from this phone for good. '
        'Connect to the internet and wait for the changes to send first if you want to keep them.$reimport';
  }

  final unsynced = report.unsynced > 0
      ? '${report.unsynced} ${plural(report.unsynced, "change hasn't", "changes haven't")} reached PandaPay yet$kinds'
      : null;
  final sentence = [?unsynced, ?stored].join(', and ');
  return '$sentence. Signing out deletes ${total == 1 ? 'it' : 'them'} from this phone.$reimport';
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
    this.onSignOutStarted,
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

  /// Called first thing in [run], before any server call or wipe step. The app
  /// uses it to record that the person chose to sign out, so the code that
  /// reacts to the account becoming `signed-out` clears account data for this
  /// and not for a session the server rejected (WP-C3, L-01).
  final void Function()? onSignOutStarted;

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
    try {
      onSignOutStarted?.call();
    } catch (_) {
      // Recording the reason must never stop the wipe.
    }
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
