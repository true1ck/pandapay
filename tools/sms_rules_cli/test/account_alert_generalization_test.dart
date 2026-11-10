// Edge-case table for the generalised account-alert rules in
// `rules/sms/v2/generalization/` (account_alerts_*, neft_sent_notices,
// sbi_style_has_credit_for, payment_thanks_receipts, IPPB-ACCT-DEBIT-COUNTED).
//
// Every message is synthetic: invented names, accounts and amounts. The layouts
// are the families seen in co-operative bank, credit society, SBI-style and
// India Post alerts; nothing is copied from a private message.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/rules_source.dart';
import 'package:test/test.dart';

const _mine = [
  'CBS-ACCT-',
  'LBL-ACCT-',
  'SBI-STYLE-',
  'NEFT-SENT-NOTICE-',
  'GENZ-INS-PAYMENT-THANKS',
  'IPPB-ACCT-DEBIT-COUNTED',
];

class _Want {
  const _Want(
    this.direction,
    this.purpose,
    this.rail,
    this.minor, {
    this.mask,
    this.date,
    this.balMinor,
    this.evidenceOnly = false,
    this.rule,
    this.party,
    this.partyMask,
  });
  final String direction, purpose, rail;
  final int minor;
  final String? mask; // instrument mask digits
  final String? date; // printed date as an IST calendar date, yyyy-MM-dd
  final int? balMinor;
  final bool evidenceOnly;
  final String? rule; // winning rule id (prefix)
  final String? party; // counterparty name
  final String? partyMask;
}

const _coop = 'VA-SDCCBK-S';
const _bankTail = 'THE SAMPLE DISTRICT CO-OPERATIVE BANK LTD';

String _acct(
  String verb,
  String amt,
  String date,
  String mode, {
  String account = 'A/c No.40000/XXXXX731',
  String? bal = 'Rs.223456.50',
}) =>
    'Your $account has been $verb by $amt on $date by $mode.'
    '${bal == null ? '' : ' Available Bal is $bal.'} $_bankTail';

void main() {
  late RuleBundle bundle;
  late RuleEngine engine;
  setUpAll(() {
    final source = readRulesFolder('../../rules/sms/v2');
    expect(source.problems, isEmpty);
    bundle = parseUnsignedBundle(source.bundle);
    engine = RuleEngine();
  });

  EngineOutcome read(String sender, String body) => engine.interpretDetailed(
    SmsMessage(
      sender: sender,
      body: body,
      observedAt: DateTime.utc(2026, 11, 20, 10),
      sourceKey: 'k',
    ),
    bundle,
    appVersion: 'test',
  );

  String ist(String utc) => DateTime.parse(utc)
      .add(const Duration(hours: 5, minutes: 30))
      .toIso8601String()
      .substring(0, 10);

  void expectRead(String sender, String body, _Want w) {
    final o = read(sender, body);
    expect(o.result.outcome, InterpretOutcome.matched, reason: '${o.reason} ${o.detail} for: $body');
    if (w.rule != null) expect(o.winnerId, startsWith(w.rule!), reason: body);
    final facts = [for (final f in o.result.facts) f.toJson()];
    final m = facts.firstWhere((f) => f['factType'] == 'movement');
    final attrs = m['attrs'] as Map;
    expect(attrs['direction'], w.direction, reason: body);
    expect(attrs['purpose'], w.purpose, reason: body);
    expect(attrs['rail'], w.rail, reason: body);
    expect(attrs['evidenceOnly'] == true, w.evidenceOnly, reason: body);
    expect(((m['amounts'] as List).first as Map)['minor'], w.minor, reason: body);
    if (w.mask != null) expect((m['instrument'] as Map)['maskDigits'], w.mask, reason: body);
    if (w.date != null) expect(ist(m['occurredAt'] as String), w.date, reason: body);
    if (w.party != null) expect((m['counterparty'] as Map)['name'], w.party, reason: body);
    if (w.partyMask != null) expect((m['counterparty'] as Map)['accountMask'], w.partyMask, reason: body);
    if (w.balMinor != null) {
      final b = facts.firstWhere((f) => f['factType'] == 'balance_snapshot');
      expect(((b['amounts'] as List).first as Map)['minor'], w.balMinor, reason: body);
    }
  }

  void expectNotMine(String sender, String body) {
    final o = read(sender, body);
    final id = o.winnerId ?? '';
    expect(_mine.any(id.startsWith), isFalse, reason: 'wrongly claimed by $id: $body');
  }

  group('account-first alerts: the mode decides the rail and purpose', () {
    const amt = 'Rs.123000.00';
    const date = '14/08/2025';
    final cases = <String, _Want>{
      'Transfer': const _Want('credit', 'transfer', 'unknown', 12300000),
      'Cash': const _Want('credit', 'p2p', 'cash', 12300000),
      'Cash Deposit': const _Want('credit', 'p2p', 'cash', 12300000),
      'Collection': const _Want('credit', 'p2p', 'cash', 12300000),
      'Clearing Cheque No 123456': const _Want('credit', 'p2p', 'cheque', 12300000),
      'Cheque': const _Want('credit', 'p2p', 'cheque', 12300000),
      'NEFT': const _Want('credit', 'p2p', 'neft', 12300000),
      'RTGS': const _Want('credit', 'p2p', 'rtgs', 12300000),
      'IMPS': const _Want('credit', 'p2p', 'imps', 12300000),
      'UPI': const _Want('credit', 'p2p', 'upi', 12300000),
      'Interest': const _Want('credit', 'interest', 'unknown', 12300000),
      'Salary': const _Want('credit', 'salary', 'unknown', 12300000),
      'Reversal': const _Want('credit', 'reversal', 'unknown', 12300000),
      'Standing Instruction': const _Want('credit', 'transfer', 'unknown', 12300000),
      'Deposit': const _Want('credit', 'transfer', 'unknown', 12300000),
    };
    cases.forEach((mode, w) {
      test('credited by $mode', () {
        expectRead(
          _coop,
          _acct('credited', amt, date, mode),
          _Want(
            w.direction,
            w.purpose,
            w.rail,
            w.minor,
            mask: '731',
            date: '2025-08-14',
            balMinor: 22345650,
          ),
        );
      });
    });
    final debits = <String, _Want>{
      'Transfer': const _Want('debit', 'transfer', 'unknown', 12300000),
      'Cash': const _Want('debit', 'atm', 'cash', 12300000),
      'Withdrawal': const _Want('debit', 'atm', 'cash', 12300000),
      'Clearing Cheque No 76864': const _Want('debit', 'purchase', 'cheque', 12300000),
      'Cheque': const _Want('debit', 'purchase', 'cheque', 12300000),
      'NEFT': const _Want('debit', 'p2p', 'neft', 12300000),
      'RTGS': const _Want('debit', 'p2p', 'rtgs', 12300000),
      'IMPS': const _Want('debit', 'p2p', 'imps', 12300000),
      'UPI': const _Want('debit', 'p2p', 'upi', 12300000),
    };
    debits.forEach((mode, w) {
      test('debited by $mode', () {
        expectRead(
          _coop,
          _acct('debited', amt, date, mode),
          _Want(w.direction, w.purpose, w.rail, w.minor, mask: '731', date: '2025-08-14', balMinor: 22345650),
        );
      });
    });
    test('no balance printed: the movement still reads, with no balance fact', () {
      final o = read(_coop, _acct('credited', amt, date, 'Cash', bal: null));
      expect(o.winnerId, 'CBS-ACCT-CR-CASH');
      expect(o.result.facts.map((f) => f.factType.wire), ['movement']);
    });
  });

  group('account and amount and date shapes', () {
    test('account forms', () {
      for (final (account, mask) in [
        ('A/c No.40000/XXXXX731', '731'),
        ('A/c No.XXXXX731', '731'),
        ('A/c XX1234', '1234'),
        ('A/c No: 12345/731', '731'),
        ('a/c no. 40000/xxxxx731', '731'),
        ('account 4567', '4567'),
        ('A/C *1234', '1234'),
        ('A/c No.1234567890', '7890'), // a long number keeps its last four digits
      ]) {
        expectRead(
          _coop,
          _acct('credited', 'Rs.500.00', '14/08/2025', 'Cash', account: account),
          _Want('credit', 'p2p', 'cash', 50000, mask: mask, date: '2025-08-14'),
        );
      }
    });
    test('amount forms', () {
      for (final (amt, minor) in [
        ('Rs.300000.00', 30000000),
        ('Rs 22,584.00', 2258400),
        ('INR 2,000.00', 200000),
        ('₹ 5,000', 500000),
        ('Rs.5000/-', 500000),
        ('Rs. 1,00,000.50', 10000050),
        ('Rs.10000000.00', 1000000000),
        ('Rs.0.50', 50),
        ('inr 750', 75000),
      ]) {
        expectRead(
          _coop,
          _acct('credited', amt, '14/08/2025', 'Cash'),
          _Want('credit', 'p2p', 'cash', minor, date: '2025-08-14'),
        );
      }
    });
    test('date forms (the printed date wins over the arrival time)', () {
      for (final (d, iso) in [
        ('14/08/2025', '2025-08-14'),
        ('14-08-2025', '2025-08-14'),
        ('14/08/25', '2025-08-14'),
        ('14-Aug-25', '2025-08-14'),
        ('14-Aug-2025', '2025-08-14'),
        ('14 Aug 2025', '2025-08-14'),
        ('2025-08-14', '2025-08-14'),
        ('14/08/2025 10:15:20', '2025-08-14'),
      ]) {
        expectRead(
          _coop,
          _acct('credited', 'Rs.500.00', d, 'Cash'),
          _Want('credit', 'p2p', 'cash', 50000, date: iso),
        );
      }
    });
    test('verbs and connectors', () {
      for (final text in [
        'Your A/c No.40000/XXXXX731 is credited with Rs.500.00 on 14/08/2025 by Cash.',
        'Your A/c No.40000/XXXXX731 was credited for Rs.500.00 on 14/08/2025 by Cash.',
        'Your A/c No.40000/XXXXX731 has been credited with Rs.500.00 dated 14/08/2025 by Cash.',
        'YOUR A/C NO.40000/XXXXX731 HAS BEEN CREDITED BY RS.500.00 ON 14/08/2025 BY CASH.',
      ]) {
        expectRead(_coop, text, const _Want('credit', 'p2p', 'cash', 50000, mask: '731', date: '2025-08-14'));
      }
    });
    test('extra spaces and a line break do not matter', () {
      expectRead(
        _coop,
        'Your A/c No.40000/XXXXX731  has been credited by  Rs.5000.00 on 14/08/2025 by Transfer.\nAvailable Bal is Rs.10000.00.',
        const _Want('credit', 'transfer', 'unknown', 500000, mask: '731', balMinor: 1000000),
      );
    });
  });

  group('credit society wording', () {
    const society = 'Sample Teachers Co.Op.Credit Society Ltd.';
    test('"in <account type> On <date>. Info: By Collection Avbl Bal"', () {
      expectRead(
        'VM-SAMPLEC-S',
        'Dear Customer, Your A/c 8412 has been credited with INR 2,000.00 in SANCHIT On 03-Sep-24. Info: By Collection Avbl Bal is INR 26,000.00. For Dispute - Call 9000000000 - $society',
        const _Want('credit', 'p2p', 'cash', 200000, mask: '8412', date: '2024-09-03', balMinor: 2600000),
      );
    });
    test('a debit "By Withdrawal"', () {
      expectRead(
        'VM-SAMPLEC-S',
        'Dear Customer, Your A/c 8412 has been debited with INR 500.00 in SAVING On 03-Sep-24. Info: By Withdrawal Avbl Bal is INR 25,500.00. $society',
        const _Want('debit', 'atm', 'cash', 50000, mask: '8412', date: '2024-09-03', balMinor: 2550000),
      );
    });
    test('no mode printed at all: still a movement, typed as a transfer', () {
      expectRead(
        'VM-SAMPLEC-S',
        'Dear Customer, Your A/c 8412 has been credited with INR 1,250.00 in SAVING On 03-Sep-24. Avbl Bal is INR 9,000.00. $society',
        const _Want('credit', 'transfer', 'unknown', 125000, rule: 'CBS-ACCT-CR-NOMODE', balMinor: 900000),
      );
      expectRead(
        'VM-SAMPLEC-S',
        'Dear Customer, Your A/c 8412 has been debited with INR 1,250.00 in SAVING On 03-Sep-24.',
        const _Want('debit', 'transfer', 'unknown', 125000, rule: 'CBS-ACCT-DB-NOMODE'),
      );
    });
  });

  group('label-first (India Post style)', () {
    test('credit, with the stray space after the bracket', () {
      expectRead(
        'BT-DOPBNK-G',
        'Account  No. XXXXXX3456 CREDIT with amount Rs. 1800.00 on 27-10-2025. Balance: Rs.9800.00. [ IN0000003]',
        const _Want('credit', 'p2p', 'unknown', 180000, mask: '3456', date: '2025-10-27', balMinor: 980000),
      );
    });
    test('debit is counted (the older IPPB rule left the purpose unknown)', () {
      expectRead(
        'BT-DOPBNK-G',
        'Account No. XXXXXX3456 DEBIT with amount Rs. 900.00 on 29-07-2026. Balance: Rs.514.00.[IN0000004]',
        const _Want('debit', 'transfer', 'unknown', 90000, rule: 'IPPB-ACCT-DEBIT-COUNTED', mask: '3456'),
      );
    });
    test('other banks with the same layout, no balance', () {
      expectRead(
        'VM-SAMPLED-S',
        'Account No. XX3456 CREDIT with amount Rs. 1800.00 on 27-10-2025.',
        const _Want('credit', 'p2p', 'unknown', 180000, rule: 'LBL-ACCT-CR'),
      );
    });
  });

  group('SBI-style "has credit/debit for <description>"', () {
    String sbi(String verb, String desc, {String amt = 'Rs 1,250.00', String date = '29/10/26', String bal = ' Avl Bal Rs 1,04,079.26.-BANK'}) =>
        'Your A/C XXXXX123456 has $verb for $desc of $amt on $date.$bal';
    test('income tax refund is money in (tax), not a shop refund', () {
      expectRead(
        'BG-CBSXXX-S',
        sbi('credit', 'ITDTAX REFUND 2026-27 ACRPN123', amt: 'Rs 22,584.00'),
        const _Want('credit', 'tax', 'unknown', 2258400, mask: '123456', date: '2026-10-29', balMinor: 10407926),
      );
    });
    test('salary, dividend, refund, plain transfer, each typed', () {
      for (final (desc, purpose) in [
        ('SALARY SAMPLE PRIVATE LTD', 'salary'),
        ('SAMPLE POWER CO FINAL DIVIDEND', 'dividend'),
        ('REFUND FROM SAMPLE SHOP', 'refund'),
        ('TRANSFER FROM SAMPLE PERSON', 'p2p'),
      ]) {
        expectRead('BG-CBSXXX-S', sbi('credit', desc), _Want('credit', purpose, 'unknown', 125000, date: '2026-10-29'));
      }
    });
    test('debits: ATM, shop swipe, transfer', () {
      expectRead('BG-CBSXXX-S', sbi('debit', 'ATM WDL SAMPLE BRANCH'), const _Want('debit', 'atm', 'cash', 125000));
      expectRead('BG-CBSXXX-S', sbi('debit', 'POS SAMPLE SHOP'), const _Want('debit', 'purchase', 'card', 125000));
      expectRead('BG-CBSXXX-S', sbi('debit', 'TRANSFER TO SAMPLE PERSON'), const _Want('debit', 'transfer', 'unknown', 125000));
    });
    test('no balance printed', () {
      final o = read('BG-CBSXXX-S', sbi('credit', 'SALARY SAMPLE PRIVATE LTD', bal: ''));
      expect(o.winnerId, 'SBI-STYLE-CR-SAL');
    });
  });

  group('NEFT / RTGS / IMPS "sent" notices are evidence only', () {
    String sent(String rail, String amt, String to, String ref) =>
        'Your $rail Txn of Rs.$amt has been sent to $to with Ref no: $ref  $_bankTail';
    test('combined label, IFSC-account-name', () {
      expectRead(
        _coop,
        sent('NEFT/RTGS', '25000', 'SAMP0000123-CURR000123456-SAMPLE TRADERS', 'SAMP52026110100001'),
        const _Want('debit', 'p2p', 'unknown', 2500000, evidenceOnly: true, party: 'SAMPLE TRADERS', partyMask: '3456', rule: 'NEFT-SENT-NOTICE-COMBO'),
      );
    });
    test('single rails', () {
      for (final (label, rail) in [('NEFT', 'neft'), ('RTGS', 'rtgs'), ('IMPS', 'imps')]) {
        expectRead(
          _coop,
          sent(label, '25000', 'SAMP0000123-CURR000123456-SAMPLE TRADERS', 'SAMP52026110100001'),
          _Want('debit', 'p2p', rail, 2500000, evidenceOnly: true, party: 'SAMPLE TRADERS'),
        );
      }
    });
    test('no IFSC, no account, a name with digits and punctuation', () {
      expectRead(
        _coop,
        sent('NEFT', '9999', 'M/S SAMPLE & SONS 2', 'SAMP52026110100002'),
        const _Want('debit', 'p2p', 'neft', 999900, evidenceOnly: true, party: 'M/S SAMPLE & SONS 2'),
      );
    });
  });

  group('insurer payment thank-you', () {
    test('names the biller from the sign-off, evidence only', () {
      expectRead(
        'CP-SAMPLEI-S',
        'We thank you for your payment of Rs. 4500.00 towards your Policy Number 000123456. You can now download your premium receipt any time by clicking to https://example.invalid/r/abc Regards, Sample Life Insurance',
        const _Want('debit', 'bill_payment', 'unknown', 450000, evidenceOnly: true, party: 'SAMPLE LIFE INSURANCE'),
      );
    });
    test('no sign-off: still a receipt, no biller name', () {
      final o = read('CP-SAMPLEI-S', 'Thank you for your premium payment of Rs 4,500.00 towards policy 000123456.');
      expect(o.winnerId, 'GENZ-INS-PAYMENT-THANKS');
    });
  });

  group('things that must NOT be read as a movement by these rules', () {
    final negatives = <String, String>{
      'a future credit': 'Your A/c No.40000/XXXXX731 will be credited by Rs.5000.00 on 14/08/2025 by Cash.',
      'a failed debit': 'Your A/c No.40000/XXXXX731 could not be debited by Rs.5000.00 on 14/08/2025 by Transfer. Transaction failed.',
      'an OTP': 'OTP 123456 for debit of Rs.5000.00 from A/c XXXXX731 on 14/08/2025 by Transfer. Do not share.',
      'a balance enquiry': 'Your A/c No.40000/XXXXX731 Available Bal is Rs.5000.00 as on 14/08/2025.',
      'a loan EMI': 'Your A/c No.40000/XXXXX731 has been debited by Rs.5000.00 on 14/08/2025 towards EMI of loan 1234.',
      'a credit card': 'Your credit card ending 1234 has been credited with Rs.5000.00 on 14/08/2025 by Transfer.',
      'a pending cheque': 'Cheque of Rs.5000.00 deposited in your A/c XXXXX731 on 14/08/2025 will be credited after clearing.',
      'a debit request': 'Request to debit Rs.5000.00 from your A/c XXXXX731 on 14/08/2025 by Transfer is received.',
      'an unknown mode such as a penalty': 'Your A/c No.40000/XXXXX731 has been debited by Rs.50.00 on 14/08/2025 by Penalty Charges. Available Bal is Rs.1000.00.',
      'a failed NEFT notice': 'Your NEFT/RTGS Txn of Rs.5000 could not be sent to SAMP0000123-CURR000123456-SAMPLE TRADERS with Ref no: SAMP52026110100003',
      'a returned NEFT': 'Your NEFT Txn of Rs.5000 sent to SAMP0000123-CURR000123456-SAMPLE TRADERS with Ref no: SAMP52026110100003 has been returned',
      'a premium due reminder': 'Your premium of Rs 5000 towards Policy 123456 is due on 20-11-2026. Regards, Sample Life Insurance',
      'a card payment thank-you': 'Thank you for your payment of Rs.500 towards your credit card ending 1234.',
      'an SBI-style failed debit': 'Your A/C XXXXX123456 has debit failed for ATM WDL SAMPLE BRANCH of Rs 1,250.00 on 29/10/26.',
    };
    negatives.forEach((name, body) => test(name, () => expectNotMine(_coop, body)));
  });

  group('sender spelling does not change the reading', () {
    test('dashless and operator-prefixed forms read the same movement', () {
      for (final sender in ['VA-SDCCBK-S', 'VASDCCBKS', 'JXSDCCBKS', 'SDCCBKS', 'AD-SDCCBK-S', 'sdccbk', 'XX-ANYTHING-S']) {
        expectRead(
          sender,
          _acct('debited', 'Rs.400000.00', '25/08/2025', 'Transfer'),
          const _Want('debit', 'transfer', 'unknown', 40000000, mask: '731', date: '2025-08-25'),
        );
      }
    });
    test('registered senders give the instrument its bank', () {
      for (final sender in ['VA-SDCCBK-S', 'VASDCCBKS', 'JXSDCCBKS', 'SDCCBKS']) {
        final o = read(sender, _acct('debited', 'Rs.500.00', '25/08/2025', 'Transfer'));
        final inst = o.result.facts.first.toJson()['instrument'] as Map;
        expect(inst['issuerSlug'], 'sindhudurg_dcc', reason: sender);
      }
    });
  });
}
