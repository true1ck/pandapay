import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/csv_statement_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart' show TxnInstrument;

void main() {
  test(
    'tags are distinct from subcategories and survive delimiter-containing JSON names',
    () {
      final result = parseFlexibleCsvStatement('''
Date,Description,Amount,Category,Subcategory,Tags
2026-10-02,Cafe,500,Dining,Lunch,"[""Thailand, 2026"",""Office""]"
''');
      final row = result.transactions.single;
      expect(row.categoryHint, 'Dining');
      expect(row.subcategoryHint, 'Lunch');
      expect(row.tagNames, ['Thailand, 2026', 'Office']);
    },
  );
  test('detects reordered debit CSV columns and ignores metadata', () {
    final result = parseFlexibleCsvStatement('''
Exported by Example Bank
Narration,Txn Date,Reference,Debit,Balance
"Coffee, MG Road",14/10/2026,ABC123,₹450.00,12000.00
Groceries,2026-10-15,ABC124,1250.00,11750.00
''');

    expect(result.transactions, hasLength(2));
    expect(result.transactions.first.description, 'Coffee, MG Road');
    expect(result.transactions.first.amount.rupees, 450);
    expect(result.transactions.last.date, DateTime(2026, 10, 15));
  });

  test('supports semicolon exports with separate credit column', () {
    final result = parseFlexibleCsvStatement('''
Date;Details;Debit;Credit
15 Oct 2026;Refund from store;;500.00
16 Oct 2026;Fuel;418.83;
''');

    expect(result.transactions, hasLength(2));
    expect(result.transactions.first.isCredit, isTrue);
    expect(result.transactions.last.amount.rupees, 418.83);
  });

  test(
    'spend report exports retain kind, category, payment method, and note',
    () {
      final result = parseFlexibleCsvStatement('''
Date,Amount (INR),Merchant,Category,Subcategory,Card,Paid with,Kind,Rail,Source,Rewards (INR),Note
2026-10-02,275.50,Cafe,Dining,Coffee,MoneyBack,credit_card,income,online,manual,0.00,Edited note
''');

      final row = result.transactions.single;
      expect(row.description, 'Cafe');
      expect(row.amount.rupees, 275.5);
      expect(row.isCredit, isTrue);
      expect(row.categoryHint, 'Dining');
      expect(row.subcategoryHint, 'Coffee');
      expect(row.sourceAccount, 'MoneyBack');
      expect(row.instrument, TxnInstrument.creditCard);
      expect(row.rail, 'online');
      expect(row.note, 'Edited note');
    },
  );
}
