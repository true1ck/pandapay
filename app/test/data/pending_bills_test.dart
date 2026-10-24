import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/data/pending_bills.dart';
import 'package:pandapay/data/user_cards_repository.dart';

void main() {
  test(
    'deduplicates bill reminders and resolves linked, upcoming, overdue',
    () {
      final now = DateTime(2026, 1, 20, 12);
      Map<String, dynamic> bill({
        required String id,
        required String title,
        required String due,
        required String received,
        String? last4,
      }) => {
        'id': id,
        'event_type': 'bill',
        'sender_bank': 'HDFC',
        'biller_name': title,
        'card_last4': last4,
        'amount_due_paise': 200000,
        'received_at': received,
        'due_date': due,
        'sample_body': 'SMS $id',
      };

      final observations = [
        bill(
          id: 'old-reminder',
          title: 'HDFC Card',
          last4: '1234',
          due: '2026-01-15T00:00:00.000',
          received: '2026-01-01T00:00:00.000',
        ),
        bill(
          id: 'new-reminder',
          title: 'HDFC Card',
          last4: '1234',
          due: '2026-01-15T00:00:00.000',
          received: '2026-01-05T00:00:00.000',
        ),
        bill(
          id: 'upcoming',
          title: 'Electricity Co',
          due: '2026-02-15T00:00:00.000',
          received: '2026-01-10T00:00:00.000',
        ),
        bill(
          id: 'overdue',
          title: 'Water Utility',
          due: '2026-01-10T00:00:00.000',
          received: '2026-01-01T00:00:00.000',
        ),
      ];
      final payment = TransactionEntry(
        id: 'payment-1',
        amount: Money.fromPaise(200000),
        occurredAt: DateTime(2026, 1, 10),
        cardLast4: '1234',
        merchantName: 'Credit card bill payment',
        entryKind: TxnEntryKind.transfer,
        source: 'sms',
        status: 'active',
      );

      final rows = deriveSmsBillRows(
        observations: observations,
        transactions: [payment],
        now: now,
      );

      expect(rows, hasLength(3));
      final card = rows.singleWhere((row) => row.title == 'HDFC Card');
      expect(card.state, SmsBillState.linked);
      expect(card.linkedTxnId, 'payment-1');
      expect(card.sampleBody, 'SMS new-reminder');
      expect(
        rows.singleWhere((row) => row.title == 'Electricity Co').state,
        SmsBillState.pending,
      );
      expect(
        rows.singleWhere((row) => row.title == 'Water Utility').state,
        SmsBillState.paymentNotDetected,
      );
    },
  );

  test('matches utility billers across spaces and punctuation', () {
    final rows = deriveSmsBillRows(
      observations: [
        {
          'event_type': 'bill',
          'biller_name': 'Tata Power',
          'amount_due_paise': 250000,
          'received_at': '2026-01-10T00:00:00.000',
          'due_date': '2026-01-20T00:00:00.000',
        },
      ],
      transactions: [
        TransactionEntry(
          id: 'utility-payment',
          amount: Money.fromPaise(250000),
          occurredAt: DateTime(2026, 1, 20),
          merchantName: 'Tata-Power Bill Payment',
          entryKind: TxnEntryKind.spend,
          source: 'manual',
          status: 'active',
        ),
      ],
      now: DateTime(2026, 1, 21),
    );

    expect(rows.single.state, SmsBillState.linked);
    expect(rows.single.linkedTxnId, 'utility-payment');
  });

  test('minimum-only card bill cannot be marked paid by a partial payment', () {
    final rows = deriveSmsBillRows(
      observations: [
        {
          'event_type': 'bill',
          'biller_name': 'HDFC Credit Card',
          'sender_bank': 'HDFC Bank',
          'card_last4': '1234',
          'minimum_due_paise': 500000,
          'received_at': '2026-01-01T00:00:00.000',
          'due_date': '2026-01-15T00:00:00.000',
        },
      ],
      transactions: [
        TransactionEntry(
          id: 'minimum-payment',
          amount: Money.fromPaise(500000),
          occurredAt: DateTime(2026, 1, 15),
          cardLast4: '1234',
          merchantName: 'Credit card bill payment',
          entryKind: TxnEntryKind.transfer,
          source: 'manual',
          status: 'active',
        ),
      ],
      now: DateTime(2026, 1, 25),
    );

    expect(rows.single.state, SmsBillState.paymentNotDetected);
    expect(rows.single.isMinimumOnly, isTrue);
  });

  test('larger unrelated card payment does not settle a bill', () {
    final rows = deriveSmsBillRows(
      observations: [
        {
          'event_type': 'bill',
          'biller_name': 'HDFC Credit Card',
          'sender_bank': 'HDFC Bank',
          'card_last4': '1234',
          'amount_due_paise': 200000,
          'received_at': '2026-01-01T00:00:00.000',
          'due_date': '2026-01-15T00:00:00.000',
        },
      ],
      transactions: [
        TransactionEntry(
          id: 'unrelated-payment',
          amount: Money.fromPaise(500000),
          occurredAt: DateTime(2026, 1, 15),
          cardLast4: '1234',
          merchantName: 'Credit card bill payment',
          entryKind: TxnEntryKind.transfer,
          source: 'manual',
          status: 'active',
        ),
      ],
      now: DateTime(2026, 1, 25),
    );

    expect(rows.single.state, SmsBillState.paymentNotDetected);
  });

  test(
    'card payment can match through cached card ID when txn has no last4',
    () {
      final rows = deriveSmsBillRows(
        observations: [
          {
            'event_type': 'bill',
            'biller_name': 'HDFC Credit Card',
            'sender_bank': 'HDFC Bank',
            'card_last4': '1234',
            'amount_due_paise': 200000,
            'received_at': '2026-01-01T00:00:00.000',
            'due_date': '2026-01-15T00:00:00.000',
          },
        ],
        transactions: [
          TransactionEntry(
            id: 'card-id-payment',
            amount: Money.fromPaise(200000),
            occurredAt: DateTime(2026, 1, 15),
            userCardId: 'user-card-1',
            merchantName: 'Credit card bill payment',
            entryKind: TxnEntryKind.transfer,
            source: 'manual',
            status: 'active',
          ),
        ],
        cardsLast4ById: const {'user-card-1': '1234'},
        now: DateTime(2026, 1, 25),
      );

      expect(rows.single.state, SmsBillState.linked);
      expect(rows.single.linkedTxnId, 'card-id-payment');
    },
  );
}
