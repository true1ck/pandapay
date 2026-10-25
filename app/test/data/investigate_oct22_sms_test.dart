import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  test('test sms messages from 5996 to 6019', () async {
    final messages = [
      (
        5996,
        'VA-SLCBNK-S',
        'Rs. 859 spent on your credit card xx9080 at slice on 22-Oct-26 (UPI Ref: 629534133759). Not you? Call 080-4832-9999 - slice',
        1792651606529,
      ),
      (
        5997,
        'VD-TNUCRD-S',
        'Important update Sujay, We have credited 12 NeuCoins based on your latest NeuCard statement. Check your dashboard for referral benefits https://m.tneu.in/TNUCRD/n2kWGPp Tata Neu',
        1792661167480,
      ),
      (
        5998,
        'JK-UNIONB-S',
        'A/c *8565 Credited for Rs:1210.00 on 22-10-2026 16:09:01 by Mob Bk ref no 629553994601 Avl Bal Rs:1804.92.Never Share OTP/PIN/CVV-Union Bank of India',
        1792665546713,
      ),
      (
        6002,
        'VA-SLCBNK-S',
        'Rs. 1,110.83 spent on your credit card xx9080 at Wellness forever goa on 22-Oct-26 (UPI Ref: 629506459698). Not you? Call 080-4832-9999 - slice',
        1792688478803,
      ),
      (
        6003,
        'VD-WELFOR-S',
        'Thank you for choosing Wellness Forever. View e-bill of Rs 1110.83 - https://b.wlfr.in/app/q?q=w3HPNMqHU8K Get the App https://wlfr.in/BM6LnT Call on 18002662247',
        1792688490789,
      ),
      (
        6004,
        'VM-SLCBNK-S',
        'Rs. 30 spent on your credit card xx9080 at Mhalasa giroba enterprises on 22-Oct-26 (UPI Ref: 629538779888). Not you? Call 080-4832-9999 - slice',
        1792688788235,
      ),
      (
        6006,
        'CP-ALEGBB-S',
        'Dear sujay_kurtikar_alegra, Payment of Rs.800/- is due. Please pay to avoid disconnection. For online payment visit login.alegragoa.com - Alegra Broadband',
        1792730376110,
      ),
      (
        6009,
        'VM-SLCBNK-S',
        'Rs. 30 spent on your credit card xx9080 at Nikesh dnyaneswar gawade on 23-Oct-26 (UPI Ref: 629668827926). Not you? Call 080-4832-9999 - slice',
        1792732907217,
      ),
      (
        6012,
        'VA-SLCBNK-S',
        'Rs. 100 spent on your credit card xx9080 at Shantesh gurudas gaude on 23-Oct-26 (UPI Ref: 629615403456). Not you? Call 080-4832-9999 - slice',
        1792772876413,
      ),
      (
        6014,
        'AD-YESBNK-S',
        'For the upcoming mandate set for 25-10-26, your account will be debited with Rs.81.00 towards Amazon Pay for the Recurring Bill Payments. If mandate is paused the execution for the same will not happen. - Amazon and Yes Bank.',
        1792833332036,
      ),
      (
        6018,
        'AD-ALEGBB-S',
        'Your request for renewal has been received & processed. Plan details are Plan:PBN_ECO_40Mbps_UL_30Days - Expiry:23-11-2026. Happy Browsing!! -Alegra Broadband',
        1792893527495,
      ),
      (
        6019,
        'AD-MYTNEU-S',
        'Your Goa Electricity bill of Rs. 927.00 is ready. Pay by 2026-11-09 to avoid late charges: https://m.tneu.in/MYTNEU/X0jzNhN - Tata Neu',
        1792896735348,
      ),
    ];

    final db = openInMemoryForTesting();
    final store = FinancialStore(db);
    final importStore = SmsImportStore(store);

    for (final m in messages) {
      final triage = classifySmsTriage(m.$2, m.$3);
      final captures = capturesFinancialSms(m.$3, sender: m.$2);
      final parsed = LocalSmsParser.parse(
        namespace: 'test',
        sender: m.$2,
        body: m.$3,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(m.$4),
      );
      print('--- SMS ${m.$1} (${m.$2}) ---');
      print('Triage: ${triage.kind} (${triage.reasonCode}) | Captures: $captures');
      print('Parsed: event=${parsed?.eventType}, disp=${parsed?.disposition}, amount=${parsed?.amount?.rupees}, due=${parsed?.amountDue?.rupees}, dueDate=${parsed?.dueDate}');
    }

    // Try batch capture
    final queued = messages
        .map(
          (m) => QueuedSms(
            sender: m.$2,
            body: m.$3,
            receivedAt: DateTime.fromMillisecondsSinceEpoch(m.$4),
          ),
        )
        .toList();

    importStore.captureBatch('test', queued);

    final intake = SmsIntakeRepository(db);
    final pending = intake.pending('test');
    print('Pending in intake: ${pending.length}');
    for (final p in pending) {
      print('Pending intake: id=${p.id}, sender=${p.message.sender}');
    }

    final obs = store.entities('test', 'sms_observations');
    print('SMS observations: ${obs.length}');
    for (final o in obs) {
      print('Observation: id=${o['id']}, sender=${o['sender_bank']}, due=${o['due_date']}, biller=${o['biller_name']}, amountDue=${o['amount_due_paise']}');
    }
  });
}
