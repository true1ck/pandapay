/// Rows for the Bills page that are not a dated statement: a loan EMI, an
/// insurance premium or a SIP instalment the bank or fund said "will be
/// debited on <date>", and a running SIP mandate whose next instalment is
/// worked out from its last one.
///
/// These are saved as ordinary [Commitment]s with a `v2:` id, so they list,
/// remind, move to Past bills and can be marked paid or dismissed like any
/// other bill.
library;

import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:pandapay_domain/sms_v2_category.dart';

import '../../../data/commitments_repository.dart';

/// A debit counts as this instalment when it lands this close to the date.
const _before = Duration(days: 5);
const _after = Duration(days: 7);

const _ist = Duration(hours: 5, minutes: 30);

DateTime _istDay(DateTime at) {
  final d = at.toUtc().add(_ist);
  return DateTime(d.year, d.month, d.day);
}

/// What a scheduled debit is for, from what the rule that read it typed: its
/// purpose (an EMI, an investment instalment, an insurance premium) and, for
/// any other bill payment, the biller's name through the same classifier every
/// other bill uses. The app reads no wording and no rule ids: a rule decides
/// what it emits.
CommitmentCategory? _kindOf(v2.AttemptFact f) => switch (f.purpose) {
  v2.MovementPurpose.investment => CommitmentCategory.investment,
  v2.MovementPurpose.emi => CommitmentCategory.loanOrEmi,
  v2.MovementPurpose.insurance => CommitmentCategory.insurance,
  v2.MovementPurpose.billPayment =>
    (f.counterparty?.name ?? '').trim().isEmpty
        ? null
        : CommitmentCategory.fromText(f.counterparty!.name!),
  _ => null,
};

String _titleCase(String s) => s
    .trim()
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

int? _minor(v2.Fact f, v2.AmountRole role) => f.amounts
    .where((a) => a.role == role && a.unit == 'INR')
    .firstOrNull
    ?.minor;

DateTime _addMonth(DateTime d, int day, int months) {
  final last = DateTime(d.year, d.month + months + 1, 0).day;
  return DateTime(d.year, d.month + months, day > last ? last : day);
}

/// The debit that settled [dueOn] for [minor], if one is in the facts.
({v2.MovementFact fact, String? eventId})? _settledBy(
  Iterable<v2.MovementFact> debits,
  Iterable<v2.Event> events,
  v2.MovementPurpose purpose,
  int minor,
  DateTime dueOn,
  String? name,
) {
  final wanted = normalizeMerchantText(name ?? '');
  for (final m in debits) {
    if (m.purpose != purpose || _minor(m, v2.AmountRole.posted) != minor) {
      continue;
    }
    // When both name a payee they must be the same one (a fund's instalment
    // does not settle another fund's).
    final paid = normalizeMerchantText(m.counterparty?.name ?? '');
    if (wanted.isNotEmpty &&
        paid.isNotEmpty &&
        !paid.contains(wanted) &&
        !wanted.contains(paid)) {
      continue;
    }
    final at = _istDay(m.effectiveAt);
    if (at.isBefore(dueOn.subtract(_before)) || at.isAfter(dueOn.add(_after))) {
      continue;
    }
    final event = events
        .where((e) => e.legs.any((l) => l.factId == m.factId))
        .firstOrNull;
    return (fact: m, eventId: event?.eventId);
  }
  return null;
}

List<Commitment> scheduledCommitments(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events, {
  required DateTime now,
  Map<String, String> transactionIdByEvent = const {},
}) {
  final today = DateTime(now.year, now.month, now.day);
  final debits = facts
      .whereType<v2.MovementFact>()
      .where((m) => m.direction == v2.Direction.debit)
      .toList();
  String? txnOf(String? eventId) =>
      eventId == null ? null : transactionIdByEvent[eventId] ?? 'v2:$eventId';

  // 1. "Will be debited on <date>" notices: one row per thing and date.
  final groups = <String, v2.AttemptFact>{};
  final kinds = <String, CommitmentCategory>{};
  for (final f in facts.whereType<v2.AttemptFact>()) {
    // A scheduled debit only: not a failure, not a credit coming in.
    if (f.status != v2.AttemptStatus.scheduled ||
        f.direction != v2.Direction.debit ||
        f.dueAt == null) {
      continue;
    }
    final kind = _kindOf(f);
    final minor = _minor(f, v2.AmountRole.scheduled);
    if (kind == null || minor == null || minor <= 0) continue;
    final key = [
      kind.name,
      normalizeMerchantText(f.counterparty?.name ?? ''),
      f.instrument?.maskDigits ?? '',
      _istDay(f.dueAt!).toIso8601String(),
      minor,
    ].join('|');
    final seen = groups[key];
    if (seen == null || f.effectiveAt.isAfter(seen.effectiveAt)) {
      groups[key] = f;
      kinds[key] = kind;
    }
  }
  final out = <Commitment>[];
  final fundsWithDate = <String>{};
  groups.forEach((key, f) {
    final kind = kinds[key]!;
    final minor = _minor(f, v2.AmountRole.scheduled)!;
    final dueOn = _istDay(f.dueAt!);
    final name = f.counterparty?.name;
    final title = name == null ? kind.label : _titleCase(name);
    final settled = _settledBy(debits, events, f.purpose, minor, dueOn, name);
    if (kind == CommitmentCategory.investment && !dueOn.isBefore(today)) {
      fundsWithDate.add(normalizeMerchantText(name ?? ''));
    }
    out.add(
      Commitment(
        id: 'v2:${f.factId}',
        title: title,
        category: kind,
        amount: Money.fromPaise(minor),
        dueOn: dueOn,
        identifier: f.instrument?.maskDigits,
        // A SIP or an EMI repeats every month; a bill payment is one-off.
        cadence: kind == CommitmentCategory.investment ||
                kind == CommitmentCategory.loanOrEmi
            ? CommitmentCadence.monthly
            : CommitmentCadence.oneTime,
        anchorDay: kind == CommitmentCategory.investment ||
                kind == CommitmentCategory.loanOrEmi
            ? dueOn.day
            : null,
        status: settled == null ? CommitmentStatus.due : CommitmentStatus.paid,
        paidOn: settled?.fact.effectiveAt,
        linkedTransactionId: txnOf(settled?.eventId),
        confidence: f.confidence,
        sourceKey: f.sourceKey,
      ),
    );
  });

  // 2. A running SIP the notices did not date: next instalment = the month
  // after its last debit, on the same day.
  final byFund = <String, List<v2.MandateFact>>{};
  for (final m in facts.whereType<v2.MandateFact>()) {
    if (m.mandatePurpose != v2.MandatePurpose.sip || m.oneTime == true) {
      continue;
    }
    final fund = m.merchantName ?? m.counterparty?.name;
    if (fund == null || fund.trim().isEmpty) continue;
    byFund.putIfAbsent(normalizeMerchantText(fund), () => []).add(m);
  }
  byFund.forEach((fundKey, list) {
    list.sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));
    final latest = list.last;
    if ({
      v2.MandatePhase.revoked,
      v2.MandatePhase.expired,
      v2.MandatePhase.paused,
    }.contains(latest.phase)) {
      return;
    }
    if (fundsWithDate.contains(fundKey)) return;
    final instalments = debits.where((m) {
      if (m.purpose != v2.MovementPurpose.investment) return false;
      final n = normalizeMerchantText(m.counterparty?.name ?? '');
      return n.isNotEmpty && (n.contains(fundKey) || fundKey.contains(n));
    }).toList()..sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));
    if (instalments.isEmpty) return;
    final last = instalments.last;
    final lastDay = _istDay(last.effectiveAt);
    var next = _addMonth(lastDay, lastDay.day, 1);
    while (next.isBefore(today)) {
      next = _addMonth(next, lastDay.day, 1);
    }
    final minor =
        _minor(last, v2.AmountRole.posted) ??
        _minor(latest, v2.AmountRole.ceiling);
    if (minor == null || minor <= 0) return;
    out.add(
      Commitment(
        id: 'v2:sip:$fundKey:${next.year}-${next.month}',
        title: _titleCase(
          latest.merchantName ?? latest.counterparty?.name ?? 'SIP',
        ),
        category: CommitmentCategory.investment,
        amount: Money.fromPaise(minor),
        dueOn: next,
        cadence: CommitmentCadence.monthly,
        anchorDay: lastDay.day,
        confidence: latest.confidence,
        sourceKey: last.sourceKey,
      ),
    );
  });
  return out;
}
