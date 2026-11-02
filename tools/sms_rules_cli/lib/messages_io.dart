import 'dart:convert';
import 'dart:io';

/// One SMS as read from CSV or JSONL: `{sender, body, observedAt}`.
class RawSms {
  const RawSms({
    required this.sender,
    required this.body,
    required this.observedAt,
  });

  final String sender;
  final String body;
  final DateTime observedAt;

  Map<String, Object?> toJson() => {
    'sender': sender,
    'body': body,
    'observedAt': observedAt.toUtc().toIso8601String(),
  };
}

/// Reads messages from a `.csv` (header row with sender, body, observedAt) or
/// JSONL file. Anything not ending in `.csv` is read as JSONL.
List<RawSms> readMessages(String path) {
  final text = File(path).readAsStringSync();
  return path.toLowerCase().endsWith('.csv')
      ? parseCsvMessages(text)
      : parseJsonlMessages(text);
}

List<RawSms> parseJsonlMessages(String text) {
  final out = <RawSms>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    final m = jsonDecode(line) as Map<String, dynamic>;
    out.add(_fromMap(m));
  }
  return out;
}

List<RawSms> parseCsvMessages(String text) {
  final rows = parseCsv(text);
  if (rows.isEmpty) return const [];
  final header = rows.first.map((h) => h.trim().toLowerCase()).toList();
  int col(List<String> names) {
    for (final n in names) {
      final i = header.indexOf(n);
      if (i >= 0) return i;
    }
    throw FormatException('CSV header needs one of $names, got $header');
  }

  final s = col(['sender', 'address']);
  final b = col(['body', 'text', 'message']);
  final t = col(['observedat', 'observed_at', 'date', 'receivedat']);
  final out = <RawSms>[];
  for (final r in rows.skip(1)) {
    if (r.every((c) => c.isEmpty)) continue;
    out.add(_fromMap({'sender': r[s], 'body': r[b], 'observedAt': r[t]}));
  }
  return out;
}

RawSms _fromMap(Map<String, dynamic> m) {
  final at = m['observedAt'] ?? m['observed_at'];
  return RawSms(
    sender: (m['sender'] ?? '').toString(),
    body: (m['body'] ?? '').toString(),
    observedAt: DateTime.parse(at.toString()).toUtc(),
  );
}

/// Minimal RFC 4180 CSV parser (quoted fields, doubled quotes, newlines in
/// quotes).
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var i = 0;
  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == ',') {
      endField();
    } else if (ch == '\n') {
      endRow();
    } else if (ch == '\r') {
      // ignore; the following \n ends the row
    } else {
      field.write(ch);
    }
    i++;
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}
