import 'commitments_repository.dart';
import 'local_sms_parser.dart';
import 'pending_bills.dart';

/// An insurance renewal whose SMS named only a month ("Next Premium falls due
/// on 09/2026"). No day and usually no amount, so it is not a payable bill
/// row; it is a reminder for the month printed in the message.
class MonthOnlyPremium {
  final String title;
  final DateTime month;
  final DateTime? receivedAt;
  final String? accountLast4;
  final String body;

  const MonthOnlyPremium({
    required this.title,
    required this.month,
    required this.receivedAt,
    required this.accountLast4,
    required this.body,
  });
}

/// Reads a local bill observation that carries only a next-premium month.
/// Amount-bearing rows stay in the SMS bill list, so they are not reminders.
MonthOnlyPremium? parseMonthOnlyPremium(Map<String, dynamic> observation) {
  if (observation['event_type'] != 'bill') return null;
  final reasons = observation['reason_codes'];
  if (reasons is! List || !reasons.contains('next_premium_due_month_only')) {
    return null;
  }
  final amountPaise = observation['amount_due_paise'];
  final minimumPaise = observation['minimum_due_paise'];
  if ((amountPaise is int && amountPaise > 0) ||
      (minimumPaise is int && minimumPaise > 0)) {
    return null;
  }
  final body = observation['sample_body'] as String?;
  if (body == null || body.isEmpty) return null;
  final month = LocalSmsParser.nextPremiumDueMonth(body);
  if (month == null) return null;
  return MonthOnlyPremium(
    title: _titleFor(observation),
    month: month,
    receivedAt: DateTime.tryParse(
      (observation['received_at'] as String?) ?? '',
    )?.toLocal(),
    accountLast4: observation['account_last4'] as String?,
    body: body,
  );
}

class PremiumReminder {
  final String id;
  final String title;
  final CommitmentCategory category;
  final String? accountLast4;
  final DateTime premiumMonth;
  final DateTime receivedAt;
  final String? sampleBody;

  const PremiumReminder({
    required this.id,
    required this.title,
    required this.category,
    required this.accountLast4,
    required this.premiumMonth,
    required this.receivedAt,
    required this.sampleBody,
  });
}

/// Upcoming month-only premiums from local bill observations.
///
/// Past months are shown as history instead, and a policy saved as a live
/// commitment must not appear twice. Rows are grouped per policy, keeping the
/// furthest month.
List<PremiumReminder> derivePremiumReminders({
  required List<Map<String, dynamic>> observations,
  List<Commitment> commitments = const [],
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final currentMonth = DateTime(at.year, at.month);
  final taken = <String>{
    for (final commitment in commitments)
      if (commitment.status != CommitmentStatus.paid)
        smsBillIdentityForCommitment(commitment),
  };
  final byIdentity = <String, PremiumReminder>{};

  for (final observation in observations) {
    final premium = parseMonthOnlyPremium(observation);
    if (premium == null || premium.month.isBefore(currentMonth)) continue;

    const category = CommitmentCategory.insurance;
    final identity = smsBillIdentity(
      category.name,
      premium.title,
      premium.accountLast4,
    );
    if (taken.contains(identity)) continue;

    final receivedAt = premium.receivedAt ?? at;
    final reminder = PremiumReminder(
      id: 'premium-reminder:$identity',
      title: premium.title,
      category: category,
      accountLast4: premium.accountLast4,
      premiumMonth: premium.month,
      receivedAt: receivedAt,
      sampleBody: premium.body,
    );
    final existing = byIdentity[identity];
    if (existing == null ||
        premium.month.isAfter(existing.premiumMonth) ||
        (premium.month.isAtSameMomentAs(existing.premiumMonth) &&
            receivedAt.isAfter(existing.receivedAt))) {
      byIdentity[identity] = reminder;
    }
  }

  return byIdentity.values.toList()
    ..sort((a, b) {
      final byMonth = a.premiumMonth.compareTo(b.premiumMonth);
      return byMonth != 0 ? byMonth : a.title.compareTo(b.title);
    });
}

final _genericBiller = RegExp(
  r'^(?:insurance|insurance policy|policy|premium|premium due)$',
);

String _titleFor(Map<String, dynamic> observation) {
  final biller = ((observation['biller_name'] as String?) ?? '').trim();
  if (biller.isNotEmpty && !_genericBiller.hasMatch(biller.toLowerCase())) {
    return biller;
  }
  final sender = _senderTitle((observation['sender_bank'] as String?) ?? '');
  return sender.isEmpty ? 'Insurance premium' : sender;
}

String _senderTitle(String sender) {
  var value = sender.trim().toUpperCase();
  value = value.replaceFirst(RegExp(r'^[A-Z0-9]{2}-'), '');
  value = value.replaceFirst(RegExp(r'-[A-Z]$'), '');
  return value.length > 2 ? value : '';
}
