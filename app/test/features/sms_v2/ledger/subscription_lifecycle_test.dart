// Whole subscription lifecycles through the real pipeline and the real rules,
// read the way the subscriptions screen reads them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:subs';

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

  List<RecurringSeries> subs({DateTime? now}) => subscriptionsFromLedger(
    FactStore(db.db, namespace: _ns).all(),
    EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900)),
    now: now ?? DateTime.utc(2026, 11, 9),
  );

  const mandate =
      'UPI Mandate created successfully for NETFLIX for Rs 649.00 monthly on A/c XX1234. UMN abc@axis. To pause or revoke, use your UPI app. -Axis Bank';
  String debit(String d) =>
      'INR 649.00 debited from your A/c XX1234 on $d towards NETFLIX INDIA for UPI Mandate. UMRN abc@axis. -Axis Bank';

  test(
    'a mandate and its monthly debits are one subscription with a cadence',
    () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      send('AX-AXISBK-S', debit('03-08-26'), '2026-08-03');
      send('AX-AXISBK-S', debit('03-09-26'), '2026-09-03');
      send('AX-AXISBK-S', debit('03-10-26'), '2026-10-03');
      final s = subs().single;
      expect(s.displayName, 'NETFLIX');
      expect(s.occurrenceCount, 3);
      expect(s.typicalAmount.paise, 64900);
      expect(s.cadenceDays, inInclusiveRange(28, 31));
      expect(s.isMandate, isTrue);
      expect(s.lifecycleStatus, 'active');
    },
  );

  test('an announced upcoming debit sets the next date and adds no charge', () {
    send('AX-AXISBK-S', mandate, '2026-08-01');
    send('AX-AXISBK-S', debit('03-10-26'), '2026-10-03');
    send(
      'AX-AXISBK-S',
      'For the upcoming mandate set for 03-12-26, INR 649.00 will be debited from your A/c towards NETFLIX INDIA for UPI Mandate. -Axis Bank',
      '2026-11-30',
    );
    final s = subs(now: DateTime.utc(2026, 12, 1)).single;
    expect(s.occurrenceCount, 1);
    expect(s.nextExpectedOn, DateTime.utc(2026, 12, 2, 18, 30));
  });

  test('a price change takes the latest amount; pause, resume, cancel', () {
    send('AX-AXISBK-S', mandate, '2026-08-01');
    send('AX-AXISBK-S', debit('03-08-26'), '2026-08-03');
    send(
      'AX-AXISBK-S',
      debit('03-09-26').replaceAll('649.00', '799.00'),
      '2026-09-03',
    );
    send(
      'AX-AXISBK-S',
      'Your NETFLIX UPI AutoPay mandate has been paused. -Axis Bank',
      '2026-10-01',
    );
    expect(subs().single.lifecycleStatus, 'paused');
    send(
      'AX-AXISBK-S',
      'Your NETFLIX UPI AutoPay mandate has been resumed. -Axis Bank',
      '2026-10-20',
    );
    send(
      'AX-AXISBK-S',
      'AutoPay mandate for NETFLIX has been revoked successfully. -Axis Bank',
      '2026-11-02',
    );
    final s = subs().single;
    expect(s.typicalAmount.paise, 79900);
    expect(s.lifecycleStatus, 'cancelled');
    expect(s.nextExpectedOn, isNull);
  });

  group('past subscriptions are marked past, not left active', () {
    test('a mandate that never charged is awaiting its first debit only while recent', () {
      send('AX-AXISBK-S', mandate, '2026-10-20');
      expect(subs(now: DateTime.utc(2026, 11, 9)).single.lifecycleStatus, 'active');
      // Months on, with nothing ever taken under it, it is not a live subscription.
      expect(subs(now: DateTime.utc(2027, 3, 1)).single.lifecycleStatus, 'lapsed');
    });

    test('a monthly plan a week late is active, one that missed a cycle and a half is past', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      send('AX-AXISBK-S', debit('03-09-26'), '2026-09-03');
      send('AX-AXISBK-S', debit('03-10-26'), '2026-10-03');
      expect(subs(now: DateTime.utc(2026, 11, 10)).single.lifecycleStatus, 'active');
      final late = subs(now: DateTime.utc(2026, 12, 1)).single;
      expect(late.lifecycleStatus, 'lapsed');
      expect(late.nextExpectedOn, isNull, reason: 'a past plan has no renewal');
    });

    test('a paused subscription has no renewal date to remind about', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      send('AX-AXISBK-S', debit('03-10-26'), '2026-10-03');
      send(
        'AX-AXISBK-S',
        'Your NETFLIX UPI AutoPay mandate has been paused. -Axis Bank',
        '2026-10-20',
      );
      final s = subs(now: DateTime.utc(2026, 11, 1)).single;
      expect(s.lifecycleStatus, 'paused');
      expect(s.nextExpectedOn, isNull);
    });

    test('a charge long after a revoke notice means it carried on', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      send('AX-AXISBK-S', debit('03-08-26'), '2026-08-03');
      send(
        'AX-AXISBK-S',
        'AutoPay mandate for NETFLIX has been revoked successfully. -Axis Bank',
        '2026-08-20',
      );
      expect(subs(now: DateTime.utc(2026, 9, 1)).single.lifecycleStatus, 'cancelled');
      send('AX-AXISBK-S', debit('03-10-26'), '2026-10-03');
      expect(subs(now: DateTime.utc(2026, 10, 10)).single.lifecycleStatus, 'active');
    });

    test('a debit settling just after the revoke notice does not undo it', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      send('AX-AXISBK-S', debit('03-08-26'), '2026-08-03');
      send(
        'AX-AXISBK-S',
        'AutoPay mandate for NETFLIX has been revoked successfully. -Axis Bank',
        '2026-09-02',
      );
      send('AX-AXISBK-S', debit('03-09-26'), '2026-09-03');
      expect(subs(now: DateTime.utc(2026, 9, 10)).single.lifecycleStatus, 'cancelled');
    });

    test('a failed payment from long ago is not still a payment problem', () {
      send(
        'VM-HDFCBK-S',
        'Dear Customer, Standing Instruction (SI) of Rs 119.00 towards SPOTIFY on HDFC Bank Card ending 1234 has been registered.',
        '2026-01-01',
      );
      send(
        'VM-HDFCBK-S',
        'Dear Customer, your standing instruction of Rs 119.00 for SPOTIFY on card XX1234 could not be processed due to insufficient limit.',
        '2026-02-02',
      );
      expect(subs(now: DateTime.utc(2026, 2, 20)).single.lifecycleStatus, 'failed_payment');
      expect(subs(now: DateTime.utc(2026, 11, 9)).single.lifecycleStatus, 'lapsed');
    });
  });

  test('the history tells the whole story newest first', () {
    send('AX-AXISBK-S', mandate, '2026-08-01');
    send('AX-AXISBK-S', debit('03-08-26'), '2026-08-03');
    send(
      'AX-AXISBK-S',
      debit('03-09-26').replaceAll('649.00', '799.00'),
      '2026-09-03',
    );
    send(
      'AX-AXISBK-S',
      'Your NETFLIX UPI AutoPay mandate has been paused. -Axis Bank',
      '2026-10-01',
    );
    send(
      'AX-AXISBK-S',
      'Your NETFLIX UPI AutoPay mandate has been resumed. -Axis Bank',
      '2026-10-20',
    );
    send(
      'AX-AXISBK-S',
      'AutoPay mandate for NETFLIX has been revoked successfully. -Axis Bank',
      '2026-11-02',
    );
    final facts = FactStore(db.db, namespace: _ns).all();
    final events = EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900));
    final history = subscriptionHistoryFromLedger(
      facts,
      events,
      now: DateTime.utc(2026, 11, 9),
    );
    final entries = history[subs().single.id]!;
    expect(
      [for (final e in entries) e.kind],
      [
        SubscriptionHistoryKind.cancelled,
        SubscriptionHistoryKind.resumed,
        SubscriptionHistoryKind.paused,
        SubscriptionHistoryKind.priceChange,
        SubscriptionHistoryKind.charge,
        SubscriptionHistoryKind.setup,
      ],
    );
    final change = entries.firstWhere(
      (e) => e.kind == SubscriptionHistoryKind.priceChange,
    );
    expect(change.amountMinor, 79900);
    expect(change.previousAmountMinor, 64900);
    expect(entries.last.amountMinor, 64900, reason: 'the limit set at setup');
  });

  test('a stated cycle is trusted until three or more charges contradict it', () {
    send('AX-AXISBK-S', mandate, '2026-01-01');
    send('AX-AXISBK-S', debit('03-01-26'), '2026-01-03');
    send('AX-AXISBK-S', debit('03-04-26'), '2026-04-03');
    // Two charges, one interval: the monthly mandate is still believed.
    expect(subs(now: DateTime.utc(2026, 4, 10)).single.cadenceDays, inInclusiveRange(28, 31));
    send('AX-AXISBK-S', debit('03-07-26'), '2026-07-03');
    // Three charges 90 days apart: the observed rhythm wins over "monthly".
    expect(subs(now: DateTime.utc(2026, 7, 10)).single.cadenceDays, inInclusiveRange(88, 92));
  });

  test('one service named two ways is one subscription, named plainly', () {
    send(
      'VM-HDFCBK-S',
      'Dear Customer, Standing Instruction (SI) of Rs 119.00 towards SPOTIFY on HDFC Bank Card ending 1234 has been registered.',
      '2026-08-01',
    );
    send(
      'VM-HDFCBK-S',
      'Dear Customer, your standing instruction (SI) of Rs 119.00 for SPOTIFY SI on HDFC Bank Card XX1234 has been processed on 02-09-26.',
      '2026-09-02',
    );
    send(
      'VM-HDFCBK-S',
      'Dear Customer, your standing instruction of Rs 119.00 for SPOTIFY on card XX1234 could not be processed due to insufficient limit.',
      '2026-11-02',
    );
    final s = subs().single;
    expect(s.displayName, 'SPOTIFY');
    expect(s.lifecycleStatus, 'failed_payment');
  });

  test('services that only share a first word on different cards stay two', () {
    send(
      'AX-AXISBK-S',
      'UPI Mandate created successfully for AMAZON for Rs 199.00 monthly on A/c XX1111. UMN a1@axis. -Axis Bank',
      '2026-08-01',
    );
    send(
      'AX-AXISBK-S',
      'UPI Mandate created successfully for AMAZON PRIME VIDEO for Rs 299.00 monthly on A/c XX2222. UMN a2@axis. -Axis Bank',
      '2026-08-02',
    );
    expect(subs(), hasLength(2));
  });

  test('a service receipt and the bank alert of one renewal are one charge', () {
    for (final (m, mm, d) in [
      ('Aug', '08', '2026-08-02'),
      ('Sep', '09', '2026-09-02'),
    ]) {
      send(
        'VM-NEWBNK-S',
        'Your subscription to SPOTIFY has been renewed. Rs 119.00 charged to your card ending 4410 on 02-$m-26.',
        d,
      );
      send(
        'VM-HDFCBK-S',
        'Rs.119.00 spent on HDFC Bank Card x4410 at SPOTIFY on 02-$mm-26',
        d,
      );
    }
    final s = subs().single;
    expect(s.occurrenceCount, 2);
    expect(s.typicalAmount.paise, 11900);
  });

  test('autopay debits in wording only the generic debit rule matches still join the mandate', () {
    send(
      'VM-NEWBNK-S',
      'AutoPay mandate set up for NETFLIX of Rs 649.00 monthly from your A/c XX1234. UMN nflx123@okhdfc',
      '2026-08-01',
    );
    for (final (d, day) in [
      ('05-Aug-26', '2026-08-05'),
      ('05-Sep-26', '2026-09-05'),
      ('05-Oct-26', '2026-10-05'),
    ]) {
      send(
        'VM-NEWBNK-S',
        'Rs 649.00 debited from A/c XX1234 on $d towards NETFLIX AutoPay. UMN nflx123@okhdfc',
        day,
      );
    }
    final s = subs().single;
    expect(s.displayName, 'NETFLIX');
    expect(s.occurrenceCount, 3);
    expect(s.typicalAmount.paise, 64900);
    expect(s.isMandate, isTrue);
  });

  test('a plain debit that mentions no subscription is left exactly as the rule read it', () {
    send('VM-NEWBNK-S', 'Rs 250.00 debited from A/c XX1234 on 05-Aug-26. Avl Bal Rs 9,000.00', '2026-08-05');
    final facts = FactStore(db.db, namespace: _ns).all().whereType<MovementFact>();
    expect(facts, hasLength(1));
    expect(facts.single.provenance.ruleId, startsWith('GEN-'));
    expect(subs(), isEmpty);
  });

  test('an upcoming-debit notice that mentions "if mandate is paused" is not a paused mandate', () {
    send(
      'VM-YESBNK-S',
      'For the upcoming mandate set for 05-12-26, your account will be debited with Rs.75.00 towards Amazon Pay for the Recurring Bill Payments. If mandate is paused the execution for the same will not happen. - Amazon Pay and Yes Bank.',
      '2026-11-28',
    );
    final all = FactStore(db.db, namespace: _ns).all();
    expect(all.whereType<MandateFact>(), isEmpty, reason: 'it is not a mandate event');
    final attempt = all.whereType<AttemptFact>().single;
    expect(attempt.status, AttemptStatus.scheduled);
    expect(attempt.counterparty?.name?.toLowerCase(), contains('amazon pay'));
    expect(subs(), isEmpty, reason: 'no subscription row is made from it');
  });

  group('no mandate message: found by pattern, and flagged as such', () {
    void spend(String merchant, String amount, String d, String day) => send(
      'VM-HDFCBK-S',
      'Rs.$amount spent on HDFC Bank Card x5678 at $merchant on $d',
      day,
    );

    test('three equal monthly charges at one merchant', () {
      spend('NETFLIX', '649.00', '05-08-26', '2026-08-05');
      spend('NETFLIX', '649.00', '05-09-26', '2026-09-05');
      spend('NETFLIX', '649.00', '05-10-26', '2026-10-05');
      final s = subs().single;
      expect(s.occurrenceCount, 3);
      expect(s.isMandate, isFalse);
      expect(s.setupConfirmed, isFalse);
      expect(s.detectionSource, 'sms_v2_pattern');
      expect(s.lifecycleStatus, 'active');
      expect(s.reviewCandidate, isTrue, reason: 'listed as a possible subscription');
      final report = recurringReportFromLedger(
        FactStore(db.db, namespace: _ns).all(),
        EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900)),
        now: DateTime.utc(2026, 11, 9),
      );
      expect(report.totalAnnual.paise, 0, reason: 'a candidate is not counted');
    });

    test('two charges are not enough', () {
      spend('NETFLIX', '649.00', '05-09-26', '2026-09-05');
      spend('NETFLIX', '649.00', '05-10-26', '2026-10-05');
      expect(subs(), isEmpty);
    });

    test('different amounts or an irregular rhythm are not a subscription', () {
      spend('GROCER', '640.00', '05-08-26', '2026-08-05');
      spend('GROCER', '712.00', '05-09-26', '2026-09-05');
      spend('GROCER', '655.00', '05-10-26', '2026-10-05');
      spend('CAFE', '300.00', '05-08-26', '2026-08-05');
      spend('CAFE', '300.00', '09-08-26', '2026-08-09');
      spend('CAFE', '300.00', '30-10-26', '2026-10-30');
      expect(subs(), isEmpty);
    });

    test('a service that has a mandate is not listed a second time', () {
      send('AX-AXISBK-S', mandate, '2026-08-01');
      spend('NETFLIX', '649.00', '05-08-26', '2026-08-05');
      spend('NETFLIX', '649.00', '05-09-26', '2026-09-05');
      spend('NETFLIX', '649.00', '05-10-26', '2026-10-05');
      expect(subs(), hasLength(1));
    });

    test('one that stops charging is lapsed, never shown as upcoming', () {
      spend('NETFLIX', '649.00', '05-05-26', '2026-05-05');
      spend('NETFLIX', '649.00', '05-06-26', '2026-06-05');
      spend('NETFLIX', '649.00', '05-07-26', '2026-07-05');
      final s = subs(now: DateTime.utc(2026, 11, 9)).single;
      expect(s.lifecycleStatus, 'lapsed');
      expect(s.nextExpectedOn, isNull);
    });
  });
}
