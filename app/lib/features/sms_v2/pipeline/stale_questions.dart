import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../storage/fact_store.dart';
import 'ai_doubt.dart';

/// Closes the Needs review questions that an older build opened for a message that is read now.
///
/// An older build opened a "can't read this format yet" question for every message no rule had read, and for every
/// reading an unverified AI rule made. A question is closed when its message is read again, but only when the reading
/// changes: a message that a rule read, then the same rule again, keeps its old question for ever. The new three-tab
/// screen then shows the message as a question, not as read by the AI, even though nothing is left to ask.
///
/// A question is closed here only when all of these hold, so nothing the person still has to decide is lost:
///  * the message has a decision of "matched" (a reading exists) and facts the person did not write;
///  * the question was not put back by the person (`reason: reopened`) and was not answered;
///  * the reading is not in doubt by the same test the pipeline uses to raise a question ([aiDoubtOf]: a low
///    confidence, a direction that contradicts the words, or money booked that the words say has not moved).
///
/// Returns how many questions were closed. One query over the open template questions, so it is cheap to run at every
/// refresh; the facts of a handful of sources are read only when a question is open.
int closeStaleTemplateQuestions(Database db, String namespace) {
  final candidates = db.select(
    '''
    SELECT r.review_id AS id, r.payload AS payload, m.body AS body
      FROM v2_review_items r
      JOIN sms_source_decisions d
        ON d.namespace = r.namespace
       AND d.source_key = json_extract(r.payload, '\$.sourceKey')
       AND d.policy_version = 'v2' AND d.decision = 'matched'
      LEFT JOIN sms_captured_messages m
        ON m.namespace = r.namespace AND m.id = d.source_key
     WHERE r.namespace = ? AND r.kind = 'template' AND r.status = 'open'
    ''',
    [namespace],
  );
  if (candidates.isEmpty) return 0;
  final facts = FactStore(db, namespace: namespace);
  var closed = 0;
  for (final row in candidates) {
    final Map<String, Object?> payload;
    try {
      payload = (jsonDecode(row['payload'] as String) as Map)
          .cast<String, Object?>();
    } catch (_) {
      continue;
    }
    if (payload['reason'] == 'reopened' || payload['answer'] != null) continue;
    final source = payload['sourceKey'];
    if (source is! String) continue;
    final read = [
      for (final fact in facts.forSource(source))
        if (fact.provenance.engine != Engine.user) fact,
    ];
    if (read.isEmpty) continue;
    if (aiDoubtOf(read, body: row['body'] as String?) != null) continue;
    db.execute(
      "UPDATE v2_review_items SET status='resolved' WHERE namespace=? AND review_id=? AND status='open'",
      [namespace, row['id']],
    );
    closed++;
  }
  return closed;
}
