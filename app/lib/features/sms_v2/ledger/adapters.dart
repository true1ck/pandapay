import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../../../data/commitments_repository.dart';
import '../../../data/card_bill_ledger.dart';
import '../../../data/pending_bills.dart';
import '../../../data/spend_reports_repository.dart';

String _instrumentKey(v2.Fact f) => [
  f.instrument?.issuerSlug,
  f.instrument?.kind?.wire,
  f.instrument?.maskDigits,
].join('|');
String _name(v2.Fact f) => f is v2.MandateFact
    ? f.merchantName ?? f.counterparty?.name ?? 'Unknown service'
    : f.counterparty?.name ?? f.counterparty?.vpa ?? 'Unknown service';

/// One subscription per service. A cancellation or failure notice often omits
/// the card or account, so the instrument must not split a service's history.
String _seriesKey(v2.Fact f) => normalizeMerchantText(_name(f));
Map<String, v2.Fact> _facts(Iterable<v2.Fact> facts) => {
  for (final f in facts) f.factId: f,
};
int? _amount(v2.Fact f, v2.AmountRole role) => f.amounts
    .where((a) => a.role == role && a.unit == 'INR')
    .firstOrNull
    ?.minor;
bool _usable(v2.Event e) => e.status != v2.EventStatus.ambiguous;

int? _cadence(String? frequency) =>
    switch (frequency?.toLowerCase().replaceAll('_', '')) {
      'daily' => 1,
      'weekly' => 7,
      'fortnightly' => 14,
      'monthly' => 30,
      'quarterly' => 91,
      'halfyearly' || 'semiannual' => 182,
      'yearly' || 'annual' || 'annually' => 365,
      _ => null,
    };
DateTime _next(DateTime date, int days) {
  final months = days >= 350 ? 12 : (days >= 26 && days <= 32 ? 1 : 0);
  if (months == 0) return date.add(Duration(days: days));

  // SMS date-only values are parsed at midnight in India and stored in UTC.
  const offset = Duration(hours: 5, minutes: 30);
  final wall = date.toUtc().add(offset);
  final month = wall.month + months;
  final max = DateTime.utc(wall.year, month + 1, 0).day;
  return DateTime.utc(
    wall.year,
    month,
    wall.day > max ? max : wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
    wall.microsecond,
  ).subtract(offset);
}

/// Mandate history plus actual charge events. Attempts never add a charge or
/// an amount; a failed payment is a lifecycle state on the same subscription.
List<RecurringSeries> subscriptionsFromLedger(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events, {
  required DateTime now,
}) {
  final byId = _facts(facts);
  final groups = <String, List<v2.Fact>>{};
  final excluded = <String>{};
  for (final f in byId.values.whereType<v2.MandateFact>()) {
    if (f.oneTime == true ||
        {
          v2.MandatePurpose.ipo,
          v2.MandatePurpose.sip,
          v2.MandatePurpose.loan,
        }.contains(f.mandatePurpose)) {
      excluded.add(f.factId);
      continue;
    }
    groups.putIfAbsent(_seriesKey(f), () => []).add(f);
  }
  final charges = <String, List<(v2.Event, v2.MovementFact)>>{};
  for (final e in events.where(
    (e) => e.type == v2.EventType.subscriptionCharge && _usable(e),
  )) {
    final f = moneyFactForEvent(e, byId);
    if (f == null) continue;
    final original = e.legs
        .where((l) => l.role == v2.LegRole.original)
        .map((l) => byId[l.factId])
        .whereType<v2.MandateFact>()
        .firstOrNull;
    if (original != null && excluded.contains(original.factId)) continue;
    final key = _seriesKey(original ?? f);
    groups.putIfAbsent(key, () => []);
    charges.putIfAbsent(key, () => []).add((e, f));
  }
  final result = <RecurringSeries>[];
  for (final group in groups.entries) {
    final mandates = group.value.whereType<v2.MandateFact>().toList()
      ..sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));
    final latest = mandates.lastOrNull;
    final paid = charges[group.key] ?? [];
    paid.sort((a, b) => a.$1.occurredAt.compareTo(b.$1.occurredAt));
    final anchor = latest ?? paid.last.$2;
    final intervals =
        [
            for (var i = 1; i < paid.length; i++)
              paid[i].$1.occurredAt
                  .difference(paid[i - 1].$1.occurredAt)
                  .inDays,
          ]
          ..removeWhere((d) => d <= 0)
          ..sort();
    final cadence =
        _cadence(latest?.frequency) ??
        (intervals.isEmpty ? 0 : intervals[intervals.length ~/ 2]);
    final last = paid.lastOrNull;
    final next = last == null || cadence == 0
        ? null
        : _next(last.$1.occurredAt, cadence);
    final failures =
        byId.values
            .whereType<v2.AttemptFact>()
            .where(
              (f) =>
                  f.status == v2.AttemptStatus.failed &&
                  _seriesKey(f) == group.key,
            )
            .toList()
          ..sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));
    // A renewal the service announced ("will renew on 12 Nov") is a better guess
    // for the next charge than last charge plus cadence. It adds no charge and
    // no amount: an announcement is not money moved.
    final announced =
        (byId.values
                .whereType<v2.AttemptFact>()
                .where(
                  (f) =>
                      f.status == v2.AttemptStatus.scheduled &&
                      f.dueAt != null &&
                      f.dueAt!.isAfter(now) &&
                      (last == null || f.dueAt!.isAfter(last.$1.occurredAt)) &&
                      _seriesKey(f) == group.key,
                )
                .toList()
              ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!)))
            .firstOrNull
            ?.dueAt;
    final cancelled =
        latest?.phase == v2.MandatePhase.revoked ||
        latest?.phase == v2.MandatePhase.expired;
    final failed =
        failures.isNotEmpty &&
        (last == null ||
            failures.last.effectiveAt.isAfter(last.$1.occurredAt)) &&
        (latest == null ||
            !latest.effectiveAt.isAfter(failures.last.effectiveAt));
    final lifecycle = cancelled
        ? 'cancelled'
        : latest?.phase == v2.MandatePhase.paused
        ? 'paused'
        : failed
        ? 'failed_payment'
        : next != null && now.isAfter(next.add(Duration(days: cadence)))
        ? 'lapsed'
        : 'active';
    final amount = last == null ? null : _amount(last.$2, v2.AmountRole.posted);
    final yearly = cadence == 0
        ? 0
        : cadence >= 26 && cadence <= 32
        ? 12
        : cadence >= 350
        ? 1
        : 365 / cadence;
    result.add(
      RecurringSeries(
        id: 'v2:${group.key}',
        displayName: _name(anchor),
        typicalAmount: Money.fromPaise(amount ?? 0),
        amountKnown: amount != null,
        cadenceDays: cadence,
        occurrenceCount: paid.length,
        annualCost: Money.fromPaise(
          amount == null ? 0 : (amount * yearly).round(),
        ),
        autopayLimit:
            latest == null || _amount(latest, v2.AmountRole.ceiling) == null
            ? null
            : Money.fromPaise(_amount(latest, v2.AmountRole.ceiling)!),
        lastSeenOn: last?.$1.occurredAt,
        nextExpectedOn: cancelled ? null : (announced ?? next),
        startDate:
            mandates.firstOrNull?.effectiveAt ??
            paid.firstOrNull?.$1.occurredAt,
        endDate: cancelled ? latest?.effectiveAt : null,
        lifecycleStatus: lifecycle,
        autopayStatus: cancelled
            ? 'cancelled'
            : latest?.phase.wire ?? 'unknown',
        isMandate: latest != null,
        mandateReference: latest?.references['umrn'],
        sourceKey: anchor.sourceKey,
        detectionSource: 'sms_v2',
        cadenceConfirmed: cadence > 0,
        setupConfirmed: latest != null,
      ),
    );
  }
  result.sort((a, b) => a.displayName.compareTo(b.displayName));
  return result;
}

class _BillRecord {
  const _BillRecord(
    this.fact,
    this.paidMinor,
    this.lastPayment, [
    this.receiptAt,
    this.superseded = false,
  ]);
  final v2.BillDueFact fact;
  final int paidMinor;
  final v2.Event? lastPayment;

  /// When a biller's payment receipt, chained to this bill by consumer number
  /// and amount, says it was paid (no ledger event stands behind it).
  final DateTime? receiptAt;

  /// A later statement for the same card / biller exists. If this one is unpaid it
  /// is no longer a bill to pay: the newer statement carries whatever is owed
  /// (the old balance plus later spend), or the user settled this one elsewhere.
  final bool superseded;
  int? get dueMinor =>
      _amount(fact, v2.AmountRole.dueTotal) ??
      _amount(fact, v2.AmountRole.dueMinimum);
  bool get paid => dueMinor != null && paidMinor >= dueMinor!;
}

bool _sameInstrument(v2.Fact a, v2.Fact b) =>
    a.instrument?.issuerSlug != null &&
    a.instrument?.issuerSlug == b.instrument?.issuerSlug &&
    a.instrument?.maskDigits == b.instrument?.maskDigits &&
    (a.instrument?.kind == null ||
        b.instrument?.kind == null ||
        a.instrument!.kind == b.instrument!.kind);
String _billIdentity(v2.BillDueFact f) => f.instrument?.issuerSlug != null
    ? _instrumentKey(f)
    : normalizeMerchantText(f.billerName ?? 'unknown:${f.factId}');
DateTime _statementAt(v2.BillDueFact f) => f.statementDate == null
    ? f.effectiveAt
    : DateTime.parse('${f.statementDate}T00:00:00+05:30').toUtc();

/// A payment belongs to only one statement cycle. Later reminders of the same
/// due date cannot erase a payment that followed the original statement.
List<_BillRecord> _billRecords(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events,
) {
  final byId = _facts(facts);
  final groups = <String, List<v2.BillDueFact>>{};
  for (final fact in byId.values.whereType<v2.BillDueFact>()) {
    groups
        .putIfAbsent('${_billIdentity(fact)}|${fact.dueDate}', () => [])
        .add(fact);
  }
  final cycles = groups.values.toList()
    ..sort((a, b) => a.first.dueDate.compareTo(b.first.dueDate));
  final remaining = <String, int>{};
  final payments = {
    for (final event in events)
      if (_usable(event) &&
          {
            v2.EventType.cardBillPayment,
            v2.EventType.billPayment,
          }.contains(event.type))
        event.eventId: event,
  }.values.toList()..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
  for (final event in payments) {
    remaining[event.eventId] = event.amountMinor;
  }
  final receipts = byId.values
      .whereType<v2.MovementFact>()
      .where(
        (f) =>
            f.evidenceOnly == true &&
            f.purpose == v2.MovementPurpose.billPayment &&
            f.direction == v2.Direction.debit,
      )
      .toList();
  final result = <_BillRecord>[];
  for (final cycle in cycles) {
    cycle.sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));
    final fact = cycle.last;
    final totalFact = cycle.reversed
        .where((f) => _amount(f, v2.AmountRole.dueTotal) != null)
        .firstOrNull;
    final minFact = cycle.reversed
        .where((f) => _amount(f, v2.AmountRole.dueMinimum) != null)
        .firstOrNull;
    final amounts = [
      if (totalFact != null)
        totalFact.amounts
            .firstWhere((a) => a.role == v2.AmountRole.dueTotal)
            .toJson(),
      if (minFact != null)
        minFact.amounts
            .firstWhere((a) => a.role == v2.AmountRole.dueMinimum)
            .toJson(),
    ];
    final statementDate = cycle.reversed
        .map((f) => f.statementDate)
        .whereType<String>()
        .firstOrNull;
    final json = fact.toJson();
    final combined =
        v2.Fact.fromJson({
              ...json,
              'amounts': amounts,
              if (statementDate != null)
                'attrs': <String, Object?>{
                  ...(json['attrs'] as Map).cast<String, Object?>(),
                  'statementDate': statementDate,
                },
            })
            as v2.BillDueFact;
    final due =
        _amount(combined, v2.AmountRole.dueTotal) ??
        _amount(combined, v2.AmountRole.dueMinimum);
    final start = cycle
        .map(_statementAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final nextStarts =
        cycles
            .where((other) => _billIdentity(other.first) == _billIdentity(fact))
            .map(
              (other) => other
                  .map(_statementAt)
                  .reduce((a, b) => a.isBefore(b) ? a : b),
            )
            .where((at) => at.isAfter(start))
            .toList()
          ..sort();
    final nextStatement = nextStarts.firstOrNull;
    final superseded = cycles.any(
      (other) =>
          !identical(other, cycle) &&
          _billIdentity(other.first) == _billIdentity(fact) &&
          other.first.dueDate.compareTo(fact.dueDate) > 0 &&
          other
              .map(_statementAt)
              .reduce((a, b) => a.isBefore(b) ? a : b)
              .isAfter(start) &&
          // A guess (an inferred reminder) never retires a real statement.
          other.any((f) => f.confidence >= 0.7),
    );
    var paid = 0;
    v2.Event? last;
    for (final event in payments) {
      if (event.occurredAt.isBefore(start) ||
          (nextStatement != null &&
              !event.occurredAt.isBefore(nextStatement)) ||
          (remaining[event.eventId] ?? 0) <= 0) {
        continue;
      }
      final matches = event.legs
          .where((l) => moneyLegRoles.contains(l.role))
          .map((l) => byId[l.factId])
          .whereType<v2.MovementFact>()
          .where(
            (f) =>
                f.evidenceOnly != true &&
                (fact.instrument?.issuerSlug != null
                    ? _sameInstrument(f, fact)
                    : fact.billerName != null &&
                          normalizeMerchantText(f.counterparty?.name ?? '') ==
                              normalizeMerchantText(fact.billerName!)),
          );
      if (matches.isEmpty || due == null) continue;
      final available = remaining[event.eventId]!;
      final take = available < due - paid ? available : due - paid;
      if (take <= 0) break;
      paid += take;
      remaining[event.eventId] = available - take;
      last = event;
      if (paid >= due) break;
    }
    DateTime? receiptAt;
    if (paid == 0 && due != null) {
      receiptAt = _chainedReceipt(
        receipts,
        combined,
        due,
        start,
        nextStatement,
        cycles.where((c) => !identical(c, cycle)),
      );
    }
    result.add(
      _BillRecord(
        combined,
        receiptAt == null ? paid : due ?? paid,
        last,
        receiptAt,
        superseded,
      ),
    );
  }
  return result;
}

/// The longest run of 6+ digits in a name: the biller's consumer number.
String? _consumerNo(String? name) {
  String? best;
  for (final m in RegExp(r'\d{6,}').allMatches(name ?? '')) {
    if (best == null || m.group(0)!.length > best.length) best = m.group(0);
  }
  return best;
}

/// A biller's `payment of X for CONSUMER_NO` receipt that settles this bill.
/// The chain: same amount, inside the bill's cycle, and either the same consumer
/// number or (when the bill never printed one) no other bill that could take it.
DateTime? _chainedReceipt(
  List<v2.MovementFact> receipts,
  v2.BillDueFact bill,
  int due,
  DateTime start,
  DateTime? nextStatement,
  Iterable<List<v2.BillDueFact>> otherCycles,
) {
  final billNo = _consumerNo(bill.billerName);
  final limit = nextStatement ?? start.add(const Duration(days: 75));
  DateTime? found;
  for (final r in receipts) {
    if (_amount(r, v2.AmountRole.posted) != due) continue;
    final at = r.effectiveAt;
    if (at.isBefore(start) || !at.isBefore(limit)) continue;
    final no = _consumerNo(r.counterparty?.name);
    if (no != null && billNo != null && no != billNo) continue;
    if (no == null || billNo == null) {
      // No shared number: only chain when the amount singles out this bill.
      final rival = otherCycles.any(
        (c) => c.any((o) => _amount(o, v2.AmountRole.dueTotal) == due),
      );
      if (rival) continue;
    }
    if (found == null || at.isAfter(found)) found = at;
  }
  return found;
}

List<Commitment> billsFromFacts(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events, {
  Map<String, String> transactionIdByEvent = const {},
}) => [
  for (final record in _billRecords(facts, events))
    _commitment(record, transactionIdByEvent: transactionIdByEvent),
];
Commitment _commitment(
  _BillRecord record, {
  Map<String, String> transactionIdByEvent = const {},
}) {
  final bill = record.fact;
  final title =
      bill.billerName ??
      bill.instrument?.productName ??
      '${bill.instrument?.issuerSlug ?? ''} bill'.trim();
  return Commitment(
    id: 'v2:${bill.factId}',
    title: title,
    category: CommitmentCategory.fromText(title),
    amount: record.dueMinor == null ? null : Money.fromPaise(record.dueMinor!),
    dueOn: DateTime.parse(bill.dueDate),
    identifier: bill.instrument?.maskDigits,
    cadence: CommitmentCadence.oneTime,
    // An unpaid statement that a newer one replaced is kept in history but is no
    // longer something to pay: its payment was not seen in SMS (it may have been
    // settled elsewhere, or it is carried inside the newer statement).
    status: record.paid
        ? CommitmentStatus.paid
        : record.superseded
        ? CommitmentStatus.paymentNotDetected
        : CommitmentStatus.due,
    paidOn: record.lastPayment?.occurredAt ?? record.receiptAt,
    linkedTransactionId: record.lastPayment == null
        ? null
        : transactionIdByEvent[record.lastPayment!.eventId] ??
              'v2:${record.lastPayment!.eventId}',
    confidence: bill.confidence,
  );
}

class MoneyInItem {
  const MoneyInItem({
    required this.eventId,
    required this.kind,
    required this.payer,
    required this.amountMinor,
    required this.occurredAt,
  });
  final String eventId, kind, payer;
  final int amountMinor;
  final DateTime occurredAt;
}

const _unknownPayer = 'Unknown payer';
const _indiaOffset = Duration(hours: 5, minutes: 30);

/// Who paid: the money fact's counterparty, else the counterparty of another
/// leg (a refund names its merchant on the original purchase). Null when the
/// messages never named anyone.
String? _payerName(v2.Event e, Map<String, v2.Fact> byId, v2.Fact money) {
  String? named(v2.Fact f) {
    final c = f.counterparty;
    if (c == null || c.kind == v2.CounterpartyKind.own) return null;
    final n = c.name ?? c.vpa;
    return n == null || n.trim().isEmpty ? null : n;
  }

  final direct = named(money);
  if (direct != null) return direct;
  for (final leg in e.legs) {
    final fact = byId[leg.factId];
    final n = fact == null ? null : named(fact);
    if (n != null) return n;
  }
  return null;
}

/// True when [a] and [b] (Indian wall time) are in consecutive months and the
/// pay days are within seven days of each other, wrapping at month end.
bool _paidAroundSameDay(DateTime a, DateTime b) {
  if (b.year * 12 + b.month - (a.year * 12 + a.month) != 1) return false;
  final gap = (a.day - b.day).abs();
  return gap <= 7 || 30 - gap <= 7;
}

/// All incoming money except own transfers and investment withdrawals. Salary
/// requires a confirmed payer or a repeated consecutive-month pattern from a
/// payer the messages actually named.
List<MoneyInItem> moneyIn(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events,
  DateTime from,
  DateTime to, {
  Set<String> confirmedSalaryPayers = const {},
}) {
  final byId = _facts(facts);
  final all = events
      .where(
        (e) =>
            _usable(e) &&
            (incomeEventTypes.contains(e.type) ||
                e.type == v2.EventType.refund),
      )
      .toList();
  final payerDates = <String, List<DateTime>>{};
  for (final e in all.where((e) => e.type == v2.EventType.income)) {
    final f = moneyFactForEvent(e, byId);
    final payer = f == null ? null : _payerName(e, byId, f);
    if (payer == null) continue;
    payerDates
        .putIfAbsent(normalizeMerchantText(payer), () => [])
        .add(e.occurredAt.toUtc().add(_indiaOffset));
  }
  final salary = {...confirmedSalaryPayers.map(normalizeMerchantText)};
  for (final p in payerDates.entries) {
    final dates = p.value..sort();
    for (var i = 1; i < dates.length; i++) {
      if (_paidAroundSameDay(dates[i - 1], dates[i])) salary.add(p.key);
    }
  }
  return [
    for (final e in all.where(
      (e) => !e.occurredAt.isBefore(from) && e.occurredAt.isBefore(to),
    ))
      if (moneyFactForEvent(e, byId) case final f?)
        if (_payerName(e, byId, f) case final payer)
          MoneyInItem(
            eventId: e.eventId,
            kind: e.type == v2.EventType.refund
                ? 'refund'
                : e.type == v2.EventType.dividend
                ? 'dividend'
                : e.type == v2.EventType.cashback
                ? 'cashback'
                : e.type == v2.EventType.p2pIn
                ? 'person'
                : f.purpose == v2.MovementPurpose.salary ||
                      (payer != null &&
                          salary.contains(normalizeMerchantText(payer)))
                ? 'salary'
                : 'other',
            payer: payer ?? _unknownPayer,
            amountMinor: e.amountMinor,
            occurredAt: e.occurredAt,
          ),
  ];
}

class InvestmentSummary {
  const InvestmentSummary({
    required this.platform,
    required this.putInMinor,
    required this.takenOutMinor,
    required this.dividendMinor,
    this.balanceMinor,
  });
  final String platform;
  final int putInMinor, takenOutMinor, dividendMinor;
  final int? balanceMinor;
  int get netInvestedMinor => putInMinor - takenOutMinor;
}

const ipoPlatformLabel = 'IPO allotments';
const bankDividendsLabel = 'Dividends paid to bank';

/// Investments are their own area, never spending. Rows are per platform: a
/// broker the user has an account with, or one of two honest buckets for money
/// that has no platform (IPO allotments, dividends paid straight to the bank).
List<InvestmentSummary> investmentsSummary(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events,
  Iterable<v2.Instrument> instruments,
) {
  final byId = _facts(facts);
  final brokers = {
    for (final i in instruments.where(
      (i) => i.kind == v2.InstrumentKind.broker,
    ))
      normalizeMerchantText(i.issuerSlug): i,
  };
  String? brokerFor(String name) {
    final key = normalizeMerchantText(name);
    if (key.length < 3) return null;
    for (final slug in brokers.keys) {
      if (slug.isNotEmpty && (key.contains(slug) || slug.contains(key))) {
        return slug;
      }
    }
    return null;
  }

  final groups = <String, List<int>>{};
  for (final e in events.where(
    (e) =>
        _usable(e) &&
        {
          v2.EventType.investment,
          v2.EventType.ipoApplication,
          v2.EventType.investmentWithdrawal,
          v2.EventType.dividend,
        }.contains(e.type),
  )) {
    if (transactionKindForEvent(e) == null) continue;
    final f = moneyFactForEvent(e, byId);
    if (f == null) continue;
    final named = _payerName(e, byId, f);
    final key = e.type == v2.EventType.ipoApplication
        ? ipoPlatformLabel
        : named == null
        ? (e.type == v2.EventType.dividend
              ? bankDividendsLabel
              : 'Unknown platform')
        : brokerFor(named) ??
              (e.type == v2.EventType.dividend
                  ? bankDividendsLabel
                  : normalizeMerchantText(named));
    final g = groups.putIfAbsent(key, () => [0, 0, 0]);
    g[e.type == v2.EventType.investmentWithdrawal
            ? 1
            : e.type == v2.EventType.dividend
            ? 2
            : 0] +=
        e.amountMinor;
  }
  final balances = <String, int>{};
  for (final entry in brokers.entries) {
    groups.putIfAbsent(entry.key, () => [0, 0, 0]);
    if (entry.value.availableMinor != null) {
      balances[entry.key] = entry.value.availableMinor!;
    }
  }
  return [
    for (final g in groups.entries)
      InvestmentSummary(
        platform: g.key,
        putInMinor: g.value[0],
        takenOutMinor: g.value[1],
        dividendMinor: g.value[2],
        balanceMinor: balances[g.key],
      ),
  ];
}

class IpoApplication {
  const IpoApplication({
    required this.eventId,
    required this.company,
    required this.status,
    required this.blockedMinor,
    required this.investedMinor,
    this.releasedMinor = 0,
    this.accountMask,
    this.platform,
    this.appliedAt,
    this.updatedAt,
  });
  final String eventId, company, status;
  final int blockedMinor, investedMinor, releasedMinor;

  /// When the money was blocked, and when the application last changed.
  final DateTime? appliedAt, updatedAt;
  int get remainingHoldMinor {
    final remaining = blockedMinor - investedMinor - releasedMinor;
    return remaining > 0 ? remaining : 0;
  }

  final String? accountMask, platform;
}

List<IpoApplication> ipoApplications(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events,
) {
  final byId = _facts(facts);
  final result = <IpoApplication>[];
  for (final e in events.where((e) => e.type == v2.EventType.ipoApplication)) {
    final fs = e.legs.map((l) => byId[l.factId]).whereType<v2.Fact>().toList();
    final hold = fs
        .whereType<v2.HoldFact>()
        .where((f) => f.phase == v2.HoldPhase.placed)
        .firstOrNull;
    var released = 0;
    for (final f in fs.whereType<v2.HoldFact>()) {
      released += _amount(f, v2.AmountRole.released) ?? 0;
    }
    final money = moneyFactForEvent(e, byId);
    final blocked = hold == null ? 0 : _amount(hold, v2.AmountRole.held) ?? 0;
    final invested = money == null ? 0 : e.amountMinor;
    final company = hold?.issueName ?? money?.counterparty?.name ?? 'IPO';
    // The debit names the issuer, which is the company and not a platform.
    final partyName = money?.counterparty?.name;
    final issuerKey = normalizeMerchantText(company);
    final partyKey = partyName == null ? '' : normalizeMerchantText(partyName);
    final platform =
        partyKey.isEmpty ||
            issuerKey.contains(partyKey) ||
            partyKey.contains(issuerKey)
        ? null
        : partyName;
    result.add(
      IpoApplication(
        eventId: e.eventId,
        company: company,
        status: e.status == v2.EventStatus.ambiguous
            ? 'review'
            : invested > 0
            ? (invested < blocked ? 'partially_allotted' : 'allotted')
            : released >= blocked && released > 0
            ? 'released'
            : 'blocked',
        blockedMinor: blocked,
        investedMinor: invested,
        releasedMinor: released,
        accountMask: (money ?? hold)?.instrument?.maskDigits,
        platform: platform,
        appliedAt: hold?.effectiveAt,
        updatedAt: e.occurredAt,
      ),
    );
  }
  result.sort(
    (a, b) => (b.appliedAt ?? b.updatedAt ?? DateTime.utc(1900)).compareTo(
      a.appliedAt ?? a.updatedAt ?? DateTime.utc(1900),
    ),
  );
  return result;
}

RecurringReport recurringReportFromLedger(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events, {
  required DateTime now,
}) {
  final series = subscriptionsFromLedger(facts, events, now: now);
  return RecurringReport(
    series: series,
    totalAnnual: Money.fromPaise(
      series
          .where(
            (s) =>
                s.lifecycleStatus == 'active' ||
                s.lifecycleStatus == 'failed_payment',
          )
          .fold(0, (sum, s) => sum + s.annualCost.paise),
    ),
  );
}

List<SmsBillRow> smsBillRowsFromFacts(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events, {
  required DateTime now,
  Map<String, String> transactionIdByEvent = const {},
}) {
  final byId = _facts(facts);
  final bills = billsFromFacts(
    facts,
    events,
    transactionIdByEvent: transactionIdByEvent,
  );
  return [
    for (final bill in bills)
      if (byId[bill.id.substring(3)] case final v2.BillDueFact fact)
        SmsBillRow(
          id: bill.id,
          title: bill.title,
          category: bill.category,
          cardLast4: fact.instrument?.kind == v2.InstrumentKind.creditCard
              ? fact.instrument?.maskDigits
              : null,
          accountLast4: fact.instrument?.kind == v2.InstrumentKind.bankAccount
              ? fact.instrument?.maskDigits
              : null,
          amountDue: bill.amount ?? const Money.zero(),
          minimumDue: _amount(fact, v2.AmountRole.dueMinimum) == null
              ? null
              : Money.fromPaise(_amount(fact, v2.AmountRole.dueMinimum)!),
          isMinimumOnly: _amount(fact, v2.AmountRole.dueTotal) == null,
          dueDate: bill.dueOn,
          receivedAt: fact.observedAt,
          isAutopay: false,
          sawFailedAttempt: false,
          state: bill.status == CommitmentStatus.paid
              ? SmsBillState.linked
              : bill.status == CommitmentStatus.paymentNotDetected ||
                    bill.dueOn.isBefore(DateTime(now.year, now.month, now.day))
              ? SmsBillState.paymentNotDetected
              : SmsBillState.pending,
          linkedTxnId: bill.linkedTransactionId,
          linkedTxnAt: bill.paidOn,
          linkedTxnAmount: bill.status == CommitmentStatus.paid
              ? bill.amount
              : null,
        ),
  ];
}

Map<String, CardBillLedger> cardBillLedgersFromFacts(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events,
  Iterable<v2.Instrument> instruments,
) {
  final byInstrument = {for (final i in instruments) i.instrumentId: i};
  final groups = <String, List<CardBill>>{};
  final statements = _billRecords(facts, events);
  for (final record in statements) {
    final fact = record.fact;
    final statement = _commitment(record);
    final instrument = instrumentForFact(fact, byInstrument);
    if (instrument?.kind != v2.InstrumentKind.creditCard ||
        instrument?.userCardId == null) {
      continue;
    }
    groups
        .putIfAbsent(instrument!.userCardId!, () => [])
        .add(
          CardBill(
            statementDate: fact.statementDate == null
                ? fact.effectiveAt
                : DateTime.parse(fact.statementDate!),
            statementDateExplicit: fact.statementDate != null,
            statementDateVerified: fact.statementDate != null,
            dueDate: statement.dueOn,
            amountDue: _amount(fact, v2.AmountRole.dueTotal) == null
                ? null
                : Money.fromPaise(_amount(fact, v2.AmountRole.dueTotal)!),
            minimumDue: _amount(fact, v2.AmountRole.dueMinimum) == null
                ? null
                : Money.fromPaise(_amount(fact, v2.AmountRole.dueMinimum)!),
            paidToward: Money.fromPaise(record.paidMinor),
            lastPaymentAt: statement.paidOn,
            confidence: fact.confidence,
            sourceIds: [fact.sourceKey],
          ),
        );
  }
  return {
    for (final group in groups.entries)
      group.key: (() {
        final history = group.value
          ..sort((a, b) => b.statementDate.compareTo(a.statementDate));
        return CardBillLedger(
          current: history.first,
          previous: history.skip(1).firstOrNull,
          history: List.unmodifiable(history),
        );
      })(),
  };
}
