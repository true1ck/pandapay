import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One bank SMS captured while the app was not in the foreground.
class QueuedSms {
  final String sender;
  final String body;
  final DateTime receivedAt;

  const QueuedSms({required this.sender, required this.body, required this.receivedAt});

  Map<String, dynamic> toJson() => {
    'sender': sender,
    'body': body,
    'receivedAt': receivedAt.toIso8601String(),
  };

  static QueuedSms? fromJson(Map<String, dynamic> json) {
    final sender = json['sender'] as String?;
    final body = json['body'] as String?;
    final receivedAt = json['receivedAt'] as String?;
    if (sender == null || body == null || receivedAt == null) return null;
    final parsed = DateTime.tryParse(receivedAt);
    if (parsed == null) return null;
    return QueuedSms(sender: sender, body: body, receivedAt: parsed);
  }
}

/// The handover between the SMS background isolate and the app.
///
/// A message arriving while the app is closed is delivered to a SEPARATE
/// Dart isolate with no access to the app's providers, its auth token, or
/// its HTTP client. So the background handler does the one thing it safely
/// can — write the message down — and the app uploads it on next resume.
///
/// That deliberately makes capture "eventually, on next open" rather than
/// instant. The alternative is reading the auth token inside a background
/// isolate and making network calls from it, which means credential
/// handling in a context that is much harder to reason about and impossible
/// to observe when it goes wrong. Delayed-but-correct beats
/// instant-but-fragile for something that only has to be right by the time
/// the user next looks.
///
/// SharedPreferences is the store because it is the one thing reachable
/// from both isolates without extra plugin registration. The queue holds
/// raw SMS text, so it is bounded, cleared as soon as it is uploaded, and
/// never synced anywhere — the same on-device-only promise
/// [SmsConsentScreen] already makes.
class SmsBackgroundQueue {
  static const storageKey = 'pandapay_app.sms_background_queue_v1';

  /// Hard cap on queued messages.
  ///
  /// A phone left closed for weeks must not accumulate an unbounded amount
  /// of raw SMS text on disk. When full the OLDEST are dropped: the newest
  /// messages are the ones most likely to still matter, and anything older
  /// is recoverable through the backup-file import.
  static const maxQueued = 200;

  /// Appends one message, oldest-dropped-first when full.
  ///
  /// Read-modify-write on a single key. Two SMS arriving in the same
  /// millisecond could in principle interleave and lose one; the platform
  /// delivers them sequentially to a single background handler, so this is
  /// a theoretical rather than a practical race — and losing one SMS
  /// degrades to the pre-existing behaviour of not capturing it at all.
  static Future<void> enqueue(SharedPreferences prefs, QueuedSms message) async {
    final existing = read(prefs);
    existing.add(message);
    final trimmed = existing.length > maxQueued
        ? existing.sublist(existing.length - maxQueued)
        : existing;
    await prefs.setStringList(
      storageKey,
      [for (final m in trimmed) jsonEncode(m.toJson())],
    );
  }

  /// Everything queued, oldest first. Malformed entries are dropped rather
  /// than thrown on — a corrupt entry must not make the whole queue
  /// unreadable and strand every message behind it.
  static List<QueuedSms> read(SharedPreferences prefs) {
    final raw = prefs.getStringList(storageKey) ?? const [];
    final out = <QueuedSms>[];
    for (final entry in raw) {
      try {
        final decoded = jsonDecode(entry);
        if (decoded is! Map<String, dynamic>) continue;
        final message = QueuedSms.fromJson(decoded);
        if (message != null) out.add(message);
      } catch (_) {
        // Skip this entry; the rest of the queue is still good.
      }
    }
    return out;
  }

  /// Clears the queue. Called only AFTER a successful upload — clearing
  /// first would lose messages on any network failure, and a lost bank
  /// alert is not recoverable from anywhere else on the device.
  static Future<void> clear(SharedPreferences prefs) async {
    await prefs.remove(storageKey);
  }

  /// Replaces the queue with [remaining] — used to put back the messages an
  /// upload did not manage to send.
  static Future<void> replace(SharedPreferences prefs, List<QueuedSms> remaining) async {
    if (remaining.isEmpty) {
      await clear(prefs);
      return;
    }
    await prefs.setStringList(
      storageKey,
      [for (final m in remaining) jsonEncode(m.toJson())],
    );
  }
}
