import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  late AppDatabase db;
  late FinancialStore financialStore;
  late SmsIntakeRepository intake;
  late SmsImportStore importStore;
  late NeedsReviewRepository reviewRepo;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    financialStore = FinancialStore(db);
    intake = SmsIntakeRepository(db);
    importStore = SmsImportStore(financialStore);
    reviewRepo = NeedsReviewRepository(
      namespace: 'user_test',
      loadDatabase: () async => db,
    );
  });

  tearDown(() => db.close());

  group('Category 1: Aggressive EMI Solicitations Quoting Past Spend', () {
    final emiMessages = <(String sender, String body)>[
      ('BP-SBICRD-S', 'Trxns of Rs. 40,016 eligible for EMI conversion. SMS EMI to 56767.'),
      ('BP-SBICRD-S', 'Txn of Rs. 40,016 eligible for EMI conversion. Click link.'),
      ('VM-HDFCBK-S', 'Your txn of Rs. 40,016 is eligible for EMI conversion.'),
      ('VM-HDFCBK-S', 'Your txn of Rs. 15,000 on HDFC Bank Card ending 1234 is eligible for conversion to easy EMI. Apply now.'),
      ('VM-ICICIB-S', 'Convert your txn of Rs. 15,000 into easy EMIs. Click bit.ly/emi.'),
      ('VM-ICICIB-S', 'Convert your transaction of Rs 10000 into EMI.'),
      ('BP-SBICRD-S', 'Dear Cardholder, trxns. of combined value Rs.40016 are eligible for conversion to Flexipay EMIs. Click link.'),
      ('BP-SBICRD-S', 'You spent Rs.40016 on your SBI Credit Card and are eligible for conversion to Flexipay EMIs.'),
      ('VM-HDFCBK-S', 'Convert txn of INR 24,999 on your HDFC Bank Card ending 1234 into easy EMIs starting @ Rs 1200/mo. Call 18002664332.'),
      ('VM-ICICIB-S', 'Your recent transaction of Rs. 12,499 on ICICI Bank Card 5678 is eligible for EMI. SMS EMI to 56767.'),
      ('AD-AXISBK-S', 'Convert your spends of Rs. 18,500 on Axis Bank Card into EMIs at just 1.5% interest. Visit axisbank.com/emi.'),
      ('VM-KOTAKB-S', 'Good news! Spends of Rs 9,999 on Kotak Card can now be converted to Smart EMIs. Log in to app.'),
    ];

    for (final (sender, body) in emiMessages) {
      test('EMI promo rejected: "$body"', () {
        final captured = capturesFinancialSms(body, sender: sender);
        final isNoise = LocalSmsParser.isNonTransactionNoise(sender, body);
        expect(captured, isFalse, reason: 'capturesFinancialSms should be false for EMI solicitation: $body');
        expect(isNoise, isTrue, reason: 'isNonTransactionNoise should be true for EMI solicitation: $body');
      });
    }
  });

  group('Category 2: Spend-Threshold Promotions With Prices and Amounts', () {
    final spendThresholdMessages = <(String sender, String body)>[
      ('VM-HDFCBK-P', 'Spend INR 15,000 on your card and get cashback of INR 250. Offer valid this month.'),
      ('VM-HDFCBK-S', 'Spend INR 15,000 on your card and get cashback of INR 250. Offer valid this month.'),
      ('VM-ICICIB-P', 'Spend Rs. 20,000 on ICICI Bank Credit Card this festive season and get an Amazon voucher worth Rs. 1,000!'),
      ('AD-AXISBK-P', 'Shop for Rs. 5,000 or more using Axis Card and earn 500 bonus reward points. Valid till Sunday.'),
      ('VM-SBICRD-P', 'Spend Rs. 10,000 on SBI Card ending 4321 and get flat 5% cashback up to Rs. 750. T&C apply.'),
      ('VM-KOTAKB-P', 'Make 3 transactions of Rs. 1,000 each and get Rs. 300 Swiggy voucher free!'),
      ('VM-AMEXIN-P', 'Unlock Rs. 2,000 Taj voucher by spending Rs. 50,000 in your first 90 days. Enroll now.'),
    ];

    for (final (sender, body) in spendThresholdMessages) {
      test('Spend threshold rejected: "$body"', () {
        final captured = capturesFinancialSms(body, sender: sender);
        final isNoise = LocalSmsParser.isNonTransactionNoise(sender, body);
        expect(captured, isFalse, reason: 'capturesFinancialSms should be false for: $body');
        expect(isNoise, isTrue, reason: 'isNonTransactionNoise should be true for: $body');
      });
    }
  });

  group('Category 3: Retail & E-commerce Offers Quoting Prices', () {
    final retailOffers = <(String sender, String body)>[
      ('TX-WAKFTT-P', 'Luxury on a budget? Treat yourself to Wakefit sofa at just Rs.28,125. Grab offer https://gs.im/x'),
      ('VA-LIFSTL-P', 'Make Festive Shopping More Rewarding! Shop at Lifestyle stores and get vouchers worth Rs.10,000.'),
      ('VM-FLPKRT-P', 'Flipkart Big Billion Days! iPhone 15 at just Rs. 49,999. Use HDFC card for extra Rs. 3,000 off. Shop now!'),
      ('VM-AMAZON-P', 'Great Indian Festival: Laptops starting at Rs. 24,990. No Cost EMI available. Buy now on Amazon.'),
      ('BZ-MYNTRA-P', 'Flat 50% - 80% off on premium fashion. Branded shoes starting at Rs. 999. Use coupon MYNTRA500.'),
      ('AD-AJIOST-P', 'Ajio All Stars Sale! T-shirts at just Rs. 199, Jeans at Rs. 599. Extra Rs. 500 off on orders above Rs. 1999.'),
      ('VM-CROMA-P', 'Smart TVs starting at Rs. 11,990 at Croma! Instant discount of Rs. 1,500 on ICICI Bank Cards.'),
      ('VM-RELIAN-P', 'Reliance Digital: Buy Samsung Galaxy S24 at effective price of Rs. 64,999 with bank cashback of Rs. 5,000.'),
    ];

    for (final (sender, body) in retailOffers) {
      test('Retail offer rejected: "$body"', () {
        final captured = capturesFinancialSms(body, sender: sender);
        final isNoise = LocalSmsParser.isNonTransactionNoise(sender, body);
        expect(captured, isFalse, reason: 'capturesFinancialSms should be false for: $body');
        expect(isNoise, isTrue, reason: 'isNonTransactionNoise should be true for: $body');
      });
    }
  });

  group('Category 4: Credit Card Upgrade / Pre-Approved Loan Spam', () {
    final loanCardSpam = <(String sender, String body)>[
      ('VM-HDFCBK-P', 'Pre-approved personal loan of Rs. 5 Lakhs! Apply now. Disbursal in 10 seconds. Click bit.ly/hdfcln'),
      ('VM-HDFCBK-S', 'Pre-approved personal loan of Rs. 5 Lakhs! Apply now'),
      ('AD-ICICIB-P', 'Congratulations! You are eligible for pre-approved personal loan of Rs. 10,00,000 with low interest. Apply now.'),
      ('VM-AXISBK-P', 'Upgrade your ICICI Credit Card to Rubyx with credit limit of Rs. 5,00,000 at zero joining fee! Apply today.'),
      ('VM-BAJAJF-P', 'Instant Cash Loan up to Rs. 2,00,000 approved in your Bajaj Finserv account. Avail now at zero processing fee.'),
      ('BP-POONAW-P', 'Get Instant Business Loan up to Rs. 30 Lakhs with minimum documentation. Apply now at Poonawalla Fincorp.'),
      ('VM-TATACR-P', 'Lifetime Free Tata Neu Infinity Card with credit limit of Rs. 3,00,000! Apply now and earn 10% NeuCoins.'),
      ('VM-SBICRD-P', 'Special offer: Pre-approved SBI Credit Card with credit limit of Rs. 1,50,000. No income proof required. Apply now.'),
    ];

    for (final (sender, body) in loanCardSpam) {
      test('Loan/card upgrade spam rejected: "$body"', () {
        final captured = capturesFinancialSms(body, sender: sender);
        final isNoise = LocalSmsParser.isNonTransactionNoise(sender, body);
        expect(captured, isFalse, reason: 'capturesFinancialSms should be false for: $body');
        expect(isNoise, isTrue, reason: 'isNonTransactionNoise should be true for: $body');
      });
    }
  });

  group('Category 5: Smishing Fraud & Fake Bank SMS from Mobile Numbers', () {
    final smishingMessages = <(String sender, String body)>[
      ('9876543210', 'Your bank account debited Rs. 50,000 call 9876543210 if not done.'),
      ('+919876543210', 'Rs. 25,000 debited from A/c XX4321 on 22-10-26. If not you, contact 9876543210 immediately.'),
      ('+91 9876543210', 'Dear customer, INR 45,000 transferred to John Doe. Call +919876543210 to cancel.'),
      ('09876543210', 'Your SBI a/c XX1234 debited by Rs. 10,000 at ATM. If not done by you call 09876543210.'),
      ('8888888888', 'Your credit card XX9999 charged Rs. 85,000 at JEWELLERS. Call fraud desk 8888888888.'),
      ('7001234567', 'Electricity bill unpaid! Your power will be disconnected at 9 PM. Pay Rs. 2,450 to 7001234567.'),
    ];

    for (final (sender, body) in smishingMessages) {
      test('Smishing from mobile number rejected: sender=$sender', () {
        final captured = capturesFinancialSms(body, sender: sender);
        final isNoise = LocalSmsParser.isNonTransactionNoise(sender, body);
        expect(captured, isFalse, reason: 'capturesFinancialSms should be false for 10-digit sender: $sender');
        expect(isNoise, isTrue, reason: 'isNonTransactionNoise should be true for 10-digit sender: $sender');
      });
    }
  });

  group('Category 6: TRAI DLT 6-Digit Numeric Telemarketing Headers', () {
    final dltNumericMessages = <(String sender, String body)>[
      ('512345', 'Rs.500 debited from your card for subscription.'),
      ('VM-123456', 'Rs.500 debited from your card. Thank you for using our service.'),
      ('123456-A', 'Account XX1234 debited INR 1,200.00 at MERCHANT.'),
      ('1409876543', 'Your card XX5678 was debited Rs. 2,000. Call for details.'),
      ('+911409876543', 'Transaction of Rs. 3,500 completed on your account.'),
      ('123456', 'Dear user, Rs. 1,000 debited from your wallet.'),
      ('654321', 'Your account XX9876 has been charged Rs. 499.'),
    ];

    for (final (sender, body) in dltNumericMessages) {
      test('DLT numeric sender rejected: sender=$sender', () {
        final captured = capturesFinancialSms(body, sender: sender);
        final isNoise = LocalSmsParser.isNonTransactionNoise(sender, body);
        expect(captured, isFalse, reason: 'capturesFinancialSms should be false for DLT sender: $sender');
        expect(isNoise, isTrue, reason: 'isNonTransactionNoise should be true for DLT sender: $sender');
      });
    }
  });

  group('Category 7: Telecom Roaming Pack & Service Promo Ads', () {
    final telecomServicePromo = <(String sender, String body)>[
      ('AY-AIRTEL-P', 'Breaking news: 5-Din ka Airtel International Roaming pack. Payein sirf Rs.999.'),
      ('VM-JIOINF-P', 'Jio Cricket Pack: Recharge with Rs. 499 and get 3 months Disney+ Hotstar free! Recharge now on MyJio.'),
      ('VM-VILINF-P', 'Vi Hero Unlimited: Unlimited night data from 12am to 6am at just Rs. 299/month. Recharge now on Vi App.'),
      ('AD-AIRTEL-P', 'Special recharge offer! Unlimited calls + 2GB/day at Rs. 359 for 28 days. Pay via Airtel Payments Bank for Rs. 20 cashback.'),
      ('VM-TATAPL-P', 'Recharge your Tata Play account with Rs. 500 and get 30 days extra sports pack free. Visit tataplay.com.'),
      ('VM-DISH-P', 'DishTV festive offer: Recharge with Rs. 1,200 for 6 months and save Rs. 300. Call 18002583474.'),
    ];

    for (final (sender, body) in telecomServicePromo) {
      test('Telecom service promo rejected: "$body"', () {
        final captured = capturesFinancialSms(body, sender: sender);
        final isNoise = LocalSmsParser.isNonTransactionNoise(sender, body);
        expect(captured, isFalse, reason: 'capturesFinancialSms should be false for: $body');
        expect(isNoise, isTrue, reason: 'isNonTransactionNoise should be true for: $body');
      });
    }
  });

  group('Category 8: Security, OTP, and KYC Scam Spam', () {
    final securityKycSpam = <(String sender, String body)>[
      ('VA-SBIBNK-S', 'Dear SBI customer, RINB/YONO services is being blocked due to suspicious txns in your account. Visit nearest branch.'),
      ('VM-SBIINB-S', 'Dear SBI customer, your YONO account is blocked due to suspicious txns. Visit link http://sbi-kyc-update.xyz to unblock.'),
      ('AD-ICICIB-S', 'ICICI Alert: Your NetBanking is deactivated. Update PAN card immediately to avoid penalty of Rs. 10,000. Click http://bit.ly/icici-pan.'),
      ('VM-HDFCBK-S', 'Dear customer, your HDFC bank a/c XX1234 will be suspended today. Please complete your KYC verification by visiting http://hdfc-kyc.net.'),
      ('VM-HDFCBK-S', '812345 is your OTP for transaction of INR 500 at SWIGGY. Valid for 5 mins. Do not share OTP with anyone.'),
      ('VM-AXISBK-S', 'OTP is 908123 for txn of Rs. 2,499.00 on Axis Bank Credit Card XX4321 at FLIPKART. Do not share OTP.'),
      ('VM-KOTAKB-S', 'Your debit card has been blocked due to 3 incorrect PIN attempts. Call 1860-266-2661 or visit nearest branch to unblock.'),
    ];

    for (final (sender, body) in securityKycSpam) {
      test('Security/OTP/KYC spam rejected: "$body"', () {
        final captured = capturesFinancialSms(body, sender: sender);
        expect(captured, isFalse, reason: 'capturesFinancialSms should be false for: $body');
      });
    }
  });

  group('Category 9: Lottery / Rewards Spam', () {
    final lotteryRewardsSpam = <(String sender, String body)>[
      ('VM-REWARD-P', 'You won Rs. 50,000 cash prize in Diwali Lucky Draw! Claim now by paying processing fee of Rs. 500 at http://claim-prize.in'),
      ('AD-PRIZE-P', 'Congratulations! You have won Rs. 25,00,000 in Kaun Banega Crorepati lucky draw. Call 9876543210 to claim your prize.'),
      ('VM-WINNER-P', 'Dear user, your phone number has won a cash prize of Rs. 1,00,000. Click to transfer to your bank account: bit.ly/prize-claim'),
      ('VM-SPINWN-P', 'Spin and Win! You have won Rs. 10,000 cash reward. Claim your reward at bit.ly/prize now. Valid for 24 hours.'),
      ('BZ-LUCKY7-P', 'Winner alert! You are selected for cash prize of Rs. 5,00,000 from Government of India. Send details to claim.'),
    ];

    for (final (sender, body) in lotteryRewardsSpam) {
      test('Lottery/rewards spam rejected: "$body"', () {
        final captured = capturesFinancialSms(body, sender: sender);
        final isNoise = LocalSmsParser.isNonTransactionNoise(sender, body);
        expect(captured, isFalse, reason: 'capturesFinancialSms should be false for: $body');
        expect(isNoise, isTrue, reason: 'isNonTransactionNoise should be true for: $body');
      });
    }
  });

  group('Category 10: General Personal Chats, Delivery Notices, Food Order Arrival Notices', () {
    final personalAndDeliveryNotices = <(String sender, String body)>[
      ('VM-SWIGGY', 'Your Swiggy order is arriving in 5 minutes! Delivery partner Ramesh is on his way.'),
      ('VM-ZOMATO', 'Your Zomato delivery partner has arrived at your location. Please collect your food. Enjoy your meal!'),
      ('VM-AMAZON', 'Your Amazon package with tracking ID 123456 is out for delivery today. Delivery agent will arrive by 7 PM.'),
      ('AD-BLUDRT', 'Your Blue Dart AWB 987654321 has been delivered to security. Thank you for shipping with Blue Dart.'),
      ('VM-DELHIV', 'Delhivery: Shipment 443210123 is out for delivery today. Share OTP 4321 with agent at time of delivery.'),
      ('VM-UBERIN', 'Your Uber driver is arriving in a White Swift Dzire (KA01AB1234). OTP is 1234.'),
      ('VM-CLINIC', 'Your appointment with Dr. Sharma at Apollo Clinic is confirmed for tomorrow 4:00 PM.'),
      ('9876543210', 'Good morning! Are you free for lunch today?'),
      ('9876543210', 'Hey, did you reach home safely? Call me when you get free.'),
      ('VM-AIRTEL', 'Alert: call forwarding is active on your mobile number. Dial ##002# to deactivate.'),
    ];

    for (final (sender, body) in personalAndDeliveryNotices) {
      test('Chat/delivery notice rejected: "$body"', () {
        final captured = capturesFinancialSms(body, sender: sender);
        expect(captured, isFalse, reason: 'capturesFinancialSms should be false for: $body');
      });
    }
  });

  group('End-to-End Ingestion Pipeline: Verify No Noise Enters Needs Review or Intake Pending', () {
    test('Zero noise / promo SMS enters intake pending or needs review', () async {
      final noiseBatch = <QueuedSms>[
        QueuedSms(
          sender: 'BP-SBICRD-S',
          body: 'Trxns of Rs. 40,016 eligible for EMI conversion. SMS EMI to 56767.',
          receivedAt: DateTime(2026, 10, 22, 10, 0),
        ),
        QueuedSms(
          sender: 'VM-HDFCBK-P',
          body: 'Spend INR 15,000 on your card and get cashback of INR 250. Offer valid this month.',
          receivedAt: DateTime(2026, 10, 22, 10, 1),
        ),
        QueuedSms(
          sender: 'TX-WAKFTT-P',
          body: 'Luxury on a budget? Treat yourself to Wakefit sofa at just Rs.28,125. Grab offer https://gs.im/x',
          receivedAt: DateTime(2026, 10, 22, 10, 2),
        ),
        QueuedSms(
          sender: 'VM-HDFCBK-P',
          body: 'Pre-approved personal loan of Rs. 5 Lakhs! Apply now',
          receivedAt: DateTime(2026, 10, 22, 10, 3),
        ),
        QueuedSms(
          sender: '9876543210',
          body: 'Your bank account debited Rs. 50,000 call 9876543210 if not done.',
          receivedAt: DateTime(2026, 10, 22, 10, 4),
        ),
        QueuedSms(
          sender: '512345',
          body: 'Rs.500 debited from your card for subscription.',
          receivedAt: DateTime(2026, 10, 22, 10, 5),
        ),
        QueuedSms(
          sender: 'AY-AIRTEL-P',
          body: 'Breaking news: 5-Din ka Airtel International Roaming pack. Payein sirf Rs.999.',
          receivedAt: DateTime(2026, 10, 22, 10, 6),
        ),
        QueuedSms(
          sender: 'VA-SBIBNK-S',
          body: 'Dear SBI customer, RINB/YONO services is being blocked due to suspicious txns in your account. Visit nearest branch.',
          receivedAt: DateTime(2026, 10, 22, 10, 7),
        ),
        QueuedSms(
          sender: 'VM-REWARD-P',
          body: 'You won Rs. 50,000 cash prize in Diwali Lucky Draw! Claim now by paying processing fee of Rs. 500 at http://claim-prize.in',
          receivedAt: DateTime(2026, 10, 22, 10, 8),
        ),
        QueuedSms(
          sender: 'VM-SWIGGY',
          body: 'Your Swiggy order is arriving in 5 minutes! Delivery partner Ramesh is on his way.',
          receivedAt: DateTime(2026, 10, 22, 10, 9),
        ),
      ];

      importStore.captureBatch('user_test', noiseBatch);

      final pending = intake.pending('user_test');
      expect(pending, isEmpty, reason: 'No noise message should be pending financial sync');

      final capturedBodies = intake.capturedBodies('user_test');
      expect(capturedBodies, isEmpty, reason: 'No noise message raw body should be retained');

      final reviewItems = await reviewRepo.fetchAll();
      expect(reviewItems, isEmpty, reason: 'No noise message should be routed to Needs Review');
    });
  });
}
