import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../../../data/spend_reports_repository.dart';
import '../../../data/spending_selection.dart';
import '../../../data/spend_by_category_repository.dart';
import '../../../data/user_cards_repository.dart';

/// Adapts existing manual/email/unreplayed rows into the same ledger math.
/// This is compatibility data conversion, not another totals implementation.
class LedgerReadModel {
  LedgerReadModel({
    required this.ledger,
    this.transactions = const [],
    this.facts = const [],
    this.instruments = const [],
    this.v2Ready = true,
  });
  final bool v2Ready;
  final LedgerSnapshot ledger;
  final List<TransactionEntry> transactions;
  final List<v2.Fact> facts;
  final List<v2.Instrument> instruments;

  late final transactionIdByEvent = Map<String, String>.unmodifiable({
    for (final row in transactions)
      if (row.eventId != null && row.status == 'active') row.eventId!: row.id,
  });

  /// Facts by id / by source message, built once per model instead of once
  /// per consumer rebuild (the review list used to rebuild both every time).
  late final Map<String, v2.Fact> factsById = Map.unmodifiable({
    for (final fact in facts) fact.factId: fact,
  });
  late final Map<String, List<v2.Fact>> factsBySource = () {
    final out = <String, List<v2.Fact>>{};
    for (final fact in facts) {
      (out[fact.sourceKey] ??= <v2.Fact>[]).add(fact);
    }
    return Map<String, List<v2.Fact>>.unmodifiable(out);
  }();

  /// True when [other] holds exactly the same rows. Rows the loader reused
  /// from its decode cache are the same instances, so an unchanged model
  /// compares in one pointer check per row (the row types' `==` is a deep
  /// JSON comparison and is deliberately not used). A false answer only
  /// means "possibly different", never "equal".
  bool sameContentAs(LedgerReadModel other) =>
      identical(this, other) ||
      (v2Ready == other.v2Ready &&
          _sameInstances(ledger.entries, other.ledger.entries) &&
          _sameInstances(ledger.events, other.ledger.events) &&
          _sameInstances(facts, other.facts) &&
          _sameInstances(instruments, other.instruments) &&
          _sameInstances(transactions, other.transactions) &&
          _sameDecisions(
            ledger.categoryByEvent,
            other.ledger.categoryByEvent,
          ));

  static bool _sameInstances(List<Object> a, List<Object> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _sameDecisions(
    Map<String, v2.CategoryDecision> a,
    Map<String, v2.CategoryDecision> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || !identical(other, entry.value)) return false;
    }
    return true;
  }

  // snapshot() with no selection is a pure function of this immutable model,
  // and every report, total, home summary and review list asks for it.
  late final LedgerSnapshot _fullSnapshot = _buildSnapshot(null);

  LedgerSnapshot snapshot({Iterable<TransactionEntry>? selected}) =>
      selected == null ? _fullSnapshot : _buildSnapshot(selected);

  LedgerSnapshot _buildSnapshot(Iterable<TransactionEntry>? selected) {
    final rows = (selected ?? transactions)
        .where((r) => r.status == 'active')
        .toList();
    final visible = rows.map((r) => r.eventId).whereType<String>().toSet();
    final inactive = transactions
        .where((r) => r.status != 'active')
        .map((r) => r.eventId)
        .whereType<String>()
        .toSet();
    final events = {
      for (final e in ledger.events)
        if (!inactive.contains(e.eventId) &&
            (selected == null || visible.contains(e.eventId)))
          e.eventId: e,
    };
    final entries = {
      for (final e in ledger.entries)
        if (events.containsKey(e.eventId)) e.entryId: e,
    };
    final categories = {...ledger.categoryByEvent};
    for (final row in rows) {
      if (row.eventId != null && events.containsKey(row.eventId)) continue;
      final kind = switch (row.entryKind) {
        TxnEntryKind.spend => v2.EventType.purchase,
        TxnEntryKind.income => v2.EventType.income,
        TxnEntryKind.investment => v2.EventType.investment,
        TxnEntryKind.refund => v2.EventType.refund,
        TxnEntryKind.transfer => v2.EventType.ownTransfer,
        TxnEntryKind.unknown => v2.EventType.unknown,
      };
      if (kind == v2.EventType.unknown || row.amount.paise <= 0) continue;
      final id =
          row.eventId ??
          sha256.convert(utf8.encode('legacy|${row.id}')).toString();
      final event = v2.Event(
        eventId: id,
        type: kind,
        status: v2.EventStatus.complete,
        legs: [
          v2.EventLeg(
            factId: id,
            role: kind == v2.EventType.refund
                ? v2.LegRole.reversal
                : v2.LegRole.debitLeg,
          ),
        ],
        confidence: 1,
        occurredAt: row.occurredAt,
        amountMinor: row.amount.paise,
      );
      events[id] = event;
      final name = row.categoryName?.toLowerCase();
      final slug =
          TaxonomyRegistry.v1.categories
              .where(
                (c) => c.displayName.toLowerCase() == name || c.slug == name,
              )
              .firstOrNull
              ?.slug ??
          'other';
      categories[id] = v2.CategoryDecision(
        slug: slug,
        source: v2.CategorySource.user,
        confidence: 1,
      );
      const own = v2.OwnUnresolvedEndpoint(v2.InstrumentKind.bankAccount);
      final outside = v2.ExternalEndpoint(
        normalizeMerchantText(row.merchantName ?? 'UNKNOWN'),
      );
      final incoming =
          kind == v2.EventType.income || kind == v2.EventType.refund;
      final entry = v2.LedgerEntry(
        entryId: sha256.convert(utf8.encode('$id|0')).toString(),
        eventId: id,
        from: incoming ? outside : own,
        to: incoming || kind == v2.EventType.ownTransfer ? own : outside,
        amountMinor: row.amount.paise,
        unit: v2.LedgerUnit.inr,
        occurredAt: row.occurredAt,
        category: kind == v2.EventType.purchase ? slug : null,
        categorySource: kind == v2.EventType.purchase
            ? v2.CategorySource.user
            : null,
        countsAsTransaction: kind != v2.EventType.ownTransfer,
        isSpend: kind == v2.EventType.purchase,
        isIncome: kind == v2.EventType.income,
        isInvestment: kind == v2.EventType.investment,
      );
      entries[entry.entryId] = entry;
    }
    return LedgerSnapshot(
      entries: entries.values,
      events: events.values,
      categoryByEvent: categories,
    );
  }

  late final _merchantByEvent = {
    for (final entry in ledger.entries)
      if (entry.isSpend || entry.from is v2.ExternalEndpoint)
        entry.eventId: _ledgerMerchantKey(entry),
  };

  String merchantKeyForTransaction(TransactionEntry row) =>
      _merchantByEvent[row.eventId] ??
      normalizeMerchantText(row.merchantName ?? 'UNKNOWN');

  static String _ledgerMerchantKey(v2.LedgerEntry entry) {
    final endpoint = entry.to is v2.ExternalEndpoint ? entry.to : entry.from;
    return endpoint is v2.ExternalEndpoint
        ? endpoint.counterpartyKey
        : 'UNKNOWN';
  }

  v2.Totals totalsForTransactions(Iterable<TransactionEntry> selected) =>
      snapshot(
        selected: selected,
      ).totals(DateTime.utc(1900), DateTime.utc(9999));

  SpendReport spendReport(
    SpendReportQuery query,
    DateTime now, {
    List<BankAccountSummary> bankAccounts = const [],
    bool monthlySeries = false,
  }) {
    final (from, to) = reportBounds(query, now);
    final (previousFrom, previousTo) = query.isCustom
        ? (from.subtract(to.difference(from)), from)
        : reportBounds(query, DateTime(from.year, from.month, from.day - 1));
    final state = snapshot();
    final totals = state.totals(from, to);
    final previous = state.totals(previousFrom, previousTo);
    final events = {for (final e in state.events) e.eventId: e};
    final display = {
      for (final r in transactions)
        (r.eventId ?? sha256.convert(utf8.encode('legacy|${r.id}')).toString()):
            r,
    };
    final current = state.entries
        .where((e) => !e.occurredAt.isBefore(from) && e.occurredAt.isBefore(to))
        .toList();
    final spend = current
        .where(
          (e) => e.isSpend || events[e.eventId]?.type == v2.EventType.refund,
        )
        .toList();
    v2.Totals groupTotals(Iterable<v2.LedgerEntry> entries) => LedgerSnapshot(
      entries: entries,
      events: state.events,
      categoryByEvent: state.categoryByEvent,
    ).totals(from, to);
    Map<String, List<v2.LedgerEntry>> groups(
      String Function(v2.LedgerEntry) key,
    ) {
      final out = <String, List<v2.LedgerEntry>>{};
      for (final e in spend) {
        out.putIfAbsent(key(e), () => []).add(e);
      }
      return out;
    }

    Money rewards(Iterable<v2.LedgerEntry> entries) {
      final ids = entries.where((e) => e.isSpend).map((e) => e.eventId).toSet();
      return Money.fromPaise(
        ids.fold(0, (sum, id) => sum + (display[id]?.rewardValue?.paise ?? 0)),
      );
    }

    String category(v2.LedgerEntry e) =>
        e.category ?? state.categoryByEvent[e.eventId]?.slug ?? 'other';
    String instrument(v2.LedgerEntry e) {
      final row = display[e.eventId];
      return (row == null
              ? TxnInstrument.other
              : SpendingSelection.effectiveInstrument(row))
          .wireValue;
    }

    String sourceName(v2.LedgerEntry e) {
      final row = display[e.eventId];
      return row == null
          ? 'Unknown source'
          : SpendingSelection.sourceName(row, bankAccounts: bankAccounts);
    }

    String card(v2.LedgerEntry e) =>
        display[e.eventId]?.userCardId ?? 'source:${sourceName(e)}';
    final categories = groups(category),
        merchants = groups(_ledgerMerchantKey),
        cards = groups(card),
        methods = groups(instrument);
    final cardCategories = groups((e) => '${card(e)}|${category(e)}');
    EntryKindTotals kindTotal(
      int amount,
      bool Function(v2.LedgerEntry) match,
    ) => EntryKindTotals(
      total: Money.fromPaise(amount),
      txnCount: current.where(match).map((e) => e.eventId).toSet().length,
      rewards: rewards(current.where(match)),
    );
    final byCategory = [
      for (final g in categories.entries)
        SpendBreakdownRow(
          label: TaxonomyRegistry.v1.categoryFor(g.key)?.displayName ?? 'Other',
          categoryId: display[g.value.first.eventId]?.categoryId,
          total: Money.fromPaise(groupTotals(g.value).spendMinor),
          txnCount: g.value.map((e) => e.eventId).toSet().length,
        ),
    ]..sort((a, b) => b.total.paise.compareTo(a.total.paise));
    final byMonth =
        monthlySeries ||
        query.period == SpendPeriod.year ||
        query.period == SpendPeriod.quarter;
    DateTime bucket(DateTime date) {
      final local = date.toLocal();
      return DateTime(local.year, local.month, byMonth ? 1 : local.day);
    }

    final byDate = groups((e) => bucket(e.occurredAt).toIso8601String());
    final points = <SpendSeriesPoint>[];
    for (
      var date = bucket(from);
      date.isBefore(to);
      date = byMonth
          ? DateTime(date.year, date.month + 1)
          : DateTime(date.year, date.month, date.day + 1)
    ) {
      final es = byDate[date.toIso8601String()] ?? const <v2.LedgerEntry>[];
      points.add(
        SpendSeriesPoint(
          periodStart: date,
          spend: Money.fromPaise(groupTotals(es).spendMinor),
          rewards: rewards(es),
          txnCount: es.map((e) => e.eventId).toSet().length,
        ),
      );
    }
    return SpendReport(
      period: query.period,
      periodStart: from,
      periodEnd: to,
      elapsedFraction:
          (now.difference(from).inMicroseconds /
                  to.difference(from).inMicroseconds)
              .clamp(0, 1)
              .toDouble(),
      spend: kindTotal(
        totals.spendMinor,
        (e) => e.isSpend || events[e.eventId]?.type == v2.EventType.refund,
      ),
      income: kindTotal(totals.incomeMinor, (e) => e.isIncome),
      investment: kindTotal(totals.investmentMinor, (e) => e.isInvestment),
      previousSpend: EntryKindTotals(
        total: Money.fromPaise(previous.spendMinor),
        txnCount: state.entries
            .where(
              (e) =>
                  (e.isSpend ||
                      events[e.eventId]?.type == v2.EventType.refund) &&
                  !e.occurredAt.isBefore(previousFrom) &&
                  e.occurredAt.isBefore(previousTo),
            )
            .map((e) => e.eventId)
            .toSet()
            .length,
        rewards: const Money.zero(),
      ),
      byCategory: byCategory,
      byMerchant: [
        for (final g in merchants.entries)
          SpendBreakdownRow(
            label: g.key,
            total: Money.fromPaise(groupTotals(g.value).spendMinor),
            txnCount: g.value.map((e) => e.eventId).toSet().length,
          ),
      ],
      byCard: [
        for (final g in cards.entries)
          CardSpendRow(
            cardId: display[g.value.first.eventId]?.userCardId,
            cardName: sourceName(g.value.first),
            total: Money.fromPaise(groupTotals(g.value).spendMinor),
            rewards: rewards(g.value),
            txnCount: g.value.map((e) => e.eventId).toSet().length,
          ),
      ],
      byInstrument: [
        for (final g in methods.entries)
          InstrumentSpendRow(
            instrument: g.key,
            total: Money.fromPaise(groupTotals(g.value).spendMinor),
            txnCount: g.value.map((e) => e.eventId).toSet().length,
          ),
      ],
      byCardCategory: [
        for (final g in cardCategories.values)
          CardCategorySpendRow(
            cardId: display[g.first.eventId]?.userCardId,
            cardName: sourceName(g.first),
            categoryId: display[g.first.eventId]?.categoryId,
            categoryName:
                TaxonomyRegistry.v1
                    .categoryFor(category(g.first))
                    ?.displayName ??
                'Other',
            total: Money.fromPaise(groupTotals(g).spendMinor),
            txnCount: g.map((e) => e.eventId).toSet().length,
          ),
      ],
      series: points,
    );
  }

  List<CategorySpend> categorySpend(DateTime now) {
    final report = spendReport(
      SpendReportQuery.custom(
        from: DateTime(now.year, now.month - 11),
        to: now,
      ),
      now,
    );
    return [
      for (final row in report.byCategory)
        CategorySpend(
          categoryId: row.categoryId,
          categorySlug: TaxonomyRegistry.v1.categories
              .where((c) => c.displayName == row.label)
              .firstOrNull
              ?.slug,
          categoryName: row.label,
          totalSpend: row.total,
          txnCount: row.txnCount,
        ),
    ];
  }

  HomeSummary homeSummary(DateTime now) {
    final all = snapshot();
    final counts = all.totals(DateTime.utc(1900), DateTime.utc(9999));
    final spendIds = all.entries
        .where((e) => e.isSpend)
        .map((e) => e.eventId)
        .toSet();
    var month = 0, total = 0;
    for (final row in transactions.where(
      (r) => r.status == 'active' && r.entryKind == TxnEntryKind.spend,
    )) {
      final id =
          row.eventId ??
          sha256.convert(utf8.encode('legacy|${row.id}')).toString();
      if (!spendIds.contains(id)) continue;
      total += row.rewardValue?.paise ?? 0;
      if (row.occurredAt.year == now.year &&
          row.occurredAt.month == now.month) {
        month += row.rewardValue?.paise ?? 0;
      }
    }
    return HomeSummary(
      rewardsThisMonth: Money.fromPaise(month),
      rewardsAllTime: Money.fromPaise(total),
      transactionCount: counts.transactionCount,
      streakDays: _streak(all, now),
    );
  }

  int _streak(LedgerSnapshot state, DateTime now) {
    final counted = state.entries
        .where((e) => e.countsAsTransaction)
        .map((e) => e.eventId)
        .toSet();
    final dates = {
      for (final event in state.events)
        if (counted.contains(event.eventId))
          DateTime(
            event.occurredAt.toLocal().year,
            event.occurredAt.toLocal().month,
            event.occurredAt.toLocal().day,
          ),
    };
    var day = DateTime(now.year, now.month, now.day), count = 0;
    if (!dates.contains(day)) day = DateTime(day.year, day.month, day.day - 1);
    while (dates.contains(day)) {
      count++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return count;
  }
}

(DateTime, DateTime) reportBounds(SpendReportQuery query, DateTime now) {
  if (query.isCustom) {
    return (
      DateTime(query.from!.year, query.from!.month, query.from!.day),
      DateTime(query.to!.year, query.to!.month, query.to!.day + 1),
    );
  }
  return switch (query.period) {
    SpendPeriod.week => (
      DateTime(now.year, now.month, now.day - now.weekday + 1),
      DateTime(now.year, now.month, now.day - now.weekday + 8),
    ),
    SpendPeriod.month => (
      DateTime(now.year, now.month),
      DateTime(now.year, now.month + 1),
    ),
    SpendPeriod.quarter => (
      DateTime(now.year, ((now.month - 1) ~/ 3) * 3 + 1),
      DateTime(now.year, ((now.month - 1) ~/ 3) * 3 + 4),
    ),
    SpendPeriod.year => (DateTime(now.year), DateTime(now.year + 1)),
    SpendPeriod.custom => throw ArgumentError('custom range requires dates'),
  };
}
