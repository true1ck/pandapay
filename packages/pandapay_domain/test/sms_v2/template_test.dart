import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:test/test.dart';

/// Fake "real-looking" messages. Every name, number and amount below is
/// invented for this test; none comes from a real SMS.
class _Fake {
  const _Fake(this.sender, this.body, this.forbidden, {this.keep = const []});
  final String sender;
  final String body;

  /// Strings (names, numbers, amounts) that must not appear in the output.
  final List<String> forbidden;

  /// Strings that must survive (catalogue merchants, wording).
  final List<String> keep;
}

const _fakes = <_Fake>[
  _Fake(
    'VM-HDFCBK-S',
    'Rs.7,845.50 debited from A/c XX4821 on 14-09-26 to VPA priya.nair84@okhdfcbank (PRIYA NAIR) (UPI Ref No 427711903388). Avl bal Rs 61,204.17',
    ['7,845.50', '4821', '427711903388', 'PRIYA', 'NAIR', 'priya.nair84', '61,204.17', '14-09-26'],
    keep: ['Rs.', 'debited from A/c XX', 'UPI Ref No', 'Avl bal Rs'],
  ),
  _Fake(
    'AX-ICICIT-S',
    'Dear Mr. Anand Venkataraman, INR 12,499.00 spent using ICICI Bank Card XX6035 on 03-Oct-26 on SWIGGY. Avl Limit: INR 2,31,870.25. If not you, call 18002662/SMS BLOCK 6035 to 9215676766.',
    ['Anand', 'Venkataraman', '12,499.00', '6035', '2,31,870.25', '18002662', '9215676766', '03-Oct-26'],
    keep: ['SWIGGY', 'INR', 'ICICI Bank Card XX'],
  ),
  _Fake(
    'AD-SBIBNK-S',
    'Dear UPI user A/C X7712 debited by 3250.0 on date 21Aug26 trf to GAURI SHANKAR TRADERS Refno 424433221100. If not u? call 1800111109. -SBI',
    ['GAURI', 'SHANKAR', 'TRADERS', '3250.0', '7712', '424433221100', '1800111109', '21Aug26'],
    keep: ['trf to', '-SBI'],
  ),
  _Fake(
    'VM-KOTAKB-S',
    'Sent Rs.1,250.00 from Kotak Bank AC X3390 to ramesh.kulkarni@okaxis on 09-11-26.UPI Ref 431122009988. Not you, https://kotak.com/KBANKT/Fraud',
    ['1,250.00', '3390', 'ramesh', 'kulkarni', '431122009988', 'https://kotak.com', '09-11-26'],
    keep: ['Sent Rs.', 'Kotak Bank AC X'],
  ),
  _Fake(
    'VM-HDFCBK-S',
    'Update! INR 1,42,000.00 deposited in HDFC Bank A/c XX9087 on 01-NOV-26 for NEFT Cr-HDFC0000314-BRIGHTWAVE SOFTWARE SERVICES-SALARY NOV. Avl bal INR 2,03,118.60.',
    ['1,42,000.00', '9087', 'BRIGHTWAVE', 'SOFTWARE', '0000314', '2,03,118.60', '01-NOV-26'],
    keep: ['deposited in HDFC Bank A/c XX', 'SALARY'],
  ),
  _Fake(
    'JM-iPaytm',
    'Rs 640 paid from Paytm Wallet to Sunrise General Store. Updated balance: Rs 1,380. Txn ID 90817263544. Reach us on 9876501234 or help@sunrisestore.in',
    ['640', 'Sunrise', 'General', '1,380', '90817263544', '9876501234', 'help@sunrisestore.in'],
    keep: ['Paytm Wallet', 'Updated balance: Rs'],
  ),
  _Fake(
    'AX-AXISBK-S',
    'INR 1500.00 debited\nA/c no. XX530962\n01-11-26, 12:30:11\nUPI/P2M/432112345678/Chai Point\nNot you? SMS BLOCKUPI Cust ID to 919951860002\nAxis Bank',
    ['1500.00', '530962', '432112345678', '919951860002', '01-11-26'],
    keep: ['Chai Point', 'Axis Bank'],
  ),
  _Fake(
    'VM-HDFCBK-S',
    'Payment of Rs.25,000.00 received towards your HDFC Bank Credit Card XX5678 on 10-11-2026 from Meera Subramaniam. Reference 7771234.',
    ['25,000.00', '5678', 'Meera', 'Subramaniam', '7771234', '10-11-2026'],
    keep: ['Payment of Rs.', 'received towards your HDFC Bank Credit Card XX'],
  ),
  _Fake(
    'AD-AMEXIN',
    'We have received your payment of INR 12,000.00 towards your American Express Card ending 10005 on 10 Nov 2026. Hi rohan, thank you.',
    ['12,000.00', '10005', 'rohan', '10 Nov 2026'],
    keep: ['American Express Card ending', 'thank you'],
  ),
  _Fake(
    'VM-HDFCBK-S',
    'Rs.499.00 spent on HDFC Bank Card x5678 at ZOMATO on 2026-11-01:12:30:11. Avl Lmt: Rs.45,000.00. Credited to Dilip Kumar Rao (9988776655) ref 5566778899.',
    ['499.00', '5678', '45,000.00', 'Dilip', 'Rao', '9988776655', '5566778899', '2026-11-01'],
    keep: ['ZOMATO', 'Avl Lmt: Rs.', 'spent on HDFC Bank Card x'],
  ),
];

final _options = SmsRedactionOptions(salt: 'test-salt');

void main() {
  group('redactSms', () {
    for (var i = 0; i < _fakes.length; i++) {
      final f = _fakes[i];
      test('fake message $i: no original name, number or amount survives', () {
        final r = redactSms(
          sender: f.sender,
          body: f.body,
          observedAt: DateTime.utc(2026, 11, 2, 9, 30),
          options: _options,
        );
        final out = r.body.toLowerCase();
        for (final v in f.forbidden) {
          expect(out.contains(v.toLowerCase()), isFalse,
              reason: '"$v" survived in: ${r.body}');
        }
        for (final v in f.keep) {
          expect(r.body.contains(v), isTrue,
              reason: '"$v" was lost from: ${r.body}');
        }
        // No digit run of 4+ characters of the original survives.
        for (final m in RegExp(r'\d{4,}').allMatches(f.body)) {
          if (RegExp(r'^20\d\d$').hasMatch(m[0]!)) continue; // year of a shifted date
          expect(r.body.contains(m[0]!), isFalse,
              reason: 'digit run ${m[0]} survived in: ${r.body}');
        }
      });
    }

    test('keeps the printed amount format but changes the value', () {
      final r = redactSms(
        sender: 'VM-HDFCBK-S',
        body: 'Rs.1,48,701.00 spent; INR 250 paid; ₹ 9,999.5 sent; Rs 12/- charged',
        observedAt: DateTime.utc(2026, 11, 2),
        options: _options,
      );
      expect(
        RegExp(r'Rs\.\d,\d{2},\d{3}\.\d{2} spent; INR \d{3} paid; ₹ \d,\d{3}\.\d sent; Rs \d{2}/- charged')
            .hasMatch(r.body),
        isTrue,
        reason: r.body,
      );
      expect(r.body.contains('1,48,701.00'), isFalse);
      expect(r.body.contains('250 paid'), isFalse);
    });

    test('digit runs keep their length and are consistent within a message', () {
      final r = redactSms(
        sender: 'VM-HDFCBK-S',
        body: 'Ref 123456789012 and again 123456789012 and 99887766',
        observedAt: DateTime.utc(2026, 11, 2),
        options: _options,
      );
      final runs = RegExp(r'\d+').allMatches(r.body).map((m) => m[0]!).toList();
      expect(runs.length, 3);
      expect(runs[0].length, 12);
      expect(runs[0], runs[1]);
      expect(runs[2].length, 8);
    });

    test('dates keep their format and move by the same shift', () {
      final o = SmsRedactionOptions(salt: 's', dateShiftDays: 10);
      final r = redactSms(
        sender: 'VM-HDFCBK-S',
        body: 'a 22-11-26 b 30-Nov-26 c 01NOV26 d 10 Nov 2026 e 2026-11-01:12:30:11 f 01/11/26',
        observedAt: DateTime.utc(2026, 11, 22, 8),
        options: o,
      );
      expect(r.body,
          'a 02-12-26 b 10-Dec-26 c 11NOV26 d 20 Nov 2026 e 2026-11-11:12:30:11 f 11/11/26');
      expect(r.observedAt, DateTime.utc(2026, 12, 2, 8));
    });

    test('phone numbers, urls and emails become placeholders', () {
      final r = redactSms(
        sender: 'VM-HDFCBK-S',
        body: 'Call +91 98765 43210 or 1800 266 2666, visit https://bank.example.in/x mail a.b@corp.com',
        observedAt: DateTime.utc(2026, 11, 2),
        options: _options,
      );
      expect(r.body, contains('<PHONE>'));
      expect(r.body, contains('<URL>'));
      expect(r.body, contains('<EMAIL>'));
      expect(r.body.contains('98765'), isFalse);
      expect(r.body.contains('corp.com'), isFalse);
    });

    test('catalogue merchants survive, unknown merchants do not', () {
      final r = redactSms(
        sender: 'VM-HDFCBK-S',
        body: 'Rs.500.00 spent on Card XX1234 at BIGBASKET and at Lakshmi Tiffin Centre today',
        observedAt: DateTime.utc(2026, 11, 2),
        options: _options,
      );
      expect(r.body, contains('BIGBASKET'));
      expect(r.body.contains('Lakshmi'), isFalse);
      expect(r.body.contains('Tiffin'), isFalse);
      expect(r.body, contains('<PARTY>'));
    });

    test('is deterministic for a fixed salt and differs between salts', () {
      String run(String salt) => redactSms(
            sender: 'VM-HDFCBK-S',
            body: 'Rs.500.00 debited from A/c XX1234 ref 987654321',
            observedAt: DateTime.utc(2026, 11, 2),
            options: SmsRedactionOptions(salt: salt),
          ).body;
      expect(run('a'), run('a'));
      expect(run('a'), isNot(run('b')));
    });

    test('a numeric sender is treated as a phone number', () {
      final r = redactSms(
        sender: '+919876543210',
        body: 'hello',
        observedAt: DateTime.utc(2026, 11, 2),
        options: _options,
      );
      expect(r.sender, '<PHONE>');
    });
  });

  group('templates', () {
    test('brand drops operator prefix, suffix and iOS filter tag', () {
      expect(smsTemplateBrand('VM-HDFCBK-S'), 'HDFCBK');
      expect(smsTemplateBrand('ax-icicit-p'), 'ICICIT');
      expect(smsTemplateBrand('AMEXIN'), 'AMEXIN');
      expect(smsTemplateBrand('JM-iPaytm (smsft_fi)'), 'IPAYTM');
    });

    test('the same template with different values has one hash', () {
      String h(String body) =>
          smsTemplateHash('HDFCBK', smsSkeleton(body));
      final a = h('Rs.499.00 spent on HDFC Bank Card x5678 at SWIGGY on 2026-11-01:12:30:11. Avl Lmt: Rs.45,000.00');
      final b = h('Rs.1,250.50 spent on HDFC Bank Card x1234 at SWIGGY on 2026-12-09:08:01:45. Avl Lmt: Rs.1,45,000.50');
      expect(a, b);
      final c = h('Rs.499.00 spent on HDFC Bank Card x5678 at SWIGGY. Avl Lmt: Rs.45,000.00');
      expect(c, isNot(a));
    });

    test('skeleton replaces amounts, dates, masks, vpas, refs and digits', () {
      final s = smsSkeleton(
        'Rs.5,000.00 debited from A/c XX1234 on 05-11-26 to VPA groww.mf@validhdfc (UPI Ref No 432112345678). Call 18002662 now',
      );
      expect(s,
          '<AMT> debited from A/c <MASK> on <DATE> to VPA <VPA> (UPI Ref No <REF>). Call <REF> now');
      expect(smsSkeleton('Order #123 shipped'), 'Order #### shipped');
    });

    test('an address with a hidden part is still an address', () {
      expect(
        smsSkeleton('Statement is sent to ab***@gmail.com. Pay Rs 5,000.00'),
        'Statement is sent to <VPA> Pay <AMT>',
      );
      expect(smsSkeleton('Write to care@hdfcbank.com or visit hdfcbank.com'),
          'Write to <VPA> or visit <URL>');
      final redacted = redactSms(
        sender: 'VM-HDFCBK-S',
        body: 'Statement is sent to ab***@gmail.com. Pay Rs 5,000.00',
        observedAt: DateTime.utc(2026, 11, 1),
        options: SmsRedactionOptions(salt: 'x'),
      );
      expect(redacted.body, isNot(contains('@')));
    });

    test('a skeleton is shareable only without digits, addresses and links', () {
      expect(smsSkeletonIsShareable('<AMT> spent at <W> on <DATE>'), isTrue);
      expect(smsSkeletonIsShareable(''), isFalse);
      expect(smsSkeletonIsShareable('Order 123 shipped'), isFalse);
      expect(smsSkeletonIsShareable('Mail ab***@<URL>'), isFalse);
      expect(smsSkeletonIsShareable('See HTTPS://x.example'), isFalse);
      expect(smsSkeletonIsShareable('a' * 20001), isFalse);
      // Whatever the builder produces for an address must pass the check.
      expect(
        smsSkeletonIsShareable(smsSkeleton('Sent to ab***@gmail.com, call 18002662')),
        isTrue,
      );
    });

    test('hash is sha256 of brand, newline, skeleton', () {
      expect(smsTemplateHash('A', 'B'),
          '23519a43c66b4c342f25b32e09797ec5f3fc0be388cd8243fb3449afbdce4013');
      expect(smsTemplateHash('A', 'B').length, 64);
      expect(smsTemplateHash('A', 'B'), isNot(smsTemplateHash('A', 'C')));
    });

    test('words seen in fewer than 5 messages become <W>', () {
      final skeletons = <String>[
        for (var i = 0; i < 6; i++) 'Rs <AMT> spent at SWIGGY by card',
        'Rs <AMT> spent at Lakshmi Tiffin Centre by card',
        'Rs <AMT> spent at Gauri Stores by card',
      ];
      final df = skeletonWordFrequency(skeletons);
      expect(coarsenSkeleton(skeletons[0], df), skeletons[0]);
      expect(coarsenSkeleton(skeletons[6], df), 'Rs <AMT> spent at <W> by card');
      expect(coarsenSkeleton(skeletons[7], df), 'Rs <AMT> spent at <W> by card');
      expect(
        smsTemplateHash('X', coarsenSkeleton(skeletons[6], df)),
        smsTemplateHash('X', coarsenSkeleton(skeletons[7], df)),
      );
    });
  });
}
