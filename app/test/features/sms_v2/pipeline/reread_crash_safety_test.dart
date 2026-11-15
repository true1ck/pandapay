import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/ai_withdrawal.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';

import '../support/rules.dart';
import '../support/sync_harness.dart';

// A re-read withdraws a message's saved transaction, then reads the message again. If the app is closed (or
// capture fails) in between, the transaction must come back the next time the app runs, not wait for a re-import.
void main() {
  test('a re-read cut short after the withdrawal is finished by the next sync, and only then', () async {
    final bundle = testRuleBundle();
    final encoded = jsonEncode(bundle.toJson());
    final device = Device('crash');
    addTearDown(device.dispose);
    final runtime = SmsV2Runtime(
      financial: device.financial,
      namespace: harnessNamespace,
      client: MockClient((_) async => throw StateError('offline')),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'crash',
      appVersion: '2',
      headers: () async => {},
      verify: (value) async => value == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
      clock: () => DateTime.utc(2026, 11, 30),
    );
    const sender = 'VA-UNIONB-T';
    const body =
        'Union Bank of India A/c *8565 Debited for Rs:2900.00 on 21-10-2026 19:28:42 by Mob Bk ref no 629453274545, Fvg: Asha Rao Avl Bal Rs:594.92. Not you?Call 18002333';
    final sms = QueuedSms(sender: sender, body: body, receivedAt: DateTime.utc(2026, 10, 21, 14));
    SmsIntakeRepository(device.database).remember(harnessNamespace, sms);
    await runtime.capture([sms], backfill: true);

    List<String> rows() => [
      for (final t in device.financial.entities(harnessNamespace, 'transactions').map(TransactionEntry.fromJson))
        if (t.status == 'active') '${t.amount.paise}:${t.merchantName}',
    ];
    expect(rows(), ['290000:Asha Rao']);

    // The cut-short re-read: pending written, transaction withdrawn, then the app dies.
    final source = smsSourceKey(harnessNamespace, sender, body);
    final state = SyncStateStore(device.db, namespace: harnessNamespace);
    state.put(SmsV2Runtime.pendingRereadKey, jsonEncode([source]));
    AiWithdrawal(financial: device.financial, namespace: harnessNamespace, bundle: bundle).withdraw([source]);
    expect(rows(), isEmpty, reason: 'withdrawn: no transaction until it is read again');

    // The next run of the app.
    expect(await runtime.finishPendingReread(), 1);
    expect(rows(), ['290000:Asha Rao'], reason: 'the transaction is back, once');
    expect(state.get(SmsV2Runtime.pendingRereadKey), '', reason: 'nothing left pending');
    expect(await runtime.finishPendingReread(), 0, reason: 'a second run does nothing');
    expect(rows(), ['290000:Asha Rao']);
  });
}
