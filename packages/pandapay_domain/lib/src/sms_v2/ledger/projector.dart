import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../contract/enums.dart';
import '../contract/event.dart';
import '../contract/fact.dart';
import '../contract/instrument.dart';
import '../contract/interfaces.dart';
import '../contract/ledger_entry.dart';
import '../instruments/instrument_resolver.dart' show instrumentByNumberOnly, rejectedByNumberOnly;
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
  // Money coming back from an investment is its own kind. It is neither a
  // transfer (it leaves no pair to match) nor income (it is mostly the
  // user's own principal), so it shows as "Investment return" and lands in
  // Money in without touching earned income.
  if (event.type == EventType.investmentWithdrawal) return 'investment_return';
  if (ownTransferEventTypes.contains(event.type)) return 'transfer';
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
  if (m == null) return null;
  // A notice that names no bank points at an account by its number alone.
  if (m.issuerSlug == null) {
    // A live account wins. When the only matches are rejected ones, return the
    // rejected account so the caller hides the movement instead of counting it
    // to an account nobody can name.
    return instrumentByNumberOnly(m.kind, m.maskDigits, instruments.values) ??
        rejectedByNumberOnly(m.kind, m.maskDigits, instruments.values);
  }
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
/// A refund row carries the category of the purchase it reverses (CCR-003),
/// so another device reads the same category from the synced row. A linked
/// refund takes the purchase's decision; an unlinked refund takes the decision
/// LedgerSnapshot resolved for it, falling back to `other`. Rows written before
/// CCR-003 have no category; [categoryByEvent] still covers them in totals.
class DefaultLedgerProjector implements LedgerProjector {
  DefaultLedgerProjector({
    Map<String, CategoryDecision> categoryByEvent = const {},
    Map<String, String> instrumentIdByFactId = const {},
    MerchantKeyer? keyer,
    Set<String> excludedEventIds = const {},
  }) : categoryByEvent = Map.unmodifiable(categoryByEvent),
       instrumentIdByFactId = Map.unmodifiable(instrumentIdByFactId),
       excludedEventIds = Set.unmodifiable(excludedEventIds),
       keyer = keyer ?? MerchantKeyer();

  /// Events the person chose not to count in their spending, together with any
  /// refund of one of them. Their spend moves to `excludedSpendMinor`: out of
  /// spending and budgets, still in Money out.
  final Set<String> excludedEventIds;
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
    final refund = event.type == EventType.refund;
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
                (anchor.provenance.engine != Engine.user ||
                    name.isEmpty ||
                    name == normalizeMerchantText(i.issuerSlug) ||
                    name == normalizeMerchantText(i.displayName)) &&
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

    /// A card bill paid through a bill-pay app: the app's receipt names the card
    /// ("Your <issuer> credit card ending 1234 bill ... has been paid"), though
    /// the bank debit only names the app. The receipt joined the event as a
    /// `duplicate_notice`; it picks the destination card when exactly one card
    /// fits its number (and its issuer name, when two cards share the digits).
    Instrument? receiptCard() {
      if (event.type != EventType.cardBillPayment) return null;
      for (final leg in event.legs) {
        if (leg.role != LegRole.duplicateNotice) continue;
        final receipt = factsById[leg.factId];
        if (receipt is! MovementFact ||
            receipt.evidenceOnly != true ||
            receipt.purpose != MovementPurpose.cardPayment) {
          continue;
        }
        final mask = receipt.counterparty?.accountMask;
        if (mask == null || mask.isEmpty) continue;
        final name = normalizeMerchantText(receipt.counterparty?.name ?? '');
        final cards = instrumentsById.values
            .where(
              (i) =>
                  i.kind == InstrumentKind.creditCard &&
                  i.status != InstrumentStatus.rejected &&
                  i.maskDigits == mask,
            )
            .toList();
        if (cards.length == 1 && name.isEmpty) return cards.single;
        final named = cards
            .where(
              (i) => name.contains(normalizeMerchantText(i.issuerSlug)),
            )
            .toList();
        if (named.length == 1) return named.single;
      }
      return null;
    }

    final broker = investment ? uniqueTarget(InstrumentKind.broker) : null;
    final destination = transfer && credit == null
        ? uniqueTarget(fallbackTarget) ?? receiptCard()
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
        category: spend || refund ? decision.slug : null,
        categorySource: spend || refund ? decision.source : null,
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
    var investmentOut = 0, investmentReturn = 0, excludedSpend = 0;
    var returns = 0, fromPeople = 0, cardBills = 0, transfers = 0;
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
      final leftOut = excludedEventIds.contains(row.eventId);
      if (row.isSpend && leftOut) {
        excludedSpend += row.amountMinor;
      } else if (row.isSpend) {
        spend += row.amountMinor;
        byCategory.update(
          row.category ?? 'other',
          (v) => v + row.amountMinor,
          ifAbsent: () => row.amountMinor,
        );
      }
      if (event.type == EventType.refund && leftOut) {
        // A refund of something left out of spending comes off that same
        // amount, so neither spending nor a category goes negative for it.
        refunds += row.amountMinor;
        excludedSpend -= row.amountMinor;
      } else if (event.type == EventType.refund) {
        refunds += row.amountMinor;
        spend -= row.amountMinor;
        String? category;
        for (final l in event.legs) {
          if (l.role == LegRole.original) {
            category = categories[purchaseByFact[l.factId]];
          }
          if (category != null) break;
        }
        // Purchase entry first, so a corrected purchase category is followed
        // live; then the refund row's own category (CCR-003); then explicit
        // context for rows written before CCR-003; then `other`.
        category ??=
            row.category ?? categoryByEvent[event.eventId]?.slug ?? 'other';
        byCategory.update(
          category,
          (v) => v - row.amountMinor,
          ifAbsent: () => -row.amountMinor,
        );
      }
      if (row.isIncome) income += row.amountMinor;
      switch (event.type) {
        case EventType.dividend:
          returns += row.amountMinor;
        case EventType.p2pIn:
          fromPeople += row.amountMinor;
        case EventType.cardBillPayment:
          cardBills += row.amountMinor;
        case EventType.ownTransfer || EventType.walletTopup:
          transfers += row.amountMinor;
        default:
      }
      if (row.isInvestment) {
        if (event.type == EventType.investmentWithdrawal) {
          investment -= row.amountMinor;
          investmentReturn += row.amountMinor;
        } else {
          investment += row.amountMinor;
          investmentOut += row.amountMinor;
        }
      }
    }
    return Totals(
      spendMinor: spend,
      refundMinor: refunds,
      incomeMinor: income,
      investmentMinor: investment,
      investmentOutMinor: investmentOut,
      investmentReturnMinor: investmentReturn,
      excludedSpendMinor: excludedSpend,
      withdrawnMinor: investmentReturn,
      investmentReturnsMinor: returns,
      fromPeopleMinor: fromPeople,
      cardBillsPaidMinor: cardBills,
      transfersMinor: transfers,
      transactionCount: counts.length,
      byCategory: Map.unmodifiable(byCategory),
    );
  }
}
