import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../support/rules.dart';
import '../support/sync_harness.dart';

// A phone that kept the server-read (old pipeline) transaction for a message AND read the same message itself
// shows two rows and adds the payment twice. The Activity list, the Spending totals and the Spending list all
// read the ledger model, so the model must hold one row per message.
void main() {
  test('one SMS, one old-pipeline copy and one phone-read row: counted once in Spending', () async {
    final bundle = testRuleBundle();
    final encoded = jsonEncode(bundle.toJson());
    final device = Device('twin');
    addTearDown(device.dispose);
    final runtime = SmsV2Runtime(
      financial: device.financial,
      namespace: harnessNamespace,
      client: MockClient((_) async => throw StateError('offline')),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'twin',
      appVersion: '2',
      headers: () async => {},
      verify: (value) async => value == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
      isOffline: () => true,
      clock: () => DateTime.utc(2026, 10, 30),
    );
    const sender = 'VA-UNIONB-T';
    const body =
        'Union Bank of India A/c *8565 Debited Rs:4000.00 on 13-10-2026 19:30:59 by Mob Bk ref no 104241294136, Fvg: Asha Rao Avl Bal Rs:2895.92. Not you?Call 18002333';
    final sms = QueuedSms(sender: sender, body: body, receivedAt: DateTime.utc(2026, 10, 13, 14, 4));
    SmsIntakeRepository(device.database).remember(harnessNamespace, sms);
    await runtime.capture([sms], backfill: true);
    final key = smsSourceKey(harnessNamespace, sender, body);

    // What the server's old pipeline saved for this message and the phone pulled: no merchant, no received time.
    device.financial.saveTransactions(harnessNamespace, [
      TransactionEntry(
        id: 'server-txn-1',
        pipelineVersion: 1,
        sourceKey: key,
        amount: Money.fromRupees(4000),
        occurredAt: DateTime.utc(2026, 10, 13, 14, 0, 59),
        entryKind: TxnEntryKind.spend,
        instrument: TxnInstrument.upiBank,
        source: 'sms',
        status: 'active',
      ),
    ]);

    final stored = device.financial.entities(harnessNamespace, 'transactions').map(TransactionEntry.fromJson).where((t) => t.status == 'active').toList();
    expect(stored.length, 2, reason: 'the phone really holds two active rows for the one message');

    final model = loadLedgerReadModel(db: device.db, financialStore: device.financial, namespace: harnessNamespace);
    final active = model.transactions.where((t) => t.status == 'active').toList();
    expect([for (final t in active) t.merchantName], ['Asha Rao'], reason: 'only the row the phone read, with its payee');

    final report = model.spendReport(
      SpendReportQuery.custom(from: DateTime(2026, 10, 1), to: DateTime(2026, 11, 1)),
      DateTime.utc(2026, 10, 30),
    );
    expect(report.spend.total.paise, 400000, reason: 'Rs 4,000 once, not Rs 8,000');
    expect(report.spend.txnCount, 1);
  });
}
