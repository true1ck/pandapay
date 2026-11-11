import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import '../support/rules.dart';

// A card or account number must be introduced like one. A rule that skips over
// arbitrary words between "card" and some digits can turn a reference number
// into a card (the digits after "card ending from UPI CR ADJ" are not a card).
// Every message here is synthetic.
void main() {
  group('maskFollowsOpenSkip', () {
    test('a wide skip in front of the mask is flagged', () {
      for (final pattern in [
        r'card\b[^\d\n]{0,30}?(?:[x*•.]+\s*)?(?<mask>\d{4,16})\b',
        r'card.{0,40}?(?<mask>\d{4})',
        r'card[\s\S]*?(?<mask>\d{4})',
        r'account\S+(?<mask>\d{4})',
        r'card[^\d]+(?<mask>\d{4})',
        r'card[^\d]{2,}(?<mask>\d{4})',
      ]) {
        expect(maskFollowsOpenSkip(pattern, 'mask'), isTrue, reason: pattern);
      }
    });

    test('closed introducers and short gaps pass', () {
      for (final pattern in [
        r'card\b(?:\s*(?:no|number)\.?)?(?:\s+(?:ending|ends)(?:\s+(?:with|in))?)?\s*[:\-]?\s*[x*•.]*\s?(?<mask>\d{4,16})\b',
        r'card\s+x(?<mask>\d{4})',
        r'a/c\s*(?:no\.?)?\s*[x*•.]*(?<mask>\d{4})',
        r'ending[^\d]{0,4}(?<mask>\d{4})',
        r'(?<mask>\d{4})',
      ]) {
        expect(maskFollowsOpenSkip(pattern, 'mask'), isFalse, reason: pattern);
      }
    });
  });

  group('the shipped rules', () {
    late RuleBundle bundle;
    final engine = RuleEngine();
    setUpAll(() => bundle = testRuleBundle());

    test('no rule takes its mask from behind a wide skip', () {
      final bad = [
        for (final i in lintBundle(bundle))
          if (i.code == 'lint.mask.open_skip') i.toString(),
      ];
      expect(bad, isEmpty);
    });

    List<String?> masks(String sender, String body) => [
      for (final f in engine.interpretDetailed(
        SmsMessage(
          sender: sender,
          body: body,
          observedAt: DateTime.utc(2026, 11, 20, 10),
          sourceKey: 'm',
        ),
        bundle,
        appVersion: 'test',
      ).result.facts)
        f.instrument?.maskDigits,
    ];

    test('digits behind a reference word are never read as a card', () {
      // Synthetic lookalikes from several issuers: a reference, UPI id, RRN or
      // transaction number sits between the card word and the digits.
      const decoys = <(String, String, String)>[
        (
          'VM-GENCRD-S',
          'An amount of INR 206.2 received on your Sample Bank Credit Card ending from UPI CR ADJ 534833597 on 19-12-26. Current Total Amount Due is INR 13558.45 and Min Amount Due INR 285.98 due on 05-01-27. - Sample Bank',
          '3597',
        ),
        (
          'VM-GENCRD-S',
          'Statement alert: Credit Card payment ref 998877665 received. Outstanding balance of Rs.12,345.00. Minimum amount payable Rs.617.00. Payment due date 20-11-2026.',
          '7665',
        ),
        (
          'AX-GENCRD-S',
          'Your Example Card statement for txn id 123456789012 is ready. Total due Rs 4,200.00, Minimum due Rs 210.00, due date 03-12-2026.',
          '9012',
        ),
        (
          'JD-GENCRD-S',
          'Statement: Sample Credit Card bill against UTR 445566778899 has outstanding balance of Rs 9,100.00. Minimum amount payable Rs 455.00. Payment due date 11-12-2026.',
          '8899',
        ),
      ];
      for (final (sender, body, tail) in decoys) {
        expect(masks(sender, body), isNot(contains(tail)), reason: body);
      }
    });

    test('a card number printed the usual ways is still read', () {
      const cases = <(String, String)>[
        (
          'Statement alert: your Sample Bank Credit Card ending 1234 has an outstanding balance of Rs.12,345.00. Minimum amount payable Rs.617.00. Payment due date 20-11-2026.',
          '1234',
        ),
        (
          'Statement alert: your Sample Bank Credit Card no. XX4321 has an outstanding balance of Rs.12,345.00. Minimum amount payable Rs.617.00. Payment due date 20-11-2026.',
          '4321',
        ),
        (
          'Statement alert: your Sample Bank Credit Card ending with 5566 has an outstanding balance of Rs.12,345.00. Minimum amount payable Rs.617.00. Payment due date 20-11-2026.',
          '5566',
        ),
        (
          'Sample Bank Credit Card XXXX7788: Total due Rs 12,345.00, Minimum due Rs 617.00, due date 20-11-2026. Pay now to avoid late fee.',
          '7788',
        ),
      ];
      for (final (body, mask) in cases) {
        expect(masks('VM-GENCRD-S', body), contains(mask), reason: body);
      }
    });
  });
}
