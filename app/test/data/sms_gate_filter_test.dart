import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/sms_gate_filter.dart';

void main() {
  group('SmsGateFilter DLT Header Cleaning', () {
    test('strips standard 2-letter DLT prefixes and route suffixes', () {
      expect(SmsGateFilter.cleanDltHeader('VK-HDFCBK-S'), 'HDFCBK');
      expect(SmsGateFilter.cleanDltHeader('AD-ICICIB'), 'ICICIB');
      expect(SmsGateFilter.cleanDltHeader('JM-AxisBk-P'), 'AXISBK');
      expect(SmsGateFilter.cleanDltHeader('BZ-SBIINB-T'), 'SBIINB');
      expect(SmsGateFilter.cleanDltHeader('PAYTM'), 'PAYTM');
    });
  });

  group('SmsGateFilter 5-Gate Triage', () {
    test('Gate 1: drops empty or huge payload', () {
      expect(SmsGateFilter.evaluate('HDFCBK', '').action, SmsGateAction.drop);
      expect(
        SmsGateFilter.evaluate('HDFCBK', '').dropReason,
        SmsGateDropReason.emptyOrMalformed,
      );
      expect(
        SmsGateFilter.evaluate('HDFCBK', 'a' * 20001).action,
        SmsGateAction.drop,
      );
    });

    test('Gate 2: drops OTPs and security alerts instantly', () {
      const otpMsg =
          'Your OTP for transaction of Rs. 4,500 at Amazon is 839201. Do not share this with anyone. Valid for 10 mins.';
      final verdict = SmsGateFilter.evaluate('VK-HDFCBK-S', otpMsg);
      expect(verdict.action, SmsGateAction.drop);
      expect(verdict.dropReason, SmsGateDropReason.otpOrSecurity);
      expect(verdict.shouldPass, isFalse);
    });

    test('Gate 3: drops P2P 10-digit phone numbers and 140 telemarketing', () {
      const spendMsg = 'Dear customer, Rs.500 spent at Store on 20-Oct-2026.';
      expect(
        SmsGateFilter.evaluate('9876543210', spendMsg).dropReason,
        SmsGateDropReason.telemarketingOrP2p,
      );
      expect(
        SmsGateFilter.evaluate('+919876543210', spendMsg).dropReason,
        SmsGateDropReason.telemarketingOrP2p,
      );
      expect(
        SmsGateFilter.evaluate('1401234567', spendMsg).dropReason,
        SmsGateDropReason.telemarketingOrP2p,
      );
    });

    test('Gate 3: drops promotional route (-P) messages unless completed txn', () {
      const promoMsg =
          'Enjoy 10% off on your next dining experience with HDFC Credit Card. Book now!';
      final verdict = SmsGateFilter.evaluate('AD-HDFCBK-P', promoMsg);
      expect(verdict.action, SmsGateAction.drop);
      expect(verdict.dropReason, SmsGateDropReason.promotionalNoise);
    });

    test('Gate 4: drops CDSL / NSDL depository share movements and trading tips', () {
      const cdslMsg =
          'CDSL: Debit in A/c **1234 for 10 units of NIFTYBEES on 22-OCT-2026.';
      final verdict = SmsGateFilter.evaluate('CDSLIN', cdslMsg);
      expect(verdict.action, SmsGateAction.drop);
      expect(verdict.dropReason, SmsGateDropReason.dematOrSecuritiesAlert);
    });

    test('Gate 4: drops depository pledge/unpledge alerts and KRA/folio address updates', () {
      const unpledgeMsg =
          'CDSL: Unpledge confirmed for 50 shares of TATASTEEL in A/c **4321 on 22-OCT-2026.';
      final v1 = SmsGateFilter.evaluate('CDSLIN', unpledgeMsg);
      expect(v1.action, SmsGateAction.drop);
      expect(v1.dropReason, SmsGateDropReason.dematOrSecuritiesAlert);

      const kraMsg =
          'Updated your address under folio 12345678 based on feed received from KRA.';
      final v2 = SmsGateFilter.evaluate('KFINTECH', kraMsg);
      expect(v2.action, SmsGateAction.drop);
      expect(v2.dropReason, SmsGateDropReason.dematOrSecuritiesAlert);
    });

    test('Gate 4/5: drops operational downtime, logistics, coupons, cards, and insurance noise', () {
      const downtimeMsg =
          'Due to scheduled maintenance banking services will be unavailable from 1 AM to 4 AM.';
      final v1 = SmsGateFilter.evaluate('HDFCBK', downtimeMsg);
      expect(v1.action, SmsGateAction.drop);
      expect(v1.dropReason, SmsGateDropReason.promotionalNoise);

      const regMsg =
          'Registration alert: device name iPhone 15 was registered for Mobile Banking.';
      final v2 = SmsGateFilter.evaluate('HDFCBK', regMsg);
      expect(v2.action, SmsGateAction.drop);

      const couponMsg = 'Hurry! Your 5 discount coupons expire today. Shop now at Amazon.';
      final v3 = SmsGateFilter.evaluate('AMAZON', couponMsg);
      expect(v3.action, SmsGateAction.drop);

      const dispatchMsg =
          'Your order ID 987654 is dispatched through Blue Dart with tracking AWB 12345.';
      final v4 = SmsGateFilter.evaluate('DELHIV', dispatchMsg);
      expect(v4.action, SmsGateAction.drop);

      const ltfCardMsg =
          'Congratulations! Lifetime-free credit card facility has been enabled with limit Rs. 1,50,000.';
      final v5 = SmsGateFilter.evaluate('ICICIB', ltfCardMsg);
      expect(v5.action, SmsGateAction.drop);
      expect(v5.dropReason, SmsGateDropReason.promotionalNoise);

      const insuranceMsg =
          'Motor insurance for MH02CB1234 has expired. Renew today at Rs. 2,099.';
      final v6 = SmsGateFilter.evaluate('BAJAJA', insuranceMsg);
      expect(v6.action, SmsGateAction.drop);
      expect(v6.dropReason, SmsGateDropReason.promotionalNoise);
    });

    test('Gate 5: drops non-financial chatter with no amounts or financial verbs', () {
      const chatMsg = 'Hey, are you free to meet up this evening? Let me know!';
      final verdict = SmsGateFilter.evaluate('FRIEND', chatMsg);
      expect(verdict.action, SmsGateAction.drop);
    });

    test('Passes valid debit, credit, bill, and autopay notifications', () {
      const debitMsg =
          'Rs. 1,450.00 debited from HDFC Bank A/c ending 1234 on 22-Oct-26 at Swiggy. Avl bal: Rs. 45,000.';
      final v1 = SmsGateFilter.evaluate('VM-HDFCBK-S', debitMsg);
      expect(v1.action, SmsGateAction.pass);
      expect(v1.normalizedSender, 'HDFCBK');
      expect(v1.shouldPass, isTrue);

      const billMsg =
          'Your Airtel Broadband bill of Rs. 999 is due on 28-Oct-2026. Pay now to avoid disconnection.';
      final v2 = SmsGateFilter.evaluate('AIRTEL', billMsg);
      expect(v2.action, SmsGateAction.pass);
      expect(v2.normalizedSender, 'AIRTEL');
      expect(v2.shouldPass, isTrue);

      const autopayMsg =
          'AutoPay reminder: Rs. 500 will be debited from A/c 1234 on 25-Oct-2026 for Netflix subscription.';
      final v3 = SmsGateFilter.evaluate('HDFCBK', autopayMsg);
      expect(v3.action, SmsGateAction.pass);
      expect(v3.shouldPass, isTrue);
    });
  });
}
