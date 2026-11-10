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
