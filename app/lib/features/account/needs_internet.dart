import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart' show isOnlineProvider;
import '../../data/connectivity/reachability.dart' show serverReachableProvider;
import 'account_local_first.dart';

const needsInternetHint = 'Needs internet';

/// WP-C11: true when the phone is known offline, or the server is known
/// unreachable (not merely "not probed yet"). For actions that are
/// legitimately online only (delete account, phone change, revoke a device,
/// finishing sign-up): the button is disabled with [needsInternetHint] instead
/// of failing after a spinner. Online, healthy: always false.
final needsInternetProvider = Provider<bool>((ref) {
  if (!kAccountLocalFirst) return false;
  if (ref.watch(isOnlineProvider).valueOrNull == false) return true;
  return ref.watch(serverReachableProvider) == false;
});

/// [button] with the hint under it while [offline]. The caller disables the
/// button itself (pass `offline ? null : onPressed`).
Widget withNeedsInternetHint(bool offline, Widget button) {
  if (!offline) return button;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      button,
      const SizedBox(height: 4),
      Text(
        needsInternetHint,
        textAlign: TextAlign.center,
        style: BambooFonts.ui(12, color: BambooInk.ink500),
      ),
    ],
  );
}
