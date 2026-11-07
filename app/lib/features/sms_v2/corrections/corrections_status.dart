import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Where one of the person's corrections stands, in words they can read.
enum CorrectionState {
  /// Saved on the phone and waiting for a connection.
  queued,

  /// Delivered; nobody has reviewed it yet.
  sent,

  /// Reviewed, and the shared rules were fixed.
  fixedByRules,

  /// Reviewed, and the app itself needs a fix.
  codeFixPlanned,

  /// Reviewed; nothing needed changing.
  noChangeNeeded,

  /// The server declined it for good; the change stays on this phone.
  keptOnPhone,

  /// Never meant to leave the phone (no sharing, or a confirmation).
  localOnly,
}

class CorrectionStatusRow {
  const CorrectionStatusRow({
    required this.id,
    required this.kind,
    required this.state,
    this.detail,
  });
  final String id;

  /// The wire name of what was corrected, such as `wrong_category`.
  final String kind;
  final CorrectionState state;

  /// The reviewer's note, or why it stayed on the phone.
  final String? detail;
}

const _kindWords = {
  'wrong_category': 'Category',
  'wrong_merchant': 'Shop name',
  'wrong_amount': 'Amount',
  'wrong_date': 'Date',
  'wrong_instrument': 'Payment method',
  'wrong_kind': 'Type',
  'not_financial': 'Not a transaction',
  'missing': 'Missed SMS',
  'wrong_link': 'Linked payments',
  'duplicate': 'Duplicate',
  'preference_only': 'Your preference',
};

String correctionKindWords(String wire) => _kindWords[wire] ?? 'Correction';

String correctionStateWords(CorrectionStatusRow row) => switch (row.state) {
  CorrectionState.queued => 'Waiting to send',
  CorrectionState.sent => 'Sent. Not reviewed yet',
  CorrectionState.fixedByRules => 'Reviewed. The shared rules were fixed',
  CorrectionState.codeFixPlanned => 'Reviewed. The app needs an update',
  CorrectionState.noChangeNeeded => 'Reviewed. No change needed',
  CorrectionState.keptOnPhone => 'Kept on this phone: ${_whyNotSent(row.detail)}',
  CorrectionState.localOnly => 'Applied on this phone only',
};

String _whyNotSent(String? code) => switch (code) {
  'correction_facts_not_found' || 'correction_event_not_found' =>
    'the server could not match it to your messages',
  'correction_stage_mismatch' => 'this kind of fix cannot be shared',
  _ => 'the server declined it',
};

/// The person's corrections, newest first, up to [limit].
List<CorrectionStatusRow> correctionStatuses(
  Database db,
  String namespace, {
  int limit = 100,
}) {
  final queued = {
    for (final row in db.select(
      "SELECT id FROM v2_outbox WHERE namespace=? AND kind='correction'",
      [namespace],
    ))
      row['id'] as String,
  };
  return [
    for (final row in db.select(
      "SELECT review_id, payload, status FROM v2_review_items WHERE namespace=? AND kind='correction' ORDER BY rowid DESC LIMIT ?",
      [namespace, limit],
    ))
      _row(
        row['review_id'] as String,
        row['status'] as String,
        (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
        queued.contains(row['review_id']),
      ),
  ];
}

CorrectionStatusRow _row(
  String id,
  String status,
  Map<String, Object?> payload,
  bool inQueue,
) {
  final kind = payload['kind'] as String? ?? '';
  CorrectionStatusRow of(CorrectionState state, [String? detail]) =>
      CorrectionStatusRow(id: id, kind: kind, state: state, detail: detail);
  final notSent = payload['notSent'] as String?;
  if (notSent != null) return of(CorrectionState.keptOnPhone, notSent);
  if (inQueue) return of(CorrectionState.queued);
  final server = payload['serverStatus'];
  if (status == 'decided' && server is Map) {
    final reason = server['reason'] as String?;
    return switch (server['decision']) {
      'data_fix' => of(CorrectionState.fixedByRules, reason),
      'code_fix' => of(CorrectionState.codeFixPlanned, reason),
      'not_a_bug' => of(CorrectionState.noChangeNeeded, reason),
      _ => of(CorrectionState.sent),
    };
  }
  if (status == 'open' || payload['caseId'] != null) {
    return of(CorrectionState.sent);
  }
  return of(CorrectionState.localOnly);
}
