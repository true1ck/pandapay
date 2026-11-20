import 'dart:convert';

import '../../../data/local/financial_store.dart';

/// Closes a review question because the person added the transaction
/// themselves (the Edit transaction screen, opened on what the question knew).
///
/// The row is resolved, not deleted: it records the answer (`added`) and what
/// was added (the queued transaction's id and the values saved), so History can
/// list it and the message is not asked about again when it is read again.
/// Only the one question changes; others of the same format stay open.
void markAnsweredByAdding(
  FinancialStore financial, {
  required String namespace,
  required String reviewId,
  required Map<String, Object?> added,
}) {
  financial.batch(() {
    financial.database.db.execute(
      "UPDATE v2_review_items SET status='resolved', "
      "payload=json_set(payload,'\$.answer','added','\$.added',json(?)) "
      'WHERE namespace=? AND review_id=?',
      [jsonEncode(added), namespace, reviewId],
    );
  });
  financial.notifyExternalChanges(namespace, const ['needs_review']);
}
