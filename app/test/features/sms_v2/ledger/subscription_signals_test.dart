// Subscription signals through the real pipeline and the real rules: the
// wordings real banks and services use to start, end and announce a
// subscription, the history each one leaves, and what is asked about instead of
// guessed. Synthetic messages only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/insights/subscription_view.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:signals';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late SmsV2Pipeline pipeline;
  var n = 0;

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    final json = (jsonDecode(jsonEncode(testRuleBundle().toJson())) as Map)
        .cast<String, Object?>();
    json['solverPack'] =
        (jsonDecode(File('../rules/sms/solver/pack.json').readAsStringSync())
                as Map)
            .cast<String, Object?>();
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: _ns,
      bundle: RuleBundle.fromJson(json),
      appVersion: '2.0.0',
    );
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  void send(String sender, String body, String day) {
    n++;
    pipeline.process(
      SmsMessage(
        sender: sender,
        body: body,
        sourceKey: n.toRadixString(16).padLeft(64, '0'),
        observedAt: DateTime.parse('${day}T06:00:00Z'),
      ),
    );
  }

  final now = DateTime.utc(2026, 11, 13);
  List<RecurringSeries> subs() => subscriptionsFromLedger(
    FactStore(db.db, namespace: _ns).all(),
    EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900)),
    now: now,
  );
  RecurringSeries named(String name) =>
      subs().singleWhere((s) => s.displayName.toLowerCase() == name.toLowerCase());

  group('starting a subscription', () {
    test('"AutoPay Active! For X Starting: Mandate ID" names the service it states', () {
      send(
        'AD-HDFCBK-S',
        'AutoPay Active!\nFor Netflix\nStarting:05/11/2026\nMandate ID:Ab12Cd34Ef\nOn HDFC Bank Card 1234\nManage: https://example.invalid/x\nTnC',
        '2026-11-05',
      );
      final s = named('Netflix');
      expect(s.lifecycleStatus, 'active');
      expect(s.mandateReference, 'Ab12Cd34Ef');
    });

    test('an Axis activation names its own service, not a fixed one', () {
      send(
        'AX-AXISBK-S',
        'AutoPay activation successful.\nTxn amt: INR 0.00\nMerchant: Spotify\nAxis Bank Card no.: XX1234\nMax limit: INR 199.00\nID: Qwe123\nManage AutoPay at https://example.invalid',
        '2026-11-05',
      );
      expect(subs().map((s) => s.displayName.toLowerCase()), ['spotify']);
    });

    test('"your subscription is now activated" starts one', () {
      send(
        'JD-JIONET-S',
        // The whole real shape, offers included: a promotional footer must not
        // hide that a subscription started.
        'Congratulations!\nYour 1-month JioHotstar subscription is now activated on Jio number 9999999999.\nPlease note, this subscription can be availed for up to 2 more months on your Jio number on recharging with eligible plans.\nLog in to JioHotstar app with your Jio number and enjoy live cricket, movies, TV shows, and more!\nTo enrol for Jio Gold offer, give a missed call on +91-8010000524 or click https://tiny.jio.com/jiogoldoffer  and enjoy 1% extra digital Gold on every purchase via the JioFinance App. T&C apply.\nTo avail 60 days free Jio Home trial offer, visit https://tiny.jio.com/jiohomeoffer to register your interest. T&C apply.\nTeam Jio',
        '2026-03-04',
      );
      expect(named('JioHotstar').lifecycleStatus, isNot('cancelled'));
    });
  });

  group('ending a subscription, however it is worded', () {
    test('a service that says it cancelled your subscription', () {
      send(
        'JD-JIONET-S',
        'Congratulations!\nYour 1-month JioHotstar subscription is now activated on Jio number 9999999999.',
        '2026-03-04',
      );
      send(
        'JX-JIOHTT-S',
        "We're sad to see you go.\n\nAs you requested, we've cancelled your JioHotstar account subscription linked to 9999999999, effective 6th May, 2026\n\nIf you change your mind, restart",
        '2026-04-19',
      );
      final s = named('JioHotstar');
      expect(s.lifecycleStatus, 'cancelled');
      expect(s.nextExpectedOn, isNull);
    });

    test('a UPI mandate cancelled by a payee known only by its handle', () {
      send(
        'JX-HDFCBK-S',
        'HDFC Bank: Your UPI-Mandate is successfully cancelled by  payee99@examplepsp for Rs 299.00.',
        '2025-12-30',
      );
      final s = subs().single;
      expect(s.lifecycleStatus, 'cancelled');
      expect(s.displayName, contains('payee99@examplepsp'));
      // Shown as a past row rather than dropped for being a UPI handle.
      expect(buildSubscriptionView([s]).past, hasLength(1));
    });

    test('a membership that expired', () {
      send(
        'VA-FLPKRT-S',
        'Flipkart Plus Membership : Your Plus membership expired on 07 Jun 2025. To know how to become a member again, click here',
        '2025-06-07',
      );
      final s = subs().single;
      expect(s.displayName.toLowerCase(), contains('flipkart plus'));
      expect(s.lifecycleStatus, 'expired');
      expect(subscriptionPhase(s), SubscriptionPhase.past);
    });

    test('auto-renewal turned off', () {
      send(
        'VM-CANVAX-S',
        'Auto-renewal for Canva Pro has been turned off. You will not be charged again.',
        '2026-10-02',
      );
      expect(named('Canva Pro').lifecycleStatus, 'cancelled');
    });

    test('"will be cancelled" and "how to cancel" are not a cancellation', () {
      send(
        'VM-SPOTFY-S',
        'Your Spotify subscription will be cancelled on 12 Dec if you do not renew.',
        '2026-11-01',
      );
      send(
        'VM-SPOTFY-S',
        'Your Spotify subscription renews on 12 Dec. To cancel, open the app.',
        '2026-11-02',
      );
      expect(subs().where((s) => s.lifecycleStatus == 'cancelled'), isEmpty);
    });
  });

  group('one service seen under two names', () {
    // A payment aggregator names the service ("Example Labs"); the bank names
    // its own payee ("EXAMPLE TEC"). The receipt and the bank debit are one
    // charge, so the two names are one subscription, and cancelling it under
    // either name ends it.
    void aggregatorFlow({bool cancel = true}) {
      send(
        'VM-UNIONB-S',
        'Dear Customer, Your account has  been successfully debited with Rs.99.00 on 31/03/2026 towards EXAMPLE TEC UPI AutoPay-Union Bank of India',
        '2026-03-31',
      );
      send(
        'VM-UNIONB-S',
        'Dear Customer,UPI AutoPay Mandate with MONTHLY is successfully created towards EXAMPLE TEC from 31/03/2026 to 04/03/2036 for Rs.1649.00-Union Bank of India',
        '2026-03-31',
      );
      send(
        'VA-RZRPAY-S',
        'Your payment of Rs.99 for the subscription to Example Labs  is successful. Any recurring subscription payments will be automatically charged to your UPI from now - Razorpay',
        '2026-03-31',
      );
      if (cancel) {
        send(
          'VM-RZRPAY-S',
          'Your subscription payments for Example Labs  has been canceled on 31 March 2026. No further charges will be made for this subscription - Razorpay',
          '2026-03-31',
        );
      }
    }

    test('a receipt under the service name and the bank debit are one subscription', () {
      aggregatorFlow();
      final dbgFacts = {for (final f in FactStore(db.db, namespace: _ns).all()) f.factId: f};
      for (final e in EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900))) {
        // ignore: avoid_print
        print('EVENT ${e.type.wire} ${e.status.wire} ${[for (final l in e.legs) '${l.role.wire}:${dbgFacts[l.factId]?.factType.wire}:${dbgFacts[l.factId]?.counterparty?.name}']}');
      }
      final all = subs();
      expect(all, hasLength(1), reason: [for (final s in all) s.displayName].join(', '));
      expect(all.single.lifecycleStatus, 'cancelled');
      expect(all.single.occurrenceCount, 1, reason: 'the receipt is not a second charge');
    });

    test('the receipt adds no spend of its own', () {
      aggregatorFlow(cancel: false);
      final events = EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900));
      final money = events.where((e) => e.type == EventType.subscriptionCharge || e.type == EventType.purchase);
      expect(money, hasLength(1), reason: [for (final e in events) e.type.wire].join(', '));
    });
  });

  group('what is asked about instead of guessed', () {
    test('upcoming AutoPay notices with no setup and no debit are a review item', () {
      for (final (d, day) in [
        ('05-08-26', '2026-08-04'),
        ('05-09-26', '2026-09-04'),
        ('05-10-26', '2026-10-04'),
      ]) {
        send(
          'VM-YESBNK-S',
          'For the upcoming mandate set for $d, your account will be debited with Rs.81.00 towards Example Pay for the Recurring Bill Payments. If mandate is paused the execution for the same will not happen. - Yes Bank.',
          day,
        );
      }
      final s = subs().single;
      expect(s.reviewCandidate, isTrue);
      expect(s.reviewReason, contains('3 upcoming AutoPay debits'));
      expect(s.occurrenceCount, 0, reason: 'no money was seen moving');
      final view = buildSubscriptionView([s]);
      expect(view.subscriptions, isEmpty, reason: 'never listed as confirmed');
      expect(view.candidates, hasLength(1));
    });

    test('one notice alone proves nothing recurs', () {
      send(
        'VM-YESBNK-S',
        'For the upcoming mandate set for 05-10-26, your account will be debited with Rs.81.00 towards Example Pay for the Recurring Bill Payments. If mandate is paused the execution for the same will not happen. - Yes Bank.',
        '2026-10-04',
      );
      expect(subs(), isEmpty);
    });

    test('equal monthly charges in a foreign currency are found by their own price', () {
      for (final (d, day) in [
        ('13-08-26', '2026-08-13'),
        ('13-09-26', '2026-09-13'),
        ('13-10-26', '2026-10-13'),
      ]) {
        send(
          'AX-AXISBK-S',
          'Spent USD 9.68\nAxis Bank Card no. XX1234\n$d 10:00:00 IST\nEXAMPLE SAAS, INC\nAvl Limit: INR 15000\nNot you? SMS BLOCK 1234 to 919900000000',
          day,
        );
      }
      final s = subs().single;
      expect(s.reviewCandidate, isTrue);
      expect(s.amountKnown, isFalse, reason: 'the rupee price moves with the rate');
      expect(s.reviewReason, contains('9.68 USD'));
      expect(s.occurrenceCount, 3);
    });
  });

  group('what is not a subscription', () {
    RecurringSeries series(String name) => RecurringSeries(
      id: 'x:$name',
      displayName: name,
      typicalAmount: Money.fromRupees(100),
      cadenceDays: 30,
      occurrenceCount: 3,
      annualCost: Money.fromRupees(1200),
      isMandate: true,
      setupConfirmed: true,
      lifecycleStatus: 'active',
    );

    test('a card-bill AutoPay (TAD / MAD) and a lender EMI are bills and loans', () {
      for (final name in ['TAD', 'MAD', 'Capital Float', 'PayU Finance India Private Lim']) {
        expect(
          buildSubscriptionView([series(name)]).subscriptions,
          isEmpty,
          reason: name,
        );
      }
    });

    test('a lender is named by its company word; a service with "finance" in its name stays', () {
      for (final name in ['Bajaj Finance Ltd', 'Example Loans Private Limited']) {
        expect(buildSubscriptionView([series(name)]).subscriptions, isEmpty, reason: name);
      }
      for (final name in ['Zoho Finance', 'Finance Buddy Premium']) {
        expect(buildSubscriptionView([series(name)]).subscriptions, hasLength(1), reason: name);
      }
    });

    test('a streaming service stays', () {
      expect(buildSubscriptionView([series('Netflix')]).subscriptions, hasLength(1));
    });
  });

  group('history', () {
    test('a hand-off between two cards is told once, then "set up again"', () {
      send(
        'AX-AXISBK-S',
        'AutoPay activation successful.\nTxn amt: INR 0.00\nMerchant: Spotify\nAxis Bank Card no.: XX1234\nMax limit: INR 199.00\nID: Qwe123',
        '2026-08-22',
      );
      send(
        'AX-AXISBK-S',
        'AutoPay activation successful.\nTxn amt: INR 0.00\nMerchant: Spotify\nAxis Bank Card no.: XX1234\nMax limit: INR 199.00\nID: Rty456',
        '2026-10-19',
      );
      final history = subscriptionHistoryFromLedger(
        FactStore(db.db, namespace: _ns).all(),
        EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900)),
        now: now,
      );
      final kinds = [for (final e in history[subs().single.id]!) e.kind];
      expect(kinds, [
        SubscriptionHistoryKind.setupAgain,
        SubscriptionHistoryKind.setup,
      ]);
    });
  });
}
