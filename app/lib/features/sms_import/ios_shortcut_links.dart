/// Where people get PandaPay's Shortcuts.
///
/// Each link is an iCloud shortcut link (Shortcuts → share → Copy iCloud
/// Link). Opening it shows the shortcut in Shortcuts with an "Add Shortcut"
/// button; iOS always asks the person to confirm.
///
/// These are currently shared from the founder's Apple ID. Before a wide
/// release, share them from a PandaPay company Apple ID and replace the
/// links here. A build can also override them without a code change:
///   --dart-define=PANDAPAY_IOS_HISTORY_SHORTCUT_URL=https://www.icloud.com/shortcuts/…
///   --dart-define=PANDAPAY_IOS_LIVE_SHORTCUT_URL=https://www.icloud.com/shortcuts/…
abstract final class IosShortcutLinks {
  /// PANDAPAY SMS HISTORY: Sender mapped to Repeat Item → Conversation,
  /// Find Messages oldest first, "Find Messages limit is off" on.
  static const history = String.fromEnvironment(
    'PANDAPAY_IOS_HISTORY_SHORTCUT_URL',
    defaultValue:
        'https://www.icloud.com/shortcuts/4570a63b84e24d9baa1938b7f36db8a1',
  );
  static const live = String.fromEnvironment(
    'PANDAPAY_IOS_LIVE_SHORTCUT_URL',
    defaultValue: '',
  );

  /// Only genuine iCloud shortcut links are offered; anything else is
  /// treated as not set, so a typo never sends people somewhere unexpected.
  static Uri? parse(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'www.icloud.com' ||
        !uri.path.startsWith('/shortcuts/') ||
        uri.pathSegments.length < 2 ||
        uri.pathSegments[1].isEmpty) {
      return null;
    }
    return uri;
  }
}
