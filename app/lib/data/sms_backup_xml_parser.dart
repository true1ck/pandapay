import 'package:xml/xml.dart';

/// F4 (ui-spec SMS Import, GAP_ANALYSIS.md §3) — one message extracted from
/// a backup file, before it's run through the same SMS parser the live
/// listener uses (UserCardsRepository.logTransactionFromSms).
///
/// [sentAt] is the message's ORIGINAL timestamp, and it matters more than it
/// looks. Before it existed, every message imported from a two-year backup
/// was inserted at `now()`, which dumped years of historical spend into the
/// current statement cycle and drove cap/milestone/fee-waiver state off the
/// real numbers. Null when the export carries no usable date — callers must
/// treat that as "cannot import this message", not as "use today".
typedef BackupSmsMessage = ({String sender, String body, DateTime? sentAt});

/// Thrown when the file isn't parseable XML at all — a message-level parse
/// failure (unrecognized bank format) is NOT this; that's handled per
/// message downstream via the needs-review queue, same as the live
/// listener. This is only for "the file itself isn't readable."
class SmsBackupParseException implements Exception {
  final String message;
  const SmsBackupParseException(this.message);
  @override
  String toString() => message;
}

/// Upper bound on a single backup file, in bytes.
///
/// `XmlDocument.parse` is a DOM parser — it holds the whole document in
/// memory, and a multi-year export from a heavy SMS user is genuinely
/// large. A stated limit with a clear message beats an OOM kill that looks
/// to the user like the app crashing at random.
const int kMaxBackupFileBytes = 25 * 1024 * 1024;

/// Parses the XML format the (widely used, de facto standard) Android
/// "SMS Backup & Restore" app exports: an `smses` root element containing
/// `sms` elements with `address`/`body`/`date` attributes. Tolerant of the
/// handful of other apps that export a similar shape with different
/// attribute names by also trying `from`/`text`/`time` as fallbacks — still
/// deliberately NOT a universal parser for every backup-app format that
/// exists, same "flagged, not hidden" scope call as the PDF statement
/// parser's own "not issuer-specific" note. An `sms` element missing both
/// a sender and a body is skipped, not thrown — a backup file with a few
/// malformed entries alongside many good ones is the normal case, not a
/// failure.
List<BackupSmsMessage> parseSmsBackupXml(String xmlText) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xmlText);
  } on XmlException catch (e) {
    throw SmsBackupParseException("This doesn't look like a valid SMS backup file (${e.message}).");
  }

  final messages = <BackupSmsMessage>[];
  for (final smsElement in document.findAllElements('sms')) {
    final sender = smsElement.getAttribute('address') ?? smsElement.getAttribute('from');
    final body = smsElement.getAttribute('body') ?? smsElement.getAttribute('text');
    if (sender == null || sender.isEmpty || body == null || body.isEmpty) continue;
    messages.add((
      sender: sender,
      body: body,
      sentAt: _parseSentAt(smsElement.getAttribute('date') ?? smsElement.getAttribute('time')),
    ));
  }
  return messages;
}

/// SMS Backup & Restore writes `date` as epoch MILLISECONDS. Some other
/// exporters write epoch seconds, and a few write an ISO-8601 string, so
/// all three are accepted.
///
/// Anything that lands outside a plausible range is rejected rather than
/// used: a seconds-vs-milliseconds mix-up silently produces a 1970 or a
/// year-56000 transaction, and a wrong date here is worse than no import at
/// all because it corrupts cycle maths the user can't easily audit.
DateTime? _parseSentAt(String? raw) {
  if (raw == null || raw.isEmpty) return null;

  final epoch = int.tryParse(raw);
  if (epoch != null) {
    // Treat a value too small to be plausible-in-milliseconds as seconds.
    // 10^11 ms is 1973; any real backup is far later than that, and 10^11
    // SECONDS is year 5138, so the branch is unambiguous.
    final asMillis = epoch < 100000000000 ? epoch * 1000 : epoch;
    return _plausible(DateTime.fromMillisecondsSinceEpoch(asMillis));
  }

  final iso = DateTime.tryParse(raw);
  return iso == null ? null : _plausible(iso);
}

/// SMS didn't meaningfully exist before 1993, and a message dated in the
/// future is a broken export, not a real message.
DateTime? _plausible(DateTime value) {
  if (value.isBefore(DateTime(1993))) return null;
  if (value.isAfter(DateTime.now().add(const Duration(days: 1)))) return null;
  return value;
}
