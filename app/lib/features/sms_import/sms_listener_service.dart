import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';

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
      QueuedSms(
        sender: sender,
        body: body,
        receivedAt: message.date == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(message.date!),
      ),
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
/// The live receiver is paired with a small inbox reconciliation pass on app
/// startup/resume. Android can deliver an SMS to the default messaging app
/// without reliably invoking every third-party receiver on every emulator or
/// OEM build; reconciling the provider makes a missed broadcast recoverable.
///
/// Wraps the `telephony` plugin (RECEIVE_SMS BroadcastReceiver +
/// READ_SMS query) so callers deal in plain (sender, body) pairs, not
/// platform-channel details.
class InboxSms {
  final String sender;
  final String body;
  final DateTime receivedAt;

  const InboxSms({
    required this.sender,
    required this.body,
    required this.receivedAt,
  });
}

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

  /// True once Android will no longer show the runtime prompt (user picked
  /// "Don't allow" twice, or "Don't ask again"). In that state the only way
  /// back is the OS app-settings screen — see [openSettings].
  Future<bool> isPermanentlyDenied() async {
    return Permission.sms.status.then((s) => s.isPermanentlyDenied);
  }

  /// Opens the OS settings page for this app so the user can flip the SMS
  /// permission back on manually. Returns false if the page could not be
  /// opened.
  Future<bool> openSettings() => openAppSettings();

  /// Queries the on-device SMS inbox (most recent first) and returns only
  /// messages worth sending to the server parser. The original sender and
  /// provider timestamp are retained so the API's source key stays stable
  /// across a live broadcast and a later reconciliation pass.
  Future<List<InboxSms>> readInboxSms({int limit = 500}) async {
    try {
      final messages = await _telephony.getInboxSms(
        columns: const [SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE],
        sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.DESC)],
      );
      return messages
          .map((m) {
            final sender = m.address;
            final body = m.body;
            final date = m.date;
            if (sender == null || body == null || date == null) return null;
            return InboxSms(
              sender: sender,
              body: body,
              receivedAt: DateTime.fromMillisecondsSinceEpoch(date),
            );
          })
          .whereType<InboxSms>()
          .where((m) => looksLikeTransactionSms(m.body))
          .take(limit)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Compatibility helper for card discovery/onboarding callers that only
  /// need message bodies.
  Future<List<String>> readInboxSmsBodies({int limit = 500}) async {
    final messages = await readInboxSms(limit: limit);
    return [for (final message in messages) message.body];
  }

  /// Registers a foreground listener. [onSms] is called with the raw sender
  /// address, message body and Android received timestamp for every incoming
  /// SMS while the app is running — no filtering by sender here (that's the server's
  /// parser_patterns.sender_pattern's job); this layer only does the cheap
  /// looksLikeTransactionSms() pre-filter to avoid forwarding obvious
  /// non-transaction noise (OTPs, delivery notices) to the API at all.
  ///
  /// Background delivery is registered alongside it via
  /// [smsBackgroundHandler], so an alert arriving while the app is closed
  /// is queued on disk and uploaded on next resume rather than lost.
  void listenForeground(void Function(String sender, String body, DateTime receivedAt) onSms) {
    _telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) {
        final sender = message.address;
        final body = message.body;
        if (sender == null || body == null) return;
        if (!looksLikeTransactionSms(body)) return;
        final receivedAt = message.date == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(message.date!);
        onSms(sender, body, receivedAt);
      },
      onBackgroundMessage: smsBackgroundHandler,
      listenInBackground: true,
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
