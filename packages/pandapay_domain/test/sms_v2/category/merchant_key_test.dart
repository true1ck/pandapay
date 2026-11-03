import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:test/test.dart';

MerchantAlias _alias(String a, String key) => MerchantAlias(alias: a, merchantKey: key, kind: 'variant');

Counterparty _c({String? name, String? vpa, CounterpartyKind? kind}) =>
    Counterparty(name: name, vpa: vpa, kind: kind);

void main() {
  final keyer = MerchantKeyer([
    _alias('AMAZON PAY IN', 'AMAZON'),
    _alias("MCDONALD'S", 'MCDONALDS'),
    _alias('APPLE.COM/BILL', 'APPLE SERVICES'),
    _alias('SWIGGY LIMITED', 'SWIGGY'),
    _alias('ADD-MONEY@PAYTM', 'PAYTM WALLET'),
  ]);

  test('upper-cases and collapses separators', () {
    expect(keyer.keyFor(_c(name: '  swiggy   instamart ')), 'SWIGGY INSTAMART');
    expect(keyer.keyFor(_c(name: 'cafe-coffee_day')), 'CAFE COFFEE DAY');
    expect(keyer.keyFor(_c(name: 'H&M')), 'H&M');
  });

  test('strips legal suffixes', () {
    expect(keyer.keyFor(_c(name: 'Bundl Technologies Pvt Ltd')), 'BUNDL TECHNOLOGIES');
    expect(keyer.keyFor(_c(name: 'Foo Bar Private Limited')), 'FOO BAR');
    expect(keyer.keyFor(_c(name: 'Foo Bar LLP')), 'FOO BAR');
    expect(keyer.keyFor(_c(name: 'Foo Bar (P) Ltd.')), 'FOO BAR');
    expect(keyer.keyFor(_c(name: 'Limited')), 'LIMITED');
  });

  test('applies aliases to the whole key only', () {
    expect(keyer.keyFor(_c(name: 'Amazon Pay IN')), 'AMAZON');
    expect(keyer.keyFor(_c(name: "McDonald's")), 'MCDONALDS');
    expect(keyer.keyFor(_c(name: 'apple.com/bill')), 'APPLE SERVICES');
    // Not a whole-key match: left alone.
    expect(keyer.keyFor(_c(name: 'Amazon Pay IN Store')), 'AMAZON PAY IN STORE');
    // The alias is found before or after the legal suffix is stripped.
    expect(keyer.keyFor(_c(name: 'Swiggy Limited')), 'SWIGGY');
  });

  group('UPI IDs', () {
    test('alias table first', () {
      expect(keyer.keyFor(_c(vpa: 'add-money@paytm')), 'PAYTM WALLET');
    });

    test('then the readable local part', () {
      expect(keyer.keyFor(_c(vpa: 'swiggy@icici')), 'SWIGGY');
      expect(keyer.keyFor(_c(vpa: 'zomato.rzp@axisbank')), 'ZOMATO');
      expect(keyer.keyFor(_c(vpa: 'cafe.coffee.day@ybl')), 'CAFE COFFEE DAY');
    });

    test('numbers and gateway ids give no key', () {
      expect(keyer.keyFor(_c(vpa: '9876543210@ybl')), isNull);
      expect(keyer.keyFor(_c(vpa: 'paytmqr2810050501011abcd@paytm')), isNull);
      expect(keyer.keyFor(_c(vpa: 'q123456789@ybl')), isNull);
    });

    test('a local part that is an alias maps to the alias target', () {
      final k = MerchantKeyer([_alias('AMAZON PAY IN', 'AMAZON')]);
      expect(k.keyFor(_c(vpa: 'amazon.pay.in@apl')), 'AMAZON');
    });

    test('the name wins over the UPI ID when it has a key', () {
      expect(keyer.keyFor(_c(name: 'Swiggy', vpa: 'q99999999@ybl')), 'SWIGGY');
      expect(keyer.keyFor(_c(name: '1234567', vpa: 'swiggy@icici')), 'SWIGGY');
    });

    test('a name that is a UPI ID is read as one', () {
      expect(keyer.keyFor(_c(name: 'swiggy@icici')), 'SWIGGY');
    });
  });

  group('people', () {
    test('a person never gets a merchant key', () {
      expect(keyer.keyFor(_c(name: 'Ramesh Kumar', kind: CounterpartyKind.person)), isNull);
      expect(keyer.keyFor(_c(name: 'Ramesh', vpa: 'ramesh@okhdfcbank', kind: CounterpartyKind.person)), isNull);
    });

    test('own accounts, empty and missing counterparties give no key', () {
      expect(keyer.keyFor(_c(name: 'HDFC Card', kind: CounterpartyKind.own)), isNull);
      expect(keyer.keyFor(null), isNull);
      expect(keyer.keyFor(_c()), isNull);
      expect(keyer.keyFor(_c(name: '   ')), isNull);
    });

    test('personRuleKey is for user rules only and uses the UPI ID first', () {
      final p = _c(name: 'Ramesh Kumar', vpa: 'ramesh@okhdfcbank', kind: CounterpartyKind.person);
      expect(keyer.personRuleKey(p), 'RAMESH OKHDFCBANK');
      expect(keyer.personRuleKey(_c(name: 'Ramesh Kumar')), 'RAMESH KUMAR');
      expect(keyer.personRuleKey(null), isNull);
    });
  });

  test('the top-level merchantKey takes aliases as an argument', () {
    expect(merchantKey(_c(name: 'Amazon Pay IN'), aliases: [_alias('AMAZON PAY IN', 'AMAZON')]), 'AMAZON');
    expect(merchantKey(_c(name: 'Amazon Pay IN')), 'AMAZON PAY IN');
  });
}
