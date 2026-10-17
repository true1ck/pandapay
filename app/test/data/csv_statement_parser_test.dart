import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/csv_statement_parser.dart';

void main() {
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
}
