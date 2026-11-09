import '../voice_format.dart';
import 'voice_answer.dart';

/// One card's current bill, as the Payments due screen sees it.
class BillLine {
  const BillLine({
    required this.cardName,
    this.hasBill = true,
    this.dueDate,
    this.amountDue,
    this.outstanding,
    this.minimumDue,
    this.isPaid = false,
    this.isAutopay = false,
  });

  final String cardName;

  /// A bill has been found for this card on the phone.
  final bool hasBill;
  final DateTime? dueDate;
  final double? amountDue;

  /// What is still unpaid; null when the amount is unknown.
  final double? outstanding;
  final double? minimumDue;
  final bool isPaid;
  final bool isAutopay;

  double? get owed => isPaid ? 0 : (outstanding ?? amountDue);
}

/// One cap on one card, with its progress already worded the way the Caps
/// screen words it.
class CapLine {
  const CapLine({
    required this.cardName,
    required this.label,
    required this.remaining,
    required this.used,
    required this.reset,
    this.ratio,
    this.reached = false,
    this.consequence,
  });

  final String cardName;
  final String label;

  /// "₹1,200 left", "800 pts left".
  final String remaining;

  /// "₹1,800 / ₹3,000 spent"
  final String used;

  /// "resets 1 Dec"
  final String reset;
  final double? ratio;
  final bool reached;

  /// What happens past the cap: "extra spend here earns only 1%".
  final String? consequence;
}

class PointsLine {
  const PointsLine({
    required this.cardName,
    this.points,
    this.valueRupees,
    this.nearestExpiry,
  });

  final String cardName;
  final double? points;
  final double? valueRupees;
  final DateTime? nearestExpiry;
}

class RecoLine {
  const RecoLine({
    required this.cardName,
    required this.expectedValue,
    this.reason,
    this.excluded = false,
  });

  final String cardName;
  final double expectedValue;
  final String? reason;
  final bool excluded;
}

String _points(double v) {
  final n = v.round();
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '${n < 0 ? '-' : ''}$buf';
}

String _count(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// Bills and due dates.
class BillsAnswerer {
  const BillsAnswerer();

  static String _relative(DateTime due, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final days = (DateTime(due.year, due.month, due.day)
                .difference(today)
                .inHours /
            24)
        .round();
    if (days == 0) return 'today';
    if (days == 1) return 'tomorrow';
    if (days > 1) return 'in $days days';
    return '${_count(-days, 'day', 'days')} overdue';
  }

  VoiceAnswer answer(
    List<BillLine> lines,
    DateTime now, {
    bool cardsNamed = false,
  }) {
    if (lines.isEmpty) {
      return VoiceAnswer.message(
        'I don’t see any cards in your wallet yet, so there are no bills to show.',
        status: AnswerStatus.noData,
      );
    }
    final withBill = lines.where((l) => l.hasBill).toList();
    final without = lines.where((l) => !l.hasBill).map((l) => l.cardName);
    const actions = [
      AnswerAction(AnswerActionKind.paymentsDue, 'Open Payments due'),
      AnswerAction(AnswerActionKind.wallet, 'Open Wallet'),
    ];
    if (withBill.isEmpty) {
      final names = without.join(' and ');
      return VoiceAnswer.message(
        'I haven’t found a bill for $names on this phone yet. A bill appears once the card’s statement message arrives.',
        status: AnswerStatus.noData,
        actions: actions,
      );
    }
    final unpaid = withBill.where((l) => (l.owed ?? 0) > 0).toList()
      ..sort((a, b) {
        final da = a.dueDate, db = b.dueDate;
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return da.compareTo(db);
      });
    final paid = withBill.where((l) => (l.owed ?? 0) <= 0).toList();
    final ordered = [...unpaid, ...paid];
    final total = unpaid.fold<double>(0, (s, l) => s + (l.owed ?? 0));
    String detail(BillLine l) {
      final parts = <String>[
        if (l.isPaid || (l.owed ?? 0) <= 0)
          'paid'
        else if (l.dueDate != null)
          'due ${VoiceFormat.day(l.dueDate!, now)} (${_relative(l.dueDate!, now)})'
        else
          'due date unknown',
        if (l.minimumDue != null && !l.isPaid)
          'minimum ${VoiceFormat.rupees(l.minimumDue!)}',
        if (l.isAutopay) 'autopay on',
      ];
      return parts.join(' · ');
    }

    final rows = [
      for (final l in ordered)
        AnswerRow(
          l.cardName,
          (l.owed ?? 0) > 0 ? VoiceFormat.rupees(l.owed!) : 'Paid',
          detail: detail(l),
        ),
    ];

    String headline;
    String spoken;
    String? comparison;
    if (unpaid.isEmpty) {
      headline = 'All paid';
      spoken = withBill.length == 1
          ? 'Your ${withBill.first.cardName} bill is already paid.'
          : 'All ${withBill.length} bills are paid.';
    } else if (unpaid.length == 1) {
      final l = unpaid.first;
      headline = VoiceFormat.rupees(l.owed!);
      final when = l.dueDate == null
          ? 'with no due date I can read yet'
          : 'due ${VoiceFormat.day(l.dueDate!, now)}, ${_relative(l.dueDate!, now)}';
      spoken = 'Your ${l.cardName} bill is ${VoiceFormat.rupees(l.owed!)}, $when.';
    } else {
      headline = VoiceFormat.rupees(total);
      final first = unpaid.first;
      comparison = first.dueDate == null
          ? null
          : 'Next due: ${first.cardName} on ${VoiceFormat.day(first.dueDate!, now)}';
      spoken =
          'You owe ${VoiceFormat.rupees(total)} across ${unpaid.length} cards.'
          '${first.dueDate == null ? '' : ' The next one is ${first.cardName}, ${VoiceFormat.rupees(first.owed!)}, due ${VoiceFormat.day(first.dueDate!, now)}.'}';
    }
    return VoiceAnswer(
      title:
          'Bills · ${cardsNamed && lines.length == 1 ? lines.first.cardName : (cardsNamed ? 'selected cards' : 'all cards')}',
      headline: headline,
      comparison: comparison,
      rows: rows,
      evidence: 'From the card bill messages on this phone.',
      coverageNote: without.isEmpty
          ? null
          : 'No bill found yet for ${without.join(', ')}.',
      actions: actions,
      spoken: spoken,
    );
  }
}

/// Card caps and what is left under them.
class CapsAnswerer {
  const CapsAnswerer();

  VoiceAnswer answer(List<CapLine> lines, {bool cardsNamed = false}) {
    const actions = [
      AnswerAction(AnswerActionKind.caps, 'Open Caps'),
      AnswerAction(AnswerActionKind.milestones, 'Open Milestones'),
    ];
    if (lines.isEmpty) {
      return VoiceAnswer.message(
        cardsNamed
            ? 'That card has no spend or reward caps to track.'
            : 'None of your cards have spend or reward caps to track.',
        status: AnswerStatus.noData,
        actions: actions,
      );
    }
    final sorted = [...lines]
      ..sort((a, b) => (b.ratio ?? 1.0).compareTo(a.ratio ?? 1.0));
    final first = sorted.first;
    final single = sorted.map((l) => l.cardName).toSet().length == 1;
    final spoken = first.reached
        ? 'You’ve used all of the ${first.label} cap on your ${first.cardName}'
              '${first.consequence == null ? '.' : ', and ${first.consequence}.'}'
        : 'On your ${first.cardName}, the ${first.label} cap has ${first.remaining} and ${first.reset}.';
    return VoiceAnswer(
      title: 'Caps · ${single ? first.cardName : 'your cards'}',
      headline: first.reached ? 'Cap reached' : first.remaining,
      comparison: '${first.label} · ${first.reset}',
      rows: [
        for (final l in sorted.take(6))
          AnswerRow(
            single ? l.label : '${l.cardName} · ${l.label}',
            l.reached ? 'Reached' : l.remaining,
            detail: '${l.used} · ${l.reset}',
          ),
      ],
      evidence:
          'From each card’s rules and the spending recorded on this phone, as of the last card sync. Fullest cap first.',
      actions: actions,
      spoken: spoken,
    );
  }
}

/// Points balances. They are estimates: banks do not text point balances.
class PointsAnswerer {
  const PointsAnswerer();

  VoiceAnswer answer(
    List<PointsLine> lines,
    DateTime now, {
    bool cardsNamed = false,
  }) {
    const actions = [
      AnswerAction(AnswerActionKind.pointsExpiry, 'Open Points'),
      AnswerAction(AnswerActionKind.wallet, 'Open Wallet'),
    ];
    if (lines.isEmpty) {
      return VoiceAnswer.message(
        'I don’t see any cards in your wallet yet, so there are no points to show.',
        status: AnswerStatus.noData,
      );
    }
    final known = lines.where((l) => l.points != null).toList();
    final unknown = lines.where((l) => l.points == null).map((l) => l.cardName);
    if (known.isEmpty) {
      return VoiceAnswer.message(
        'I don’t have a points balance saved for ${unknown.join(' or ')}. You can add one in the card’s settings.',
        status: AnswerStatus.noData,
        actions: actions,
      );
    }
    final total = known.fold<double>(0, (s, l) => s + l.points!);
    final value = known.fold<double>(0, (s, l) => s + (l.valueRupees ?? 0));
    String detail(PointsLine l) {
      final parts = <String>[
        if (l.valueRupees != null) '≈ ${VoiceFormat.rupees(l.valueRupees!)}',
        if (l.nearestExpiry != null)
          'next expiry ${VoiceFormat.day(l.nearestExpiry!, now)}',
      ];
      return parts.join(' · ');
    }

    final single = known.length == 1;
    final spoken = single
        ? 'You have about ${_points(total)} points on your ${known.first.cardName}'
              '${value > 0 ? ', worth roughly ${VoiceFormat.rupees(value)}' : ''}.'
        : 'You have about ${_points(total)} points across ${known.length} cards'
              '${value > 0 ? ', worth roughly ${VoiceFormat.rupees(value)}' : ''}.';
    return VoiceAnswer(
      title: 'Points · ${single ? known.first.cardName : 'your cards'}',
      headline: '${_points(total)} points',
      comparison: value > 0 ? 'About ${VoiceFormat.rupees(value)} in value' : null,
      rows: [
        for (final l in known)
          AnswerRow(l.cardName, '${_points(l.points!)} pts', detail: detail(l)),
      ],
      evidence:
          'An estimate from the points saved for each card. Banks don’t text point balances.',
      coverageNote: unknown.isEmpty
          ? null
          : 'No points balance saved for ${unknown.join(', ')}.',
      actions: actions,
      spoken: spoken,
    );
  }
}

/// Which card to use for a purchase, from the recommendation engine.
class BestCardAnswerer {
  const BestCardAnswerer();

  /// The amount used when none was said.
  static const defaultAmount = 1000.0;

  VoiceAnswer answer(
    List<RecoLine> ranked, {
    double? amount,
    String? merchant,
    String? categoryName,
  }) {
    const actions = [
      AnswerAction(AnswerActionKind.home, 'Open Home'),
      AnswerAction(AnswerActionKind.wallet, 'Open Wallet'),
    ];
    final usable = ranked.where((r) => !r.excluded).toList();
    if (usable.isEmpty) {
      return VoiceAnswer.message(
        ranked.isEmpty
            ? 'Add a card to your wallet and I can tell you which one to use.'
            : 'None of your cards fit that purchase.',
        status: AnswerStatus.noData,
        actions: actions,
      );
    }
    final top = usable.first;
    final backup = usable.length > 1 ? usable[1] : null;
    final used = amount ?? defaultAmount;
    final where = merchant ?? categoryName;
    final what = [
      ?where,
      VoiceFormat.rupees(used),
    ].join(' · ');
    final earn = top.expectedValue > 0
        ? 'You’d earn about ${VoiceFormat.rupees(top.expectedValue)}.'
        : '';
    final spoken =
        'Use your ${top.cardName} for ${VoiceFormat.rupees(used)}'
        '${where == null ? '' : ' at $where'}. $earn'
        '${backup == null ? '' : ' Backup: ${backup.cardName}.'}'.trim();
    return VoiceAnswer(
      title: 'Best card · $what',
      headline: top.cardName,
      comparison: top.expectedValue > 0
          ? 'Earns about ${VoiceFormat.rupees(top.expectedValue)}'
          : null,
      rows: [
        for (final r in usable.take(3))
          AnswerRow(
            r.cardName,
            r.expectedValue > 0 ? VoiceFormat.rupees(r.expectedValue) : '—',
            detail: r.reason,
          ),
      ],
      evidence:
          top.reason ??
          'From each card’s reward rules, caps and your spending so far. Same engine as Home.',
      coverageNote: amount == null
          ? 'No amount was given, so I used ${VoiceFormat.rupees(defaultAmount)}.'
          : null,
      actions: actions,
      spoken: spoken,
    );
  }
}
