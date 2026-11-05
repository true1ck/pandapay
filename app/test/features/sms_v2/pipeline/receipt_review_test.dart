// Lane X: a bill-payment receipt with no funding debit, through the real
// pipeline and stores (flag-independent: the pipeline classes are always built).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/receipt_review.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:lane-x';

const _receiptBody =
    'Your YES Bank Credit Card XXXX-9876 bill of Rs.1200 has been successfully paid via Kiwi.';
const _debitBody =
    'Rs.1,200.00 debited from A/c XX1234 on 12-11-26 to VPA cheq.hdfccard@icici (UPI Ref No 432100998877). Avl bal Rs 70,100.40';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late RuleBundle bundle;
  late SmsV2Pipeline pipeline;
  late String bankId;
  var now = DateTime.utc(2026, 11, 12, 6, 30);

  ReceiptReviews reviews() => ReceiptReviews(
    financial: financial,
    namespace: _ns,
    bundle: bundle,
    clock: () => now,
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 12, 6, 30);
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    bundle = testRuleBundle();
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: _ns,
      bundle: bundle,
      appVersion: '2.0.0',
    );
    bankId = generateUuidV4();
    InstrumentStore(db.db, namespace: _ns).upsert(
      Instrument(
        instrumentId: bankId,
        kind: InstrumentKind.bankAccount,
        issuerSlug: 'hdfc',
        maskDigits: '1234',
        displayName: 'Synthetic account',
        status: InstrumentStatus.confirmed,
        firstSeenAt: DateTime.utc(2026),
        lastSeenAt: DateTime.utc(2026),
        evidenceCount: 1,
      ),
    );
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  var counter = 0;
  SmsMessage receipt(String at, {String? key, String? body}) => SmsMessage(
    sender: 'VM-GKIWIP-S',
    body: body ?? _receiptBody,
    sourceKey: (key ?? 'r${counter++}').padRight(64, '0'),
    observedAt: DateTime.parse(at),
  );
  SmsMessage debitSms(String at, {String? key}) => SmsMessage(
    sender: 'VM-HDFCBK-S',
    body: _debitBody,
    sourceKey: (key ?? 'd${counter++}').padRight(64, '0'),
    observedAt: DateTime.parse(at),
  );

  List<Map<String, Object?>> openItems() => [
    for (final row in db.db.select(
      "SELECT review_id, payload, status FROM v2_review_items WHERE namespace=? AND json_extract(payload,'\$.reason')='receipt_without_payment'",
      [_ns],
    ))
      {
        'id': row['review_id'],
        'status': row['status'],
        'payload': jsonDecode(row['payload'] as String),
      },
  ];
  int asked() => openItems().length;
  List<LedgerEntry> ledger() => LedgerStore(db.db, namespace: _ns).list();
  int moneyMinor() => ledger().fold(0, (s, e) => s + e.amountMinor);
  bool anySpend() => ledger().any((e) => e.isSpend);

  group('no funding debit', () {
    test('receipt alone in an earlier month: skipped, no review, no money', () {
      pipeline.process(receipt('2026-09-12T10:15:00Z'));
      expect(reviews().sweep(), 0);
      expect(asked(), 0);
      expect(ledger(), isEmpty);
      expect(EventStore(db.db, namespace: _ns).count(), 0);
    });

    test('receipt alone in the current month: one review, no money', () {
      // Through the shared intake, so the sending app is known.
      SmsImportStore(financial, v2Pipeline: pipeline).captureBatch(_ns, [
        QueuedSms(
          sender: 'VM-GKIWIP-S',
          body: _receiptBody,
          receivedAt: DateTime.utc(2026, 11, 5, 10, 15),
        ),
      ]);
      // Day 1 of 3: still waiting.
      now = DateTime.utc(2026, 11, 6, 6);
      expect(reviews().sweep(), 0);
      // After the wait: asked once.
      now = DateTime.utc(2026, 11, 12, 6);
      expect(reviews().sweep(), 1);
      expect(asked(), 1);
      final item = openItems().single;
      expect(item['status'], 'open');
      final payload = (item['payload']! as Map).cast<String, Object?>();
      expect(payload['amountMinor'], 120000);
      expect(payload['cardBill'], true);
      expect(payload['app'], 'Kiwi');
      expect(
        payload['message'],
        'Did you pay this bill? We found a receipt for a credit card bill '
        'payment of ₹1,200 on 5 Nov 2026 through Kiwi, but no matching debit '
        'in your messages. Was this paid from one of your accounts?',
      );
      expect(ledger(), isEmpty);
      expect(moneyMinor(), 0);
      expect(EventStore(db.db, namespace: _ns).count(), 0);
    });

    test('re-processing and re-sweeping never duplicate the item', () {
      final sms = receipt('2026-11-05T10:15:00Z', key: 'same');
      pipeline.process(sms);
      reviews().sweep();
      expect(pipeline.process(sms), isFalse); // same source: skipped
      expect(reviews().sweep(), 0);
      expect(reviews().sweep(), 0);
      expect(asked(), 1);
    });

    test('the same receipt arriving again asks once', () {
      pipeline.process(receipt('2026-11-05T10:15:00Z'));
      pipeline.process(receipt('2026-11-05T10:40:00Z'));
      expect(reviews().sweep(), 1);
      expect(reviews().sweep(), 0);
      expect(asked(), 1);
    });
  });

  group('with a funding debit', () {
    void expectOneCardPayment() {
      expect(asked(), 0);
      final entries = ledger();
      expect(entries, hasLength(1));
      expect(entries.single.amountMinor, 120000);
      expect(entries.single.isSpend, isFalse);
      expect(entries.single.countsAsTransaction, isFalse);
      final events = EventStore(
        db.db,
        namespace: _ns,
      ).listSince(DateTime.utc(1900));
      expect(
        events.where((e) => e.type == EventType.cardBillPayment),
        hasLength(1),
      );
    }

    test('receipt then debit: one card payment, no review', () {
      pipeline.process(receipt('2026-11-05T10:15:00Z'));
      pipeline.process(debitSms('2026-11-05T10:16:00Z'));
      now = DateTime.utc(2026, 11, 12);
      expect(reviews().sweep(), 0);
      expectOneCardPayment();
    });

    test('debit then receipt: one card payment, no review', () {
      pipeline.process(debitSms('2026-11-05T10:15:00Z'));
      pipeline.process(receipt('2026-11-05T10:16:00Z'));
      now = DateTime.utc(2026, 11, 12);
      expect(reviews().sweep(), 0);
      expectOneCardPayment();
    });

    test('the debit arriving after the question resolves it by itself', () {
      pipeline.process(receipt('2026-11-05T10:15:00Z'));
      now = DateTime.utc(2026, 11, 12);
      expect(reviews().sweep(), 1);
      expect(openItems().single['status'], 'open');
      // The funding debit arrives late (within the join window of the receipt).
      pipeline.process(debitSms('2026-11-07T09:00:00Z'));
      final item = openItems().single;
      expect(item['status'], 'resolved');
      expect(
        ((item['payload']! as Map)['answer']),
        'matched',
        reason: 'closed by the debit, not by the user',
      );
      expect(ledger(), hasLength(1));
      expect(ledger().single.amountMinor, 120000);
      expect(anySpend(), isFalse);
      // Asking again never reopens it.
      expect(reviews().sweep(), 0);
      expect(asked(), 1);
    });
  });

  group('the user answers', () {
    String reviewIdAfterAsking() {
      pipeline.process(receipt('2026-11-05T10:15:00Z'));
      now = DateTime.utc(2026, 11, 12);
      reviews().sweep();
      return openItems().single['id']! as String;
    }

    test('Yes: counted once as a card payment, never as spending', () {
      final id = reviewIdAfterAsking();
      expect(
        reviews().confirm(reviewId: id, fundingInstrumentId: bankId),
        ReceiptConfirmation.counted,
      );
      final entries = ledger();
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.amountMinor, 120000);
      expect(entry.isSpend, isFalse);
      expect(entry.countsAsTransaction, isFalse);
      expect(entry.from, isA<InstrumentEndpoint>());
      expect((entry.from as InstrumentEndpoint).instrumentId, bankId);
      final event = EventStore(db.db, namespace: _ns).get(entry.eventId)!;
      expect(event.type, EventType.cardBillPayment);
      expect(event.status, EventStatus.userConfirmed);
      expect(openItems().single['status'], 'resolved');
      // Answering twice changes nothing.
      expect(
        () => reviews().confirm(reviewId: id, fundingInstrumentId: bankId),
        throwsStateError,
      );
      expect(ledger(), hasLength(1));
      expect(reviews().sweep(), 0);
    });

    test('Yes from another account: the source is an unresolved bank', () {
      final id = reviewIdAfterAsking();
      reviews().confirm(reviewId: id);
      final entry = ledger().single;
      expect(entry.amountMinor, 120000);
      expect(entry.from, isA<OwnUnresolvedEndpoint>());
      expect(entry.isSpend, isFalse);
    });

    test('Yes, then the debit arrives late: still counted once', () {
      final id = reviewIdAfterAsking();
      reviews().confirm(reviewId: id, fundingInstrumentId: bankId);
      pipeline.process(debitSms('2026-11-07T09:00:00Z'));
      expect(ledger(), hasLength(1));
      expect(ledger().single.amountMinor, 120000);
      expect(anySpend(), isFalse);
    });

    test('No: nothing is counted and the question is not asked again', () {
      final id = reviewIdAfterAsking();
      reviews().dismiss(reviewId: id);
      expect(openItems().single['status'], 'resolved');
      expect(ledger(), isEmpty);
      expect(EventStore(db.db, namespace: _ns).count(), 0);
      expect(reviews().sweep(), 0);
      expect(openItems().single['status'], 'resolved');
    });
  });

  group('history replay', () {
    test('many old receipts create no review flood', () {
      // 1,200 messages over a year: every third is a receipt, each of a
      // different amount, 12 of them in the current month.
      final messages = <SmsMessage>[];
      final start = DateTime.utc(2025, 11, 20);
      for (var i = 0; i < 1200; i++) {
        final at = start.add(Duration(hours: 7 * i));
        if (i % 3 == 0) {
          messages.add(
            receipt(
              at.toIso8601String(),
              key: 'h$i',
              body:
                  'Your YES Bank Credit Card XXXX-9876 bill of Rs.${1000 + i} has been successfully paid via Kiwi.',
            ),
          );
        } else {
          messages.add(
            SmsMessage(
              sender: 'VM-HDFCBK-S',
              body:
                  'Rs.${50 + i}.00 debited from A/c XX1234 on 12-11-26 to VPA shop$i@icici (UPI Ref No ${400000000000 + i}). Avl bal Rs 70,100.40',
              sourceKey: 'm$i'.padRight(64, '0'),
              observedAt: at,
            ),
          );
        }
      }
      now = messages.last.observedAt.add(const Duration(hours: 1));
      for (var i = 0; i < messages.length; i += 500) {
        pipeline.processBatch(
          messages.skip(i).take(500).toList(),
          backfill: true,
        );
      }
      // Nothing is asked in the middle of the import.
      expect(asked(), 0);
      reviews().sweep();
      final inMonth = messages.where(
        (m) =>
            m.sender == 'VM-GKIWIP-S' &&
            !isEarlierCalendarMonthIst(m.observedAt, now) &&
            now.difference(m.observedAt) > kReceiptWaitPeriod,
      );
      expect(inMonth, isNotEmpty);
      expect(asked(), inMonth.length);
      expect(asked(), lessThan(40));
      for (final item in openItems()) {
        final at = DateTime.parse(
          ((item['payload']! as Map)['receiptAt']) as String,
        );
        expect(isEarlierCalendarMonthIst(at, now), isFalse);
      }
      // No receipt counted as money.
      final byEvent = {
        for (final e in EventStore(
          db.db,
          namespace: _ns,
        ).listSince(DateTime.utc(1900)))
          e.eventId: e,
      };
      expect(
        ledger().where(
          (e) => byEvent[e.eventId]!.type == EventType.cardBillPayment,
        ),
        isEmpty,
      );
    });
  });
}
