import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/premium_reminders.dart';

Map<String, dynamic> _observation({
  required String body,
  required DateTime receivedAt,
  String? accountLast4 = '0879',
  String biller = 'Insurance policy',
  String sender = 'VM-LICIND',
  int? amountPaise,
  List<String> reasons = const ['next_premium_due_month_only'],
  String eventType = 'bill',
}) => {
  'event_type': eventType,
  'reason_codes': reasons,
  'amount_due_paise': amountPaise,
  'sample_body': body,
  'biller_name': biller,
  'sender_bank': sender,
  'account_last4': accountLast4,
  'received_at': receivedAt.toUtc().toIso8601String(),
};

String _licBody(DateTime month) =>
    'Dear Customer, premium due from 04/2026 to 04/2026 under policy no. '
    '931670879 is adjusted on 16/04/2026. Next Premium falls due on '
    '${month.month.toString().padLeft(2, '0')}/${month.year}. -LIC of India';

Commitment _commitment({
  required CommitmentStatus status,
  String title = 'LICIND',
  String identifier = '••••0879',
}) => Commitment(
  id: 'lic-commitment',
  title: title,
  category: CommitmentCategory.insurance,
  dueOn: DateTime(2026, 11, 15),
  identifier: identifier,
  cadence: CommitmentCadence.annual,
  status: status,
);

void main() {
  final now = DateTime(2026, 10, 25);

  test('groups month-only policies and keeps the furthest month', () {
    final reminders = derivePremiumReminders(
      observations: [
        _observation(
          body: _licBody(DateTime(2026, 11)),
          receivedAt: DateTime(2026, 10, 1),
        ),
        _observation(
          body: _licBody(DateTime(2026, 12)),
          receivedAt: DateTime(2026, 10, 20),
        ),
        _observation(
          body: _licBody(DateTime(2026, 10)),
          receivedAt: DateTime(2026, 10, 5),
          accountLast4: '4321',
          sender: 'VA-LICIND-S',
        ),
      ],
      now: now,
    );

    expect(reminders, hasLength(2));
    expect(reminders.first.accountLast4, '4321');
    expect(reminders.first.premiumMonth, DateTime(2026, 10));
    expect(reminders.last.accountLast4, '0879');
    expect(reminders.last.premiumMonth, DateTime(2026, 12));
    expect(reminders.last.title, 'LICIND');
    expect(reminders.last.category, CommitmentCategory.insurance);
  });

  test('ignores past months and month-only notices that carry an amount', () {
    final reminders = derivePremiumReminders(
      observations: [
        _observation(
          body: _licBody(DateTime(2026, 9)),
          receivedAt: DateTime(2026, 9, 1),
        ),
        _observation(
          body: _licBody(DateTime(2026, 11)),
          receivedAt: DateTime(2026, 10, 1),
          amountPaise: 250000,
        ),
        _observation(
          body: 'Your electricity bill is ready.',
          receivedAt: DateTime(2026, 10, 1),
          reasons: const [],
        ),
      ],
      now: now,
    );

    expect(reminders, isEmpty);
  });

  test('a live commitment for the policy hides the reminder', () {
    final reminders = derivePremiumReminders(
      observations: [
        _observation(
          body: _licBody(DateTime(2026, 11)),
          receivedAt: DateTime(2026, 10, 1),
        ),
      ],
      commitments: [_commitment(status: CommitmentStatus.due)],
      now: now,
    );

    expect(reminders, isEmpty);
  });

  test('a paid commitment does not hide the next premium cycle', () {
    final reminders = derivePremiumReminders(
      observations: [
        _observation(
          body: _licBody(DateTime(2026, 12)),
          receivedAt: DateTime(2026, 10, 1),
        ),
      ],
      commitments: [_commitment(status: CommitmentStatus.paid)],
      now: now,
    );

    expect(reminders.single.premiumMonth, DateTime(2026, 12));
  });
}
