// A name a message prints must reach the transaction. Five layouts printed the
// payee or the payer and the rules dropped it. Every message below is invented;
// the layouts (not the names) are the ones real banks and apps use.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import '../support/rules.dart';

void main() {
  late RuleBundle bundle;
  final engine = RuleEngine();
  setUpAll(() => bundle = testRuleBundle());

  MovementFact? read(String body, {String sender = 'VM-GENBNK-S'}) {
    final facts = engine
        .interpretDetailed(
          SmsMessage(sender: sender, body: body, observedAt: DateTime.utc(2026, 11, 20, 10), sourceKey: 'n'),
          bundle,
          appVersion: 'test',
        )
        .result
        .facts
        .whereType<MovementFact>();
    return facts.firstOrNull;
  }

  String? name(String body, {String sender = 'VM-GENBNK-S'}) => read(body, sender: sender)?.counterparty?.name?.toUpperCase().trim();

  group('a debit that says who the transfer went to', () {
    test('the payee is the name before the destination account', () {
      expect(name('Your Ac x4455 debited Rs.5,000.00 for transfer to riya Ac x7788 dt 29.01.27 Ref 123456789012.'), 'RIYA');
      expect(name('A/c XX1234 debited by Rs 700.00 on 05-11-26: transfer to RAVI KUMAR A/c XX9988. Ref 555566667777'), 'RAVI KUMAR');
      expect(name('Your Ac x4455 debited Rs.1,00,000.00 for transfer to asha rao kulkarni Ac x7788 dt 29.01.27'), 'ASHA RAO KULKARNI');
    });

    test('the other template (debited to MERCHANT from the account) keeps its own reading', () {
      final m = read('Rs 1,500.00 debited to SWIGGY from A/C XXXX4321 on 28-10-2026')!;
      expect(m.counterparty?.name?.toUpperCase(), isNot(contains('FROM')));
    });

    test('with no name there is none, and the account number is kept', () {
      final m = read('Your A/c XX1234 is debited for Rs.499.00 on 22-10-26 to A/c XX5678')!;
      expect(m.counterparty?.name, isNull);
      expect(m.counterparty?.accountMask, '5678');
    });

    test('a debit that is only announced, a credit or a failure is not read', () {
      expect(read('Your Ac x4455 will be debited Rs.5,000.00 for transfer to riya Ac x7788 dt 29.01.27.')?.counterparty?.name, isNull);
      expect(read('Your Ac x4455 credited Rs.5,000.00 for transfer to riya Ac x7788 dt 29.01.27.')?.direction, isNot(Direction.debit));
    });
  });

  group('a credit by RTGS, NEFT or IMPS prints the payer after the remitter\'s account number', () {
    test('the name may be glued to the number or follow it', () {
      expect(name('Dear Customer, INR 3,00,000.00 credited to your A/c No XX4455 on 31/12/2026 through RTGS with UTR ABCD52026123100000001 by 024400000001234 ASHA RAO, INFO: SAMPLE ////// //////'), 'ASHA RAO');
      expect(name('Dear Customer, INR 8,000.00 credited to your A/c No XX4455 on 02/01/2027 through NEFT with UTR ABCD52027010200000002 by 024400000009876PRIYA SHARMA, INFO: SAMPLE ////// //////'), 'PRIYA SHARMA');
      expect(name('Rs.12,500.00 credited to A/c XX7788 on 05-11-26 via NEFT by 998877665 EXAMPLE TRADERS PVT LTD. Ref 123456789012'), contains('EXAMPLE TRADERS'));
    });

    test('a credit that prints no payer still has none', () {
      expect(read('Rs.499.00 credited to A/c XX1234 on 22-10-26 by RTGS Ref 123456789012')?.counterparty?.name, isNull);
    });
  });

  group('a payer-side notice that signs with the sender', () {
    test('"From <name>" at the end is the other side', () {
      expect(name('Rs 7,200.00 has been transferred to your account XXXXXX4321 on 07-Nov-2026. Please check with your bank for details. From Sample Bank'), 'SAMPLE BANK');
    });

    test('with no signature there is no name, and still no issuer', () {
      final m = read('Rs: 4,100.00 has been transferred to your account XXXXXXX1234 on 05-Apr-2026. Please check with your bank for details.')!;
      expect(m.counterparty?.name, isNull);
      expect(m.instrument?.issuerSlug, isNull);
    });
  });

  group('a refund that names the merchant', () {
    test('"refund for your ... order from MERCHANT"', () {
      expect(name('Refund of Rs. 177.05 for your Sample Food order from Sunrise Biryani House - Old Town has been successfully processed and shall reflect in your account by now.', sender: 'VM-GENAPP-S'), contains('SUNRISE BIRYANI HOUSE'));
    });

    test('"MERCHANT refund of Rs X credited to ... Credit Card" keeps its old reading', () {
      // Naming this layout makes the linker look for the purchase it refunds; with
      // several purchases at the same merchant a partial refund then goes to review
      // and leaves the totals until someone answers. The amount match already
      // links the full refunds, so the name is not taken here (see the plan).
      final m = read('EXAMPLE*SHOP refund of Rs 254.70 credited to Sample Bank Credit Card XX4321 on 13-MAY-26. Revised total due Rs 2.45', sender: 'VM-GENCRD-S');
      expect(m?.counterparty?.name, isNull);
      expect(m?.purpose, MovementPurpose.refund);
    });

    test('the older "refund of Rs X from MERCHANT credited" layout still works', () {
      expect(name('Refund of Rs.499.00 from SWIGGY credited to your Bank Credit Card XX5678 on 03-11-26', sender: 'VM-GENCRD-S'), 'SWIGGY');
    });

    test('a refund that is only promised is not read', () {
      expect(read('Refund of Rs. 177.05 for your Sample Food order from Sunrise Biryani House will be processed in 3 days.', sender: 'VM-GENAPP-S')?.direction, isNot(Direction.credit));
    });
  });

  group('the printed date is kept, not replaced by the time the message arrived', () {
    DateTime? istDay(String body, {String sender = 'VM-GENBNK-S'}) {
      final at = read(body, sender: sender)?.occurredAt;
      if (at == null) return null;
      final ist = at.toUtc().add(const Duration(hours: 5, minutes: 30));
      return DateTime.utc(ist.year, ist.month, ist.day);
    }

    test('a transfer and an RTGS credit', () {
      expect(istDay('Your Ac x4455 debited Rs.5,000.00 for transfer to riya Ac x7788 dt 29.01.26 Ref 123456789012.'), DateTime.utc(2026, 1, 29));
      expect(istDay('Dear Customer, INR 3,00,000.00 credited to your A/c No XX4455 on 31/12/2025 through RTGS with UTR ABCD52025123100000001 by 024400000001234 ASHA RAO, INFO: SAMPLE'), DateTime.utc(2025, 12, 31));
    });
  });
}
