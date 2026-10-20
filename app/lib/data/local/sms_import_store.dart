import '../local_sms_parser.dart';
import '../needs_review_repository.dart';
import '../user_cards_repository.dart';
import '../../features/sms_import/sms_background_queue.dart';
import 'financial_store.dart';
import 'sms_intake_repository.dart';

/// The same capture transaction is used by inbox import, foreground delivery
/// and the Android background isolate. Upload is deliberately separate.
class SmsImportStore {
  final FinancialStore store;
  SmsImportStore(this.store);
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
    if (LocalSmsParser.sensitive(message.body)) return;
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
      final key = intake.capture(namespace, message);
      final observation = LocalSmsParser.parse(
        namespace: namespace,
        sender: message.sender,
        body: message.body,
        receivedAt: message.receivedAt,
        cards: cards,
      );
      if (observation != null) {
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
              : LocalSmsParser.isBankAccountMessage(message.body),
          'card_last4': observation.cardLast4,
          'biller_name': observation.billerName,
          'cadence_hint': observation.cadenceHint,
          'balance_paise': observation.availableBalance?.paise,
          'amount_due_paise': observation.amountDue?.paise,
          'minimum_due_paise': observation.minimumDue?.paise,
          'autopay_limit_paise': observation.autopayLimit?.paise,
          'due_date': observation.dueDate?.toIso8601String(),
          'statement_date': observation.statementDate?.toIso8601String(),
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
        // High-confidence non-spending classifications are terminal on the
        // device. They must not wait for the hosted parser, where they would
        // otherwise be uploaded as raw SMS and potentially reappear as
        // review items. Transaction and bill observations retain the
        // existing sync behavior until their structured server contracts are
        // added.
        if (observation.disposition == LocalSmsDisposition.localIgnore) {
          intake.acknowledge(namespace, key);
        }
        if (observation.dueDate != null && observation.cardLast4 != null) {
          final matching = cards
              .where((c) => !c.isArchived && c.last4 == observation.cardLast4)
              .toList();
          if (matching.length == 1 && matching.single.dueDay == null) {
            final updated = UserCard.fromJson({
              ...matching.single.toJson(),
              'due_day': observation.dueDate!.day,
            });
            // Later messages in this same batch must see the established day.
            cards[cards.indexWhere((card) => card.id == updated.id)] = updated;
            store.replaceCards(namespace, [
              for (final card in cards.where((c) => !c.isArchived))
                if (card.id == updated.id) updated else card,
            ]);
          }
        }
        if (observation.statementDate != null && observation.cardLast4 != null) {
          final matching = cards
              .where((c) => !c.isArchived && c.last4 == observation.cardLast4)
              .toList();
          if (matching.length == 1 && matching.single.statementDay == null) {
            final updated = UserCard.fromJson({
              ...matching.single.toJson(),
              'statement_day': observation.statementDate!.day,
            });
            cards[cards.indexWhere((card) => card.id == updated.id)] = updated;
            store.replaceCards(namespace, [
              for (final card in cards.where((c) => !c.isArchived))
                if (card.id == updated.id) updated else card,
            ]);
          }
        }
      }
      db.execute('RELEASE SAVEPOINT sms_capture');
    } catch (_) {
      db.execute('ROLLBACK TO SAVEPOINT sms_capture');
      db.execute('RELEASE SAVEPOINT sms_capture');
      rethrow;
    }
  }
}
