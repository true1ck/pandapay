import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/features/activity/needs_review_clustering.dart';

LocalSmsObservation? _parse(String sender, String body, DateTime at) =>
    LocalSmsParser.parse(
      namespace: 'test',
      sender: sender,
      body: body,
      receivedAt: at,
    );

void main() {
  // Synthetic fixtures only: never copy real phone numbers or bill amounts.
  group('JioHome bill reminders are bills, never review items', () {
    test('"due for payment on <date>" yields due date and amount', () {
      final obs = _parse(
        'JIOFIB-S',
        'Your bill dated 15-06-2026 for JioHome connection with JioFixedVoice '
        'Number [redacted] is due for payment on 20-06-2026.\n'
        'Total amount payable : Rs.100.00.\n'
        'To pay your bill, click www.jio.com/r/TESTCODE1\n'
        'Overdue charges will be applicable, in case of delay in payment. '
        'Kindly ignore, if already paid.',
        DateTime(2026, 6, 18, 14, 59),
      );
      expect(obs?.eventType, LocalSmsEventType.bill);
      expect(obs?.dueDate, DateTime(2026, 6, 20));
      expect(obs?.amountDue?.paise, 10000);
      expect(obs?.billerName, 'JioHome');
    });

    test('"due for payment today" uses the SMS day as the due date', () {
      final obs = _parse(
        'JIOFBR-S',
        'Dear Customer,\nBill dated 26-Oct-26 for your JioHome connection with '
        'JioFixedVoice Number [redacted] is due for payment today. Total '
        'amount payable is Rs. 100.00.\nPlease pay immediately to enjoy '
        'uninterrupted services.\nTo pay now, click www.jio.com/GetMyJio\n'
        'Kindly ignore, if already paid.\nTeam JioHome',
        DateTime(2026, 11, 1, 14, 10),
      );
      expect(obs?.eventType, LocalSmsEventType.bill);
      expect(obs?.dueDate, DateTime(2026, 11, 1));
      expect(obs?.amountDue?.paise, 10000);
    });
  });

  group('review clustering templates', () {
    test('same reminder with different link codes shares one template', () {
      String t(String code) => normalizeBodyForClustering(
          'Total amount payable : Rs.100.00. To pay, click www.jio.com/r/$code',
      );
      expect(t('TESTCODE1'), t('TESTCODE2'));
    });

    test('month/year periods and reference ids do not split a cluster', () {
      expect(
        normalizeBodyForClustering(
          'EPFO: contribution for 09/2026 received. Ref TXN8842KD91A',
        ),
        normalizeBodyForClustering(
          'EPFO: contribution for 10/2026 received. Ref TXN1190ZZ73B',
        ),
      );
    });
  });
}
