import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  group('False Positive Audit - Legitimate Financial SMS Formats', () {
    final Map<String, List<Map<String, String>>> testCasesByCategory = {
      'Debit Alerts - UPI P2P': [
        {
          'sender': 'HDFCBK',
          'body': 'Sent Rs. 500.00 to rahul@okaxis from HDFC Bank A/c XX1234 on 22-10-26. UPI Ref 628100123456.',
        },
        {
          'sender': 'SBIUPI',
          'body': 'Dear SBI User, your A/c ending 1234 debited by Rs 500.00 on 22Oct26 transfer to UPI/628100123456/Rahul. Avl Bal Rs 12000.00.',
        },
        {
          'sender': 'AXISBK',
          'body': 'Paid Rs. 150.00 to Rohan via Google Pay from Axis Bank A/c XX4321 on 22-10-26. UPI Ref 123456789012.',
        },
        {
          'sender': 'ICICIB',
          'body': 'Rs 500.00 debited from A/c XX1234 to user via PhonePe. UPI Ref 987654321012.',
        },
      ],
      'Debit Alerts - UPI P2M': [
        {
          'sender': 'HDFCBK',
          'body': 'Paid Rs. 350.00 to Starbucks on UPI from HDFC Bank A/c XX1234 on 22-10-26. UPI Ref 324152637485.',
        },
        {
          'sender': 'ICICIB',
          'body': 'Rs 250.00 debited from A/c XX4321 for UPI-P2M txn at DMART on 22-10-26. Bal INR 5,400.00.',
        },
        {
          'sender': 'PAYTM',
          'body': 'Rs. 99 paid to Swiggy using UPI on 22-10-26. UPI Ref 564738291012.',
        },
      ],
      'Debit Alerts - POS Swipe': [
        {
          'sender': 'ICICIB',
          'body': 'INR 1,250.00 spent on your ICICI Bank Debit Card XX5678 at RELIANCE RETAIL on 22-Oct-26. Avl Bal INR 15,200.00.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'Transaction of Rs.450.00 made on HDFC Bank Debit Card ending 1234 at SHELL PETROL PUMP on 22-10-26.',
        },
      ],
      'Debit Alerts - ATM Withdrawal': [
        {
          'sender': 'SBIINB',
          'body': 'Rs. 2000.00 withdrawn from ATM using SBI Debit Card XX1234 on 22-10-26. Avl Bal Rs 8,000.00.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'Cash withdrawal of INR 5,000 on your HDFC Bank card XX9999 at ATM on 22-10-26.',
        },
      ],
      'Debit Alerts - NetBanking': [
        {
          'sender': 'HDFCBK',
          'body': 'INR 10,000.00 debited from A/c XX1234 via NetBanking for transfer to XX5678 on 22-10-26.',
        },
        {
          'sender': 'AXISBK',
          'body': 'Your A/c XX1234 has been debited for INR 4,500.00 through Net Banking on 22-10-26. Avl Bal INR 22,000.00.',
        },
      ],
      'Debit Alerts - IMPS': [
        {
          'sender': 'HDFCBK',
          'body': 'Dear Customer, INR 3,500.00 debited from your A/c XX1234 on 22-Oct-26 by IMPS ref 123456789012.',
        },
        {
          'sender': 'ICICIB',
          'body': 'IMPS txn of Rs 2000 debited from A/c XX4321 to XX8765 on 22-Oct-26. Avl Bal Rs 14,000.',
        },
      ],
      'Debit Alerts - NEFT / RTGS': [
        {
          'sender': 'SBIINB',
          'body': 'Your A/c XX1234 is debited with INR 25,000.00 on 22-OCT-26 towards NEFT transfer to Biller. UTR SBIN123456.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'NEFT Outward txn Rs 15000 debited from a/c XX1234 on 22-10-26. Ref N123456789.',
        },
        {
          'sender': 'KOTAKB',
          'body': 'Rs. 2,50,000.00 debited from A/c XX1234 towards RTGS txn UTR KKBK123456 on 22-10-26.',
        },
      ],
      'Credit Alerts - Salary Credits': [
        {
          'sender': 'HDFCBK',
          'body': 'Your A/c XX1234 is credited with INR 75,000.00 on 30-Oct-26 as Salary from TECH CORP. Avl Bal INR 85,000.00.',
        },
        {
          'sender': 'ICICIB',
          'body': 'Salary credit of Rs 65000 to A/c XX9999 on 31-Oct-26 by INFOSYS LTD. Avl Bal Rs 70,500.',
        },
      ],
      'Credit Alerts - NEFT / IMPS / UPI Received': [
        {
          'sender': 'HDFCBK',
          'body': 'Your A/c XX1234 is credited by Rs. 5000.00 on 22-Oct-26 by NEFT transfer from ABC CORP.',
        },
        {
          'sender': 'SBIINB',
          'body': 'INR 2,000.00 credited to A/c XX1234 through IMPS from RAHUL on 22-Oct-26.',
        },
        {
          'sender': 'AXISBK',
          'body': 'Received Rs 1200.00 in your A/c XX1234 from Priya via UPI on 22-10-26. Ref 987654321.',
        },
        {
          'sender': 'PYTM',
          'body': 'You have received INR 500.00 in your Paytm Payments Bank A/c XX1234 on 22-10-26 via UPI.',
        },
      ],
      'Credit Alerts - Refund & Reversal & Cashback': [
        {
          'sender': 'HDFCBK',
          'body': 'Refund of Rs. 499 credited to your card XX1234 from AMAZON on 22-Oct-26.',
        },
        {
          'sender': 'ICICIB',
          'body': 'INR 1,299.00 refunded to A/c XX1234 for cancelled order on 22-Oct-26.',
        },
        {
          'sender': 'SBIINB',
          'body': 'Rs. 500.00 reversed to your A/c XX1234 on 22-Oct-26.',
        },
        {
          'sender': 'AXISBK',
          'body': 'Reversal of INR 200.00 credited back to your account XX1234 on 22-10-26.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'Cashback of Rs. 50 credited to your account XX1234 on 22-10-26.',
        },
        {
          'sender': 'SBICRD',
          'body': 'Rs 100 cashback credited to your credit card XX4321 on 22-10-26.',
        },
      ],
      'Credit Card Alerts - Online / POS / Intl / Repayments / Fees': [
        {
          'sender': 'AXISBK',
          'body': 'INR 2,499.00 spent on Axis Bank Credit Card XX4321 at FLIPKART on 22-Oct-26. Avl Limit INR 85,000.00.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'Alert: Card XX1234 used for INR 850.00 at UBER on 22-Oct-26.',
        },
        {
          'sender': 'SBICRD',
          'body': 'Your SBI Card ending 5678 was used for Rs 1800 at APOLLO PHARMACY on 22-Oct-26.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'USD 25.00 (approx INR 2,100.00) spent on your HDFC Bank Card ending 1234 at GITHUB on 22-10-26.',
        },
        {
          'sender': 'SBICRD',
          'body': 'Payment of Rs 15000 received towards your SBI Card XX4321 on 20-Oct-26.',
        },
        {
          'sender': 'ICICIB',
          'body': 'Annual fee of INR 1,500.00 plus GST debited to your ICICI Credit Card XX4321 on 22-Oct-26.',
        },
      ],
      'Bill & Statement Notifications': [
        {
          'sender': 'AXISBK',
          'body': 'Axis Bank Card XX4321 statement generated. Total Due Rs 12,500, Min Due Rs 1,250, Due Date 15-Nov-26.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'Total Amount Due on your HDFC Credit Card XX1234 is INR 8,900.00 and Min Due is INR 900.00 pay by 10-Nov-26.',
        },
        {
          'sender': 'BESCOM',
          'body': 'BESCOM bill of Rs. 1450 generated for account 87654321 due date 12-Nov-26.',
        },
        {
          'sender': 'LICIND',
          'body': 'Dear Customer, premium of Rs 12,450 for LIC Policy 123456789 is due on 28-Oct-26.',
        },
      ],
      'AutoPay & Mandates': [
        {
          'sender': 'HDFCBK',
          'body': 'Auto debit of Rs 5000 for SIP investment towards NIPPON INDIA MUTUAL FUND from A/c XX1234 on 22-10-26.',
        },
        {
          'sender': 'ICICIB',
          'body': 'SIP installment of INR 2,500.00 successfully debited from your A/c XX1234 on 22-10-26.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'Your AutoPay mandate of INR 499 for HOTSTAR is scheduled for 25-Oct-26 from A/c XX1234.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'AutoPay execution failed for NETFLIX on your A/c XX1234 due to insufficient funds.',
        },
      ],
      'Investment & Broker Payouts': [
        {
          'sender': 'ZERODH',
          'body': 'Zerodha: Payout of INR 12,450.00 has been processed to your bank account XX1234 on 22-10-26.',
        },
        {
          'sender': 'GROWW',
          'body': 'Groww: Withdrawal of Rs 5,000.00 to your bank account XX1234 has been initiated on 22-10-26.',
        },
        {
          'sender': 'UPSTOX',
          'body': 'Upstox: Payout request of INR 4,500.00 processed to your bank account ending 1234 on 22-10-26.',
        },
      ],
      'Edge Cases - Marketing Footers & -P Senders & Non-standard Currency & Recharges & Hinglish': [
        {
          'sender': 'HDFCBK',
          'body': 'INR 500 debited from card XX1234. Get 5% cashback on next order.',
        },
        {
          'sender': 'AXISBK',
          'body': 'Rs 1500 spent on card XX1234 at STORE. Apply now for personal loan up to 5L.',
        },
        {
          'sender': 'SBIINB',
          'body': 'A/c XX1234 debited by Rs 250.00 on 22-10-26. Enjoy exciting offers on dining.',
        },
        {
          'sender': 'SBIINB',
          'body': 'A/c XX1234 debited by Rs 250.00 on 22-10-26. Get 5% cashback on dining.',
        },
        {
          'sender': 'HDFCBK-P',
          'body': 'Rs 500.00 debited from your A/c XX1234 on 22-10-26.',
        },
        {
          'sender': 'SBICRD-P',
          'body': 'Your card ending 4321 was debited Rs. 1,200 at RELIANCE on 22-10-26.',
        },
        {
          'sender': 'HDFCBK-P',
          'body': 'A/c ending 1234 debited by Rs 500.00 on 22-10-26.',
        },
        {
          'sender': 'HDFCBK',
          'body': '500.00 INR debited from A/c XX1234 on 22-10-26.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'Rs.1,250/- spent on your card XX1234 at SWIGGY.',
        },
        {
          'sender': 'JIOINF',
          'body': 'Recharge of Rs.349 successful on your Jio number 9876543210 on 22-10-26.',
        },
        {
          'sender': 'TATASKY',
          'body': 'DTH recharge of Rs. 450 completed for subscriber 123456 on 22-10-26.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'A/c XX1234 me INR 500 debit hua on 22-10-26.',
        },
        {
          'sender': 'SBIINB',
          'body': 'Aapke A/c XX1234 se Rs 500 debit kiya gaya hai on 22-10-26.',
        },
        {
          'sender': 'HDFCBK',
          'body': 'A/c XX1234 me Rs. 1000 credit hua hai on 22-10-26.',
        },
      ],
    };

    for (final entry in testCasesByCategory.entries) {
      final category = entry.key;
      final cases = entry.value;

      group(category, () {
        for (final tc in cases) {
          final sender = tc['sender']!;
          final body = tc['body']!;

          test('${body.length > 50 ? body.substring(0, 50) : body}...', () {
            final isNoise = LocalSmsParser.isNonTransactionNoise(sender, body);
            final triage = classifySmsTriage(sender, body);
            final captures = capturesFinancialSms(body, sender: sender);

            // Audit expectations for legitimate alerts:
            // 1. Should not be rejected as noise
            // 2. Triage kind must be financialCandidate
            // 3. capturesFinancialSms must be true
            expect(isNoise, isFalse, reason: 'Rejected as non-transaction noise: $body');
            expect(triage.kind, SmsTriageKind.financialCandidate,
                reason: 'Triage failed (${triage.kind}, ${triage.reasonCode}): $body');
            expect(captures, isTrue, reason: 'capturesFinancialSms returned false: $body');
          });
        }
      });
    }

    test('Non-transaction noise: credit line marketing and betting spam are rejected', () {
      final noiseMessages = [
        (
          'VK-BFDLPS-S',
          'Notice: Your digital credit power is now active on Bajaj Markets. View your updated limit here: 1kx.in/TaEc4L T&C Apply.',
        ),
        (
          'VK-BFDLPS-S',
          'New Credit alert Your loan limit is revised. Click here to know more: 1kx.in/khOzn2 Bajaj Markets T&C',
        ),
        (
          'CP-DISHTV-S',
          'FRPendingDTIL IPL trusted betting site GullyBET, Instant withdrawal. Fancy bet All games, casino, slots, aviator, cockfight. Huge bonus gbets.win/1w1',
        ),
      ];

      for (final record in noiseMessages) {
        final sender = record.$1;
        final body = record.$2;
        expect(LocalSmsParser.isNonTransactionNoise(sender, body), isTrue,
            reason: 'Expected noise rejection for: ' + body);
        expect(classifySmsTriage(sender, body).kind, SmsTriageKind.promotion,
            reason: 'Expected promotion triage for: ' + body);
        expect(capturesFinancialSms(body, sender: sender), isFalse,
            reason: 'capturesFinancialSms should be false for noise: ' + body);
      }
    });
  });
}
