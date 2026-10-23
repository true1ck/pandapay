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
}
