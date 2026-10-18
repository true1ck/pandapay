import '../local_sms_parser.dart';
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
      db.execute('SAVEPOINT sms_batch');
      try {
        for (final message in messages) {
          capture(namespace, message);
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
    if (LocalSmsParser.sensitive(message.body)) return;
    final db = store.database.db;
    db.execute('SAVEPOINT sms_capture');
    try {
      final key = SmsIntakeRepository(
        store.database,
      ).capture(namespace, message);
      final cards = store
          .entities(namespace, 'cards')
          .map(UserCard.fromJson)
          .toList();
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
          'card_last4': observation.cardLast4,
          'balance_paise': observation.availableBalance?.paise,
          'due_date': observation.dueDate?.toIso8601String(),
        });
        if (observation.transaction != null) {
          store.saveProvisional(namespace, observation.transaction!);
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
