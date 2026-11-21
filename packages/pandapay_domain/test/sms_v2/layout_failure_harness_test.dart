import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:test/test.dart';

/// How often the phone's layout building ends in a layout the server cannot use, measured on invented bank messages
/// (every name, number and value below is made up). It reports WHY each failing layout fails, so a change to the
/// redaction or the matcher shows its effect as a number instead of a guess.
///
/// The phone uploads `smsCleanLayout(smsSkeleton(redaction.body))` and skips a layout the server would refuse, so a
/// refused layout means the message stays in Needs review for ever. "Fixed words" below is the share of the message's
/// words that are still readable text in the layout (a layout with almost none gives the AI and the matcher nothing).
const _corpus = <(String, String)>[
  ('HDFCBK', 'Rs.2,450.00 debited from A/c XX4821 on 12-11-26 to VPA grocerystore@okhdfc (UPI Ref 431287654321). Not you? Call 18002586161'),
  ('HDFCBK', 'Dear Customer, Rs 15000 credited to your A/c XX4821 on 05-Nov-26 by NEFT from ACME INDUSTRIES LTD. Avl bal Rs 62,310.45'),
  ('HDFCBK', 'Thank you for using your HDFC Bank Credit Card ending 7712 for Rs 1,299.00 at AMAZON on 09-11-2026. Available limit Rs 84,000'),
  ('HDFCBK', 'Your AutoPay for Netflix Premium of Rs 649.00 is scheduled on 15-Nov-26 against mandate UPI-AUTOPAY-882134. Reply STOP to cancel'),
  ('SBIINB', 'Dear SBI User, your A/c X4821 is debited by Rs.540.00 on 10Nov26 transfer to RAMESH KUMAR Ref No 331298765432. If not done by you, forward this SMS to 9223008333'),
  ('SBIINB', 'Your A/c X4821 is credited with Rs.25000.00 on 03Nov26. Info: SALARY NOV 2026:ACME INDUSTRIES. The Available balance is Rs.48,200.10. SBI'),
  ('ICICIB', 'ICICI Bank Acct XX482 debited for Rs 3,200.00 on 08-Nov-26; Priya Sharma credited. UPI:431298761234. Call 18002662 for dispute. SMS BLOCK 482 to 9215676766'),
  ('ICICIB', 'Dear Customer, your ICICI Bank Credit Card XX7712 has been used for a transaction of INR 2,150.00 on 11-Nov-26 at Cafe Mocha. Avl Limit: INR 91,000.00'),
  ('AXISBK', 'INR 899.00 spent on Axis Bank Card no. XX1209 on 11-11-26 at SWIGGY. Avl Limit INR 1,20,000. Not you? SMS BLOCK 1209 to 919951860002'),
  ('AXISBK', 'Payment of Rs. 5,432.00 received towards your Axis Bank Credit Card XX1209 on 12-11-26. Thank you for the payment'),
  ('KOTAKB', 'Your transaction for Rs 750.00 against txn ID KMB8812734 has been processed successfully. Thank you for banking with Kotak Mahindra Bank'),
  ('KOTAKB', 'Sent Rs.1200.00 from Kotak Bank AC X4821 to joes.bakery@ybl on 07-11-26.UPI Ref 431287650001. Not You? Call 18002091234'),
  ('JIOINF', 'Dear Customer, your Jio recharge of Rs 299.00 is successful. Plan: 28 days 1.5GB/day valid till 10-Dec-2026. Thank you for choosing Jio'),
  ('JIOINF', 'Jio Fiber bill of Rs 1,179.00 for the period 01-Nov-26 to 30-Nov-26 is due on 15-Nov-26. Pay now to avoid late charges at jio.com'),
  ('BSESMS', 'DEAR INVESTOR,APPLICATION NO.88231 OF ACME LTD IPO HAS BEEN ACCEPTED ON 08-NOV-26.YOU WILL RECEIVE A UPI-MANDATE REQUEST FOR BLOCKING OF FUNDS.NSE TEAM'),
  ('BSESMS', 'UPI MANDATE RECEIVED FOR APPLICATION NO 88231 FOR ACME LTD IPO AMOUNT RS 14,800.00 PLEASE APPROVE ON YOUR UPI APP BEFORE 5PM TODAY'),
  ('LNKRTA', 'Dividend of Rs 3.50 per share for Acme Ltd FY 2025-26 by Acme Ltd has been credited in your bank account on 06-Nov-26. Link Intime'),
  ('ZERODH', 'Hi Asha, your Zerodha funds of Rs 20,000.00 have been added to your trading account on 05-Nov-26. Happy investing'),
  ('PAYTMB', 'Rs 1,000.00 added to your Paytm Wallet on 06-Nov-26. Updated balance Rs 1,350.00. Ref 431287770001'),
  ('PAYTMB', 'You have paid Rs 120.00 to Chai Point from Paytm Wallet on 09-Nov-26. Balance Rs 1,230.00'),
  ('AIRTEL', 'Dear Customer, Rs 399.00 has been successfully recharged on 9876543210. Validity 28 days. Airtel Thanks app: bit.ly/airtelthx'),
  ('BESCOM', 'BESCOM: Electricity bill of Rs 1,845.00 for Account 7701234567 for the month Oct 2026 is due on 20-Nov-26. Pay online at bescom.in'),
  ('FASTAG', 'Dear Customer, Rs 95.00 has been deducted from your FASTag wallet for toll at Hosur Plaza on 10-Nov-26. Balance Rs 410.00'),
  ('LICIND', 'Dear Policyholder, your LIC premium of Rs 12,500.00 for policy 123456789 is due on 28-Nov-26. Please pay to keep your policy in force'),
  ('SIPMFD', 'Your SIP of Rs 5,000.00 in Acme Bluechip Fund - Direct Growth has been processed on 05-Nov-26. Units allotted 42.113. NAV 118.55'),
  ('HDFCBK', 'EMI of Rs 8,250.00 for your Personal Loan A/c 5500123 will be debited on 05-Dec-26. Please keep sufficient balance'),
  ('BAJAJF', 'Dear Customer, your EMI of Rs 4,100.00 towards loan 2001234567 is overdue since 05-Nov-26. Please pay immediately to avoid penalty'),
  ('SBIINB', 'Refund of Rs.1,299.00 for your order has been initiated to your A/c X4821 by Flipkart on 12-Nov-26. It will reflect in 3-5 working days'),
  ('SWIGGY', 'Dear Swiggy customer, your refund reference number for Rs 349.00 is PD88213-R1-R2. Amount will be credited in 5-7 days'),
  ('HDFCBK', 'ATM withdrawal of Rs 5,000.00 from A/c XX4821 at HDFC ATM Koramangala on 11-Nov-26. Avl bal Rs 40,200.00'),
  ('SBIINB', 'Your SBI Credit Card XX7712 statement dated 10-Nov-26 shows total amount due Rs 6,720.00 minimum due Rs 340.00 payable by 28-Nov-26'),
  ('CANBNK', 'An amount of INR 2,000.00 has been DEBITED to your account XX4821 on 12/11/2026 by UPI transfer to Gupta Stores. Total Avail.bal INR 12,450.00 - Canara Bank'),
  ('PNBSMS', 'A/c XX4821 debited INR 700.00 Dt 09-11-26 18:42:11 thru UPI:431298760099 to Meera Textiles. Bal INR 9,800.00. Not you? Call 1800180222 -PNB'),
  ('BOBSMS', 'Rs.4500.00 Dr. from A/c XXXXXX4821 and Cr. to Anil Traders thru UPI Ref No 431287650777. Bal Rs 15,400.00 -BOB'),
  ('IDFCFB', 'Dear Customer, INR 1,150.00 has been credited to your IDFC FIRST Bank A/c XX4821 on 08-Nov-26 towards interest for Oct 2026'),
  ('YESBNK', 'Alert: Your Yes Bank Credit Card XX7712 was used for INR 3,299.00 at Croma Retail on 07-Nov-26. If this was not you call 18001234'),
  ('INDUSB', 'Your IndusInd Bank account XX4821 has been credited with INR 31,000.00 on 02-Nov-26 against salary from ACME INDUSTRIES. Balance INR 55,200.00'),
  ('PHONEP', 'Paid Rs 250.00 to Sharma Sweets via PhonePe UPI on 11-Nov-26. Txn ID T2611231234567890. Contact support if not done by you'),
  ('GPAYIN', 'You received Rs 500.00 from Rahul Verma in your bank account via Google Pay on 10-Nov-26. UPI ID rahul.verma@okaxis'),
  ('MYNTRA', 'Hi Asha, your order 123-4567890 has been shipped and will reach you by 14-Nov-26. Track your package at myntra.com/track'),
  ('ADANIE', 'Dear Consumer, your electricity bill of Rs 2,310.00 for consumer no 55012345 is generated. Last date of payment 22-Nov-26. Adani Electricity'),
  ('HDFCLF', 'Dear Customer, you have received a credit of Rs 1,500.00 in your HDFC Life policy 98765432 towards bonus on 03-Nov-26. Thank you'),
];

class _Result {
  _Result(this.sender, this.layout, this.total, this.unanchored, this.looseRun, this.fixedShare);
  final String sender;
  final String layout;
  final int total;
  final int unanchored;
  final int looseRun;
  final double fixedShare;

  /// Why the server (and so the phone's upload) would refuse this layout, under the limits as they stand.
  String? get refusal {
    if (total > smsMaxAnchoredLayoutWildcards || unanchored > smsMaxLayoutWildcards) return 'too many name slots';
    if (looseRun > smsMaxAdjacentLooseSlots) return 'touching name slots';
    return null;
  }

  /// What the limit was before anchored name slots were counted apart: more than 4 name slots of any kind.
  bool get refusedBefore => total > 4 || looseRun > 2;
}

_Result _measure(String sender, String body) {
  final redacted = redactSms(
    sender: sender,
    body: body,
    observedAt: DateTime.utc(2026, 11, 18),
    options: SmsRedactionOptions(salt: 's'),
  );
  final layout = smsCleanLayout(smsSkeleton(redacted.body));
  final words = RegExp(r'[A-Za-z]{2,}').allMatches(body).length;
  final fixed = RegExp(r'[A-Za-z]{2,}').allMatches(layout.replaceAll(RegExp(r'<[A-Z_]+>'), ' ')).length;
  return _Result(
    sender,
    layout,
    smsLayoutWildcards(layout),
    smsLayoutUnanchoredWildcards(layout),
    smsLayoutLooseRun(layout),
    words == 0 ? 1 : fixed / words,
  );
}

void main() {
  test('layout building on invented bank messages: how many layouts are unusable, and why', () {
    final results = [for (final (sender, body) in _corpus) _measure(sender, body)];
    final refused = results.where((r) => r.refusal != null).toList();
    final refusedBefore = results.where((r) => r.refusedBefore).toList();
    final lowFixed = results.where((r) => r.fixedShare < 0.5).toList();
    final manyParty = results.where((r) => r.total >= 5).toList();

    // ignore: avoid_print
    print('\nlayout harness: ${results.length} messages\n'
        '  refused under the old limit (more than 4 name slots): ${refusedBefore.length}\n'
        '  refused under the current limits: ${refused.length}\n'
        '  5 or more name slots: ${manyParty.length}\n'
        '  under half of the words left readable: ${lowFixed.length}');
    for (final r in results.where((r) => r.refusal != null || r.refusedBefore || r.fixedShare < 0.5)) {
      // ignore: avoid_print
      print('  [${r.refusal ?? (r.refusedBefore ? 'ok now' : 'ok')}; ${r.total} slots, '
          '${(r.fixedShare * 100).round()}% words kept] ${r.sender}: ${r.layout}');
    }

    // Which words the redaction hid, most common first: ordinary words in this list are gaps in the phone's word list
    // (a name would be different on every message; a word that repeats across senders is wording).
    final hidden = <String, int>{};
    for (final (sender, body) in _corpus) {
      final layout = smsCleanLayout(smsSkeleton(redactSms(
        sender: sender,
        body: body,
        observedAt: DateTime.utc(2026, 11, 18),
        options: SmsRedactionOptions(salt: 's'),
      ).body)).toLowerCase();
      for (final m in RegExp(r'[A-Za-z]{3,}').allMatches(body)) {
        final w = m[0]!.toLowerCase();
        if (!layout.contains(w)) hidden[w] = (hidden[w] ?? 0) + 1;
      }
    }
    final top = hidden.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    // ignore: avoid_print
    print('  words hidden from the layout (${hidden.length} different): '
        '${top.take(60).map((e) => '${e.key}×${e.value}').join(', ')}');

    // The ceiling is the measured baseline of 22 Nov 2026: lower it as the redaction improves, never raise it.
    expect(refused.length, lessThanOrEqualTo(2), reason: 'layouts refused by the current limits');
  });
}
