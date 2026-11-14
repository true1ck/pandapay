import 'package:pandapay_domain/pandapay_domain.dart' show TxnRail;
import '../../data/local_first/command_outbox.dart';
import '../../data/user_cards_repository.dart';

/// WP-C5: changing how a transaction was paid, queued while offline.
///
/// Setting a method is a state ("this transaction was paid by X"), so repeating
/// it is harmless; a later command for the same transaction replaces an earlier
/// unsent one. The payload carries the wire value, or `null` to clear.
abstract final class PaymentMethodCommand {
  static const set = 'transaction_payment_method';

  /// Instrument / entry kind of a transaction, through the transaction's own
  /// PATCH route (the legacy sync writer refuses these typed columns, so they
  /// never ride the sync queue). Also a state, so a repeat is harmless.
  static const setTyped = 'transaction_typed_fields';
}

Map<String, CommandHandler> paymentMethodCommandHandlers(
  UserCardsRepository repo,
) => {
  PaymentMethodCommand.setTyped: (p) {
    // Amount / category / card / rail are typed columns the legacy sync writer
    // refuses, so they travel here (the transaction's own PATCH route).
    final hasCategoryKey =
        p.containsKey('categoryId') || p.containsKey('userCategoryId');
    final categoryId = p['categoryId'] as String?;
    final userCategoryId = p['userCategoryId'] as String?;
    final railWire = p['rail'] as String?;
    return repo.editTransaction(
      p['id'] as String,
      amountInr: (p['amountInr'] as num?)?.toDouble(),
      occurredAt: p['occurredAt'] == null
          ? null
          : DateTime.parse(p['occurredAt'] as String),
      categoryId: categoryId,
      userCategoryId: userCategoryId,
      clearCategory:
          hasCategoryKey && categoryId == null && userCategoryId == null,
      userCardId: p['userCardId'] as String?,
      rail: railWire == null
          ? null
          : TxnRail.values.where((r) => _railWire(r) == railWire).firstOrNull,
      instrument: p['instrument'] == null
          ? null
          : TxnInstrument.fromJson(p['instrument'] as String),
      entryKind: p['entryKind'] == null
          ? null
          : TxnEntryKind.fromJson(p['entryKind'] as String),
    );
  },
  PaymentMethodCommand.set: (p) {
    final method = p['paymentMethod'] as String?;
    return repo.editTransaction(
      p['id'] as String,
      paymentMethod: method,
      clearPaymentMethod: method == null,
    );
  },
};

String _railWire(TxnRail rail) => switch (rail) {
  TxnRail.upiQr => 'upi_qr',
  TxnRail.swipe => 'swipe',
  TxnRail.online => 'online',
  TxnRail.contactless => 'contactless',
  TxnRail.atm => 'atm',
  TxnRail.emi => 'emi',
  TxnRail.unknown => 'unknown',
};
