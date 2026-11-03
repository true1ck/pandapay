import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../contract/enums.dart';
import '../contract/event.dart';
import '../contract/fact.dart';
import '../contract/instrument.dart';
import '../contract/interfaces.dart';
import '../contract/ledger_entry.dart';
import '../category/merchant_key.dart';

const spendEventTypes = {
  EventType.purchase,
  EventType.subscriptionCharge,
  EventType.fee,
  EventType.emi,
  EventType.billPayment,
  EventType.atmWithdrawal,
  EventType.p2pOut,
};
const incomeEventTypes = {
  EventType.income,
  EventType.p2pIn,
  EventType.cashback,
  EventType.dividend,
};
const ownTransferEventTypes = {
  EventType.ownTransfer,
  EventType.cardBillPayment,
  EventType.walletTopup,
};
const moneyLegRoles = {
  LegRole.debitLeg,
  LegRole.creditLeg,
  LegRole.charge,
  LegRole.reversal,
};

/// The legacy transaction kind, or null when the event has no money row.
String? transactionKindForEvent(Event event) {
  if (event.status == EventStatus.ambiguous ||
      event.type == EventType.unknown) {
    return null;
  }
  if (event.type == EventType.ipoApplication &&
      !event.legs.any((l) => l.role == LegRole.debitLeg)) {
    return null;
  }
  if (spendEventTypes.contains(event.type)) return 'spend';
  if (incomeEventTypes.contains(event.type)) return 'income';
  if (event.type == EventType.refund) return 'refund';
  if (event.type == EventType.investment ||
      event.type == EventType.ipoApplication) {
    return 'investment';
  }
  if (ownTransferEventTypes.contains(event.type) ||
      event.type == EventType.investmentWithdrawal) {
    return 'transfer';
  }
  return null;
}

/// A unique resolved instrument, never a guess between matching accounts.
Instrument? instrumentForFact(
  Fact fact,
  Map<String, Instrument> instruments, {
  Map<String, String> instrumentIdByFactId = const {},
}) {
  final resolved = instrumentIdByFactId[fact.factId];
  if (resolved != null) return instruments[resolved];
  final m = fact.instrument;
  if (m == null || m.issuerSlug == null) return null;
  final matches = instruments.values
      .where(
        (i) =>
            i.issuerSlug == m.issuerSlug &&
            (m.kind == null || i.kind == m.kind) &&
            (m.maskDigits == null || i.maskDigits == m.maskDigits),
      )
      .toList();
  return matches.length == 1 ? matches.single : null;
}

/// Latest available-credit snapshot and limit must both be known.
int? cardUsage(Instrument instrument) =>
    instrument.creditLimitMinor == null || instrument.availableMinor == null
    ? null
    : instrument.creditLimitMinor! - instrument.availableMinor!;

/// Pure projection. Refund decisions are explicit input, never cached state.
///
/// Refund ledger rows cannot carry category under the frozen contract because
/// their destination is own. Linked refunds derive it from the purchase; an
/// unlinked refund uses [categoryByEvent], reconstructed by LedgerSnapshot from
/// facts and the category resolver. Pass the same context when reading totals.
class DefaultLedgerProjector implements LedgerProjector {
  DefaultLedgerProjector({
    Map<String, CategoryDecision> categoryByEvent = const {},
    Map<String, String> instrumentIdByFactId = const {},
    MerchantKeyer? keyer,
  }) : categoryByEvent = Map.unmodifiable(categoryByEvent),
       instrumentIdByFactId = Map.unmodifiable(instrumentIdByFactId),
       keyer = keyer ?? MerchantKeyer();

  final Map<String, CategoryDecision> categoryByEvent;
  final Map<String, String> instrumentIdByFactId;
  final MerchantKeyer keyer;

  @override
  List<LedgerEntry> project(
    Event event,
    Map<String, Fact> factsById,
    Map<String, Instrument> instrumentsById,
    CategoryDecision? category,
  ) {
    if (transactionKindForEvent(event) == null) return const [];
    final movements = <(EventLeg, MovementFact)>[
      for (final leg in event.legs)
        if (moneyLegRoles.contains(leg.role) &&
            factsById[leg.factId] is MovementFact)
          (leg, factsById[leg.factId] as MovementFact),
    ].where((x) => x.$2.evidenceOnly != true).toList();
    if (movements.isEmpty) return const [];
    if (movements.any(
      (pair) =>
          instrumentForFact(
            pair.$2,
            instrumentsById,
            instrumentIdByFactId: instrumentIdByFactId,
          )?.status ==
          InstrumentStatus.rejected,
    )) {
      return const [];
    }
    MovementFact? direction(Direction direction) {
      for (final pair in movements) {
        if (pair.$2.direction == direction) return pair.$2;
      }
      return null;
    }

    final debit = direction(Direction.debit);
    final credit = direction(Direction.credit);
    final inward =
        incomeEventTypes.contains(event.type) ||
        event.type == EventType.refund ||
        event.type == EventType.investmentWithdrawal;
    final anchor = (inward ? credit : debit) ?? movements.first.$2;
    final posted = anchor.amounts
        .where((a) => a.role == AmountRole.posted)
        .firstOrNull;
    if (posted == null || posted.unit != 'INR' || posted.minor <= 0) {
      return const [];
    }
    LedgerEndpoint own(Fact? fact, InstrumentKind fallback) {
      final instrument = fact == null
          ? null
          : instrumentForFact(
              fact,
              instrumentsById,
              instrumentIdByFactId: instrumentIdByFactId,
            );
      return instrument == null
          ? OwnUnresolvedEndpoint(fact?.instrument?.kind ?? fallback)
          : InstrumentEndpoint(instrument.instrumentId);
    }

    final key =
        keyer.keyFor(anchor.counterparty) ??
        keyer.personRuleKey(anchor.counterparty) ??
        normalizeMerchantText(
          anchor.counterparty?.name ?? anchor.counterparty?.vpa ?? 'UNKNOWN',
        );
    final external = ExternalEndpoint(key.isEmpty ? 'UNKNOWN' : key);
    final transfer = ownTransferEventTypes.contains(event.type);
    final spend = spendEventTypes.contains(event.type);
    final investment =
        event.type == EventType.investment ||
        event.type == EventType.ipoApplication ||
        event.type == EventType.investmentWithdrawal;
    final fallbackTarget = event.type == EventType.cardBillPayment
        ? InstrumentKind.creditCard
        : event.type == EventType.walletTopup
        ? InstrumentKind.wallet
        : InstrumentKind.bankAccount;
    Instrument? uniqueTarget(InstrumentKind kind) {
      final name = normalizeMerchantText(anchor.counterparty?.name ?? '');
      final mask = anchor.counterparty?.accountMask;
      final matches = instrumentsById.values
          .where(
            (i) =>
                i.kind == kind &&
                i.status != InstrumentStatus.rejected &&
                (mask != null
                    ? i.maskDigits == mask
                    : name.isNotEmpty &&
                          {
                            normalizeMerchantText(i.issuerSlug),
                            normalizeMerchantText(i.displayName),
                            ...i.aliases.productNames.map(
                              normalizeMerchantText,
                            ),
                          }.contains(name)),
          )
          .toList();
      return matches.length == 1 ? matches.single : null;
    }

    final broker = investment ? uniqueTarget(InstrumentKind.broker) : null;
    final destination = transfer && credit == null
        ? uniqueTarget(fallbackTarget)
        : null;
    final from = transfer
        ? own(debit, InstrumentKind.bankAccount)
        : inward
        ? broker == null
              ? external
              : InstrumentEndpoint(broker.instrumentId)
        : own(anchor, InstrumentKind.bankAccount);
    final to = transfer
        ? destination == null
              ? own(credit, fallbackTarget)
              : InstrumentEndpoint(destination.instrumentId)
        : inward
        ? own(anchor, InstrumentKind.bankAccount)
        : broker == null
        ? external
        : InstrumentEndpoint(broker.instrumentId);
    final amount = event.type == EventType.ipoApplication
        ? movements
              .where(
                (pair) =>
                    pair.$1.role == LegRole.debitLeg &&
                    pair.$2.direction == Direction.debit,
              )
              .expand((pair) => pair.$2.amounts)
              .where((a) => a.role == AmountRole.posted && a.unit == 'INR')
              .fold<int>(0, (sum, a) => sum + a.minor)
        : posted.minor;
    final decision =
        category ??
        const CategoryDecision(
          slug: 'other',
          source: CategorySource.fallback,
          confidence: 0,
        );
    return [
      LedgerEntry(
        entryId: sha256.convert(utf8.encode('${event.eventId}|0')).toString(),
        eventId: event.eventId,
        from: from,
        to: to,
        amountMinor: amount,
        unit: LedgerUnit.inr,
        occurredAt: event.occurredAt,
        category: spend ? decision.slug : null,
        categorySource: spend ? decision.source : null,
        countsAsTransaction: !transfer,
        isSpend: spend,
        isIncome: incomeEventTypes.contains(event.type),
        isInvestment: investment,
      ),
    ];
  }

  /// Periods are half-open [from, to). Keep out-of-period purchase entries in
  /// [entries] so a later refund retains its original category.
  @override
  Totals totals(
    Iterable<LedgerEntry> entries,
    Iterable<Event> events,
    DateTime from,
    DateTime to,
  ) {
    if (to.isBefore(from)) throw ArgumentError('to precedes from');
    final byId = {for (final e in entries) e.entryId: e};
    final eventsById = {for (final e in events) e.eventId: e};
    final purchaseByFact = <String, String>{};
    for (final e in eventsById.values) {
      if (!spendEventTypes.contains(e.type)) continue;
      for (final l in e.legs) {
        if (moneyLegRoles.contains(l.role)) {
          purchaseByFact[l.factId] = e.eventId;
        }
      }
    }
    final categories = <String, String>{
      for (final e in byId.values)
        if (e.category != null) e.eventId: e.category!,
    };
    var spend = 0, refunds = 0, income = 0, investment = 0;
    final counts = <String>{};
    final byCategory = <String, int>{};
    for (final row in byId.values) {
      final event = eventsById[row.eventId];
      if (event == null ||
          event.status == EventStatus.ambiguous ||
          event.type == EventType.unknown ||
          row.unit != LedgerUnit.inr ||
          row.occurredAt.isBefore(from) ||
          !row.occurredAt.isBefore(to)) {
        continue;
      }
      if (row.countsAsTransaction) counts.add(row.eventId);
      if (row.isSpend) {
        spend += row.amountMinor;
        byCategory.update(
          row.category ?? 'other',
          (v) => v + row.amountMinor,
          ifAbsent: () => row.amountMinor,
        );
      }
      if (event.type == EventType.refund) {
        refunds += row.amountMinor;
        spend -= row.amountMinor;
        String? category;
        for (final l in event.legs) {
          if (l.role == LegRole.original) {
            category = categories[purchaseByFact[l.factId]];
          }
          if (category != null) break;
        }
        category ??= categoryByEvent[event.eventId]?.slug ?? 'other';
        byCategory.update(
          category,
          (v) => v - row.amountMinor,
          ifAbsent: () => -row.amountMinor,
        );
      }
      if (row.isIncome) income += row.amountMinor;
      if (row.isInvestment) {
        investment += event.type == EventType.investmentWithdrawal
            ? -row.amountMinor
            : row.amountMinor;
      }
    }
    return Totals(
      spendMinor: spend,
      refundMinor: refunds,
      incomeMinor: income,
      investmentMinor: investment,
      transactionCount: counts.length,
      byCategory: Map.unmodifiable(byCategory),
    );
  }
}
