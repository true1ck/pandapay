import 'package:permission_handler/permission_handler.dart';
import 'package:telephony/telephony.dart';

import 'sms_text_hint.dart';

/// UA-5.3 (Chunk 31): the on-device SMS listening plumbing.
///
/// STATUS: structurally present, NOT verified against a real device or a
/// real incoming SMS. This sandbox has no Android SDK/emulator and no way
/// to receive a real text message — same honesty gap as UA-4 (Chunk 30)'s
/// camera preview, and the same reason: nothing here can be exercised, so
/// nothing here is claimed as tested. What IS genuinely verified is
/// everything downstream of "a (sender, body) string pair arrived" — the
/// `sms_text_hint.dart` extraction logic (unit tests) and the whole
/// server-side parse+insert path (curl-verified against live Postgres, see
/// PROGRESS.md Chunk 31).
///
/// Wraps the `telephony` plugin (RECEIVE_SMS BroadcastReceiver +
/// READ_SMS query) so callers deal in plain (sender, body) pairs, not
/// platform-channel details.
class SmsListenerService {
  final Telephony _telephony;
  SmsListenerService({Telephony? telephony}) : _telephony = telephony ?? Telephony.instance;

  /// Requests READ_SMS + RECEIVE_SMS at runtime (Android 6+ requires this
  /// beyond the manifest declaration). Returns true only if BOTH are
  /// granted — a partial grant (e.g. RECEIVE_SMS only) can't reliably
  /// support both live listening and the onboarding backfill scan, so this
  /// is treated as "not ready" rather than silently degrading.
  Future<bool> requestPermissions() async {
    final results = await [Permission.sms].request();
    return results[Permission.sms]?.isGranted ?? false;
  }

  Future<bool> hasPermissions() async {
    return Permission.sms.status.then((s) => s.isGranted);
  }

  /// Registers a foreground listener. [onSms] is called with the raw
  /// sender address and message body for every incoming SMS while the app
  /// is running — no filtering by sender here (that's the server's
  /// parser_patterns.sender_pattern's job); this layer only does the cheap
  /// looksLikeTransactionSms() pre-filter to avoid forwarding obvious
  /// non-transaction noise (OTPs, delivery notices) to the API at all.
  ///
  /// NOTE: `telephony`'s background/killed-app listening requires a
  /// registered top-level background message handler and additional
  /// platform wiring this chunk does not attempt — only foreground listening
  /// is wired here. That's a real, intentional scope cut (not silently
  /// dropped): background delivery would need its own verification pass on
  /// a real device, which this sandbox cannot do either.
  void listenForeground(void Function(String sender, String body) onSms) {
    _telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) {
        final sender = message.address;
        final body = message.body;
        if (sender == null || body == null) return;
        if (!looksLikeTransactionSms(body)) return;
        onSms(sender, body);
      },
      listenInBackground: false,
    );
  }
}
