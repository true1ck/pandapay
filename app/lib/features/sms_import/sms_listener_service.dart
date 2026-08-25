import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';

import '../../app/env.dart';
import 'sms_background_queue.dart';
import 'sms_text_hint.dart';

/// The background-isolate entry point for an SMS that arrives while the app
/// is closed or backgrounded.
///
/// MUST be a top-level function and MUST carry `@pragma('vm:entry-point')`:
/// the platform spawns a fresh Dart isolate and looks this up by name, and
/// tree-shaking would otherwise remove it from a release build — producing
/// a handler that works in debug and silently does nothing in production.
///
/// It writes the message down and stops there. A background isolate has no
/// access to the app's providers, auth token or HTTP client, so uploading
/// from here would mean handling credentials in a context that is hard to
/// reason about and impossible to observe when it fails.
/// [SmsListenerService.flushBackgroundQueue] does the upload on next
/// resume. See [SmsBackgroundQueue] for why delayed-but-correct is the
/// right trade here.
@pragma('vm:entry-point')
Future<void> smsBackgroundHandler(SmsMessage message) async {
  // The fresh isolate has no plugin registrations of its own; without this,
  // the SharedPreferences channel call throws MissingPluginException.
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final sender = message.address;
  final body = message.body;
  if (sender == null || body == null) return;
  // The same cheap pre-filter the foreground path uses, applied BEFORE
  // anything is written: an OTP or a delivery notice must never be
  // persisted to disk, not even briefly.
  if (!looksLikeTransactionSms(body)) return;

  try {
    final prefs = await SharedPreferences.getInstance();
    await SmsBackgroundQueue.enqueue(
      prefs,
      QueuedSms(sender: sender, body: body, receivedAt: DateTime.now()),
    );
  } catch (_) {
    // Nothing in a background isolate can surface an error to the user, and
    // an uncaught throw here would be reported by the OS as an app crash
    // for a message the user never saw. Dropping one SMS degrades to the
    // pre-existing behaviour of not capturing it at all.
  }
}

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
  final Telephony? _injected;

  const SmsListenerService({Telephony? telephony}) : _injected = telephony;

  /// Resolved on first use, not in the constructor.
  ///
  /// `Telephony.instance` registers a platform-channel method-call handler
  /// the moment it is built, which asserts if the Flutter binding isn't up
  /// yet. [flushBackgroundQueue] touches no telephony at all — it only
  /// reads a queue and calls back — so constructing this service to flush
  /// must not drag the plugin in and fail.
  Telephony get _telephony => _injected ?? Telephony.instance;

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
  /// Background delivery is registered alongside it via
  /// [smsBackgroundHandler], so an alert arriving while the app is closed
  /// is queued on disk and uploaded on next resume rather than lost. It is
  /// enabled only OUTSIDE the prod flavor: prod strips READ_SMS/RECEIVE_SMS
  /// at the manifest level for Play Store policy reasons (see [Env.isProd]),
  /// so asking for background delivery there would register a handler whose
  /// permission can never be granted.
  void listenForeground(void Function(String sender, String body) onSms) {
    final background = !Env.isProd;
    _telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) {
        final sender = message.address;
        final body = message.body;
        if (sender == null || body == null) return;
        if (!looksLikeTransactionSms(body)) return;
        onSms(sender, body);
      },
      onBackgroundMessage: background ? smsBackgroundHandler : null,
      listenInBackground: background,
    );
  }

  /// Uploads anything the background handler queued while the app was away.
  ///
  /// [upload] returns true when the message is dealt with — imported,
  /// already known, or filed for review. A false or a throw means it is NOT
  /// dealt with, and that message stays queued for the next attempt: a bank
  /// alert dropped here is not recoverable from anywhere else on the
  /// device, so the queue is cleared only for what actually landed.
  ///
  /// Returns how many were successfully handled.
  Future<int> flushBackgroundQueue(
    Future<bool> Function(String sender, String body, DateTime receivedAt) upload, {
    SharedPreferences? prefs,
  }) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    final queued = SmsBackgroundQueue.read(store);
    if (queued.isEmpty) return 0;

    final remaining = <QueuedSms>[];
    var handled = 0;
    for (final message in queued) {
      try {
        final ok = await upload(message.sender, message.body, message.receivedAt);
        if (ok) {
          handled += 1;
        } else {
          remaining.add(message);
        }
      } catch (_) {
        // Offline, or the server is down. Keep it and try again next time.
        remaining.add(message);
      }
    }
    await SmsBackgroundQueue.replace(store, remaining);
    return handled;
  }
}
