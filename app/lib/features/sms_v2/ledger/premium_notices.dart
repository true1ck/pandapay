/// Month-only bill notices ("Next Premium falls due on 09/2026"), read from the
/// facts the rules produce.
///
/// A rule reads the message: it flags the bill month-only (`dueMonthOnly`), says
/// what it is (`billKind`) and carries no amount and no invented day. This file
/// only turns those typed facts into what the Bills page lists: a month still
/// ahead is an upcoming reminder, a month gone by is past history. It reads no
/// wording.
library;

import 'package:pandapay_domain/sms_v2.dart' as v2;

import '../../../data/commitments_repository.dart';
import '../../../data/pending_bills.dart';
import '../../../data/premium_reminders.dart';

/// The category a rule's `billKind` names, or null when it names none.
CommitmentCategory? categoryOfBillKind(String? kind) => switch (kind) {
  'utility' => CommitmentCategory.utility,
  'telecom' => CommitmentCategory.telecom,
  'insurance' => CommitmentCategory.insurance,
  'loan' => CommitmentCategory.loanOrEmi,
  'rent' => CommitmentCategory.rent,
  'education' => CommitmentCategory.education,
  'tax' => CommitmentCategory.tax,
  _ => null,
};

/// One month-only notice.
class PremiumNotice {
  const PremiumNotice({
    required this.sourceKey,
    required this.month,
    required this.category,
    required this.receivedAt,
    this.title,
    this.policyLast4,
  });

  /// The message the notice came from (its page shows the SMS).
  final String sourceKey;

  /// First day of the month the notice names.
  final DateTime month;
  final CommitmentCategory category;
  final DateTime receivedAt;

  /// The biller, when the rule read one.
  final String? title;
  final String? policyLast4;

  String get displayTitle => title ?? category.label;
}

/// Every month-only bill among [facts].
List<PremiumNotice> premiumNoticesFromFacts(Iterable<v2.Fact> facts) {
  final out = <PremiumNotice>[];
  for (final f in facts.whereType<v2.BillDueFact>()) {
    if (f.dueMonthOnly != true) continue;
    final d = DateTime.tryParse(f.dueDate);
    if (d == null) continue;
    final mask = f.counterparty?.accountMask;
    out.add(
      PremiumNotice(
        sourceKey: f.sourceKey,
        month: DateTime(d.year, d.month),
        category:
            categoryOfBillKind(f.billKind) ?? CommitmentCategory.other,
        receivedAt: f.observedAt.toLocal(),
        title: f.billerName,
        policyLast4: mask == null || mask.length < 4
            ? mask
            : mask.substring(mask.length - 4),
      ),
    );
  }
  return out;
}

/// Upcoming reminders: months not yet past, one per policy (the furthest month,
/// the latest message), and none for a policy a live bill already covers.
List<PremiumReminder> premiumRemindersFromNotices(
  Iterable<PremiumNotice> notices, {
  List<Commitment> commitments = const [],
  required DateTime now,
}) {
  final thisMonth = DateTime(now.year, now.month);
  final taken = <String>{
    for (final c in commitments)
      if (c.status != CommitmentStatus.paid) smsBillIdentityForCommitment(c),
  };
  final byIdentity = <String, PremiumReminder>{};
  for (final n in notices) {
    if (n.month.isBefore(thisMonth)) continue;
    final identity = smsBillIdentity(
      n.category.name,
      n.displayTitle,
      n.policyLast4,
    );
    if (taken.contains(identity)) continue;
    final existing = byIdentity[identity];
    if (existing == null ||
        n.month.isAfter(existing.premiumMonth) ||
        (n.month.isAtSameMomentAs(existing.premiumMonth) &&
            n.receivedAt.isAfter(existing.receivedAt))) {
      byIdentity[identity] = PremiumReminder(
        id: 'premium-reminder:$identity',
        title: n.displayTitle,
        category: n.category,
        accountLast4: n.policyLast4,
        premiumMonth: n.month,
        receivedAt: n.receivedAt,
        sampleBody: null,
        sourceKey: n.sourceKey,
      );
    }
  }
  return byIdentity.values.toList()
    ..sort((a, b) {
      final byMonth = a.premiumMonth.compareTo(b.premiumMonth);
      return byMonth != 0 ? byMonth : a.title.compareTo(b.title);
    });
}
