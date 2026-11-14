import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local_export.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry _row(String id, String merchant, {String? key}) =>
    TransactionEntry(
      id: id,
      sourceKey: key,
      amount: Money.fromPaise(12345),
      occurredAt: DateTime.utc(2026, 10, 15, 8),
      merchantName: merchant,
      source: 'sms',
      status: 'active',
    );

void main() {
  const all = TransactionQuery();
  late AppDatabase db;
  late FinancialStore store;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
  });
  tearDown(() {
    store.dispose();
    db.close();
  });

  List<TransactionEntry> stored() => store.transactions('ns', all)?.rows ?? const [];

  test('export includes a row the server never received (offline, unsynced)', () {
    store.saveTransactions('ns', [_row('server-1', 'Synced Cafe')]);
    store.saveProvisional('ns', _row('local-sms:k1', 'Unsynced, "Quoted" Shop', key: 'k1'));
    expect(store.hasPendingTransactions('ns'), isTrue);

    final csv = buildLocalExport(
      scope: 'transactions',
      format: 'csv',
      transactions: stored(),
      cards: const [],
    );
    expect(csv, startsWith('# transactions\nid,source_account,user_card_id,'));
    expect(csv, contains('Synced Cafe'));
    expect(csv, contains('"Unsynced, ""Quoted"" Shop"'));

    final json =
        jsonDecode(
              buildLocalExport(
                scope: 'all',
                format: 'json',
                transactions: stored(),
                cards: const [],
              ),
            )
            as Map<String, dynamic>;
    expect(json.keys, ['transactions', 'tags', 'cards']);
    expect(
      (json['transactions'] as List).map((r) => (r as Map)['merchant_name']),
      containsAll(['Synced Cafe', 'Unsynced, "Quoted" Shop']),
    );
    expect(((json['transactions'] as List).first as Map)['amount_inr'], 123.45);
  });

  test('scope and CSV sections match the server layout', () {
    final cards = buildLocalExport(
      scope: 'cards',
      format: 'csv',
      transactions: const [],
      cards: const [],
    );
    expect(cards, '# cards\n');
    final all = buildLocalExport(
      scope: 'all',
      format: 'csv',
      transactions: stored(),
      cards: const [],
    );
    expect(all, '# transactions\n\n\n# cards\n');
    expect(
      jsonDecode(
        buildLocalExport(
          scope: 'cards',
          format: 'json',
          transactions: const [],
          cards: const [],
        ),
      ),
      {'cards': <dynamic>[]},
    );
  });
}
