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
  /// PANDAPAY SMS HISTORY (looping): Repeat 500 × Next PandaPay History
  /// Range → Window Start/End → Find Messages oldest first → Capture each
  /// (Sender = Repeat Item → Conversation) → Finish.
  static const history = String.fromEnvironment(
    'PANDAPAY_IOS_HISTORY_SHORTCUT_URL',
    defaultValue:
        'https://www.icloud.com/shortcuts/f8e3a510ba904480886fbaa475f38b2c',
  );

  /// PandaPay Incoming SMS (iOS 27): its own "When I receive a message
  /// containing a space" trigger → Capture Incoming SMS in PandaPay (body =
  /// the message, sender = its Sender, date = Current Date, Estimated).
  /// The trigger travels with the link, so adding it is the whole setup.
  /// Shared from a Personal Team build; re-share from the release build.
  static const live = String.fromEnvironment(
    'PANDAPAY_IOS_LIVE_SHORTCUT_URL',
    defaultValue:
        'https://www.icloud.com/shortcuts/ea897aea99a74b3f867b6b067d71b4e9',
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
