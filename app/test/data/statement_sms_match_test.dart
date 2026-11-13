// An imported statement row that an SMS already explains is shown as a probable
// duplicate, not added a second time. Invented data only.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/import_models.dart';
import 'package:pandapay/data/statement_sms_match.dart';
import 'package:pandapay/data/transaction_import_pipeline.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

ParsedStatementLine row(String account, int day, double rupees, {bool credit = false, String text = 'UPI/DR/116581668664/Sample Shop/YESB'}) =>
    ParsedStatementLine(
      date: DateTime(2026, 1, day),
      description: text,
      amount: Money.fromRupees(rupees),
      isCredit: credit,
      sourceAccount: account,
    );

TransactionEntry sms(
  String id,
  int day,
  double rupees, {
  TxnEntryKind kind = TxnEntryKind.spend,
  TxnInstrument instrument = TxnInstrument.upiBank,
  String? last4 = '8648',
  String? merchant = 'SAMPLE SHOP',
  String source = 'sms',
  String? cardId,
}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(rupees),
  occurredAt: DateTime(2026, 1, day, 10, 30),
  merchantName: merchant,
  entryKind: kind,
  instrument: instrument,
  accountLast4: last4,
  userCardId: cardId,
  source: source,
  status: 'active',
);

void main() {
  test('the same amount, direction and account within two days is explained', () {
    final out = rowsExplainedBySms([row('SBI ••8648', 5, 706.82)], [sms('a', 4, 706.82)]);
    expect(out.keys, [0]);
    expect(out[0], contains('already in your SMS history'));
    expect(out[0], contains('SAMPLE SHOP'));
  });

  test('another account, another direction, or three days away is not', () {
    expect(rowsExplainedBySms([row('SBI ••8648', 5, 706.82)], [sms('a', 5, 706.82, last4: '4911')]), isEmpty);
    expect(rowsExplainedBySms([row('SBI ••8648', 5, 706.82, credit: true)], [sms('a', 5, 706.82)]), isEmpty);
    expect(rowsExplainedBySms([row('SBI ••8648', 10, 706.82)], [sms('a', 5, 706.82)]), isEmpty);
  });

  test('only SMS-derived bank-account transactions count', () {
    final rows = [row('SBI ••8648', 5, 706.82)];
    expect(rowsExplainedBySms(rows, [sms('a', 5, 706.82, source: 'statement')]), isEmpty);
    expect(rowsExplainedBySms(rows, [sms('a', 5, 706.82, instrument: TxnInstrument.creditCard)]), isEmpty);
    expect(rowsExplainedBySms(rows, [sms('a', 5, 706.82, instrument: TxnInstrument.wallet)]), isEmpty);
    expect(rowsExplainedBySms(rows, [sms('a', 5, 706.82, cardId: 'card')]), isEmpty);
  });

  test('one saved transaction explains one row', () {
    final out = rowsExplainedBySms(
      [row('SBI ••8648', 5, 200), row('SBI ••8648', 5, 200)],
      [sms('a', 5, 200)],
    );
    expect(out, hasLength(1));
  });

  test('money in is matched to money in', () {
    final out = rowsExplainedBySms(
      [row('SBI ••8648', 6, 5000, credit: true)],
      [sms('a', 6, 5000, kind: TxnEntryKind.income)],
    );
    expect(out.keys, [0]);
  });

  test('an investment return is money in, so it matches a credit row only', () {
    final returned = sms('a', 6, 5000, kind: TxnEntryKind.investmentReturn);
    expect(
      rowsExplainedBySms([row('SBI ••8648', 6, 5000, credit: true)], [returned]).keys,
      [0],
    );
    expect(
      rowsExplainedBySms([row('SBI ••8648', 6, 5000)], [returned]),
      isEmpty,
    );
  });

  test('the import review leaves such a row out unless the person keeps both', () {
    final session = TransactionImportSession(
      fileDigest: 'file',
      importSource: 'statement',
      statement: ParsedStatement(transactions: [row('SBI ••8648', 5, 706.82), row('SBI ••8648', 6, 99)]),
    );
    session.destinations['SBI ••8648'] = '';
    session.checkSavedDuplicates([sms('a', 5, 706.82)]);
    expect(session.exclusionReason(0), contains('already in your SMS history'));
    expect(session.exclusionReason(1), isNull);
    session.confirmSeparate(0);
    session.checkSavedDuplicates([sms('a', 5, 706.82)]);
    expect(session.exclusionReason(0), isNull);
  });
}
