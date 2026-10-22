import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument;
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

/// Phase 0 baseline corpus: asserts the *current* behavior for every shared
/// fixture case. `coreTest/fixtures/sms_family_corpus.json` documents the
/// desired end state (expected) plus measured current behavior (baseline).
/// Later phases flip assertions toward expected and rewrite the notes.
void main() {
  final corpus = jsonDecode(
    File('test/fixtures/sms_family_corpus.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final cases = {
    for (final c in (corpus['cases'] as List).cast<Map<String, dynamic>>())
      c['id'] as String: c,
  };

  LocalSmsObservation? parseCase(Map<String, dynamic> c) {
    final raw = c['body'] as String;
    // Mirrors the real capture path: gate first, sensitivity veto second, then
    // the local parser. Phase 2: the gate is the broadened capture decision
    // (spend candidates plus recognized non-spend families).
    if (!capturesFinancialSms(raw) || LocalSmsParser.sensitive(raw)) {
      return null;
    }
    return LocalSmsParser.parse(
      namespace: 'user:test',
      sender: c['sender'] as String,
      body: raw,
      receivedAt: DateTime(2026, 10, 18),
      ownUserName: 'Ramesh Kumar',
    );
  }

  group('corpus cases', () {
    test('every case id resolves to a body and sender', () {
      for (final c in cases.values) {
        expect(c['sender'], isA<String>());
        expect((c['body'] as String).isNotEmpty, isTrue);
      }
    });

    test(
      'send_debit_with_balance: one spend plus balance evidence, no second event',
      () {
        final o = parseCase(cases['send_debit_with_balance']!)!;
        expect(o.transaction?.entryKind, TxnEntryKind.spend);
        expect(o.transaction?.amount.paise, 125050);
        expect(o.transaction?.accountLast4, '1234');
        expect(o.availableBalance?.paise, 875025);
      },
    );

    test('balance_only: balance observation, terminally acknowledged locally', () {
      final o = parseCase(cases['balance_only']!)!;
      expect(o.eventType, LocalSmsEventType.balance);
      expect(o.disposition, LocalSmsDisposition.localIgnore);
      expect(o.availableBalance?.paise, 900000);
      expect(o.transaction, isNull);
    });

    test('card_statement: bill observation with distinct money/date roles', () {
      final o = parseCase(cases['card_statement']!)!;
      expect(o.eventType, LocalSmsEventType.bill);
      expect(o.amountDue?.paise, 300000);
      expect(o.minimumDue?.paise, 60000);
      expect(o.dueDate, DateTime(2026, 11, 5));
      expect(o.statementDate, DateTime(2026, 10, 12));
      expect(o.cardLast4, '4321');
      expect(o.transaction, isNull);
    });

    test('bill_with_offer: real bill wins over appended marketing', () {
      final o = parseCase(cases['bill_with_offer']!)!;
      expect(o.eventType, LocalSmsEventType.bill);
      expect(o.billerName, 'TNEB electricity');
      expect(o.amountDue?.paise, 150000);
      expect(o.transaction, isNull);
      expect(
        o.reasonCodes,
        isNot(contains('promotional_message')),
      );
    });

    test('autopay_mandate: mandate observation whose ceiling is now captured', () {
      final o = parseCase(cases['autopay_mandate']!)!;
      expect(o.eventType, LocalSmsEventType.autopay);
      expect(o.disposition, LocalSmsDisposition.localIgnore);
      expect(o.transaction, isNull);
      // Phase 2 fixed the Phase 0 gap: "maximum limit of INR 2,000.00" is
      // read, so the mandate fact carries its ceiling.
      expect(o.autopayLimit?.paise, 200000);
    });

    test('autopay_scheduled: no posted spend', () {
      final o = parseCase(cases['autopay_scheduled']!)!;
      expect(o.transaction, isNull);
      expect(o.disposition, isNot(LocalSmsDisposition.sync));
    });

    test('autopay_failed: captured as a terminal failed observation', () {
      final o = parseCase(cases['autopay_failed']!)!;
      expect(o.eventType, LocalSmsEventType.failed);
      expect(o.disposition, LocalSmsDisposition.localIgnore);
      expect(o.transaction, isNull);
    });

    test('mandate_cancelled: captured as a terminal failed observation', () {
      final o = parseCase(cases['mandate_cancelled']!)!;
      expect(o.eventType, LocalSmsEventType.failed);
      expect(o.disposition, LocalSmsDisposition.localIgnore);
      expect(o.transaction, isNull);
      expect(o.accountLast4, '1797');
    });

    test('refund_with_offer: refund is a transfer, not income, not promotion', () {
      final o = parseCase(cases['refund_with_offer']!)!;
      expect(o.transaction?.entryKind, TxnEntryKind.transfer);
      expect(o.transaction?.amount.paise, 49900);
      expect(o.transaction?.merchantName, 'Refund');
      expect(o.transaction?.instrument, TxnInstrument.creditCard);
    });

    test('card_bill_payment: repayment is a transfer, not a purchase', () {
      final o = parseCase(cases['card_bill_payment']!)!;
      expect(o.transaction?.entryKind, TxnEntryKind.transfer);
      expect(o.transaction?.amount.paise, 1200000);
      expect(o.transaction?.merchantName, 'Credit card bill payment');
    });

    test('kotak_settlement: no spend, kept as a generic review item today', () {
      final o = parseCase(cases['kotak_settlement']!)!;
      expect(o.transaction, isNull);
      expect(o.disposition, LocalSmsDisposition.review);
    });

    test('hdfc_txn_check_alert: verification alert is dropped, not reviewed (screenshot case)', () {
      // The corpus fixture documents the end state: this verification alert
      // must never mint a spend or a review action. The shipped contract
      // (7c107ea) goes one step further — the triage gate classifies it as a
      // service notice and drops it before any observation is stored.
      final c = cases['hdfc_txn_check_alert']!;
      final raw = c['body'] as String;
      expect(capturesFinancialSms(raw, sender: c['sender'] as String), isFalse);
      expect(parseCase(c), isNull);
    });

    test('reversed_credit: reversal is a transfer, not earned income', () {
      final o = parseCase(cases['reversed_credit']!)!;
      expect(o.transaction?.entryKind, TxnEntryKind.transfer);
      expect(o.transaction?.amount.paise, 50000);
      expect(o.transaction?.merchantName, 'Reversal');
      expect(o.transaction?.accountLast4, '1234');
    });

    test('upi_person_spend: payment to a person is spending', () {
      final o = parseCase(cases['upi_person_spend']!)!;
      expect(o.transaction?.entryKind, TxnEntryKind.spend);
      expect(o.transaction?.amount.paise, 25000);
      // BASELINE GAP → Phase 2: the merchant capture swallows the account
      // clause ("debited from A/c XX1234 to ...") instead of the payee.
      expect(o.transaction?.merchantName, 'A/c XX1234 to Sujay Enterprises');
    });

    test('salary_income: explicit salary wording earns income', () {
      final o = parseCase(cases['salary_income']!)!;
      expect(o.transaction?.entryKind, TxnEntryKind.income);
      expect(o.transaction?.amount.paise, 5000000);
      expect(o.transaction?.merchantName, 'Salary');
    });

    test('atm_withdrawal: own cash movement is a transfer, not spend', () {
      final o = parseCase(cases['atm_withdrawal']!)!;
      expect(o.transaction?.entryKind, TxnEntryKind.transfer);
      expect(o.transaction?.amount.paise, 2000000);
      expect(o.transaction?.merchantName, 'Cash withdrawal');
    });

    test('call_forwarding_vicare: nonfinancial service alert is excluded', () {
      expect(looksLikeTransactionSms(cases['call_forwarding_vicare']!['body']), isFalse);
    });

    test('cashback_offer_only: conditional offer is excluded', () {
      expect(looksLikeTransactionSms(cases['cashback_offer_only']!['body']), isFalse);
    });

    test('otp_security: safety veto before persistence', () {
      final body = cases['otp_security']!['body'] as String;
      expect(looksLikeTransactionSms(body), isFalse);
      expect(LocalSmsParser.sensitive(body), isTrue);
    });

    test('declined_attempt: captured as a terminal failed observation', () {
      final o = parseCase(cases['declined_attempt']!)!;
      expect(o.eventType, LocalSmsEventType.failed);
      expect(o.disposition, LocalSmsDisposition.localIgnore);
      expect(o.transaction, isNull);
    });

    test(
      'ambiguous suffix at two institutions: independent observations never merge',
      () {
        final first = parseCase(cases['ambiguous_suffix_two_banks']!);
        final second = parseCase(cases['ambiguous_suffix_two_banks_second']!);
        final firstKey = smsSourceKey(
          'user:test',
          cases['ambiguous_suffix_two_banks']!['sender'],
          cases['ambiguous_suffix_two_banks']!['body'],
        );
        final secondKey = smsSourceKey(
          'user:test',
          cases['ambiguous_suffix_two_banks_second']!['sender'],
          cases['ambiguous_suffix_two_banks_second']!['body'],
        );
        expect(firstKey, isNot(secondKey));
        // Both legs keep their own account suffix binding.
        expect(first?.accountLast4, '9080');
        expect(second?.transaction?.accountLast4, '9080');
        expect(second?.transaction?.entryKind, TxnEntryKind.transfer);
        // No cross-bank automatic pairing exists on the device today.
        expect(second?.transaction?.merchantName, isNot('Sujay Kumar'));
      },
    );
  });

  group('delivery identity', () {
    late AppDatabase db;
    late ResponseCache cache;
    const namespace = 'user:account-a';

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = openInMemoryForTesting();
      cache = ResponseCache(db);
    });
    tearDown(() {
      cache.financialStore.dispose();
      db.close();
    });

    QueuedSms broadcast() => QueuedSms(
      sender: 'HDFCBK',
      body:
          'Rs.500 debited from A/c XX1234 to SHOP via UPI on 16-10-26. Ref 123456789012.',
      receivedAt: DateTime(2026, 10, 18, 9),
    );

    test(
      'live broadcast then identical inbox row collapses to one source and one provisional spend',
      () {
        final intake = SmsIntakeRepository(db);
        SmsImportStore(cache.financialStore).capture(namespace, broadcast());
        expect(intake.pending(namespace), hasLength(1));
        // The inbox reconciliation replays the same source. Source identity
        // ignores delivery time, so the second capture must not add an
        // observation, a provisional transaction or a pending row.
        SmsImportStore(cache.financialStore).capture(
          namespace,
          QueuedSms(
            sender: broadcast().sender,
            body: broadcast().body,
            receivedAt: DateTime(2026, 10, 18, 9, 0, 5),
          ),
        );
        final observations = cache.financialStore.entities(
          namespace,
          'sms_observations',
        );
        expect(observations, hasLength(1));
        expect(
          cache
              .financialStore
              .transactions(namespace, const TransactionQuery(source: 'sms'))
              ?.rows,
          hasLength(1),
        );
        expect(intake.pending(namespace), hasLength(1));
      },
    );

    test(
      'identical sender/body delivered days apart is documented as one source today',
      () {
        // Known limitation recorded in the compatibility audit: source keys
        // deliberately exclude delivery time, so an exact re-send collapses.
        // The corpus records this distinct-source edge case; a versioned
        // source-identity design must change this, never the legacy hash.
        final intake = SmsIntakeRepository(db);
        SmsImportStore(cache.financialStore).capture(namespace, broadcast());
        SmsImportStore(cache.financialStore).capture(
          namespace,
          QueuedSms(
            sender: broadcast().sender,
            body: broadcast().body,
            receivedAt: DateTime(2026, 10, 21, 9),
          ),
        );
        expect(cache.financialStore.entities(namespace, 'sms_observations'),
            hasLength(1));
        expect(intake.pending(namespace), hasLength(1));
      },
    );
  });
}
