import 'package:pandapay_domain/pandapay_domain.dart' show CardProduct;

import '../../../data/local/financial_store.dart';
import '../../../data/user_cards_repository.dart' show UserCard;
import '../storage/instrument_store.dart';
import 'card_transaction_relinker.dart';
import 'instrument_seeder.dart';

/// Run right after a wallet card is stored (and by anything else that changes
/// the wallet): links each wallet card to the card the messages already found,
/// then gives that card its saved transactions.
///
/// Before this, adding a card after the SMS import did nothing for the
/// transactions already imported: the link only happened at the next incoming
/// message, and even then only the card record changed.
///
/// Returns how many transactions were updated. Does nothing before the SMS
/// pipeline has stored a single instrument, or before its tables exist; the
/// first capture seeds the wallet then. Throws on a storage error: callers
/// that must never fail (adding a card) catch it.
int linkWalletCards(
  FinancialStore financial,
  String namespace,
  List<CardProduct> catalogue,
) {
  final db = financial.database.db;
  final ready = db
      .select(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name IN ('v2_facts','v2_instruments','v2_sync_state')",
      )
      .length;
  if (ready != 3) return 0;
  final store = InstrumentStore(db, namespace: namespace);
  if (store.count() == 0) return 0;
  final report = InstrumentSeeder(store).seed(
    cards: financial
        .entities(namespace, 'cards')
        .map(UserCard.fromJson)
        .toList(),
    issuerSlugOf: cardIssuerSlugFromCatalogue(catalogue),
    bankAccounts: const [],
  );
  return CardTransactionRelinker(
    financial,
    namespace: namespace,
  ).relinkAll(report.linked);
}
