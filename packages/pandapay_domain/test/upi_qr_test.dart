import 'package:test/test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  group('parseUpiQrString', () {
    test('parses a full merchant UPI QR string', () {
      final parsed = parseUpiQrString('upi://pay?pa=shop@okhdfcbank&pn=DMart%20Powai&am=2400.00&mc=5411&cu=INR');

      expect(parsed, isNotNull);
      expect(parsed!.pa, 'shop@okhdfcbank');
      expect(parsed.pn, 'DMart Powai');
      expect(parsed.mc, '5411');
      expect(parsed.am, Money.fromRupees(2400));
      expect(parsed.cu, 'INR');
      expect(parsed.isLikelyP2P, isFalse);
    });

    test('a QR with no mc param is flagged as likely P2P', () {
      final parsed = parseUpiQrString('upi://pay?pa=friend@okaxis&pn=A%20Friend');

      expect(parsed, isNotNull);
      expect(parsed!.mc, isNull);
      expect(parsed.isLikelyP2P, isTrue);
    });

    test('a QR with no am param leaves am null rather than zero', () {
      final parsed = parseUpiQrString('upi://pay?pa=shop@okicici&pn=Some%20Shop&mc=5812');

      expect(parsed, isNotNull);
      expect(parsed!.am, isNull);
    });

    test('a malformed am param does not throw — parses everything else and leaves am null', () {
      // This app scans arbitrary (attacker-controlled) QR codes, and the
      // function's own doc comment promises it returns null for anything
      // unusable — not that it throws. double.parse would throw
      // FormatException here; double.tryParse must not, and every other
      // field (pa/mc) is still perfectly valid and usable.
      final parsed = parseUpiQrString('upi://pay?pa=x@y&mc=5411&am=abc');

      expect(parsed, isNotNull);
      expect(parsed!.pa, 'x@y');
      expect(parsed.mc, '5411');
      expect(parsed.am, isNull);
    });

    test('a non-UPI string returns null', () {
      expect(parseUpiQrString('https://example.com'), isNull);
      expect(parseUpiQrString('not a url at all'), isNull);
    });

    test('a upi:// link missing pa entirely returns null — not a usable payment target', () {
      expect(parseUpiQrString('upi://pay?pn=Nobody'), isNull);
    });
  });

  group('buildUpiPayUri', () {
    test('builds a well-formed intent with amount', () {
      final uri = buildUpiPayUri(pa: 'shop@okhdfcbank', pn: 'DMart Powai', am: Money.fromRupees(2400));

      expect(uri, 'upi://pay?pa=shop%40okhdfcbank&pn=DMart%20Powai&am=2400.00&cu=INR');
    });

    test('omits am from the query string when no amount is given', () {
      final uri = buildUpiPayUri(pa: 'shop@okhdfcbank', pn: 'DMart Powai');

      expect(uri, 'upi://pay?pa=shop%40okhdfcbank&pn=DMart%20Powai&cu=INR');
    });
  });
}
