/// Month-only insurance premium notices ("Next Premium falls due on 09/2026").
///
/// They print no day and usually no amount, so they cannot be a bill fact (a
/// bill needs both). The pipeline therefore keeps them in a small saved list of
/// their own, written when a message is read, and the Bills page reads that
/// list: a month still ahead is an upcoming reminder, a month gone by is past
/// history. Reading never scans messages.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../../data/sms_capture_signals.dart';

const _prefix = 'premium-notice:';
final _amountWord = RegExp(r'(?:rs\.?|inr|₹)\s*[\d,]+', caseSensitive: false);
final _policyNo = RegExp(
  r'(?:policy\s*(?:no\.?|number)?\s*[:#]?\s*)(?:[x*]+)?(\d{4,})',
  caseSensitive: false,
);

/// One notice, as saved.
class PremiumNotice {
  const PremiumNotice({
    required this.sourceKey,
    required this.month,
    required this.sender,
    required this.receivedAt,
    required this.body,
    this.policyLast4,
  });

  final String sourceKey;

  /// First day of the month the notice names.
  final DateTime month;
  final String sender;
  final DateTime receivedAt;
  final String body;
  final String? policyLast4;

  Map<String, dynamic> toJson() => {
    'month': '${month.year}-${month.month.toString().padLeft(2, '0')}',
    'sender': sender,
    'receivedAt': receivedAt.toUtc().toIso8601String(),
    'body': body,
    'policyLast4': policyLast4,
  };

  /// The shape the older premium reminder logic reads, so one derivation
  /// (dedupe per policy, hide what a live bill already covers) serves both.
  Map<String, dynamic> toObservation() => {
    'id': sourceKey,
    'event_type': 'bill',
    'reason_codes': const ['next_premium_due_month_only'],
    'sample_body': body,
    'received_at': receivedAt.toUtc().toIso8601String(),
    'sender_bank': sender,
    'account_last4': policyLast4,
  };
}

/// The notice [body] is, or null when it is anything else. Cheap: a message
/// without the words "next premium" is rejected before any pattern runs.
PremiumNotice? premiumNoticeFromSms({
  required String sourceKey,
  required String sender,
  required String body,
  required DateTime receivedAt,
}) {
  if (!body.toLowerCase().contains('next premium')) return null;
  final month = SmsCaptureSignals.nextPremiumDueMonth(body);
  if (month == null) return null;
  // A message that also prints an amount is a payable bill; the rules read it.
  if (_amountWord.hasMatch(body)) return null;
  final policy = _policyNo.firstMatch(body)?.group(1);
  return PremiumNotice(
    sourceKey: sourceKey,
    month: month,
    sender: sender,
    receivedAt: receivedAt,
    body: body,
    policyLast4: policy?.substring(policy.length - 4),
  );
}

/// The saved notices, in the same table the rest of SMS v2 keeps its small
/// state in (`v2_sync_state`).
class PremiumNoticeStore {
  PremiumNoticeStore(this._db, {required this.namespace});

  final Database _db;
  final String namespace;

  void save(PremiumNotice notice) {
    _db.execute(
      'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?) '
      'ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value',
      [namespace, '$_prefix${notice.sourceKey}', jsonEncode(notice.toJson())],
    );
  }

  List<PremiumNotice> all() {
    final rows = _db.select(
      'SELECT key, value FROM v2_sync_state WHERE namespace=? AND key LIKE ?',
      [namespace, '$_prefix%'],
    );
    final out = <PremiumNotice>[];
    for (final row in rows) {
      try {
        final j = jsonDecode(row['value'] as String) as Map<String, dynamic>;
        final parts = (j['month'] as String).split('-');
        final received = DateTime.tryParse(j['receivedAt'] as String? ?? '');
        if (received == null) continue;
        out.add(
          PremiumNotice(
            sourceKey: (row['key'] as String).substring(_prefix.length),
            month: DateTime(int.parse(parts[0]), int.parse(parts[1])),
            sender: j['sender'] as String? ?? '',
            receivedAt: received.toLocal(),
            body: j['body'] as String? ?? '',
            policyLast4: j['policyLast4'] as String?,
          ),
        );
      } on Object {
        continue; // one damaged row never hides the others
      }
    }
    return out;
  }

  /// Saves every notice among the phone's already captured messages. Run once
  /// (the caller keeps a marker), off the UI thread: it is the only place that
  /// scans, and only the few messages that say "next premium".
  int scanCaptured() {
    final rows = _db.select(
      "SELECT id, sender, body, received_at FROM sms_captured_messages "
      "WHERE namespace=? AND body LIKE '%next premium%'",
      [namespace],
    );
    var found = 0;
    for (final row in rows) {
      final notice = premiumNoticeFromSms(
        sourceKey: row['id'] as String,
        sender: row['sender'] as String,
        body: row['body'] as String,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          row['received_at'] as int,
        ),
      );
      if (notice == null) continue;
      save(notice);
      found++;
    }
    return found;
  }
}
