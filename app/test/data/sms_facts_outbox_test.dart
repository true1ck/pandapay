
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_facts_outbox.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/sms_fact_contract.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

/// SMS intelligence Phase 2 device routing: the broadened capture gate plus
/// the typed-facts outbox that lets the server learn about recognized
/// non-spend financial messages without any raw body ever leaving the
/// device through this path.
void main() {
  group('capturesFinancialSms gate', () {
    test('captures the recognized non-spend families', () {
      expect(
        capturesFinancialSms(
          'AutoPay payment for NETFLIX failed due to insufficient balance. No money was debited.',
        ),
        isTrue,
      );
      expect(
        capturesFinancialSms(
          'Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.',
        ),
        isTrue,
      );
      expect(
        capturesFinancialSms('INR 500 purchase declined on credit card XX4321.'),
        isTrue,
      );
    });

    test('keeps dedicating spend candidates to the strict gate', () {
      expect(
        capturesFinancialSms(
          'Your Axis Bank Credit Card XX4321 e-statement generated on 12-10-26. Total Amount Due INR 3,000.00, Minimum Amount Due INR 600.00, pay by 05-Nov-26.',
        ),
        isTrue,
      );
      expect(
        capturesFinancialSms(
          'Your A/c XX9876 available balance is Rs.9,000.00 as on 16-10-26.',
        ),
        isTrue,
      );
    });

    test('still rejects OTP, promo and non-financial noise', () {
      expect(
        capturesFinancialSms(
          'OTP 483921 for txn of Rs.2,500 on your HDFC card XX4321. Do not share.',
        ),
        isFalse,
      );
      expect(
        capturesFinancialSms(
          'Get Rs.100 cashback when you spend Rs.15,000 on Paytm app recharge offers. Apply now!',
        ),
        isFalse,
      );
      expect(capturesFinancialSms('Call Forwarding is now active on your Vodafone idea number.'), isFalse);
      expect(
        capturesFinancialSms('Your Netflix renewal reminder: nothing was attempted. Enjoy your shows!'),
        isFalse,
      );
    });
  });

  LocalSmsObservation parse(String sender, String body) => LocalSmsParser.parse(
        namespace: 'user:test',
        sender: sender,
        body: body,
        receivedAt: DateTime(2026, 10, 18, 9),
        ownUserName: 'Ramesh Kumar',
      )!;

  group('buildSmsFactsForObservation mapper', () {
    test('balance-only observation mints a balance_snapshot fact', () {
      final facts = buildSmsFactsForObservation(
        body: 'Your A/c XX9876 available balance is Rs.9,000.00 as on 16-10-26.',
        observation: parse(
          'HDFCBK',
          'Your A/c XX9876 available balance is Rs.9,000.00 as on 16-10-26.',
        ),
        receivedAt: DateTime(2026, 10, 18, 9),
      );
      expect(facts, hasLength(1));
      expect(facts.first.factType, 'balance_snapshot');
      expect(facts.first.payload['availableBalanceInr'], 9000.0);
      expect(facts.first.payload['instrument'], 'upi_bank');
      expect(facts.first.payload['accountLast4'], '9876');
      expect(facts.first.payload['asOfAt'], isA<String>());
      for (final fact in facts) {
        expect(
          validateSmsFact(fact).valid,
          isTrue,
          reason: '${fact.factType}: ${validateSmsFact(fact).errors}',
        );
      }
    });

    test('autopay failure mints a failed attempt fact with the biller', () {
      final body =
          'AutoPay payment for NETFLIX failed due to insufficient balance. No money was debited.';
      final facts = buildSmsFactsForObservation(
        body: body,
        observation: parse('KOTAKB', body),
        receivedAt: DateTime(2026, 10, 18, 9),
      );
      expect(facts, hasLength(1));
      expect(facts.single.factType, 'pending_or_failed_attempt');
      expect(facts.single.payload['attemptStatus'], 'failed');
      expect(facts.single.payload['merchant'], 'NETFLIX');
      expect(validateSmsFact(facts.single).valid, isTrue);
    });

    test('mandate cancellation mints a cancelled mandate_lifecycle fact', () {
      final body =
          'Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.';
      final facts = buildSmsFactsForObservation(
        body: body,
        observation: parse('HDFCBK', body),
        receivedAt: DateTime(2026, 10, 18, 9),
      );
      expect(facts, hasLength(1));
      expect(facts.single.factType, 'mandate_lifecycle');
      expect(facts.single.payload['mandateStatus'], 'cancelled');
      expect(facts.single.payload['merchant'], 'NETFLIX');
      expect(validateSmsFact(facts.single).valid, isTrue);
    });

    test('registered mandate mints mandate_lifecycle with its ceiling', () {
      final body =
          'AutoPay e-mandate successfully registered for NETFLIX with maximum limit of INR 2,000.00 on HDFC Bank A/c XX1797';
      final facts = buildSmsFactsForObservation(
        body: body,
        observation: parse('HDFCBK', body),
        receivedAt: DateTime(2026, 10, 18, 9),
      );
      expect(facts, hasLength(1));
      expect(facts.single.factType, 'mandate_lifecycle');
      expect(facts.single.payload['mandateStatus'], 'registered');
      expect(facts.single.payload['limitInr'], 2000.0);
      expect(facts.single.payload['merchant'], 'NETFLIX');
      expect(validateSmsFact(facts.single).valid, isTrue);
    });

    test('declined attempt carries the card suffix, never spend semantics', () {
      final body = 'INR 500 purchase declined on credit card XX4321.';
      final facts = buildSmsFactsForObservation(
        body: body,
        observation: parse('HDFCBK', body),
        receivedAt: DateTime(2026, 10, 18, 9),
      );
      expect(facts, hasLength(1));
      expect(facts.single.factType, 'pending_or_failed_attempt');
      expect(facts.single.payload['attemptStatus'], 'failed');
      expect(facts.single.payload['last4'], '4321');
      expect(facts.single.payload['instrument'], 'credit_card');
      expect(facts.first.payload.containsKey('amountInr'), isFalse);
      expect(validateSmsFact(facts.first).valid, isTrue);
    });

    test('corpus card_statement mints separated due_total and due_minimum facts', () {
      final body =
          'Your Axis Bank Credit Card XX4321 e-statement generated on 12-10-26. Total Amount Due INR 3,000.00, Minimum Amount Due INR 600.00, pay by 05-Nov-26.';
      final facts = buildSmsFactsForObservation(
        body: body,
        observation: parse('AXISBK', body),
        receivedAt: DateTime(2026, 10, 18, 9),
      );
      expect(facts, hasLength(2));
      final roles = facts.map((f) => f.payload['amountRole']).toSet();
      expect(roles, {'due_total', 'due_minimum'});
      final total = facts.firstWhere((f) => f.payload['amountRole'] == 'due_total');
      expect(total.payload['amountDueInr'], 3000.0);
      // Device dates pin to local midnight, so the wire value is that
      // calendar day in the device's own timezone and shifts back one
      // evening in UTC. The server specialist re-derives the IST day (5).
      // Compare the calendar day, never the instant: the same source must
      // pass this test on a phone in India and on a UTC CI runner.
      final dueDate = DateTime.parse(total.payload['dueDate'] as String).toLocal();
      expect(dueDate.year, 2026);
      expect(dueDate.month, 11);
      expect(dueDate.day, 5);
      expect(total.payload['statementDate'], contains('-10-'));
      expect(total.payload['last4'], '4321');
      expect(total.payload['instrument'], 'credit_card');
      expect(
        facts.every((f) => validateSmsFact(f).valid),
        isTrue,
        reason: '${facts.map((f) => validateSmsFact(f).errors).toList()}',
      );
    });

    test('corpus bill_with_offer mints one due_total role with the biller name', () {
      final body =
          'Your TNEB electricity bill of Rs.1,500 is due on 18-10-26. Pay on TNEB app and get Rs.100 cashback offer!';
      final facts = buildSmsFactsForObservation(
        body: body,
        observation: parse('TNBPAY', body),
        receivedAt: DateTime(2026, 10, 18, 9),
      );
      expect(facts, hasLength(1));
      expect(facts.single.factType, 'bill_obligation');
      expect(facts.single.payload['amountRole'], 'due_total');
      expect(facts.single.payload['amountDueInr'], 1500.0);
      expect(facts.single.payload['billerName'], 'TNEB electricity');
      expect(facts.single.payload.containsKey('amountInr'), isFalse);
      expect(validateSmsFact(facts.single).valid, isTrue);
    });

    test('corpus balance_only / autopay_failed / mandate_cancelled / decline match expected families', () {
      // Backed by the one labeled corpus: recognized non-spend families mint
      // exactly the expected fact types (initially asserted in Phase 2).
      // expected and outbox dedupe stay replay-safe.
      expect(
        buildSmsFactsForObservation(
          body: 'Your A/c XX9876 available balance is Rs.9,000.00 as on 16-10-26.',
          observation: parse('SBIINB', 'Your A/c XX9876 available balance is Rs.9,000.00 as on 16-10-26.'),
          receivedAt: DateTime(2026, 10, 18, 9),
        ).map((f) => f.factType),
        ['balance_snapshot'],
      );
      expect(
        buildSmsFactsForObservation(
          body: 'AutoPay payment for NETFLIX failed due to insufficient balance. No money was debited.',
          observation: parse('HDFCBK', 'AutoPay payment for NETFLIX failed due to insufficient balance. No money was debited.'),
          receivedAt: DateTime(2026, 10, 18, 9),
        ).map((f) => f.factType),
        ['pending_or_failed_attempt'],
      );
      expect(
        buildSmsFactsForObservation(
          body: 'Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.',
          observation: parse('HDFCBK', 'Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.'),
          receivedAt: DateTime(2026, 10, 18, 9),
        ).map((f) => f.factType),
        ['mandate_lifecycle'],
      );
    });

    test('non-mappable shapes mint nothing (abstain, never half-trust)', () {
      // The default branch (spend/income/promotions/review) routes through
      // the legacy pipeline and must mint exactly nothing.
      final income = parse(
        'HDFCBK',
        'Your account XX1234 credited INR 50000 as salary on 16-10-26.',
      );
      expect(
        buildSmsFactsForObservation(
          body: 'n/a',
          observation: income,
          receivedAt: DateTime(2026, 10, 18, 9),
        ),
        isEmpty,
      );
      // A cancellation notice without a reconstructable merchant must
      // abstain rather than post an unattributable mandate fact.
      final orphans = parse(
        'HDFCBK',
        'The e-mandate has been cancelled for your reference 12345.',
      );
      expect(
        buildSmsFactsForObservation(
          body: 'The e-mandate has been cancelled for your reference 12345.',
          observation: orphans,
          receivedAt: DateTime(2026, 10, 18, 9),
        ),
        isEmpty,
      );
      // A registered mandate with no extractable ceiling must abstain too
      // (the contract refuses a registered mandate without limitInr).
      final noCeiling = parse(
        'HDFCBK',
        'Your mandated subscription renewal plan was successfully activated for NETFLIX on card XX1797.',
      );
      expect(
        buildSmsFactsForObservation(
          body: 'Your mandated subscription renewal plan was successfully activated for NETFLIX on card XX1797.',
          observation: noCeiling,
          receivedAt: DateTime(2026, 10, 18, 9),
        ),
        isEmpty,
      );
    });
  });

  group('SmsFactsOutbox persistence', () {
    late AppDatabase db;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = openInMemoryForTesting();
    });
    tearDown(() => db.close());

    QueuedSms message(String body, {DateTime? receivedAt}) => QueuedSms(
          sender: 'HDFCBK',
          body: body,
          receivedAt: receivedAt ?? DateTime(2026, 10, 18, 9),
        );

    test('enqueue stores a valid envelope with the body hash', () {
      final outbox = SmsFactsOutbox(db);
      final facts = buildSmsFactsForObservation(
        body: 'Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.',
        observation: parse(
          'HDFCBK',
          'Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.',
        ),
        receivedAt: DateTime(2026, 10, 18, 9),
      );
      final sourceKey = smsSourceKey(
        'user:a',
        'HDFCBK',
        'Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.',
      );
      outbox.enqueue('user:a', message('Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.'), facts, sourceKey: sourceKey);
      final pendingRows = outbox.pending('user:a');
      expect(pendingRows, hasLength(1));
      final envelope = pendingRows.single.envelope;
      expect(envelope['sourceKey'], sourceKey);
      expect(envelope['sender'], 'HDFCBK');
      expect(envelope['bodyHash'], smsBodyHash('HDFCBK', 'Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.'));
      expect((envelope['facts'] as List), hasLength(1));
      expect(envelope['facts'][0], containsPair('factIndex', 0));
      // Replay of the same source does not duplicate the row.
      outbox.enqueue('user:a', message('Your NETFLIX AutoPay mandate has been cancelled successfully on HDFC A/c XX1797.'), facts, sourceKey: sourceKey);
      expect(outbox.pending('user:a'), hasLength(1));
      outbox.acknowledge('user:a', sourceKey);
      expect(outbox.pending('user:a'), isEmpty);
    });

    test('enqueue drops fact sets the contract refuses', () {
      final outbox = SmsFactsOutbox(db);
      outbox.enqueue(
        'user:a',
        message('registered without ceiling'),
        [SmsFactValidationEntry(factType: 'mandate_lifecycle', payload: {'mandateStatus': 'registered', 'asOfAt': '2026-10-18T03:30:00.000Z'})],
        sourceKey: 'f' * 64,
      );
      expect(outbox.pending('user:a'), isEmpty);
    });

    test('failed bumps the retry time and keeps the row', () {
      final outbox = SmsFactsOutbox(db, now: () => DateTime(2026, 10, 18, 10));
      outbox.enqueue(
        'user:a',
        message('x'),
        [SmsFactValidationEntry(factType: 'balance_snapshot', payload: {'availableBalanceInr': 9000.0, 'asOfAt': '2026-10-18T03:30:00.000Z'})],
        sourceKey: 'a' * 64,
      );
      outbox.failed('user:a', 'a' * 64);
      final row = outbox.pending('user:a');
      expect(row, isEmpty, reason: 'backoff hides the row until its next_attempt');
      final visible = db.db.select(
        'SELECT attempts FROM sms_facts_outbox WHERE namespace=? AND id=?',
        ['user:a', 'a' * 64],
      ).toList();
      expect(visible.single['attempts'], 1);
    });

    test('manual corrections remain durable and retry without storing SMS text', () {
      final outbox = SmsFactsOutbox(db, now: () => DateTime(2026, 10, 18, 10));
      final key = 'b' * 64;
      outbox.enqueueOverride(
        'user:a',
        sourceKey: key,
        factIndex: 0,
        patch: {'amountDueInr': 2450.0},
        reason: 'confirmed in needs review',
      );
      expect(outbox.pendingOverrides('user:a'), hasLength(1));
      outbox.failedOverride('user:a', key, 0);
      expect(outbox.pendingOverrides('user:a'), isEmpty);
      final row = db.db.select(
        'SELECT attempts, patch FROM sms_fact_override_outbox WHERE namespace=? AND source_key=?',
        ['user:a', key],
      ).single;
      expect(row['attempts'], 1);
      expect(row['patch'], contains('2450'));
      expect(row['patch'], isNot(contains('SMS')));
      outbox.acknowledgeOverride('user:a', key, 0);
      expect(outbox.pendingOverrides('user:a'), isEmpty);
    });
  });

  group('capture integrates the facts outbox', () {
    late AppDatabase db;
    late ResponseCache cache;
    late SmsFactsOutbox outbox;
    const namespace = 'user:account-a';

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = openInMemoryForTesting();
      cache = ResponseCache(db);
      outbox = SmsFactsOutbox(db);
    });
    tearDown(() {
      cache.financialStore.dispose();
      db.close();
    });

    test('declined attempt capture leaves a facts row and no pending intake', () {
      final body = 'INR 500 purchase declined on credit card XX4321.';
      SmsImportStore(cache.financialStore).capture(
        namespace,
        QueuedSms(sender: 'HDFCBK', body: body, receivedAt: DateTime(2026, 10, 18, 9)),
      );
      expect(outbox.pending(namespace), hasLength(1));
      expect(outbox.pending(namespace).single.envelope['facts'][0]['factType'], 'pending_or_failed_attempt');
      // Terminal local ack: the raw body never rides the legacy upload.
      expect(SmsIntakeRepository(db).pending(namespace), isEmpty);
    });

    test('balance-only capture leaves a facts row; bill capture rides both feeds', () {
      final balance = 'Your A/c XX9876 available balance is Rs.9,000.00 as on 16-10-26.';
      SmsImportStore(cache.financialStore).capture(
        namespace,
        QueuedSms(sender: 'HDFCBK', body: balance, receivedAt: DateTime(2026, 10, 18, 9)),
      );
      expect(outbox.pending(namespace), hasLength(1));
      expect(outbox.pending(namespace).single.envelope['facts'][0]['factType'], 'balance_snapshot');

      final bill =
          'Your Axis Bank Credit Card XX4321 e-statement generated on 12-10-26. Total Amount Due INR 3,000.00, Minimum Amount Due INR 600.00, pay by 05-Nov-26.';
      SmsImportStore(cache.financialStore).capture(
        namespace,
        QueuedSms(sender: 'AXISBK', body: bill, receivedAt: DateTime(2026, 10, 18, 10)),
      );
      // Phase 3: bills ride the legacy batch AND the typed fact contract.
      // Separate due roles keep the total and minimum from collapsing.
      final billRows = outbox.pending(namespace);
      expect(billRows, hasLength(2));
      final billEnvelope = billRows
          .firstWhere((r) => r.envelope['sender'] == 'AXISBK')
          .envelope;
      expect(
        (billEnvelope['facts'] as List).map((f) => f['payload']['amountRole']).toSet(),
        {'due_total', 'due_minimum'},
      );
      expect(SmsIntakeRepository(db).pending(namespace), hasLength(1));
    });

    test('spend capture never mints facts; OTP stays invisible', () {
      final spend =
          'Rs.250 debited from A/c XX1234 to Sujay Enterprises via UPI on 16-10-26. Ref 123456789012';
      SmsImportStore(cache.financialStore).capture(
        namespace,
        QueuedSms(sender: 'HDFCBK', body: spend, receivedAt: DateTime(2026, 10, 18, 9)),
      );
      expect(outbox.pending(namespace), isEmpty);
      expect(SmsIntakeRepository(db).pending(namespace), hasLength(1));

      SmsImportStore(cache.financialStore).capture(
        namespace,
        QueuedSms(
          sender: 'HDFCBK',
          body: 'OTP 483921 for txn of Rs.2,500 on your HDFC card XX4321. Do not share.',
          receivedAt: DateTime(2026, 10, 18, 9),
        ),
      );
      expect(outbox.pending(namespace), isEmpty);
      expect(SmsIntakeRepository(db).pending(namespace), hasLength(1));
      final storedFacts = db.db
          .select('SELECT facts FROM sms_facts_outbox')
          .map((r) => r['facts'] as String)
          .join('');
      expect(storedFacts, isNot(contains('OTP')));
    });
  });
}
