import '../../features/sms_import/ios_shortcut_sms.dart';
import '../../features/sms_import/sms_background_queue.dart';
import '../../features/sms_import/sms_text_hint.dart';
import '../local_sms_parser.dart';
import 'financial_store.dart';
import 'sms_intake_repository.dart';

/// Commits local processing evidence before native raw input is acknowledged.
/// Acquisition occurrence IDs never replace PandaPay's canonical financial key.
class IosSmsAcquisitionReceipts {
  final FinancialStore store;
  IosSmsAcquisitionReceipts(this.store);

  List<Map<String, Object?>> record(
    String namespace,
    String generation,
    List<Map<Object?, Object?>> records,
  ) {
    final intake = SmsIntakeRepository(store.database);
    final results = <Map<String, Object?>>[];
    final db = store.database.db;
    db.execute('SAVEPOINT ios_sms_receipts');
    try {
      for (final row in records) {
        if (row['namespace'] != namespace ||
            row['generation'] != generation ||
            row['id'] is! String) {
          throw StateError('Shortcut receipt ownership mismatch');
        }
        final message = QueuedSms(
          // Same normalisation as capture, so the lookup finds its decision.
          sender: IosShortcutSmsBatch.normalizeSender(
            row['sender'] as String? ?? '',
          ),
          body: row['body'] as String,
          receivedAt: DateTime.parse(row['receivedAt'] as String),
        );
        // Older native policies admitted some security alerts. A terminal
        // exclusion must release that queue item without storing a body digest
        // or inventing a financial decision. Native acknowledgement erases it.
        if (classifySmsTriage(message.sender, message.body).kind ==
            SmsTriageKind.sensitive) {
          results.add({
            'id': row['id'] as String,
            'parserVersion': LocalSmsParser.version,
            'outcome': 'excluded_security',
          });
          continue;
        }
        final key = smsSourceKey(namespace, message.sender, message.body);
        final decision = intake.decision(namespace, key);
        final existing = store.hasReceipt(namespace, key);
        if (decision == null && !existing) {
          throw StateError('Shared intake has not committed a decision');
        }
        // Pending HTTP upload is separate from a committed local intake result.
        final outcome = existing
            ? 'existing'
            : decision!.decision.startsWith('ignored') ||
                  decision.decision == 'user_corrected_not_financial'
            ? 'ignored'
            : decision.decision.contains('review')
            ? 'review'
            : 'captured';
        db.execute(
          'INSERT INTO ios_sms_acquisition_receipts VALUES(?,?,?,?,?,?,?,?) '
          'ON CONFLICT(namespace,generation,capture_id) DO UPDATE SET '
          'parser_version=excluded.parser_version,outcome=excluded.outcome',
          [
            namespace,
            generation,
            row['id'],
            key,
            message.receivedAt.millisecondsSinceEpoch,
            row['dateProvenance'] ?? 'unknown',
            LocalSmsParser.version,
            outcome,
          ],
        );
        results.add({
          'id': row['id'] as String,
          'sourceKey': key,
          'parserVersion': LocalSmsParser.version,
          'outcome': outcome,
          'occurrenceAmbiguous': intake.hasRepeatedOccurrence(namespace, key),
        });
      }
      db.execute('RELEASE SAVEPOINT ios_sms_receipts');
      return results;
    } catch (_) {
      db.execute('ROLLBACK TO SAVEPOINT ios_sms_receipts');
      db.execute('RELEASE SAVEPOINT ios_sms_receipts');
      rethrow;
    }
  }
}
