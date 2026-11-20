// What a review question knows about a payment that has no transaction yet,
// turned into the draft the Edit transaction screen opens on, and what is kept
// when the person saves it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/edit_transaction_screen.dart'
    show kDraftTransactionPrefix;
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/review_answers.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/ui/review_draft.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart' show kReceiptWithoutPaymentReason;
import 'package:sqlite3/sqlite3.dart';

LocalReviewItem _item(
  String id,
  Map<String, Object?> payload, {
  String kind = 'template',
  String? body,
  DateTime? at,
}) => LocalReviewItem(
  id: id,
  kind: kind,
  payload: payload,
  message: body == null
      ? null
      : SmsIntakeEntry(
          id,
          QueuedSms(
            sender: 'VM-SBIUPI-S',
            body: body,
            receivedAt: at ?? DateTime(2026, 11, 20, 9, 30),
          ),
        ),
);

void main() {
  group('the draft a question opens on', () {
    test('a bill receipt: its amount, app and date', () {
      final draft = reviewDraftEntry(
        _item('r1', {
          'reason': kReceiptWithoutPaymentReason,
          'amountMinor': 1000,
          'receiptAt': '2026-11-20T04:00:00Z',
          'app': 'Airtel',
        }),
      );
      expect(draft.id, '${kDraftTransactionPrefix}r1');
      expect(draft.amount, Money.fromPaise(1000));
      expect(draft.merchantName, 'Airtel');
      expect(draft.occurredAt.toUtc(), DateTime.utc(2026, 11, 20, 4));
      expect(draft.entryKind, TxnEntryKind.spend);
      expect(draft.instrumentKnown, isFalse, reason: 'how it was paid is not known');
      expect(draft.source, 'manual');
    });

    test('a suggested reading: amount, shop and direction come from it', () {
      final spend = reviewDraftEntry(
        _item('s1', {'reading': 'debit ₹250.0 AMAZON'}, body: 'Dear customer, see app'),
      );
      expect(spend.amount, Money.fromPaise(25000));
      expect(spend.merchantName, 'AMAZON');
      expect(spend.entryKind, TxnEntryKind.spend);
      final income = reviewDraftEntry(
        _item('s2', {'reading': 'credit ₹5000.5 ACME PAYROLL'}),
      );
      expect(income.amount, Money.fromPaise(500050));
      expect(income.merchantName, 'ACME PAYROLL');
      expect(income.entryKind, TxnEntryKind.income);
    });

    test('a message with no reading: the amount printed in it and the day it arrived', () {
      final draft = reviewDraftEntry(
        _item(
          'm1',
          {},
          body: 'Rs.1,250.00 debited from A/c XX1234 on 05-11-26 Ref 99',
          at: DateTime(2026, 11, 5, 18),
        ),
      );
      expect(draft.amount, Money.fromPaise(125000));
      expect(draft.merchantName, isNull);
      expect(draft.occurredAt, DateTime(2026, 11, 5, 18));
    });

    test('nothing known: zero, now, and the person fills it in', () {
      final now = DateTime(2026, 11, 21, 8);
      final draft = reviewDraftEntry(_item('n1', {}), now: now);
      expect(draft.amount, const Money.zero());
      expect(draft.occurredAt, now);
      expect(draft.merchantName, isNull);
    });
  });

  group('answering by adding', () {
    late AppDatabase database;
    late FinancialStore financial;
    setUp(() {
      database = AppDatabase.forTesting(sqlite3.openInMemory());
      financial = FinancialStore(database);
      SmsV2Schema.ensure(database.db);
    });
    tearDown(() {
      financial.dispose();
      database.close();
    });

    void open(String id, Map<String, Object?> payload) => database.db.execute(
      "INSERT INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES('user:t',?, 'template', ?, 'open')",
      [id, jsonEncode(payload)],
    );
    Map<String, Object?> row(String id) {
      final r = database.db.select(
        "SELECT status,payload FROM v2_review_items WHERE namespace='user:t' AND review_id=?",
        [id],
      ).single;
      return {
        'status': r['status'],
        ...jsonDecode(r['payload'] as String) as Map<String, Object?>,
      };
    }

    test('the question is resolved and remembers what was added', () {
      open('q1', {'sourceKey': 's1', 'templateHash': 'h'});
      open('q2', {'sourceKey': 's2', 'templateHash': 'h'});
      markAnsweredByAdding(
        financial,
        namespace: 'user:t',
        reviewId: 'q1',
        added: {
          'clientMutationId': 'cm-1',
          'amountMinor': 1250,
          'merchantName': 'Airtel',
          'occurredAt': '2026-11-20T04:00:00Z',
          'entryKind': 'spend',
        },
      );
      final answered = row('q1');
      expect(answered['status'], 'resolved');
      expect(answered['answer'], 'added');
      expect((answered['added'] as Map)['clientMutationId'], 'cm-1');
      expect(answered['sourceKey'], 's1', reason: 'what the question was about is kept');
      expect(row('q2')['status'], 'open', reason: 'only that question is answered');
    });

    test('History lists what the person added, newest first, with what they saved', () {
      for (final (id, day) in [('q1', 18), ('q2', 20)]) {
        open(id, {'sourceKey': id});
        markAnsweredByAdding(
          financial,
          namespace: 'user:t',
          reviewId: id,
          added: {
            'clientMutationId': 'cm-$id',
            'amountMinor': 1000 * day,
            'merchantName': 'Shop $id',
            'occurredAt': DateTime.utc(2026, 11, day, 4).toIso8601String(),
            'entryKind': 'spend',
          },
        );
      }
      // A resolved item that was not an add (dismissed) is not listed.
      open('q3', {'sourceKey': 'q3'});
      database.db.execute(
        "UPDATE v2_review_items SET status='resolved' WHERE review_id='q3'",
      );
      final items = addedFromReview(
        database.db,
        namespace: 'user:t',
        now: DateTime.utc(2026, 11, 21),
        syncedId: (cm) => cm == 'cm-q1' ? 'server-77' : null,
      );
      expect(items.map((i) => i.entry.merchantName), ['Shop q2', 'Shop q1']);
      expect(items.first.entry.id, 'local-outbox:cm-q2', reason: 'still on the phone');
      expect(items.last.entry.id, 'server-77', reason: 'delivered: the real transaction');
      expect(items.first.entry.amount, Money.fromPaise(20000));
      expect(items.every((i) => i.byUser), isTrue);
      expect(items.first.how, 'You added this from a message');
    });

    test('older than the history window is not listed', () {
      open('old', {'sourceKey': 'old'});
      markAnsweredByAdding(
        financial,
        namespace: 'user:t',
        reviewId: 'old',
        added: {
          'clientMutationId': 'cm-old',
          'amountMinor': 100,
          'occurredAt': DateTime.utc(2026, 1, 1).toIso8601String(),
          'entryKind': 'spend',
        },
      );
      expect(
        addedFromReview(database.db, namespace: 'user:t', now: DateTime.utc(2026, 11, 21)),
        isEmpty,
      );
    });
  });
}
