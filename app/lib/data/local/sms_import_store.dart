import 'package:pandapay_domain/sms_v2.dart' as sms_v2;

import '../../features/sms_import/sms_background_queue.dart';
import '../../features/sms_import/sms_text_hint.dart';
import '../../features/sms_v2/pipeline/intake_gate.dart';
import '../../features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'financial_store.dart';
import 'sms_intake_repository.dart';
import 'sms_learning_feedback.dart';

/// The same capture transaction is used by inbox import, foreground delivery
/// and the Android background isolate. Every message goes through SMS v2:
/// with a [v2Pipeline] it is parsed on the phone right away, without one it is
/// only remembered in the intake table for the foreground pipeline to process.
/// Nothing is uploaded from here.
class SmsImportStore {
  final FinancialStore store;
  final SmsV2Pipeline? v2Pipeline;
  final bool v2Backfill;
  SmsImportStore(this.store, {this.v2Pipeline, this.v2Backfill = false});

  void captureBatch(String namespace, List<QueuedSms> messages) =>
      _captureV2(namespace, messages);

  void capture(String namespace, QueuedSms message) =>
      _captureV2(namespace, [message]);

  void _captureV2(String namespace, List<QueuedSms> messages) {
    final pipeline = v2Pipeline;
    if (pipeline != null && pipeline.namespace != namespace) {
      throw ArgumentError('SMS pipeline account mismatch');
    }
    final intake = SmsIntakeRepository(store.database);
    final candidates = <sms_v2.SmsMessage>[];
    store.batch(() {
      final db = store.database.db;
      db.execute('SAVEPOINT sms_v2_capture');
      try {
        final feedback = SmsLearningFeedback(store.database, namespace: namespace);
        for (final message in messages) {
          final triage = classifySmsV2Intake(message.sender, message.body);
          if (triage.kind == SmsTriageKind.sensitive) continue;
          final sourceKey = smsSourceKey(namespace, message.sender, message.body);
          if (triage.kind == SmsTriageKind.unrelated || triage.kind == SmsTriageKind.promotion) {
            intake.recordDecision(
              namespace, sourceKey: sourceKey, decision: 'ignored', state: 'final',
              reasonCode: triage.reasonCode, receivedAt: message.receivedAt.millisecondsSinceEpoch,
              policyVersion: 'v2',
            );
            intake.acknowledge(namespace, sourceKey);
            continue;
          }
          if (feedback.matchesFalseTransactionRuleSync(sender: message.sender, body: message.body)) {
            intake.recordDecision(
              namespace, sourceKey: sourceKey, decision: 'user_corrected_not_financial',
              state: 'final', reasonCode: 'user_false_transaction_rule',
              receivedAt: message.receivedAt.millisecondsSinceEpoch, policyVersion: 'v2',
            );
            intake.forgetRaw(namespace, sourceKey);
            continue;
          }
          intake.remember(namespace, message);
          if (pipeline == null) {
            db.execute(
              'INSERT INTO sms_intake(namespace,id,sender,body,received_at) VALUES (?,?,?,?,?) '
              'ON CONFLICT(namespace,id) DO NOTHING',
              [namespace, sourceKey, message.sender, message.body, message.receivedAt.millisecondsSinceEpoch],
            );
            continue;
          }
          if (message.sender.trim().isEmpty) {
            // An unknown sender must not create financial effects or enter the
            // v2 pipeline as a verified bank alert.
            intake.recordDecision(
              namespace, sourceKey: sourceKey, decision: 'financial_review',
              state: 'final', reasonCode: 'sender_unavailable',
              receivedAt: message.receivedAt.millisecondsSinceEpoch,
              policyVersion: 'sender-evidence-v1',
            );
            intake.acknowledge(namespace, sourceKey);
            continue;
          }
          candidates.add(sms_v2.SmsMessage(
            sender: message.sender,
            body: message.body,
            observedAt: message.receivedAt.toUtc(),
            sourceKey: sourceKey,
            iosFilter: sms_v2.normalizeSenderBrand(message.sender).iosFilter,
          ));
        }
        if (pipeline != null) {
          for (var start = 0; start < candidates.length; start += 500) {
            final end = (start + 500).clamp(0, candidates.length);
            final chunk = candidates.sublist(start, end);
            pipeline.processBatch(chunk, backfill: v2Backfill);
            for (final message in chunk) {
              intake.acknowledge(namespace, message.sourceKey);
            }
          }
        }
        db.execute('RELEASE SAVEPOINT sms_v2_capture');
        store.notifyExternalChanges(namespace, const ['observations', 'needs_review']);
      } catch (_) {
        db.execute('ROLLBACK TO SAVEPOINT sms_v2_capture');
        db.execute('RELEASE SAVEPOINT sms_v2_capture');
        rethrow;
      }
    });
  }
}
