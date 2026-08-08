import 'package:xml/xml.dart';

/// F4 (ui-spec SMS Import, GAP_ANALYSIS.md §3) — one message extracted from
/// a backup file, before it's run through the same SMS parser the live
/// listener uses (UserCardsRepository.logTransactionFromSms).
typedef BackupSmsMessage = ({String sender, String body});

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

/// Parses the XML format the (widely used, de facto standard) Android
/// "SMS Backup & Restore" app exports: an `smses` root element containing
/// `sms` elements with `address`/`body` attributes. Tolerant of the
/// handful of other apps that export a similar shape with different
/// attribute names by also trying `from`/`text` as fallbacks — still
/// deliberately NOT a universal parser for every backup-app format that
/// exists, same "flagged, not hidden" scope call as the PDF statement
/// parser's own "not issuer-specific" note. An `sms` element missing both
/// a sender and a body is skipped,
/// not thrown — a backup file with a few malformed entries alongside many
/// good ones is the normal case, not a failure.
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
    messages.add((sender: sender, body: body));
  }
  return messages;
}
