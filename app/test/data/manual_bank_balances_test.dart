import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';

void main() {
  test('manual bank balances persist by issuer and account suffix', () {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}pandapay-manual-bank-${DateTime.now().microsecondsSinceEpoch}.sqlite',
    );
    final database = AppDatabase.openFile(file.path);
    final store = FinancialStore(database);
    try {
      store.setManualBankBalance(
        'user:test',
        issuer: 'HDFC Bank',
        accountLast4: '1797',
        balance: Money.fromRupees(12345.67),
      );

      final saved = store.manualBankBalances('user:test')['hdfc:1797'];
      expect(saved?.balance, Money.fromRupees(12345.67));
      expect(saved?.updatedAt, isNotNull);

      store.clearManualBankBalance(
        'user:test',
        issuer: 'hdfc',
        accountLast4: '1797',
      );
      expect(store.manualBankBalances('user:test'), isEmpty);
    } finally {
      store.dispose();
      database.close();
      if (file.existsSync()) file.deleteSync();
    }
  });
}
