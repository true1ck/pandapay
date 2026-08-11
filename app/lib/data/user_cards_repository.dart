import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

import 'api_exception.dart';

double _num(dynamic v) => v == null ? 0 : (v is num ? v.toDouble() : double.parse(v as String));

/// Chunk 17: the CURRENTLY-ACTIVE period's cap/milestone consumption for
/// this owned card — a missing entry for a given cap/milestone rule id
/// means nothing's been logged against it yet this period (full headroom),
/// matching exactly what CardSnapshot.capRemaining/milestoneProgress
/// already default to when a key is absent.
class UserCard {
  final String id;
  final String cardProductId;
  final String? nickname;
  final String cardName;
  final bool isDefault;
  final Map<String, Money> capConsumed; // capRule.id -> consumed (in the cap's own measure unit)
  final Map<String, Money> milestoneQualifiedSpend; // milestoneRule.id -> qualified spend so far
  final Map<String, DateTime> milestonePeriodEnd; // milestoneRule.id -> this period's deadline (E4)
  final double totalPointsEarned; // lifetime, in the reward's own native unit — not an INR Money
  final List<FeeWaiverProgress> feeWaiverStates;

  /// Task 11 (E7 Billing Cycle Float): day-of-month the statement cuts, and
  /// when the card was opened. Both null until the user sets a statement
  /// day (no capture flow exists yet — C4 Edit Card, deferred) — Billing
  /// Cycle Float must degrade to a prompt rather than fabricate a date.
  final int? statementDay;
  final DateTime? openedOn;

  /// Task E-0 (Group E plan): all three already existed in Postgres
  /// (0004_user_domain.sql) but were dropped by GET /user-cards until now.
  /// [creditLimit] gates E3 Credit Utilization (null == user hasn't entered
  /// one — E3 must exclude the card and prompt, never assume a limit).
  /// [dueDay] feeds E8's calendar. [anniversaryOn] feeds E5's
  /// days-to-anniversary.
  final Money? creditLimit;
  final int? dueDay;
  final DateTime? anniversaryOn;

  /// Task C-1: only ever true when the caller passed `includeArchived` to
  /// [UserCardsRepository.fetchUserCards] — every other call site (ranking,
  /// cap assembly) never sees an archived card at all, so this is always
  /// false there by construction, not by checking this field.
  final bool isArchived;

  /// Migration 0027 — what the user has told us about autopay on this card.
  ///
  /// Never observed from the issuer: PandaPay is read-only by design and has
  /// no mandate integration, so [AutopayMode.off] means "hasn't said
  /// otherwise", not "confirmed off". Anything shown to the user from this
  /// must be phrased as their own answer, never as a fact about their bank.
  final AutopayMode autopayMode;

  const UserCard({
    required this.id,
    required this.cardProductId,
    this.nickname,
    required this.cardName,
    required this.isDefault,
    this.capConsumed = const {},
    this.milestoneQualifiedSpend = const {},
    this.milestonePeriodEnd = const {},
    this.totalPointsEarned = 0,
    this.feeWaiverStates = const [],
    this.statementDay,
    this.openedOn,
    this.creditLimit,
    this.dueDay,
    this.anniversaryOn,
    this.isArchived = false,
    this.autopayMode = AutopayMode.off,
  });

  factory UserCard.fromJson(Map<String, dynamic> json) {
    final capStates = (json['cap_states'] as List? ?? const []).cast<Map<String, dynamic>>();
    final milestoneStates = (json['milestone_states'] as List? ?? const []).cast<Map<String, dynamic>>();
    final feeWaiverStates = (json['fee_waiver_states'] as List? ?? const []).cast<Map<String, dynamic>>();
    return UserCard(
      id: json['id'] as String,
      cardProductId: json['card_product_id'] as String,
      nickname: json['nickname'] as String?,
      cardName: json['card_name'] as String,
      isDefault: json['is_default'] as bool? ?? false,
      capConsumed: {
        for (final s in capStates) s['cap_rule_id'] as String: Money.fromRupees(_num(s['consumed'])),
      },
      milestoneQualifiedSpend: {
        for (final s in milestoneStates)
          s['milestone_rule_id'] as String: Money.fromRupees(_num(s['qualified_spend'])),
      },
      milestonePeriodEnd: {
        for (final s in milestoneStates)
          if (s['period_end'] != null)
            s['milestone_rule_id'] as String: DateTime.parse(s['period_end'] as String),
      },
      totalPointsEarned: _num(json['total_points_earned']),
      feeWaiverStates: feeWaiverStates.map(FeeWaiverProgress.fromJson).toList(),
      statementDay: json['statement_day'] as int?,
      openedOn: json['opened_on'] == null ? null : DateTime.parse(json['opened_on'] as String),
      creditLimit: json['credit_limit_inr'] == null ? null : Money.fromRupees(_num(json['credit_limit_inr'])),
      dueDay: json['due_day'] as int?,
      anniversaryOn: json['anniversary_on'] == null ? null : DateTime.parse(json['anniversary_on'] as String),
      isArchived: json['is_archived'] as bool? ?? false,
      autopayMode: AutopayMode.fromJson(json['autopay_mode'] as String?),
    );
  }

  /// Offline-cache round-trip only (docs/superpowers/plans/2026-08-08-offline-first-local-cache.md)
  /// — mirrors [fromJson]'s keys exactly so a cached blob decodes through
  /// the unmodified fromJson parser above.
  Map<String, dynamic> toJson() => {
    'id': id,
    'card_product_id': cardProductId,
    'nickname': nickname,
    'card_name': cardName,
    'is_default': isDefault,
    'cap_states': [
      for (final entry in capConsumed.entries) {'cap_rule_id': entry.key, 'consumed': entry.value.rupees},
    ],
    'milestone_states': [
      for (final entry in milestoneQualifiedSpend.entries)
        {
          'milestone_rule_id': entry.key,
          'qualified_spend': entry.value.rupees,
          if (milestonePeriodEnd[entry.key] != null)
            'period_end': milestonePeriodEnd[entry.key]!.toIso8601String(),
        },
    ],
    'fee_waiver_states': feeWaiverStates.map((fw) => fw.toJson()).toList(),
    'total_points_earned': totalPointsEarned,
    'statement_day': statementDay,
    'opened_on': openedOn?.toIso8601String(),
    'credit_limit_inr': creditLimit?.rupees,
    'due_day': dueDay,
    'anniversary_on': anniversaryOn?.toIso8601String(),
    'is_archived': isArchived,
    'autopay_mode': autopayMode.wireValue,
  };
}

/// What the user has told PandaPay about autopay on a card — migration
/// 0027's `user_cards.autopay_mode`.
///
/// Three states, not a boolean, because the deck's own copy distinguishes
/// them and the distinction carries real money: autopay set to the MINIMUM
/// due still avoids a late-payment mark on the credit report, but leaves
/// the rest of the balance revolving at around 42% p.a. Telling a user on
/// [minimum] that they are "covered" would be false in the way that costs
/// the most.
enum AutopayMode {
  /// Also the value for a card the user has never answered about — see
  /// [UserCard.autopayMode]. Treat as "unknown", not as a verified negative.
  off('off'),
  minimum('minimum'),
  full('full');

  final String wireValue;
  const AutopayMode(this.wireValue);

  /// Unknown or missing values fall back to [off] rather than throwing: a
  /// server that grows a fourth mode must not crash an older client, and
  /// [off] is the conservative reading — it prompts the user to confirm
  /// rather than reassuring them.
  static AutopayMode fromJson(String? value) =>
      AutopayMode.values.firstWhere((m) => m.wireValue == value, orElse: () => AutopayMode.off);

  /// True only when the whole statement balance is covered. [minimum] is
  /// deliberately excluded — see the enum's own doc-comment.
  bool get coversFullStatement => this == AutopayMode.full;
}

/// One share of a split transaction — design 18 "Split this expense".
///
/// A split records **who owed what**, not a second payment. The parent
/// transaction's cap, milestone and points state was computed once, on the
/// card it was actually paid with; splits never re-enter that arithmetic,
/// which is why this carries no confidence marker and never appears in an
/// earnings total.
///
/// [id] is null for a split the user has built on screen but not yet
/// saved — the server assigns ids on write, and the whole set is replaced
/// on each save, so client-side ids would be meaningless.
class TransactionSplit {
  final String? id;
  final String? userCardId;
  final String? categoryId;
  final String? categoryName;
  final Money amount;
  final String? note;

  const TransactionSplit({
    this.id,
    this.userCardId,
    this.categoryId,
    this.categoryName,
    required this.amount,
    this.note,
  });

  factory TransactionSplit.fromJson(Map<String, dynamic> json) => TransactionSplit(
    id: json['id'] as String?,
    userCardId: json['user_card_id'] as String?,
    categoryId: json['category_id'] as String?,
    categoryName: json['category_name'] as String?,
    amount: Money.fromRupees(_num(json['amount_inr'])),
    note: json['note'] as String?,
  );

  /// The PUT body shape, which is camelCase and omits server-owned fields —
  /// deliberately not the mirror of [fromJson].
  Map<String, dynamic> toRequestJson() => {
    'amountInr': amount.rupees,
    if (userCardId != null) 'userCardId': userCardId,
    if (categoryId != null) 'categoryId': categoryId,
    if (note != null && note!.isNotEmpty) 'note': note,
  };
}

/// Chunk 28: this card's fee-waiver progress for the CURRENT period only
/// (mirrors cap/milestone states above) — `waivedAt` non-null means the
/// spend threshold was already crossed this period.
class FeeWaiverProgress {
  final String feeWaiverRuleId;
  final Money qualifiedSpend;
  final Money thresholdSpend;
  final Money waivesFee;
  final DateTime? waivedAt;
  final DateTime periodEnd;

  const FeeWaiverProgress({
    required this.feeWaiverRuleId,
    required this.qualifiedSpend,
    required this.thresholdSpend,
    required this.waivesFee,
    this.waivedAt,
    required this.periodEnd,
  });

  factory FeeWaiverProgress.fromJson(Map<String, dynamic> json) {
    return FeeWaiverProgress(
      feeWaiverRuleId: json['fee_waiver_rule_id'] as String,
      qualifiedSpend: Money.fromRupees(_num(json['qualified_spend'])),
      thresholdSpend: Money.fromRupees(_num(json['threshold_spend_inr'])),
      waivesFee: Money.fromRupees(_num(json['waives_fee_inr'])),
      waivedAt: json['waived_at'] == null ? null : DateTime.parse(json['waived_at'] as String),
      periodEnd: DateTime.parse(json['period_end'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'fee_waiver_rule_id': feeWaiverRuleId,
    'qualified_spend': qualifiedSpend.rupees,
    'threshold_spend_inr': thresholdSpend.rupees,
    'waives_fee_inr': waivesFee.rupees,
    'waived_at': waivedAt?.toIso8601String(),
    'period_end': periodEnd.toIso8601String(),
  };
}

/// Task C-6 (ui-spec C6 Points & Expiry) — one row in `points_ledger`.
/// [expiresOn] is null for most auto-earned rows today (no card carries a
/// modeled points-expiry policy anywhere in the schema yet — only manual
/// corrections can set one, since the user is the one who actually knows
/// their program's real expiry date). [isManualCorrection] drives C6's
/// "why does this row exist" copy.
class PointsLedgerEntry {
  final String id;
  final double deltaPoints;
  final String reason;
  final Confidence state;
  final DateTime? expiresOn;
  final DateTime occurredAt;

  const PointsLedgerEntry({
    required this.id,
    required this.deltaPoints,
    required this.reason,
    required this.state,
    this.expiresOn,
    required this.occurredAt,
  });

  bool get isManualCorrection => reason == 'manual correction';

  factory PointsLedgerEntry.fromJson(Map<String, dynamic> json) {
    return PointsLedgerEntry(
      id: json['id'] as String,
      deltaPoints: _num(json['delta_points']),
      reason: json['reason'] as String,
      state: json['state'] == 'confirmed' ? Confidence.confirmed : Confidence.estimated,
      expiresOn: json['expires_on'] == null ? null : DateTime.parse(json['expires_on'] as String),
      occurredAt: DateTime.parse(json['occurred_at'] as String),
    );
  }
}

/// E6 Lounge Access — one row in `lounge_usage`, either logged manually by
/// the user (the only source this pass supports; see POST /lounge-usage) or
/// in principle from a future bank-feed integration (`loggedManually` would
/// be false for that, not built anywhere yet).
class LoungeVisit {
  final String id;
  final String userCardId;
  final String benefitId;
  final DateTime usedOn;
  final String? airport;
  final bool loggedManually;

  const LoungeVisit({
    required this.id,
    required this.userCardId,
    required this.benefitId,
    required this.usedOn,
    this.airport,
    required this.loggedManually,
  });

  factory LoungeVisit.fromJson(Map<String, dynamic> json) {
    return LoungeVisit(
      id: json['id'] as String,
      userCardId: json['user_card_id'] as String,
      benefitId: json['benefit_id'] as String,
      usedOn: DateTime.parse(json['used_on'] as String),
      airport: json['airport'] as String?,
      loggedManually: json['logged_manually'] as bool? ?? true,
    );
  }
}

/// E9 Monthly Savings Report. `baselineSingleCard`/`valueMissed` are always
/// zero this pass — GET /monthly-reports doesn't compute them yet (needs
/// the shared historical-recompute calculator flagged in the plan as
/// shared with D6) — the screen must not present a zero here as "you missed
/// nothing," only as "not computed."
class MonthlyReport {
  final DateTime periodMonth;
  final Money totalSpend;
  final Money rewardsEarned;
  final Money baselineSingleCard;
  final Money valueMissed;
  final Money extraEarned;

  const MonthlyReport({
    required this.periodMonth,
    required this.totalSpend,
    required this.rewardsEarned,
    required this.baselineSingleCard,
    required this.valueMissed,
    required this.extraEarned,
  });

  factory MonthlyReport.fromJson(Map<String, dynamic> json) {
    return MonthlyReport(
      periodMonth: DateTime.parse(json['period_month'] as String),
      totalSpend: Money.fromRupees(_num(json['total_spend_inr'])),
      rewardsEarned: Money.fromRupees(_num(json['rewards_earned_inr'])),
      baselineSingleCard: Money.fromRupees(_num(json['baseline_single_card_inr'])),
      valueMissed: Money.fromRupees(_num(json['value_missed_inr'])),
      extraEarned: Money.fromRupees(_num(json['extra_earned_inr'])),
    );
  }
}

/// E12 My Contributions — see GET /my-contributions' own doc-comment
/// (api/src/index.js) for why this is network-wide aggregate stats only,
/// not a per-user count: merchant_contributions has no profile_id column
/// by deliberate R2 privacy design.
class ContributionNetworkStats {
  final int publishedMerchantCount;
  final int contributingDeviceCount;

  const ContributionNetworkStats({
    required this.publishedMerchantCount,
    required this.contributingDeviceCount,
  });

  factory ContributionNetworkStats.fromJson(Map<String, dynamic> json) {
    return ContributionNetworkStats(
      publishedMerchantCount: int.parse(json['published_merchant_count'].toString()),
      contributingDeviceCount: int.parse(json['contributing_device_count'].toString()),
    );
  }
}

/// Design 01's header strip: rewards this month, rewards all time, and the
/// logging streak, from `GET /home-summary`. See that route's doc-comment
/// for how each figure is derived — every one is a real aggregate over the
/// user's own transactions, so the header never shows a number the app
/// can't point at a row for.
class HomeSummary {
  final Money rewardsThisMonth;
  final Money rewardsAllTime;
  final int transactionCount;
  final int streakDays;

  const HomeSummary({
    required this.rewardsThisMonth,
    required this.rewardsAllTime,
    required this.transactionCount,
    required this.streakDays,
  });

  factory HomeSummary.fromJson(Map<String, dynamic> json) {
    return HomeSummary(
      rewardsThisMonth: Money.fromRupees(_num(json['rewardsThisMonthInr'])),
      rewardsAllTime: Money.fromRupees(_num(json['rewardsAllTimeInr'])),
      transactionCount: int.parse((json['transactionCount'] ?? 0).toString()),
      streakDays: int.parse((json['streakDays'] ?? 0).toString()),
    );
  }
}

/// One row of design 19's notification inbox (`GET /notifications`).
class AppNotification {
  final String id;
  final String category;
  final String severity; // 'info' | 'good' | 'urgent'
  final String title;
  final String? body;

  /// In-app route to open on tap, or null for a purely informational entry
  /// — which the UI renders without a chevron rather than as a dead tap.
  final String? deepLink;
  final DateTime? readAt;
  final DateTime createdAt;

  const AppNotification({
    required this.id,
    required this.category,
    required this.severity,
    required this.title,
    this.body,
    this.deepLink,
    this.readAt,
    required this.createdAt,
  });

  bool get isUnread => readAt == null;

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: json['id'] as String,
      category: json['category'] as String,
      severity: json['severity'] as String? ?? 'info',
      title: json['title'] as String,
      body: json['body'] as String?,
      deepLink: json['deep_link'] as String?,
      readAt: json['read_at'] == null ? null : DateTime.parse(json['read_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// Design 25's Invite friends payload (`GET /referrals`).
///
/// [rewardsActive] is the programme's own `is_active` flag, not a client
/// default: when it's false the screen shows the invite mechanics with no
/// reward claim at all, because advertising money that isn't on offer is
/// the one thing this screen must never do.
class ReferralInfo {
  final bool rewardsActive;
  final Money referrerReward;
  final Money refereeReward;
  final String qualifyingAction;
  final String? code;
  final List<Referral> referrals;

  const ReferralInfo({
    required this.rewardsActive,
    required this.referrerReward,
    required this.refereeReward,
    required this.qualifyingAction,
    required this.code,
    required this.referrals,
  });

  int get qualifiedCount => referrals.where((r) => r.isQualified).length;

  factory ReferralInfo.fromJson(Map<String, dynamic> json) {
    final program = json['program'] as Map<String, dynamic>?;
    return ReferralInfo(
      rewardsActive: program?['is_active'] as bool? ?? false,
      referrerReward: Money.fromRupees(_num(program?['referrer_reward_inr'])),
      refereeReward: Money.fromRupees(_num(program?['referee_reward_inr'])),
      qualifyingAction: program?['qualifying_action'] as String? ?? 'first ranked payment',
      code: json['code'] as String?,
      referrals: ((json['referrals'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(Referral.fromJson)
          .toList(),
    );
  }
}

/// One person invited. [label] is their email local-part or a name the
/// referrer typed — never a full address, which isn't the referrer's to see.
class Referral {
  final String id;
  final String? label;
  final String rewardState; // 'pending' | 'signed_up' | 'qualified'
  final DateTime createdAt;

  const Referral({required this.id, this.label, required this.rewardState, required this.createdAt});

  bool get isQualified => rewardState == 'qualified';

  factory Referral.fromJson(Map<String, dynamic> json) => Referral(
    id: json['id'] as String,
    label: json['label'] as String?,
    rewardState: json['reward_state'] as String? ?? 'pending',
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}

/// One card the discovery matcher recognised in the user's bank email
/// and/or SMS (`POST /card-discovery`).
///
/// [evidence] is the literal text that produced the match, so the UI can
/// show *why* a card was suggested. Nothing is ever added automatically —
/// see that route's doc-comment for why a wrong auto-add is worse than a
/// missed suggestion.
class DiscoveredCard {
  final String cardProductId;
  final String name;
  final double score;
  final List<String> evidence;

  /// Last-4 digits seen next to the match, for display only. The app does
  /// not store card numbers; this is read from the message and discarded
  /// with it.
  final List<String> last4;
  final int messageCount;
  final List<String> sources; // 'email' and/or 'sms'

  const DiscoveredCard({
    required this.cardProductId,
    required this.name,
    required this.score,
    required this.evidence,
    required this.last4,
    required this.messageCount,
    required this.sources,
  });

  factory DiscoveredCard.fromJson(Map<String, dynamic> json) => DiscoveredCard(
    cardProductId: json['cardProductId'] as String,
    name: json['name'] as String,
    score: _num(json['score']),
    evidence: ((json['evidence'] as List?) ?? const []).cast<String>(),
    last4: ((json['last4'] as List?) ?? const []).cast<String>(),
    messageCount: (json['messageCount'] as num?)?.toInt() ?? 1,
    sources: ((json['sources'] as List?) ?? const []).cast<String>(),
  );
}

/// What a discovery run looked at, so the screen can explain an empty
/// result ("we read 0 emails" is a very different answer from "we read 40
/// and matched nothing").
class CardDiscoveryResult {
  final List<DiscoveredCard> suggestions;
  final int emailsScanned;
  final int smsScanned;

  const CardDiscoveryResult({
    required this.suggestions,
    required this.emailsScanned,
    required this.smsScanned,
  });

  factory CardDiscoveryResult.fromJson(Map<String, dynamic> json) {
    final scanned = (json['scanned'] as Map<String, dynamic>?) ?? const {};
    return CardDiscoveryResult(
      suggestions: ((json['suggestions'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(DiscoveredCard.fromJson)
          .toList(),
      emailsScanned: (scanned['emails'] as num?)?.toInt() ?? 0,
      smsScanned: (scanned['sms'] as num?)?.toInt() ?? 0,
    );
  }
}

class UserCardsRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  UserCardsRepository({required this.apiBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<List<UserCard>> fetchUserCards({bool includeArchived = false}) async {
    final uri = Uri.parse(
      '$apiBaseUrl/user-cards',
    ).replace(queryParameters: includeArchived ? {'includeArchived': 'true'} : null);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /user-cards failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['userCards'] as List).cast<Map<String, dynamic>>().map(UserCard.fromJson).toList();
  }

  /// Returns the newly-created `user_cards.id`. A9 (Card Details Setup)
  /// needs real ids to PATCH per-card right after adding a batch — this
  /// used to return void because nothing needed the id back until A7/A9
  /// existed; POST /user-cards already returns it (`{userCard: {id, ...}}`),
  /// this just stops discarding it.
  Future<String> addCard(String cardProductId, {String? nickname}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/user-cards'),
      headers: _headers,
      body: jsonEncode({'cardProductId': cardProductId, 'nickname': ?nickname}),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /user-cards failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['userCard'] as Map<String, dynamic>)['id'] as String;
  }

  Future<void> archiveCard(String userCardId) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/user-cards/$userCardId/archive'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException('archive failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Design 23 "Card actions" — set as default. Server-side this clears any
  /// existing default in the same transaction, so callers never have to
  /// unset the previous one themselves.
  Future<void> setDefaultCard(String userCardId) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/user-cards/$userCardId/default'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException('set default failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Task C-1: C1's active/archived filter needs a way back from archive,
  /// not just a one-way trip.
  Future<void> unarchiveCard(String userCardId) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/user-cards/$userCardId/unarchive'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException('unarchive failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Task C-1 (ui-spec C1 "drag to reorder priority"). [orderedIds] is the
  /// full new order, most-priority first.
  Future<void> reorderCards(List<String> orderedIds) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/user-cards/reorder'),
      headers: _headers,
      body: jsonEncode({'order': orderedIds}),
    );
    if (response.statusCode != 200) {
      throw ApiException('reorder failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Task C-4 (ui-spec C4 Edit Card). Only non-null fields are sent — a
  /// field the caller didn't touch stays whatever it already was
  /// server-side, matching PATCH /user-cards/:id's own "only provided
  /// fields update" contract.
  Future<void> updateCard(
    String userCardId, {
    String? nickname,
    double? creditLimitInr,
    int? statementDay,
    int? dueDay,
    double? pointsBalance,
    AutopayMode? autopayMode,
  }) async {
    final body = <String, dynamic>{
      if (nickname != null) 'nickname': nickname,
      if (creditLimitInr != null) 'creditLimitInr': creditLimitInr,
      if (statementDay != null) 'statementDay': statementDay,
      if (dueDay != null) 'dueDay': dueDay,
      if (pointsBalance != null) 'pointsBalance': pointsBalance,
      // Sent by wire value, not enum name — they happen to match today, but
      // the server's CHECK constraint is the contract, not Dart's naming.
      if (autopayMode != null) 'autopayMode': autopayMode.wireValue,
    };
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/user-cards/$userCardId'),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      throw ApiException('update failed: ${response.statusCode} ${response.body}');
    }
  }

  /// UA-3+ (Chunk 17), extended for B6: manual quick-add now carries
  /// merchantName/occurredAt/note through to POST /transactions, all three
  /// already accepted server-side (occurredAt/categoryId/rail/merchantName
  /// were already wired; note is this task's addition — see Task 15 of
  /// the Group B plan). No client-side "undo" beyond a dismiss-only
  /// snackbar (Task 16) — there is no DELETE /transactions/:id route.
  /// Updates cap_states/milestone_states server-side in the same write, so a
  /// follow-up GET /user-cards (userCardsProvider.invalidate) immediately
  /// reflects real consumed headroom.
  /// Returns the newly-created `transactions.id` — B6 Quick-Add's Undo
  /// snackbar needs it to call [ignoreTransaction] with reason 'reversal',
  /// which already exists server-side and does exactly what an undo needs
  /// (reverses cap/milestone/points/fee-waiver state, marks the row
  /// non-active) despite there being no DELETE /transactions/:id route.
  Future<String> logTransaction({
    required String userCardId,
    required Money amount,
    String? categoryId,
    String? merchantName,
    DateTime? occurredAt,
    String? note,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/transactions'),
      headers: _headers,
      body: jsonEncode({
        'userCardId': userCardId,
        'amountInr': amount.rupees,
        'categoryId': ?categoryId,
        'merchantName': ?merchantName,
        'occurredAt': occurredAt?.toIso8601String(),
        'note': ?note,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /transactions failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['transaction'] as Map<String, dynamic>)['id'] as String;
  }

  /// Design 18 "Add a note". Its own endpoint rather than a field on
  /// [updateTransaction] — see PATCH /transactions/:id/note's doc-comment
  /// in api/ for why a note must not trigger the reward-state recompute
  /// that a full transaction edit does. Pass null to clear.
  Future<void> updateTransactionNote(String transactionId, String? note) async {
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/transactions/$transactionId/note'),
      headers: _headers,
      body: jsonEncode({'note': note}),
    );
    if (response.statusCode != 200) {
      throw ApiException('note update failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Design 18 "Split this expense" — the current split set for one
  /// transaction, empty when it has never been split.
  Future<List<TransactionSplit>> fetchSplits(String transactionId) async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/transactions/$transactionId/splits'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException('GET splits failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['splits'] as List).cast<Map<String, dynamic>>().map(TransactionSplit.fromJson).toList();
  }

  /// Replaces the whole split set. Replace rather than append is the
  /// server's contract too — a split is a partition of one amount, so the
  /// set is the only coherent unit of edit. An empty list clears the
  /// splits.
  Future<List<TransactionSplit>> saveSplits(String transactionId, List<TransactionSplit> splits) async {
    final response = await _client.put(
      Uri.parse('$apiBaseUrl/transactions/$transactionId/splits'),
      headers: _headers,
      body: jsonEncode({
        'splits': [for (final s in splits) s.toRequestJson()],
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException('save splits failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['splits'] as List).cast<Map<String, dynamic>>().map(TransactionSplit.fromJson).toList();
  }

  /// UA-5.3 (Chunk 31): SMS auto-import. Sends the raw SMS sender+body to
  /// POST /transactions/from-sms, which does the server-side regex parse
  /// (parser_patterns) and, on a match, the exact same cap/milestone/
  /// points/fee-waiver update as [logTransaction] above. `userCardId` still
  /// has to be supplied by the caller — the parser extracts amount/
  /// merchant/last4/date from the SMS text, not which of the user's owned
  /// cards it belongs to (last4 alone isn't a safe/unique match key across
  /// issuers), so the on-device listener is expected to resolve that (e.g.
  /// by asking the user, or matching last4 against owned cards as a hint)
  /// before calling this. A 200 with `parsed: false` is not an error — it's
  /// the server telling us the SMS didn't match any active pattern and was
  /// logged to parser_failures for admin triage instead of silently
  /// dropped; the caller decides whether to surface that as "log manually?"
  Future<SmsImportResult> logTransactionFromSms({
    required String userCardId,
    required String sender,
    required String body,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/transactions/from-sms'),
      headers: _headers,
      body: jsonEncode({'userCardId': userCardId, 'sender': sender, 'body': body}),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw ApiException('POST /transactions/from-sms failed: ${response.statusCode} ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SmsImportResult(parsed: json['parsed'] == true, reason: json['reason'] as String?);
  }

  /// UA-3+ (Chunk 18): the Activity tab's data source. [from]/[to] (E10/E11,
  /// Task E-0's shared query-param gap-fill) are optional inclusive date
  /// bounds; [cardId] filters to one card (E10 Portfolio Audit's per-card
  /// usage-frequency count).
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? source,
    String? query,
  }) async {
    final params = <String, String>{
      if (from != null) 'from': _dateOnly(from),
      if (to != null) 'to': _dateOnly(to),
      if (cardId != null) 'cardId': cardId,
      if (categoryId != null) 'categoryId': categoryId,
      if (source != null) 'source': source,
      // Server-side match over merchant name and note. Blank/whitespace is
      // dropped rather than sent, so an empty search box is "no filter"
      // rather than a query that matches everything with a wildcard.
      if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
    };
    final uri = Uri.parse(
      '$apiBaseUrl/transactions',
    ).replace(queryParameters: params.isEmpty ? null : params);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /transactions failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['transactions'] as List)
        .cast<Map<String, dynamic>>()
        .map(TransactionEntry.fromJson)
        .toList();
  }

  /// Task D-2: single-transaction fetch, deliberately NOT filtered to
  /// status='active' server-side (see the route's own doc-comment) — D2
  /// must be able to show an ignored transaction too.
  Future<TransactionEntry> fetchTransaction(String id) async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/transactions/$id'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /transactions/:id failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return TransactionEntry.fromJson(body['transaction'] as Map<String, dynamic>);
  }

  /// Task D-3 (ui-spec D3 Edit Transaction). Only non-null fields are sent.
  Future<void> editTransaction(
    String id, {
    double? amountInr,
    DateTime? occurredAt,
    String? categoryId,
    String? merchantName,
    TxnRail? rail,
    String? userCardId,
  }) async {
    final body = <String, dynamic>{
      if (amountInr != null) 'amountInr': amountInr,
      if (occurredAt != null) 'occurredAt': occurredAt.toIso8601String(),
      if (categoryId != null) 'categoryId': categoryId,
      if (merchantName != null) 'merchantName': merchantName,
      if (rail != null) 'rail': _railToJson(rail),
      if (userCardId != null) 'userCardId': userCardId,
    };
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/transactions/$id'),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      throw ApiException('PATCH /transactions/:id failed: ${response.statusCode} ${response.body}');
    }
  }

  static String _railToJson(TxnRail rail) {
    final buffer = StringBuffer();
    for (final char in rail.name.split('')) {
      if (char == char.toUpperCase() && char != char.toLowerCase()) {
        buffer.write('_${char.toLowerCase()}');
      } else {
        buffer.write(char);
      }
    }
    return buffer.toString();
  }

  /// Task D-2 (ui-spec D2 "mark ignored (refund/reversal/transfer)").
  Future<void> ignoreTransaction(String id, {required String reason}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/transactions/$id/ignore'),
      headers: _headers,
      body: jsonEncode({'reason': reason}),
    );
    if (response.statusCode != 200) {
      throw ApiException('POST /transactions/:id/ignore failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Task D-5 (ui-spec D5 Duplicate Review). Pending pairs only.
  Future<List<DuplicateCandidate>> fetchDuplicateCandidates() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/duplicate-candidates'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /duplicate-candidates failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['duplicateCandidates'] as List)
        .cast<Map<String, dynamic>>()
        .map(DuplicateCandidate.fromJson)
        .toList();
  }

  /// [resolution] one of 'merged' / 'kept_both' / 'deleted_one'.
  /// [keepTransactionId] required unless [resolution] is 'kept_both'.
  Future<void> resolveDuplicateCandidate(
    String id, {
    required String resolution,
    String? keepTransactionId,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/duplicate-candidates/$id/resolve'),
      headers: _headers,
      body: jsonEncode({
        'resolution': resolution,
        if (keepTransactionId != null) 'keepTransactionId': keepTransactionId,
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /duplicate-candidates/:id/resolve failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Task C-6: GET /user-cards/:id/points-ledger.
  Future<List<PointsLedgerEntry>> fetchPointsLedger(String userCardId) async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/user-cards/$userCardId/points-ledger'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException('GET /user-cards/:id/points-ledger failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['pointsLedger'] as List)
        .cast<Map<String, dynamic>>()
        .map(PointsLedgerEntry.fromJson)
        .toList();
  }

  /// Task C-6 (ui-spec C6 "manual balance correction, feeds
  /// reconciliation"). [newBalance] is the card's TOTAL points after this
  /// correction, not a delta — the server computes the delta itself from
  /// the current ledger sum, same as C4's points-balance field conceptually
  /// means "this is the real number," not "add this many."
  Future<void> adjustPointsBalance(
    String userCardId, {
    required double newBalance,
    DateTime? expiresOn,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/user-cards/$userCardId/points-adjustment'),
      headers: _headers,
      body: jsonEncode({'newBalance': newBalance, if (expiresOn != null) 'expiresOn': _dateOnly(expiresOn)}),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /user-cards/:id/points-adjustment failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Task E6: GET/POST /lounge-usage.
  Future<List<LoungeVisit>> fetchLoungeUsage() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/lounge-usage'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /lounge-usage failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['loungeUsage'] as List).cast<Map<String, dynamic>>().map(LoungeVisit.fromJson).toList();
  }

  Future<void> logLoungeVisit({
    required String userCardId,
    required String benefitId,
    required DateTime usedOn,
    String? airport,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/lounge-usage'),
      headers: _headers,
      body: jsonEncode({
        'userCardId': userCardId,
        'benefitId': benefitId,
        'usedOn': _dateOnly(usedOn),
        'airport': ?airport,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /lounge-usage failed: ${response.statusCode} ${response.body}');
    }
  }

  /// "Find my cards" over forwarded bank email and, on Android, SMS bodies
  /// the device reads locally. [smsBodies] are sent for this request only
  /// and never stored server-side — see POST /card-discovery.
  Future<CardDiscoveryResult> discoverCards({List<String> smsBodies = const []}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/card-discovery'),
      headers: _headers,
      body: jsonEncode({'smsBodies': smsBodies}),
    );
    if (response.statusCode != 200) {
      throw ApiException('POST /card-discovery failed: ${response.statusCode} ${response.body}');
    }
    return CardDiscoveryResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Design 25's Invite friends screen, in one call.
  Future<ReferralInfo> fetchReferrals() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/referrals'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /referrals failed: ${response.statusCode} ${response.body}');
    }
    return ReferralInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Design 19's inbox. Newest first; the server does no grouping — the
  /// client buckets Today/Earlier in the device's own timezone.
  Future<({List<AppNotification> items, int unreadCount})> fetchNotifications() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/notifications'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /notifications failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (
      items: (body['notifications'] as List)
          .cast<Map<String, dynamic>>()
          .map(AppNotification.fromJson)
          .toList(),
      unreadCount: (body['unreadCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// Marks one notification read, or every unread one when [id] is null
  /// (design 19's "Mark all read").
  Future<void> markNotificationsRead({String? id}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/notifications/read'),
      headers: _headers,
      body: jsonEncode(id == null ? <String, dynamic>{} : {'id': id}),
    );
    if (response.statusCode != 200) {
      throw ApiException('POST /notifications/read failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Records a delivery. [dedupeKey] makes it idempotent — re-recording the
  /// same logical event updates the row instead of stacking copies.
  /// Silently does nothing (204) when the user has that category muted.
  Future<void> recordNotification({
    required String category,
    required String title,
    String? body,
    String severity = 'info',
    String? deepLink,
    String? dedupeKey,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/notifications'),
      headers: _headers,
      body: jsonEncode({
        'category': category,
        'title': title,
        'body': body,
        'severity': severity,
        'deepLink': deepLink,
        'dedupeKey': dedupeKey,
      }),
    );
    if (response.statusCode != 201 && response.statusCode != 204) {
      throw ApiException('POST /notifications failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Design 01 header: GET /home-summary. Sends the device's IANA zone so
  /// the streak buckets on the user's local calendar day, not UTC.
  Future<HomeSummary?> fetchHomeSummary({String? timeZone}) async {
    final uri = Uri.parse(
      '$apiBaseUrl/home-summary',
    ).replace(queryParameters: timeZone == null ? null : {'tz': timeZone});
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /home-summary failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final summary = body['homeSummary'];
    return summary == null ? null : HomeSummary.fromJson(summary as Map<String, dynamic>);
  }

  /// Task E9: GET /monthly-reports. Null [month] means "the current month."
  Future<MonthlyReport?> fetchMonthlyReport({DateTime? month}) async {
    final params = month == null ? null : {'month': _dateOnly(DateTime(month.year, month.month, 1))};
    final uri = Uri.parse('$apiBaseUrl/monthly-reports').replace(queryParameters: params);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /monthly-reports failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final report = body['monthlyReport'];
    return report == null ? null : MonthlyReport.fromJson(report as Map<String, dynamic>);
  }

  /// Task E12: GET /my-contributions (network-wide aggregate only — see
  /// ContributionNetworkStats' doc-comment for why) and the contributions
  /// opt-in toggle, which mirrors H4 per the plan.
  Future<ContributionNetworkStats> fetchContributionNetworkStats() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/my-contributions'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /my-contributions failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ContributionNetworkStats.fromJson(body['networkStats'] as Map<String, dynamic>);
  }

  Future<void> setContributionsOptIn(bool optIn) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/profile/contributions-opt-in'),
      headers: _headers,
      body: jsonEncode({'optIn': optIn}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /profile/contributions-opt-in failed: ${response.statusCode} ${response.body}',
      );
    }
  }
}

class TransactionEntry {
  final String id;
  final Money amount;
  final DateTime occurredAt;
  final String? merchantName;
  final String? categoryId;
  final String? categoryName;
  final String? cardDisplayName; // nickname if set, else the card's own name

  /// Task D-1/D-2/D-3: added alongside the D1 rebuild — `GET /transactions`
  /// already selected `t.source`/`t.note` (Task C-0c) and `t.user_card_id`/
  /// `t.rail`/`t.status` (always present in the row) but nothing parsed
  /// them into the client model until D2 (Transaction Detail, "source"/
  /// "reconciliation status") and D3 (Edit, needs every field) needed them.
  final String userCardId;
  final TxnRail rail;
  final String source;
  final String status;
  final String? note;

  /// What this transaction actually earned — `transactions.expected_value_inr`,
  /// written at insert time by the same server-side helper that updates cap
  /// and milestone state.
  ///
  /// `GET /transactions` already stored this per row but never selected it,
  /// so every client-side "what did I earn" figure had to be re-derived from
  /// base rates instead. Design 04 Insights breaks earnings down by category
  /// and those bars have to add up to the same total design 01 Home puts in
  /// its header — Home reads `GET /home-summary`, which is
  /// `SUM(expected_value_inr)` over these very rows, so reading the stored
  /// value here is what makes the two screens agree. A re-derivation would
  /// have quietly disagreed with Home by whatever caps and milestones
  /// applied at the time.
  ///
  /// Null for rows written before the column was populated, and for imports
  /// that never ran through the ranking engine — callers must treat null as
  /// "unknown", never as zero earned.
  final Money? rewardValue;

  const TransactionEntry({
    required this.id,
    required this.amount,
    required this.occurredAt,
    this.merchantName,
    this.categoryId,
    this.categoryName,
    this.cardDisplayName,
    required this.userCardId,
    this.rail = TxnRail.unknown,
    required this.source,
    required this.status,
    this.note,
    this.rewardValue,
  });

  factory TransactionEntry.fromJson(Map<String, dynamic> json) {
    final nickname = json['card_nickname'] as String?;
    final cardName = json['card_name'] as String?;
    return TransactionEntry(
      id: json['id'] as String,
      amount: Money.fromRupees(_num(json['amount_inr'])),
      occurredAt: DateTime.parse(json['occurred_at'] as String),
      merchantName: json['merchant_name'] as String?,
      categoryId: json['category_id'] as String?,
      categoryName: json['category_name'] as String?,
      cardDisplayName: (nickname?.isNotEmpty == true) ? nickname : cardName,
      userCardId: json['user_card_id'] as String,
      rail: _parseRail(json['rail'] as String?),
      source: json['source'] as String? ?? 'manual',
      status: json['status'] as String? ?? 'active',
      note: json['note'] as String?,
      rewardValue: json['expected_value_inr'] == null
          ? null
          : Money.fromRupees(_num(json['expected_value_inr'])),
    );
  }

  static TxnRail _parseRail(String? value) {
    if (value == null) return TxnRail.unknown;
    final camel = value.split('_').indexed.map((e) {
      final (i, part) = e;
      if (part.isEmpty) return '';
      return i == 0 ? part : part[0].toUpperCase() + part.substring(1);
    }).join();
    return TxnRail.values.firstWhere((r) => r.name == camel, orElse: () => TxnRail.unknown);
  }
}

/// UA-5.3 (Chunk 31): the outcome of a POST /transactions/from-sms call.
/// [parsed] false with a [reason] is a normal, expected outcome (the server
/// logged a parser_failures row instead of a transaction) — not exceptional.
class SmsImportResult {
  final bool parsed;
  final String? reason;
  const SmsImportResult({required this.parsed, this.reason});
}

/// Task D-5 (ui-spec D5 Duplicate Review) — one side of a suspected-
/// duplicate pair. Deliberately a smaller shape than [TransactionEntry]
/// (no category, no note) — GET /duplicate-candidates only ever selects
/// the fields D5's side-by-side comparison actually shows.
class DuplicateTransactionSummary {
  final String id;
  final Money amount;
  final DateTime occurredAt;
  final String? merchantName;
  final String source;
  final String status;
  final String? cardDisplayName;

  const DuplicateTransactionSummary({
    required this.id,
    required this.amount,
    required this.occurredAt,
    this.merchantName,
    required this.source,
    required this.status,
    this.cardDisplayName,
  });

  factory DuplicateTransactionSummary.fromJson(Map<String, dynamic> json) {
    final nickname = json['card_nickname'] as String?;
    final cardName = json['card_name'] as String?;
    return DuplicateTransactionSummary(
      id: json['id'] as String,
      amount: Money.fromRupees(_num(json['amount_inr'])),
      occurredAt: DateTime.parse(json['occurred_at'] as String),
      merchantName: json['merchant_name'] as String?,
      source: json['source'] as String,
      status: json['status'] as String,
      cardDisplayName: (nickname?.isNotEmpty == true) ? nickname : cardName,
    );
  }
}

class DuplicateCandidate {
  final String id;
  final DuplicateTransactionSummary txnA;
  final DuplicateTransactionSummary txnB;
  final double matchScore;
  final String matchReason;

  const DuplicateCandidate({
    required this.id,
    required this.txnA,
    required this.txnB,
    required this.matchScore,
    required this.matchReason,
  });

  factory DuplicateCandidate.fromJson(Map<String, dynamic> json) {
    return DuplicateCandidate(
      id: json['id'] as String,
      txnA: DuplicateTransactionSummary.fromJson(json['txn_a'] as Map<String, dynamic>),
      txnB: DuplicateTransactionSummary.fromJson(json['txn_b'] as Map<String, dynamic>),
      matchScore: _num(json['match_score']),
      matchReason: json['match_reason'] as String,
    );
  }
}
