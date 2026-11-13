import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import 'account_sign_out.dart';

/// Uploads what it can, warns if the phone holds data the server does not,
/// then signs out and wipes the phone. Returns true when the person signed
/// out and false when they cancelled.
Future<bool> confirmAndSignOut(
  BuildContext context,
  AccountSignOut signOut,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Saving your changes...')),
          ],
        ),
      ),
    ),
  );
  final SignOutReport report;
  try {
    report = await signOut.prepare();
  } finally {
    navigator.pop();
  }
  if (!context.mounted) return false;
  if (report.losesSomething) {
    // Offline (or PandaPay unreachable) with changes still waiting: the usual
    // "Sign out anyway" is too easy to tap past. Name the loss on the button
    // and make staying the prominent choice.
    final losing = report.unsentBecauseNoConnection;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          !losing
              ? 'Sign out of PandaPay?'
              : report.connection == SignOutConnection.offline
              ? "You're offline"
              : "Can't reach PandaPay",
        ),
        content: Text(signOutWarningMessage(report)),
        actions: [
          if (losing)
            // A TextButton, not a FilledButton: the app theme makes filled
            // buttons full width, which does not belong in dialog actions.
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text(
                'Stay signed in',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            )
          else
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              losing
                  ? 'Sign out and lose ${report.unsynced == 1 ? 'this change' : '${report.unsynced} changes'}'
                  : 'Sign out anyway',
              style: const TextStyle(color: BambooInk.clay),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
  }
  await signOut.run();
  return true;
}
