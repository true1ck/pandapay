import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

import 'api_exception.dart';

double _num(dynamic v) =>
    v == null ? 0 : (v is num ? v.toDouble() : double.parse(v as String));
Money _money(dynamic v) => Money.fromRupees(_num(v));

/// The period a spend report covers.
///
/// Four, not an arbitrary date range: each answers a question people
/// actually ask ("what did I spend this week / this month / this quarter /
/// this year"), and every one of them has a natural previous period to
/// compare against. An arbitrary range has no meaningful "previous", which
/// is what makes the comparison — the part that turns a number into
/// information — impossible.
enum SpendPeriod {
  week('week', 'This week', 'Last week'),
  month('month', 'This month', 'Last month'),
  quarter('quarter', 'This quarter', 'Last quarter'),
  year('year', 'This year', 'Last year'),
  custom('custom', 'Custom dates', 'Previous period');

  final String wireValue;
  final String label;
  final String previousLabel;
  const SpendPeriod(this.wireValue, this.label, this.previousLabel);
}

/// The selected range for the Spending screen.
///
/// Presets keep their existing server-side calendar semantics. A custom
/// selection is date-only and inclusive at the UI boundary; the API turns it
/// into a half-open range so transactions on the selected end date are kept.
class SpendReportQuery {
  final SpendPeriod period;
  final DateTime? from;
  final DateTime? to;

  const SpendReportQuery.preset(this.period) : from = null, to = null;

  const SpendReportQuery.custom({required this.from, required this.to})
    : period = SpendPeriod.custom;

  bool get isCustom => period == SpendPeriod.custom;

  String get cacheKey {
    if (!isCustom) return period.wireValue;
    return '${period.wireValue}:${_dateOnly(from!)}:${_dateOnly(to!)}';
  }

  String get shortLabel {
    if (!isCustom) return period.label;
    return '${_shortDate(from!)} – ${_shortDate(to!)}';
  }

  @override
  bool operator ==(Object other) =>
      other is SpendReportQuery &&
      other.period == period &&
      _sameDay(other.from, from) &&
      _sameDay(other.to, to);

  @override
  int get hashCode => Object.hash(period, _dateOnly(from), _dateOnly(to));
}

String _dateOnly(DateTime? date) => date == null
    ? ''
    : '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';

bool _sameDay(DateTime? a, DateTime? b) =>
    a == null && b == null ||
    a != null && b != null && _dateOnly(a) == _dateOnly(b);

String _shortDate(DateTime date) {
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}';
}

/// Totals for one entry kind. Spend, income and investment are carried
/// SEPARATELY and never summed together — an investment is not spending,
/// and folding it into a spend total is the fastest way to make every
/// budget figure meaningless.
class EntryKindTotals {
  final Money total;
  final int txnCount;
  final Money rewards;

  const EntryKindTotals({
    required this.total,
    required this.txnCount,
    required this.rewards,
  });

  static const zero = EntryKindTotals(
    total: Money.zero(),
    txnCount: 0,
    rewards: Money.zero(),
  );

  factory EntryKindTotals.fromJson(Map<String, dynamic>? json) {
    if (json == null) return zero;
    return EntryKindTotals(
      total: _money(json['totalInr']),
      txnCount: (json['txnCount'] as num?)?.toInt() ?? 0,
      rewards: _money(json['rewardsInr']),
    );
  }
}

/// One row of a category or merchant breakdown.
class SpendBreakdownRow {
  final String label;
  final Money total;
  final int txnCount;
  final String? categoryId;

  const SpendBreakdownRow({
    required this.label,
    required this.total,
    required this.txnCount,
    this.categoryId,
  });
}

/// One payment source's contribution to a period (saved card, bank account,
/// wallet, cash, or an unclassified source).
class CardSpendRow {
  /// Null for sources that are not a saved card. Non-card spend remains in
  /// the breakdown so it reconciles with the headline total.
  final String? cardId;
  final String cardName;
  final Money total;
  final Money rewards;
  final int txnCount;
  final Money? annualFee;

  /// `rewards / spend` over the period — what the card ACTUALLY paid, not
  /// the rate it advertises. This is the number that answers "is the annual
  /// fee worth it": a 5% headline card capped at ₹3,000/month against
  /// ₹40,000 of spend has an effective rate near 1%.
  ///
  /// Null when nothing was spent on the card: "no data" and "earned nothing
  /// on what you spent" are different statements, and showing 0% for the
  /// first would libel a perfectly good card.
  final double? effectiveRatePerRupee;

  const CardSpendRow({
    required this.cardId,
    required this.cardName,
    required this.total,
    required this.rewards,
    required this.txnCount,
    this.annualFee,
    this.effectiveRatePerRupee,
  });

  /// Rewards minus the annual fee, annualised nowhere — this is the
  /// period's own net. Null when the card has no fee on record, since
  /// "fee unknown" must not read as "fee is zero".
  Money? get netOfFee => annualFee == null ? null : rewards - annualFee!;
}

/// One payment-method contribution to a period, independent of funding source.
class InstrumentSpendRow {
  final String instrument;
  final Money total;
  final int txnCount;

  const InstrumentSpendRow({
    required this.instrument,
    required this.total,
    required this.txnCount,
  });

  String get label => switch (instrument) {
    'credit_card' => 'Credit cards',
    'debit_card' => 'Debit cards',
    'upi_bank' => 'UPI from bank account',
    'cash' => 'Cash',
    'wallet' => 'Wallets',
    _ => 'Other or unknown payment method',
  };
}

/// Spend split by both the payment method/card and category.
class CardCategorySpendRow {
  final String? cardId;
  final String cardName;
  final String? categoryId;
  final String categoryName;
  final Money total;
  final int txnCount;

  const CardCategorySpendRow({
    this.cardId,
    required this.cardName,
    this.categoryId,
    required this.categoryName,
    required this.total,
    required this.txnCount,
  });
}

/// One point on the trend chart.
class SpendSeriesPoint {
  final DateTime periodStart;
  final Money spend;
  final Money rewards;
  final int txnCount;

  const SpendSeriesPoint({
    required this.periodStart,
    required this.spend,
    required this.rewards,
    required this.txnCount,
  });
}

/// Everything the Trends screen shows, fetched in one round trip.
///
/// One request rather than five, because every figure here has to agree
/// with every other one: a category breakdown fetched a second after the
/// headline total, with a transaction landing in between, produces a screen
/// whose parts visibly contradict each other.
class SpendReport {
  final SpendPeriod period;
  final DateTime periodStart;
  final DateTime periodEnd;

  /// How far through the period we are, 0..1. Without it a percentage is
  /// just anxiety: 60% of a month's spend is alarming on day 3 and
  /// unremarkable on day 25.
  final double elapsedFraction;

  final EntryKindTotals spend;
  final EntryKindTotals income;
  final EntryKindTotals investment;
  final EntryKindTotals previousSpend;

  final List<SpendBreakdownRow> byCategory;
  final List<SpendBreakdownRow> bySubcategory;
  final List<SpendBreakdownRow> byMerchant;
  final List<CardSpendRow> byCard;
  final List<InstrumentSpendRow> byInstrument;
  final List<CardCategorySpendRow> byCardCategory;
  final List<SpendSeriesPoint> series;

  const SpendReport({
    required this.period,
    required this.periodStart,
    required this.periodEnd,
    required this.elapsedFraction,
    required this.spend,
    required this.income,
    required this.investment,
    required this.previousSpend,
    required this.byCategory,
    this.bySubcategory = const [],
    required this.byMerchant,
    required this.byCard,
    required this.byInstrument,
    this.byCardCategory = const [],
    required this.series,
  });

  String get displayLabel => period == SpendPeriod.custom
      ? '${_shortDate(periodStart.toLocal())} – '
            '${_shortDate(periodEnd.subtract(const Duration(days: 1)).toLocal())}'
      : period.label;

  String get previousDisplayLabel => period == SpendPeriod.custom
      ? 'previous period'
      : period.previousLabel.toLowerCase();

  /// Change against the previous period as a fraction (0.12 == +12%).
  ///
  /// Null when the previous period had no spend at all — "up 100%" from
  /// zero is arithmetically true and completely useless to read, and
  /// "infinite increase" is worse.
  double? get changeVsPrevious {
    if (previousSpend.total.isZero) return null;
    return (spend.total.paise - previousSpend.total.paise) /
        previousSpend.total.paise;
  }

  /// Spend at the current pace, extrapolated across the whole period. Null
  /// very early in a period, where dividing by a near-zero elapsed fraction
  /// produces an enormous meaningless figure.
  Money? get projectedSpend {
    if (elapsedFraction <= 0.05) return null;
    return Money.fromPaise((spend.total.paise / elapsedFraction).round());
  }

  Money get netFlow => income.total - spend.total - investment.total;

  factory SpendReport.fromJson(Map<String, dynamic> json) {
    final totals = json['totals'] as Map<String, dynamic>? ?? const {};
    final previousTotals =
        json['previousTotals'] as Map<String, dynamic>? ?? const {};
    return SpendReport(
      period: SpendPeriod.values.firstWhere(
        (p) => p.wireValue == json['period'],
        orElse: () => SpendPeriod.month,
      ),
      periodStart: DateTime.parse(json['periodStart'] as String),
      periodEnd: DateTime.parse(json['periodEnd'] as String),
      elapsedFraction: _num(json['elapsedFraction']),
      spend: EntryKindTotals.fromJson(totals['spend'] as Map<String, dynamic>?),
      income: EntryKindTotals.fromJson(
        totals['income'] as Map<String, dynamic>?,
      ),
      investment: EntryKindTotals.fromJson(
        totals['investment'] as Map<String, dynamic>?,
      ),
      previousSpend: EntryKindTotals.fromJson(
        previousTotals['spend'] as Map<String, dynamic>?,
      ),
      byCategory: ((json['byCategory'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(
            (e) => SpendBreakdownRow(
              label: _displayCategoryName(e['categoryName'] as String?),
              total: _money(e['totalInr']),
              txnCount: (e['txnCount'] as num?)?.toInt() ?? 0,
              categoryId: e['categoryId'] as String?,
            ),
          )
          .toList(),
      bySubcategory: ((json['bySubcategory'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(
            (e) => SpendBreakdownRow(
              label:
                  '${_displayCategoryName(e['categoryName'] as String?)} · ${e['subcategoryName'] as String? ?? 'Subcategory'}',
              total: _money(e['totalInr']),
              txnCount: (e['txnCount'] as num?)?.toInt() ?? 0,
              categoryId: e['subcategoryId'] as String?,
            ),
          )
          .toList(),
      byMerchant: ((json['byMerchant'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(
            (e) => SpendBreakdownRow(
              label: e['merchant'] as String? ?? 'Unknown merchant',
              total: _money(e['totalInr']),
              txnCount: (e['txnCount'] as num?)?.toInt() ?? 0,
            ),
          )
          .toList(),
      byCard: ((json['byCard'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(
            (e) => CardSpendRow(
              cardId: e['cardId'] as String?,
              cardName: e['cardName'] as String? ?? 'Unknown source',
              total: _money(e['totalInr']),
              rewards: _money(e['rewardsInr']),
              txnCount: (e['txnCount'] as num?)?.toInt() ?? 0,
              annualFee: e['annualFeeInr'] == null
                  ? null
                  : _money(e['annualFeeInr']),
              effectiveRatePerRupee: e['effectiveRatePerRupee'] == null
                  ? null
                  : _num(e['effectiveRatePerRupee']),
            ),
          )
          .toList(),
      byInstrument: ((json['byInstrument'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(
            (e) => InstrumentSpendRow(
              instrument: e['instrument'] as String? ?? 'other',
              total: _money(e['totalInr']),
              txnCount: (e['txnCount'] as num?)?.toInt() ?? 0,
            ),
          )
          .toList(),
      byCardCategory: ((json['byCardCategory'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(
            (e) => CardCategorySpendRow(
              cardId: e['cardId'] as String?,
              cardName: e['cardName'] as String? ?? 'Unknown source',
              categoryId: e['categoryId'] as String?,
              categoryName: _displayCategoryName(e['categoryName'] as String?),
              total: _money(e['totalInr']),
              txnCount: (e['txnCount'] as num?)?.toInt() ?? 0,
            ),
          )
          .toList(),
      series: ((json['series'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(
            (e) => SpendSeriesPoint(
              periodStart: DateTime.parse(e['periodStart'] as String),
              spend: _money(e['spendInr']),
              rewards: _money(e['rewardsInr']),
              txnCount: (e['txnCount'] as num?)?.toInt() ?? 0,
            ),
          )
          .toList(),
    );
  }
}

String _displayCategoryName(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (value == null ||
      value.trim().isEmpty ||
      normalized == 'uncategorized' ||
      normalized == 'unclassified') {
    return 'Other';
  }
  return value;
}

/// What a budget applies to.
enum BudgetScope {
  overall('overall', 'All spending'),
  category('category', 'A category'),
  card('card', 'One card'),
  tag('tag', 'One tag');

  final String wireValue;
  final String label;
  const BudgetScope(this.wireValue, this.label);
}

enum BudgetPeriod {
  weekly('weekly', 'Weekly'),
  monthly('monthly', 'Monthly'),
  quarterly('quarterly', 'Quarterly'),
  yearly('yearly', 'Yearly');

  final String wireValue;
  final String label;
  const BudgetPeriod(this.wireValue, this.label);
}

/// One budget with its current-period progress.
///
/// Progress arrives computed rather than as a bare limit for the client to
/// fill in: the period boundary depends on the budget's own start anchor
/// (a weekly budget starting Thursday runs Thursday to Wednesday), and
/// deriving that independently on each client is how two screens end up
/// disagreeing about whether you're over.
class BudgetStatus {
  final String id;
  final BudgetScope scope;
  final String? scopeRefId;
  final String label;
  final BudgetPeriod period;
  final Money amount;
  final Money spent;
  final int txnCount;
  final DateTime periodStart;
  final DateTime periodEnd;
  final double consumedFraction;
  final double elapsedFraction;
  final Money? projected;

  const BudgetStatus({
    required this.id,
    required this.scope,
    required this.scopeRefId,
    required this.label,
    required this.period,
    required this.amount,
    required this.spent,
    required this.txnCount,
    required this.periodStart,
    required this.periodEnd,
    required this.consumedFraction,
    required this.elapsedFraction,
    this.projected,
  });

  Money get remaining => amount - spent;
  bool get isOver => spent > amount;

  /// Spending faster than the period is passing, by enough to matter.
  ///
  /// The 5% margin stops a budget flickering into "off pace" on a single
  /// ordinary purchase — being 1% ahead on day 12 is noise, not a warning,
  /// and an alert that fires on noise gets ignored when it matters.
  bool get isOffPace => !isOver && consumedFraction > elapsedFraction + 0.05;

  factory BudgetStatus.fromJson(Map<String, dynamic> json) => BudgetStatus(
    id: json['id'] as String,
    scope: BudgetScope.values.firstWhere(
      (s) => s.wireValue == json['scope'],
      orElse: () => BudgetScope.overall,
    ),
    scopeRefId: json['scopeRefId'] as String?,
    label: json['label'] as String? ?? 'Budget',
    period: BudgetPeriod.values.firstWhere(
      (p) => p.wireValue == json['period'],
      orElse: () => BudgetPeriod.monthly,
    ),
    amount: _money(json['amountInr']),
    spent: _money(json['spentInr']),
    txnCount: (json['txnCount'] as num?)?.toInt() ?? 0,
    periodStart: DateTime.parse(json['periodStart'] as String),
    periodEnd: DateTime.parse(json['periodEnd'] as String),
    consumedFraction: _num(json['consumedFraction']),
    elapsedFraction: _num(json['elapsedFraction']),
    projected: json['projectedInr'] == null
        ? null
        : _money(json['projectedInr']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'scope': scope.wireValue,
    'scopeRefId': scopeRefId,
    'label': label,
    'period': period.wireValue,
    'amountInr': amount.rupees,
    'spentInr': spent.rupees,
    'txnCount': txnCount,
    'periodStart': periodStart.toIso8601String(),
    'periodEnd': periodEnd.toIso8601String(),
    'consumedFraction': consumedFraction,
    'elapsedFraction': elapsedFraction,
    'projectedInr': projected?.rupees,
  };
}

class SpendReportsRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  SpendReportsRepository({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<SpendReport> fetchReport({
    SpendPeriod period = SpendPeriod.month,
    DateTime? anchor,
    DateTime? from,
    DateTime? to,
    int buckets = 12,
    String? timeZone,
  }) async {
    return SpendReport.fromJson(
      await fetchReportJson(
        period: period,
        anchor: anchor,
        from: from,
        to: to,
        buckets: buckets,
        timeZone: timeZone,
      ),
    );
  }

  /// Fetches the exact aggregate response before domain parsing. The
  /// app-level offline cache stores this JSON, so a later cold launch can
  /// render the same report without downloading all transactions again.
  Future<Map<String, dynamic>> fetchReportJson({
    SpendPeriod period = SpendPeriod.month,
    DateTime? anchor,
    DateTime? from,
    DateTime? to,
    int buckets = 12,
    String? timeZone,
  }) async {
    if (period == SpendPeriod.custom && (from == null || to == null)) {
      throw ArgumentError(
        'Custom spend reports require both from and to dates',
      );
    }
    if (period != SpendPeriod.custom && (from != null || to != null)) {
      throw ArgumentError(
        'from/to dates are only valid for custom spend reports',
      );
    }
    final query = {
      'period': period.wireValue,
      'buckets': '$buckets',
      if (anchor != null) 'anchor': anchor.toIso8601String(),
      if (period == SpendPeriod.custom) ...{
        'from': _dateOnly(from),
        'to': _dateOnly(to),
      },
      if (timeZone != null && timeZone.isNotEmpty) 'tz': timeZone,
    };
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/spend-report').replace(queryParameters: query),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /spend-report failed: ${response.statusCode} ${response.body}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<BudgetStatus>> fetchBudgets() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/budgets'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /budgets failed: ${response.statusCode} ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return ((json['budgets'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(BudgetStatus.fromJson)
        .toList();
  }

  Future<void> saveBudget({
    required BudgetScope scope,
    String? scopeRefId,
    required BudgetPeriod period,
    required Money amount,
    bool rollover = false,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/budgets'),
      headers: _headers,
      body: jsonEncode({
        'scope': scope.wireValue,
        'scopeRefId': ?scopeRefId,
        'period': period.wireValue,
        'amountInr': amount.rupees,
        'rollover': rollover,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /budgets failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// The period's transactions as CSV bytes, ready to be written to a file
  /// and shared.
  ///
  /// Returned as bytes rather than a String so the UTF-8 BOM the server
  /// emits survives to disk — Excel on Windows needs it to read ₹ and
  /// non-ASCII merchant names, and a String round-trip through Dart's
  /// default encoder would drop it.
  Future<List<int>> fetchTransactionsCsv({DateTime? from, DateTime? to}) async {
    String? day(DateTime? d) => d == null
        ? null
        : '${d.year.toString().padLeft(4, '0')}-'
              '${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}';
    final query = <String, String>{'from': ?day(from), 'to': ?day(to)};
    final response = await _client.get(
      Uri.parse(
        '$apiBaseUrl/export/transactions.csv',
      ).replace(queryParameters: query.isEmpty ? null : query),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'CSV export failed: ${response.statusCode} ${response.body}',
      );
    }
    return response.bodyBytes;
  }

  Future<RecurringReport> fetchRecurring() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/recurring'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /recurring failed: ${response.statusCode} ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return RecurringReport(
      series: ((json['series'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(RecurringSeries.fromJson)
          .toList(),
      totalAnnual: _money(json['totalAnnualInr']),
    );
  }

  Future<void> createRecurring({
    required String displayName,
    required double amountInr,
    required int cadenceDays,
    required DateTime nextExpectedOn,
    String autopayStatus = 'unknown',
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/recurring'),
      headers: _headers,
      body: jsonEncode({
        'displayName': displayName,
        'typicalAmountInr': amountInr,
        'cadenceDays': cadenceDays,
        'nextExpectedOn':
            '${nextExpectedOn.year.toString().padLeft(4, '0')}-'
            '${nextExpectedOn.month.toString().padLeft(2, '0')}-'
            '${nextExpectedOn.day.toString().padLeft(2, '0')}',
        'autopayStatus': autopayStatus,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /recurring failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// "I cancelled this." Marks the series dismissed server-side so the next
  /// detection run doesn't immediately re-add it — a dismissal that lasted
  /// only until the screen was reopened would make the feature feel broken.
  Future<void> dismissRecurring(String seriesId) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/recurring/$seriesId/dismiss'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /recurring/dismiss failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  Future<void> updateRecurring(
    String seriesId, {
    required String displayName,
    required double amountInr,
    required int cadenceDays,
    required DateTime nextExpectedOn,
    required String autopayStatus,
  }) async {
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/recurring/$seriesId'),
      headers: _headers,
      body: jsonEncode({
        'displayName': displayName,
        'typicalAmountInr': amountInr,
        'cadenceDays': cadenceDays,
        'nextExpectedOn':
            '${nextExpectedOn.year.toString().padLeft(4, '0')}-${nextExpectedOn.month.toString().padLeft(2, '0')}-${nextExpectedOn.day.toString().padLeft(2, '0')}',
        'autopayStatus': autopayStatus,
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'PATCH /recurring failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  Future<void> deleteBudget(String budgetId) async {
    final response = await _client.delete(
      Uri.parse('$apiBaseUrl/budgets/$budgetId'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'DELETE /budgets failed: ${response.statusCode} ${response.body}',
      );
    }
  }
}

/// One detected subscription.
///
/// Detected from history rather than declared by the user: asking people to
/// list their subscriptions is asking them to remember the ones they've
/// forgotten, which are exactly the ones worth surfacing.
class RecurringSeries {
  final String id;
  final String displayName;
  final Money typicalAmount;

  /// Distinguishes an explicitly free service from an unstated price.
  final bool amountKnown;

  /// Median days between charges. Not an enum of monthly/annual — real
  /// billing runs on cycles that don't map cleanly onto either (28-day,
  /// quad-weekly, 4-monthly), and rounding them into a bucket produces a
  /// next-charge date that is visibly wrong.
  final int cadenceDays;

  final int occurrenceCount;
  final DateTime? lastSeenOn;
  final DateTime? nextExpectedOn;
  final String? userCategoryId;
  final String? categoryName;
  final String? subcategoryName;
  final String? cardName;
  final String? paymentMethod;
  final String detectionSource;
  final bool isMandate;
  final bool isUserEdited;
  final String lifecycleStatus;
  final String autopayStatus;
  final String? mandateReference;

  /// Local capture key for the SMS that produced this subscription fact.
  final String? sourceKey;
  final bool cadenceConfirmed;

  /// A named service AutoPay setup was confirmed without proving a charge or
  /// recurring terms. Such a row is presence only and has no paid estimate.
  final bool setupConfirmed;

  /// A transaction pattern without service evidence is a prompt for review,
  /// never proof that the merchant sells a subscription.
  final bool reviewCandidate;
  final Money annualCost;
  final Money? autopayLimit;
  final DateTime? startDate;
  final DateTime? endDate;

  /// One honest state computed by the detection engine:
  /// confirmed | at_risk | needs_cadence | unused. Null when the source
  /// predates the engine (an old offline cache, a test fixture) — `status`
  /// then derives it from the stored facts.
  final String? engineStatus;

  const RecurringSeries({
    required this.id,
    required this.displayName,
    required this.typicalAmount,
    this.amountKnown = true,
    required this.cadenceDays,
    required this.occurrenceCount,
    required this.annualCost,
    this.autopayLimit,
    this.startDate,
    this.endDate,
    this.lastSeenOn,
    this.nextExpectedOn,
    this.userCategoryId,
    this.categoryName,
    this.subcategoryName,
    this.cardName,
    this.paymentMethod,
    this.detectionSource = 'observed',
    this.isMandate = false,
    this.isUserEdited = false,
    this.lifecycleStatus = 'active',
    this.autopayStatus = 'unknown',
    this.mandateReference,
    this.sourceKey,
    this.cadenceConfirmed = true,
    this.setupConfirmed = false,
    this.reviewCandidate = false,
    this.engineStatus,
  });

  /// The engine state, derived from raw facts when the source didn't carry
  /// one. Same rules as the server engine — see [resolveStatus].
  String get status =>
      engineStatus ??
      resolveStatus(
        cadenceConfirmed: cadenceConfirmed,
        detectionSource: detectionSource,
        cadenceDays: cadenceDays,
        occurrenceCount: occurrenceCount,
        firstSeenOn: null,
        lastSeenOn: lastSeenOn,
        nextExpectedOn: nextExpectedOn,
      );

  /// Fallback status for data that predates the engine field (an offline
  /// cache written by an older build, or the local SMS-only detector). Same
  /// rules as the server's engineStatus, phrased over the fields stored here.
  static String resolveStatus({
    required bool cadenceConfirmed,
    required String detectionSource,
    required int cadenceDays,
    int? occurrenceCount,
    DateTime? firstSeenOn,
    DateTime? lastSeenOn,
    DateTime? nextExpectedOn,
  }) {
    final today = DateTime.now();
    final dayOnly = DateTime(today.year, today.month, today.day);
    if (!cadenceConfirmed) return 'needs_cadence';
    if (nextExpectedOn != null && nextExpectedOn.isBefore(dayOnly)) {
      return 'at_risk';
    }
    if (detectionSource == 'manual') return 'confirmed';
    final anchor = lastSeenOn ?? firstSeenOn;
    if (anchor == null) return 'confirmed';
    final age = dayOnly.difference(anchor).inDays;
    if (age > (cadenceDays * 1.5).round()) {
      final isUnused =
          detectionSource == 'mandate' && (occurrenceCount ?? 0) <= 1;
      return isUnused ? 'unused' : 'at_risk';
    }
    return 'confirmed';
  }

  bool get hasActiveAutoPay =>
      autopayStatus == 'active' || (autopayStatus == 'unknown' && isMandate);

  bool get hasPastRenewal {
    final next = nextExpectedOn;
    if (next == null) return false;
    final today = DateTime.now();
    final dateOnly = DateTime(next.year, next.month, next.day);
    return dateOnly.isBefore(DateTime(today.year, today.month, today.day));
  }

  /// A date before today is evidence that the saved schedule needs review;
  /// it is never safe to render it as an upcoming renewal. A series with an
  /// observed charge is also stale after more than one normal billing window.
  /// Active mandates without a first charge remain valid and are not marked
  /// stale because there is no charge timestamp to evaluate.
  bool get needsReview {
    if (hasPastRenewal) return true;
    if (lastSeenOn == null) return false;
    final age = DateTime.now().difference(lastSeenOn!).inDays;
    return age > (cadenceDays * 1.5).round();
  }

  /// Plain-language cadence. Approximate on purpose — "about every 5 weeks"
  /// is honest about a 33-day median in a way that "monthly" is not.
  String get cadenceLabel {
    if (cadenceDays == 0 && (isMandate || setupConfirmed || hasActiveAutoPay)) {
      return 'As presented (On-demand)';
    }
    if (cadenceDays >= 350) return 'Yearly';
    if (cadenceDays >= 175) return 'Every 6 months';
    if (cadenceDays >= 85) return 'Quarterly';
    if (cadenceDays >= 26 && cadenceDays <= 32) return 'Monthly';
    if (cadenceDays >= 13 && cadenceDays <= 16) return 'Fortnightly';
    if (cadenceDays == 7) return 'Weekly';
    if (cadenceDays < 26 && cadenceDays > 0) return 'About every $cadenceDays days';
    if (cadenceDays >= 26) return 'About every ${(cadenceDays / 7).round()} weeks';
    return 'Not confirmed';
  }

  factory RecurringSeries.fromJson(Map<String, dynamic> json) {
    final detectionSource = json['detectionSource'] as String? ?? 'observed';
    final setupConfirmed = json['setupConfirmed'] == true;
    final cadenceDays =
        (json['cadenceDays'] as num?)?.toInt() ?? (setupConfirmed ? 0 : 30);
    final cadenceConfirmed = json['cadenceConfirmed'] as bool? ?? true;
    final lastSeenOn = json['lastSeenOn'] == null
        ? null
        : DateTime.parse(json['lastSeenOn'] as String);
    final firstSeenOn = json['firstSeenOn'] == null
        ? null
        : DateTime.parse(json['firstSeenOn'] as String);
    final nextExpectedOn = json['nextExpectedOn'] == null
        ? null
        : DateTime.parse(json['nextExpectedOn'] as String);
    final occurrenceCount = (json['occurrenceCount'] as num?)?.toInt() ?? 0;
    final engine =
        json['engineStatus'] as String? ??
        resolveStatus(
          cadenceConfirmed: cadenceConfirmed,
          detectionSource: detectionSource,
          cadenceDays: cadenceDays,
          occurrenceCount: occurrenceCount,
          firstSeenOn: firstSeenOn,
          lastSeenOn: lastSeenOn,
          nextExpectedOn: nextExpectedOn,
        );
    return RecurringSeries(
      id: json['id'] as String,
      displayName: json['displayName'] as String? ?? 'Unknown',
      typicalAmount: _money(json['typicalAmountInr']),
      autopayLimit: json['autopayLimitInr'] != null ? _money(json['autopayLimitInr']) : null,
      amountKnown: json['typicalAmountInr'] != null,
      cadenceDays: cadenceDays,
      occurrenceCount: occurrenceCount,
      annualCost: _money(json['annualCostInr']),
      startDate: json['startDate'] == null ? null : DateTime.tryParse(json['startDate'] as String),
      endDate: json['endDate'] == null ? null : DateTime.tryParse(json['endDate'] as String),
      lastSeenOn: lastSeenOn,
      nextExpectedOn: nextExpectedOn,
      userCategoryId: json['userCategoryId'] as String?,
      categoryName: json['categoryName'] as String?,
      subcategoryName: json['subcategoryName'] as String?,
      cardName: json['cardName'] as String?,
      paymentMethod: json['paymentMethod'] as String?,
      detectionSource: detectionSource,
      isMandate:
          json['isMandate'] == true || json['detectionSource'] == 'mandate',
      isUserEdited: json['isUserEdited'] == true,
      lifecycleStatus: json['lifecycleStatus'] as String? ?? 'active',
      autopayStatus:
          json['autopayStatus'] as String? ??
          ((json['isMandate'] == true || json['detectionSource'] == 'mandate')
              ? 'active'
              : 'unknown'),
      mandateReference: json['mandateReference'] as String?,
      sourceKey: json['sourceKey'] as String?,
      cadenceConfirmed: cadenceConfirmed,
      setupConfirmed: setupConfirmed,
      reviewCandidate: json['reviewCandidate'] == true,
      engineStatus: engine,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'typicalAmountInr': amountKnown ? typicalAmount.rupees : null,
    if (autopayLimit != null) 'autopayLimitInr': autopayLimit!.rupees,
    'cadenceDays': cadenceDays,
    'occurrenceCount': occurrenceCount,
    if (startDate != null) 'startDate': startDate!.toIso8601String(),
    if (endDate != null) 'endDate': endDate!.toIso8601String(),
    'lastSeenOn': lastSeenOn?.toIso8601String(),
    'annualCostInr': annualCost.rupees,
    'nextExpectedOn': nextExpectedOn?.toIso8601String(),
    'userCategoryId': userCategoryId,
    'categoryName': categoryName,
    'subcategoryName': subcategoryName,
    'cardName': cardName,
    'paymentMethod': paymentMethod,
    'detectionSource': detectionSource,
    'isMandate': isMandate,
    'isUserEdited': isUserEdited,
    'lifecycleStatus': lifecycleStatus,
    'autopayStatus': autopayStatus,
    'mandateReference': mandateReference,
    'sourceKey': sourceKey,
    'cadenceConfirmed': cadenceConfirmed,
    'setupConfirmed': setupConfirmed,
    'reviewCandidate': reviewCandidate,
    if (engineStatus != null) 'engineStatus': engineStatus,
  };
}

/// Every detected subscription, plus what they cost together.
class RecurringReport {
  final List<RecurringSeries> series;
  final Money totalAnnual;

  const RecurringReport({required this.series, required this.totalAnnual});

  Map<String, dynamic> toJson() => {
    'series': series.map((item) => item.toJson()).toList(),
    'totalAnnualInr': totalAnnual.rupees,
  };
}
