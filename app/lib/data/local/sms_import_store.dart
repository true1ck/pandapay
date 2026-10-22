import '../../features/sms_import/sms_text_hint.dart';
import '../local_sms_parser.dart';
import '../needs_review_repository.dart';
import '../user_cards_repository.dart';
import '../../features/sms_import/sms_background_queue.dart';
import 'financial_store.dart';
import 'sms_facts_outbox.dart';
import 'sms_intake_repository.dart';
import 'sms_rule_bundle.dart';

/// The same capture transaction is used by inbox import, foreground delivery
/// and the Android background isolate. Upload is deliberately separate.
class SmsImportStore {
  final FinancialStore store;
  // Drain profile name into the parser for own-name self-transfer matching.
  final String? ownUserName;
  final SmsRuleBundle? downloadedRules;
  SmsImportStore(this.store, {this.ownUserName, this.downloadedRules});
  void captureBatch(String namespace, List<QueuedSms> messages) {
    store.batch(() {
      final db = store.database.db;
      final cards = store
          .entities(namespace, 'cards')
          .map(UserCard.fromJson)
          .toList();
      final intake = SmsIntakeRepository(store.database);
      db.execute('SAVEPOINT sms_batch');
      try {
        for (final message in messages) {
          _capture(namespace, message, cards, intake);
        }
        db.execute('RELEASE SAVEPOINT sms_batch');
      } catch (_) {
        db.execute('ROLLBACK TO SAVEPOINT sms_batch');
        db.execute('RELEASE SAVEPOINT sms_batch');
        rethrow;
      }
    });
  }

  void capture(String namespace, QueuedSms message) {
    _capture(
      namespace,
      message,
      store.entities(namespace, 'cards').map(UserCard.fromJson).toList(),
      SmsIntakeRepository(store.database),
    );
  }

  void _capture(
    String namespace,
    QueuedSms message,
    List<UserCard> cards,
    SmsIntakeRepository intake,
  ) {
    final triage = classifySmsTriage(message.sender, message.body);
    if (triage.kind == SmsTriageKind.sensitive) return;

    final db = store.database.db;
    db.execute('SAVEPOINT sms_capture');
    try {
      final sourceKey = smsSourceKey(namespace, message.sender, message.body);
      if (intake.wasProcessed(namespace, sourceKey) ||
          store.hasReceipt(namespace, sourceKey)) {
        intake.remember(namespace, message);
        db.execute('RELEASE SAVEPOINT sms_capture');
        return;
      }

      if (triage.kind == SmsTriageKind.promotion ||
          triage.kind == SmsTriageKind.unrelated) {
        intake.recordDecision(
          namespace,
          sourceKey: sourceKey,
          decision: triage.kind == SmsTriageKind.promotion
              ? 'ignored_promotion'
              : 'ignored_unrelated',
          state: 'final',
          reasonCode: triage.reasonCode,
          receivedAt: message.receivedAt.millisecondsSinceEpoch,
          policyVersion: 'v1',
        );
        intake.forgetRaw(namespace, sourceKey);
        db.execute('RELEASE SAVEPOINT sms_capture');
        return;
      }

      final key = intake.capture(namespace, message);
      final observation = LocalSmsParser.parse(
        namespace: namespace,
        sender: message.sender,
        body: message.body,
        receivedAt: message.receivedAt,
        cards: cards,
        ownUserName:
            ownUserName ?? store.database.profileDisplayName(namespace),
        downloadedRules: downloadedRules,
      );
      if (observation != null) {
        final decision = observation.disposition == LocalSmsDisposition.localIgnore
            ? 'ignored_noise'
            : (observation.disposition == LocalSmsDisposition.review
                ? 'financial_review'
                : 'financial_auto');
        intake.recordDecision(
          namespace,
          sourceKey: key,
          decision: decision,
          state: 'final',
          reasonCode: observation.reasonCodes.isNotEmpty
              ? observation.reasonCodes.first
              : triage.reasonCode,
          receivedAt: message.receivedAt.millisecondsSinceEpoch,
          parserVersion: LocalSmsParser.version.toString(),
          bundleVersion: downloadedRules?.bundleVersion,
          policyVersion: 'v1',
        );
        store.saveObservation(namespace, key, {
          'id': key,
          'sender_bank': message.sender
              .toUpperCase()
              .replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '')
              .replaceFirst(RegExp(r'-[A-Z]$'), ''),
          'parser_version': LocalSmsParser.version,
          'received_at': message.receivedAt.toUtc().toIso8601String(),
          'account_last4': observation.accountLast4,
          'is_bank_account': observation.accountLast4 == null
              ? false
              : LocalSmsParser.isBankAccountMessage(
                  message.body,
                  message.sender,
                ),
          'card_last4': observation.cardLast4,
          'biller_name': observation.billerName,
          'cadence_hint': observation.cadenceHint,
          'balance_paise': observation.availableBalance?.paise,
          'amount_due_paise': observation.amountDue?.paise,
          'minimum_due_paise': observation.minimumDue?.paise,
          'autopay_limit_paise': observation.autopayLimit?.paise,
          'due_date': observation.dueDate?.toIso8601String(),
          'statement_date': observation.statementDate?.toIso8601String(),
          'statement_date_explicit': observation.statementDateExplicit,
          'event_type': observation.eventType.wireValue,
          'disposition': observation.disposition.wireValue,
          'reason_codes': observation.reasonCodes,
          'confidence': observation.confidence,
        });
        if (observation.transaction != null) {
          store.saveProvisional(namespace, observation.transaction!);
        }
        if (observation.eventType == LocalSmsEventType.bill &&
            observation.cardLast4 == null &&
            (observation.dueDate == null || observation.confidence < .85)) {
          addNeedsReviewSync(
            store.database,
            namespace,
            NeedsReviewItem(
              id: 'commitment:$key',
              sender: message.sender,
              body: message.body,
              reason: observation.reasonCodes.isEmpty
                  ? 'bill_needs_confirmation'
                  : observation.reasonCodes.join(', '),
              receivedAt: message.receivedAt,
              kind: NeedsReviewKind.commitment,
            ),
          );
        }
        if (observation.eventType == LocalSmsEventType.bill &&
            observation.confidence >= .85 &&
            observation.statementDate != null) {
          if (observation.dueDate != null || observation.statementDate != null) {
            for (final card in cards) {
              final matchesLast4 =
                  observation.cardLast4 != null && card.last4 == observation.cardLast4;
              final matchesFamily = observation.cardLast4 == null &&
                  message.sender.toUpperCase().contains('TNEU') &&
                  card.cardName.toLowerCase().contains('tata');
              if (matchesLast4 || matchesFamily) {
                final patch = <String, dynamic>{};
                if (card.dueDay == null && observation.dueDate != null) {
                  patch['due_day'] = observation.dueDate!.day;
                }
                if (card.statementDay == null && observation.statementDate != null) {
                  patch['statement_day'] = observation.statementDate!.day;
                }
                if (patch.isNotEmpty) {
                  store.patchCard(namespace, card.id, patch);
                }
              }
            }
          }
        }
        // Phase 3: bill obligations also reach the typed fact contract so
        // bill projections share one feed with
        // the balance/mandate/attempt families. INSERT OR IGNORE keeps a
        // replay dedup; the legacy observation sync is unchanged.
        if (observation.eventType == LocalSmsEventType.bill) {
          final facts = buildSmsFactsForObservation(
            body: message.body,
            observation: observation,
            receivedAt: message.receivedAt,
          );
          if (facts.isNotEmpty) {
            SmsFactsOutbox(store.database).enqueue(
              namespace,
              message,
              facts,
              sourceKey: key,
            );
          }
        }
        // High-confidence non-spending classifications are terminal on the
        // device. They must not wait for the hosted parser, where they would
        // otherwise be uploaded as raw SMS and potentially reappear as
        // review items. Transaction and bill observations retain the
        // existing sync behavior until their structured server contracts
        // are added.
        if (observation.disposition == LocalSmsDisposition.localIgnore) {
          // Phase 2: a terminal local acknowledgement no longer means the
          // server never learns — recognized non-spend shapes mint typed
          // facts queued for POST /sms/facts. The raw body still never
          // leaves the device through this path.
          final facts = buildSmsFactsForObservation(
            body: message.body,
            observation: observation,
            receivedAt: message.receivedAt,
          );
          if (facts.isNotEmpty) {
            SmsFactsOutbox(store.database).enqueue(
              namespace,
              message,
              facts,
              sourceKey: key,
            );
          }
          intake.acknowledge(namespace, key);
        }
        // Billing dates are selected across the captured inbox by the server.
        // A capture page is not a complete cycle, so writing the first date
        // here would lock in an older or reminder SMS before history arrives.
      } else {
        intake.recordDecision(
          namespace,
          sourceKey: key,
          decision: 'unparsed_financial',
          state: 'pending',
          reasonCode: triage.reasonCode,
          receivedAt: message.receivedAt.millisecondsSinceEpoch,
          policyVersion: 'v1',
        );
      }
      db.execute('RELEASE SAVEPOINT sms_capture');
    } catch (_) {
      db.execute('ROLLBACK TO SAVEPOINT sms_capture');
      db.execute('RELEASE SAVEPOINT sms_capture');
      rethrow;
    }
  }
}
