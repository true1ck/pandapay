import 'package:intl/intl.dart';
import 'package:pandapay_domain/sms_v2.dart';

/// "₹1,179" for a whole amount, "₹349.50" otherwise. Indian digit grouping.
String _rupees(int minor) {
  final whole = minor % 100 == 0;
  return NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: whole ? 0 : 2,
  ).format(minor / 100);
}

/// The first INR amount with one of [roles] (in that order of preference),
/// else any INR amount. Null when the message printed none (or only a foreign
/// one: the ledger counts rupees only, so no other unit is shown as rupees).
int? _inr(Fact fact, List<AmountRole> roles) {
  for (final role in roles) {
    final a = fact.amount(role);
    if (a != null && a.isInr) return a.minor;
  }
  for (final a in fact.amounts) {
    if (a.isInr) return a.minor;
  }
  return null;
}

String _withAmount(String text, int? minor) =>
    minor == null ? text : '$text ${_rupees(minor)}';

String _day(String isoDate) {
  final parsed = DateTime.tryParse(isoDate);
  return parsed == null ? isoDate : DateFormat('d MMM').format(parsed);
}

/// What the AI understood from one fact, in plain words.
String aiFactSummary(Fact fact) {
  switch (fact) {
    case MovementFact():
      final who = fact.counterparty?.name?.trim();
      final base = _withAmount(
        fact.direction == Direction.credit ? 'Money in' : 'Money out',
        _inr(fact, [AmountRole.posted]),
      );
      return who == null || who.isEmpty ? base : '$base · $who';
    case AttemptFact():
      final what = switch (fact.status) {
        AttemptStatus.failed => 'Payment attempt failed',
        AttemptStatus.declined => 'Payment declined',
        AttemptStatus.pending => 'Payment pending',
        AttemptStatus.scheduled => 'Payment scheduled',
        AttemptStatus.cancelled => 'Payment cancelled',
      };
      return _withAmount(
        what,
        _inr(fact, [AmountRole.scheduled, AmountRole.posted]),
      );
    case HoldFact():
      final what = switch (fact.phase) {
        HoldPhase.placed => 'Money blocked',
        HoldPhase.released => 'Block released',
        HoldPhase.converted => 'Block turned into a payment',
      };
      return _withAmount(
        what,
        _inr(fact, [AmountRole.held, AmountRole.released]),
      );
    case BalanceSnapshotFact():
      return _withAmount(
        'Balance',
        _inr(fact, [AmountRole.availableBalance, AmountRole.availableCredit]),
      );
    case LimitChangeFact():
      final what = switch (fact.reason) {
        LimitChangeReason.increase => 'Credit limit increased to',
        LimitChangeReason.decrease => 'Credit limit decreased to',
        LimitChangeReason.assigned => 'Credit limit set to',
      };
      final limit = _inr(fact, [AmountRole.creditLimit, AmountRole.ceiling]);
      return limit == null ? 'Credit limit changed' : '$what ${_rupees(limit)}';
    case BillDueFact():
      final amount = _inr(fact, [AmountRole.dueTotal, AmountRole.dueMinimum]);
      final when = fact.dueMonthOnly == true
          ? 'in ${DateFormat('MMM').format(DateTime.tryParse(fact.dueDate) ?? DateTime(2000))}'
          : 'on ${_day(fact.dueDate)}';
      final biller = fact.billerName?.trim();
      return '${_withAmount('Bill due', amount)} $when'
          '${biller == null || biller.isEmpty ? '' : ' · $biller'}';
    case MandateFact():
      final what = switch (fact.phase) {
        MandatePhase.created => 'Autopay set up',
        MandatePhase.modified => 'Autopay changed',
        MandatePhase.paused => 'Autopay paused',
        MandatePhase.resumed => 'Autopay resumed',
        MandatePhase.revoked => 'Autopay cancelled',
        MandatePhase.expired => 'Autopay expired',
      };
      final who = fact.merchantName?.trim();
      return who == null || who.isEmpty ? what : '$what · $who';
    case RewardFact():
      final points =
          fact.amount(AmountRole.pointsEarned) ??
          fact.amount(AmountRole.pointsBalance) ??
          fact.amount(AmountRole.pointsRedeemed);
      return points == null ? 'Reward points' : 'Reward points ${points.minor}';
    case InstrumentHintFact():
      return switch (fact.hint) {
        InstrumentHintKind.cardIssued => 'A card was issued',
        InstrumentHintKind.cardActivated => 'A card was activated',
        InstrumentHintKind.accountOpened => 'An account was opened',
        InstrumentHintKind.productName => 'Account or card details',
        InstrumentHintKind.linkedUpi => 'A UPI id was linked',
      };
    case InfoFact():
      final what = switch (fact.category) {
        InfoCategory.otp => 'Info: one-time code',
        InfoCategory.security => 'Info: security notice',
        InfoCategory.promotion => 'Info: promotion',
        InfoCategory.service => 'Info: service notice',
        InfoCategory.delivery => 'Info: delivery update',
        InfoCategory.other => 'Info: other message',
      };
      return fact.amountMinor == null
          ? what
          : '$what ${_rupees(fact.amountMinor!)}';
  }
}

/// One plain line for everything the AI read from a message: the summaries of
/// its facts, most useful first, without repeats, at most two.
String aiReadSummary(Iterable<Fact> facts) {
  const rank = {
    FactType.billDue: 0,
    FactType.attempt: 1,
    FactType.movement: 2,
    FactType.hold: 3,
    FactType.mandate: 4,
    FactType.limitChange: 5,
    FactType.balanceSnapshot: 6,
    FactType.reward: 7,
    FactType.instrumentHint: 8,
    FactType.info: 9,
  };
  final ordered = facts.toList()
    ..sort((a, b) => rank[a.factType]!.compareTo(rank[b.factType]!));
  final lines = <String>{for (final f in ordered) aiFactSummary(f)};
  return lines.take(2).join(' · ');
}
