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

/// Auto-detect format: tries XML first, then CSV. Callers don't need to
/// know or care what format the file is — the user just picks a file.
List<BackupSmsMessage> parseSmsBackup(String content) {
  // A file starting with `<` (ignoring a possible BOM) is almost certainly XML.
  final trimmed = content.trimLeft();
  if (trimmed.startsWith('<') || trimmed.startsWith('<?')) {
    return parseSmsBackupXml(content);
  }
  // Otherwise try CSV. If that also fails, try XML anyway as a last resort
  // (some XML files have leading whitespace/comments).
  try {
    return parseSmsBackupCsv(content);
  } on SmsBackupParseException {
    return parseSmsBackupXml(content);
  }
}

/// Parses CSV exports from common SMS backup apps. Instead of hardcoding
/// one app's column layout, this scans the header row for known column
/// names across multiple popular apps:
///
/// | App                      | Sender column    | Body column      | Date column       |
/// |--------------------------|------------------|------------------|-------------------|
/// | SMS Exporter             | Phone            | Content          | DateTime          |
/// | SMS Backup & Restore CSV | address          | body             | date              |
/// | SMS Organizer            | Address          | Body             | Date              |
/// | Google Messages export   | from / sender    | text / message   | timestamp / date  |
///
/// If no recognizable header is found, the parser gives up with a clear
/// message rather than guessing column positions and silently misattributing
/// fields.
List<BackupSmsMessage> parseSmsBackupCsv(String csvText) {
  // --- 1. Parse the raw CSV into rows of string values. ---
  // Handles quoted fields with embedded commas, newlines, and escaped quotes
  // per RFC 4180.
  final rows = _parseCsvRows(csvText);
  if (rows.length < 2) {
    throw const SmsBackupParseException(
      "This file doesn't have enough rows to be an SMS backup.",
    );
  }

  // --- 2. Find the header row and map columns. ---
  // The header might not be the very first row — some apps prepend a
  // metadata line (e.g. "Exported on 2026-10-02 with SMS Exporter").
  // Scan the first few rows for something that looks like a header.
  int? headerRowIdx;
  int senderIdx = -1;
  int bodyIdx = -1;
  int dateIdx = -1;

  // Aliases for each semantic column, lowercased. Order matters: first
  // match wins, so put the most common/unambiguous names first.
  const senderAliases = ['address', 'phone', 'sender', 'from', 'number', 'phone_number', 'phonenumber'];
  const bodyAliases = ['body', 'content', 'text', 'message', 'msg_body', 'sms_body', 'msgbody'];
  const dateAliases = ['date', 'datetime', 'timestamp', 'time', 'sent_date', 'readable_date', 'date_sent'];

  for (var i = 0; i < rows.length && i < 10; i++) {
    final cells = rows[i].map((c) => c.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '')).toList();

    final si = cells.indexWhere((c) => senderAliases.contains(c));
    final bi = cells.indexWhere((c) => bodyAliases.contains(c));

    if (si != -1 && bi != -1) {
      headerRowIdx = i;
      senderIdx = si;
      bodyIdx = bi;
      dateIdx = cells.indexWhere((c) => dateAliases.contains(c));
      break;
    }
  }

  if (headerRowIdx == null) {
    throw const SmsBackupParseException(
      "Couldn't find a header row with sender and message columns. "
      "The file should have columns like 'Address'/'Phone' and 'Body'/'Content'.",
    );
  }

  // --- 3. Extract messages from data rows. ---
  final messages = <BackupSmsMessage>[];
  final minCols = [senderIdx, bodyIdx, if (dateIdx != -1) dateIdx].reduce((a, b) => a > b ? a : b) + 1;

  for (var i = headerRowIdx + 1; i < rows.length; i++) {
    final row = rows[i];
    if (row.length < minCols) continue;

    final sender = row[senderIdx].trim();
    final body = row[bodyIdx].trim();
    if (sender.isEmpty || body.isEmpty) continue;

    final dateRaw = dateIdx != -1 && dateIdx < row.length ? row[dateIdx].trim() : null;
    messages.add((
      sender: sender,
      body: body,
      sentAt: _parseSentAt(dateRaw),
    ));
  }

  if (messages.isEmpty) {
    throw const SmsBackupParseException(
      "Found the header row but no message data. The file may be empty.",
    );
  }
  return messages;
}

/// RFC 4180 CSV parser: splits the entire text into rows of string values,
/// correctly handling quoted fields that contain commas, newlines, or
/// doubled quotes.
List<List<String>> _parseCsvRows(String text) {
  final rows = <List<String>>[];
  var inQuotes = false;
  var values = <String>[];
  final buf = StringBuffer();

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    final next = i + 1 < text.length ? text[i + 1] : null;

    if (inQuotes) {
      if (c == '"' && next == '"') {
        buf.write('"');
        i++;
      } else if (c == '"') {
        inQuotes = false;
      } else {
        buf.write(c);
      }
    } else {
      if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        values.add(buf.toString());
        buf.clear();
      } else if (c == '\n' || (c == '\r' && next == '\n')) {
        if (c == '\r') i++;
        values.add(buf.toString());
        buf.clear();
        if (values.any((v) => v.trim().isNotEmpty)) rows.add(values);
        values = [];
      } else if (c == '\r') {
        // bare \r without \n
        values.add(buf.toString());
        buf.clear();
        if (values.any((v) => v.trim().isNotEmpty)) rows.add(values);
        values = [];
      } else {
        buf.write(c);
      }
    }
  }
  // Flush last row
  if (buf.isNotEmpty || values.isNotEmpty) {
    values.add(buf.toString());
    if (values.any((v) => v.trim().isNotEmpty)) rows.add(values);
  }
  return rows;
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

  // Pre-process common CSV dates like '14-Jul-26 21:05' into ISO-8601
  var normalized = raw;
  final customFormat = RegExp(r'^(\d{2})-([a-zA-Z]{3})-(\d{2})(?:\s+(\d{1,2}):(\d{2}))?$');
  final match = customFormat.firstMatch(raw);
  if (match != null) {
    const months = {
      'Jan':'01', 'Feb':'02', 'Mar':'03', 'Apr':'04', 'May':'05', 'Jun':'06',
      'Jul':'07', 'Aug':'08', 'Sep':'09', 'Oct':'10', 'Nov':'11', 'Dec':'12'
    };
    final day = match.group(1)!;
    final mon = months[match.group(2)!.substring(0, 3)] ?? '01';
    final yy = match.group(3)!;
    final hh = (match.group(4) ?? '00').padLeft(2, '0');
    final mm = match.group(5) ?? '00';
    normalized = '20$yy-$mon-${day}T$hh:$mm:00';
  }

  final iso = DateTime.tryParse(normalized);
  return iso == null ? null : _plausible(iso);
}

/// SMS didn't meaningfully exist before 1993, and a message dated in the
/// future is a broken export, not a real message.
DateTime? _plausible(DateTime value) {
  if (value.isBefore(DateTime(1993))) return null;
  if (value.isAfter(DateTime.now().add(const Duration(days: 1)))) return null;
  return value;
}
