import '../../data/local_first/command_outbox.dart';
import '../../data/user_cards_repository.dart';

/// WP-C5: changing how a transaction was paid, queued while offline.
///
/// Setting a method is a state ("this transaction was paid by X"), so repeating
/// it is harmless; a later command for the same transaction replaces an earlier
/// unsent one. The payload carries the wire value, or `null` to clear.
abstract final class PaymentMethodCommand {
  static const set = 'transaction_payment_method';
}

Map<String, CommandHandler> paymentMethodCommandHandlers(
  UserCardsRepository repo,
) => {
  PaymentMethodCommand.set: (p) {
    final method = p['paymentMethod'] as String?;
    return repo.editTransaction(
      p['id'] as String,
      paymentMethod: method,
      clearPaymentMethod: method == null,
    );
  },
};
