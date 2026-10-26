import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:uuid/uuid.dart';

import 'api_exception.dart';
import 'local/sms_dismissal_outbox.dart';
import 'local/sms_learning_privacy.dart';

// A report screen must never remain in a loading state because a mobile
// socket or the API has stopped making progress. Callers that support stale
// reads (Insights, Activity, and Spending) can then fall back to their local
// snapshot; direct callers render a bounded error with retry.
const _transactionRequestTimeout = Duration(seconds: 15);

double _num(dynamic v) =>
    v == null ? 0 : (v is num ? v.toDouble() : double.parse(v as String));

Money _nonNegativeMoney(dynamic v) {
  final value = Money.fromRupees(_num(v));
  return value.isNegative ? const Money.zero() : value;
}

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

  /// Catalogue type, when the API exposes it (`credit`, `debit`, ...). This
  /// is display/matching metadata; SMS attribution still comes from the
  /// server-side instrument resolver.
  final String? cardType;
  final bool isDefault;
  final Map<String, Money>
  capConsumed; // capRule.id -> consumed (in the cap's own measure unit)
  final Map<String, Money>
  milestoneQualifiedSpend; // milestoneRule.id -> qualified spend so far
  final Map<String, DateTime>
  milestonePeriodEnd; // milestoneRule.id -> this period's deadline (E4)
  final double
  totalPointsEarned; // lifetime, in the reward's own native unit — not an INR Money
  /// The current starting/estimated balance entered for this card. This is
  /// intentionally separate from [totalPointsEarned], which also includes
  /// the points ledger and is therefore not a form value the user entered.
  final double? pointsBalance;
  final List<FeeWaiverProgress> feeWaiverStates;

  /// Task 11 (E7 Billing Cycle Float): day-of-month the statement cuts, and
  /// when the card was opened. Both null until the user sets a statement
  /// day (no capture flow exists yet — C4 Edit Card, deferred) — Billing
  /// Cycle Float must degrade to a prompt rather than fabricate a date.
  final int? statementDay;
  final String? statementDaySource;
  final DateTime? openedOn;

  /// Task E-0 (Group E plan): all three already existed in Postgres
  /// (0004_user_domain.sql) but were dropped by GET /user-cards until now.
  /// [creditLimit] gates E3 Credit Utilization (null == user hasn't entered
  /// one — E3 must exclude the card and prompt, never assume a limit).
  /// [dueDay] feeds E8's calendar. [anniversaryOn] feeds E5's
  /// days-to-anniversary.
  final Money? creditLimit;

  /// Optional per-user annual-fee override. A zero value means the issuer
  /// treats this particular card as lifetime free; null means use the
  /// catalogue fee. This is intentionally user-scoped because LTF offers
  /// vary by customer even when the card product is the same.
  final Money? annualFeeOverride;
  final int? dueDay;
  final String? dueDaySource;
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

  /// Migration 0039 — the last four digits of the card number.
  ///
  /// A MATCHING KEY, never card data: it is what lets an incoming bank
  /// SMS or forwarded email be attached to this card automatically. Before
  /// it existed, every import route required the user to pick a card for
  /// every single message, which is why nothing was ever captured
  /// automatically. Null means the user hasn't entered it, and imports
  /// fall back to asking — the old behaviour, not a broken one.
  final String? last4;

  /// True when this card's [cardProductId] could not be matched to any row
  /// in the catalogue it was resolved against — a guest card added under an
  /// older/embedded catalogue whose ids no longer exist. Such a card has no
  /// name, art, or rules to show and is excluded from ranking; the wallet
  /// surfaces it as "Unrecognized card" with a Remove action rather than a
  /// silent, unusable "Card" tile. Always false on the signed-in path (the
  /// server always returns `card_name`). Derived at join time, never
  /// persisted.
  final bool isUnresolved;

  const UserCard({
    required this.id,
    required this.cardProductId,
    this.nickname,
    required this.cardName,
    this.cardType,
    required this.isDefault,
    this.isUnresolved = false,
    this.capConsumed = const {},
    this.milestoneQualifiedSpend = const {},
    this.milestonePeriodEnd = const {},
    this.totalPointsEarned = 0,
    this.pointsBalance,
    this.feeWaiverStates = const [],
    this.statementDay,
    this.statementDaySource,
    this.openedOn,
    this.creditLimit,
    this.annualFeeOverride,
    this.dueDay,
    this.dueDaySource,
    this.anniversaryOn,
    this.isArchived = false,
    this.autopayMode = AutopayMode.off,
    this.last4,
  });

  factory UserCard.fromJson(Map<String, dynamic> json) {
    final capStates = (json['cap_states'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final milestoneStates = (json['milestone_states'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final feeWaiverStates = (json['fee_waiver_states'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    return UserCard(
      id: json['id'] as String,
      cardProductId: json['card_product_id'] as String,
      nickname: json['nickname'] as String?,
      cardName: json['card_name'] as String,
      cardType: json['card_type'] as String?,
      isDefault: json['is_default'] as bool? ?? false,
      capConsumed: {
        for (final s in capStates)
          s['cap_rule_id'] as String: Money.fromRupees(_num(s['consumed'])),
      },
      milestoneQualifiedSpend: {
        for (final s in milestoneStates)
          s['milestone_rule_id'] as String: Money.fromRupees(
            _num(s['qualified_spend']),
          ),
      },
      milestonePeriodEnd: {
        for (final s in milestoneStates)
          if (s['period_end'] != null)
            s['milestone_rule_id'] as String: DateTime.parse(
              s['period_end'] as String,
            ),
      },
      totalPointsEarned: _num(json['total_points_earned']),
      pointsBalance: json['points_balance'] == null
          ? null
          : _num(json['points_balance']),
      feeWaiverStates: feeWaiverStates.map(FeeWaiverProgress.fromJson).toList(),
      statementDay: json['statement_day'] as int?,
      statementDaySource: json['statement_day_source'] as String?,
      openedOn: json['opened_on'] == null
          ? null
          : DateTime.parse(json['opened_on'] as String),
      creditLimit: json['credit_limit_inr'] == null
          ? null
          : Money.fromRupees(_num(json['credit_limit_inr'])),
      annualFeeOverride: json['annual_fee_override_inr'] == null
          ? null
          : Money.fromRupees(_num(json['annual_fee_override_inr'])),
      dueDay: json['due_day'] as int?,
      dueDaySource: json['due_day_source'] as String?,
      anniversaryOn: json['anniversary_on'] == null
          ? null
          : DateTime.parse(json['anniversary_on'] as String),
      isArchived: json['is_archived'] as bool? ?? false,
      autopayMode: AutopayMode.fromJson(json['autopay_mode'] as String?),
      last4: json['last4'] as String?,
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
    'card_type': cardType,
    'is_default': isDefault,
    'cap_states': [
      for (final entry in capConsumed.entries)
        {'cap_rule_id': entry.key, 'consumed': entry.value.rupees},
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
    'points_balance': pointsBalance,
    'statement_day': statementDay,
    'statement_day_source': statementDaySource,
    'opened_on': openedOn?.toIso8601String(),
    'credit_limit_inr': creditLimit?.rupees,
    'annual_fee_override_inr': annualFeeOverride?.rupees,
    'due_day': dueDay,
    'due_day_source': dueDaySource,
    'anniversary_on': anniversaryOn?.toIso8601String(),
    'is_archived': isArchived,
    'autopay_mode': autopayMode.wireValue,
    'last4': last4,
  };
}

/// What paid for a transaction — migration 0040's `transactions.instrument`.
///
/// Only [creditCard] moves cap, milestone, points and fee-waiver state:
/// those counters describe one card's billing cycle, and a cash purchase or
/// a bank-to-bank UPI payment moves none of them.
enum TxnInstrument {
  creditCard('credit_card', 'Credit card'),
  debitCard('debit_card', 'Debit card'),
  cash('cash', 'Cash'),
  upiBank('upi_bank', 'UPI from bank'),
  wallet('wallet', 'Wallet'),
  other('other', 'Other');

  final String wireValue;
  final String label;
  const TxnInstrument(this.wireValue, this.label);

  static TxnInstrument fromJson(String? value) =>
      TxnInstrument.values.firstWhere(
        (i) => i.wireValue == value,
        orElse: () => TxnInstrument.creditCard,
      );
}

/// Whether an entry is spending at all — migration 0040's
/// `transactions.entry_kind`.
///
/// Income and investments are reported on their own lines and NEVER added
/// into a spend total; a transfer between the user's own accounts is not
/// spend in either direction. Folding them together is the fastest way to
/// make every budget figure meaningless.
enum TxnEntryKind {
  spend('spend', 'Spending'),
  income('income', 'Money in'),
  investment('investment', 'Investment'),
  transfer('transfer', 'Transfer');

  final String wireValue;
  final String label;
  const TxnEntryKind(this.wireValue, this.label);

  static TxnEntryKind fromJson(String? value) => TxnEntryKind.values.firstWhere(
    (k) => k.wireValue == value,
    orElse: () => TxnEntryKind.spend,
  );
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
  static AutopayMode fromJson(String? value) => AutopayMode.values.firstWhere(
    (m) => m.wireValue == value,
    orElse: () => AutopayMode.off,
  );

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
class TransactionSplitDocument {
  final List<TransactionSplit> splits;
  final String? fingerprint;
  const TransactionSplitDocument(this.splits, {this.fingerprint});

  factory TransactionSplitDocument.fromJson(Map<String, dynamic> json) =>
      TransactionSplitDocument(
        (json['splits'] as List)
            .cast<Map<String, dynamic>>()
            .map(TransactionSplit.fromJson)
            .toList(),
        fingerprint: json['fingerprint'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'splits': [
      for (final s in splits)
        {
          'id': s.id,
          'user_card_id': s.userCardId,
          'category_id': s.categoryId,
          'category_name': s.categoryName,
          'amount_inr': s.amount.rupees,
          'note': s.note,
        },
    ],
  };
}

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

  factory TransactionSplit.fromJson(Map<String, dynamic> json) =>
      TransactionSplit(
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
      waivedAt: json['waived_at'] == null
          ? null
          : DateTime.parse(json['waived_at'] as String),
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
      state: json['state'] == 'confirmed'
          ? Confidence.confirmed
          : Confidence.estimated,
      expiresOn: json['expires_on'] == null
          ? null
          : DateTime.parse(json['expires_on'] as String),
      occurredAt: DateTime.parse(json['occurred_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'delta_points': deltaPoints,
    'reason': reason,
    'state': state == Confidence.confirmed ? 'confirmed' : 'estimated',
    'expires_on': expiresOn?.toIso8601String(),
    'occurred_at': occurredAt.toIso8601String(),
  };
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

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_card_id': userCardId,
    'benefit_id': benefitId,
    'used_on': usedOn.toIso8601String(),
    'airport': airport,
    'logged_manually': loggedManually,
  };
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
      totalSpend: _nonNegativeMoney(json['total_spend_inr']),
      rewardsEarned: _nonNegativeMoney(json['rewards_earned_inr']),
      baselineSingleCard: _nonNegativeMoney(json['baseline_single_card_inr']),
      valueMissed: _nonNegativeMoney(json['value_missed_inr']),
      extraEarned: _nonNegativeMoney(json['extra_earned_inr']),
    );
  }

  Map<String, dynamic> toJson() => {
    'period_month': periodMonth.toIso8601String(),
    'total_spend_inr': totalSpend.rupees,
    'rewards_earned_inr': rewardsEarned.rupees,
    'baseline_single_card_inr': baselineSingleCard.rupees,
    'value_missed_inr': valueMissed.rupees,
    'extra_earned_inr': extraEarned.rupees,
  };
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
      publishedMerchantCount: int.parse(
        json['published_merchant_count'].toString(),
      ),
      contributingDeviceCount: int.parse(
        json['contributing_device_count'].toString(),
      ),
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

  /// Short-lived, server-signed proof that this authenticated user opened
  /// Home. Never persist this value in the offline summary cache.
  final String? engagementReceiptToken;

  const HomeSummary({
    required this.rewardsThisMonth,
    required this.rewardsAllTime,
    required this.transactionCount,
    required this.streakDays,
    this.engagementReceiptToken,
  });

  factory HomeSummary.fromJson(Map<String, dynamic> json) {
    return HomeSummary(
      rewardsThisMonth: Money.fromRupees(_num(json['rewardsThisMonthInr'])),
      rewardsAllTime: Money.fromRupees(_num(json['rewardsAllTimeInr'])),
      transactionCount: int.parse((json['transactionCount'] ?? 0).toString()),
      streakDays: int.parse((json['streakDays'] ?? 0).toString()),
      engagementReceiptToken: json['engagementReceipt'] as String?,
    );
  }
}

/// One masked bank account observed in an imported SMS. A balance is only
/// present when the bank explicitly included an available/current balance in
/// that message, so the UI must describe it as a latest SMS snapshot rather
/// than a live bank balance.
class BankAccountSummary {
  final String accountLast4;
  final Money? availableBalance;

  /// Timestamp of the SMS that supplied [availableBalance]. This may be
  /// older than [latestSmsAt] when newer SMS messages omit a balance.
  final DateTime? latestBalanceSmsAt;
  final DateTime? latestSmsAt;
  final int smsCount;
  final String? issuerSlug;
  final String? issuerName;
  final String? issuerShortName;
  final String? issuerLogoUrl;
  final bool isBalanceManuallySet;
  final DateTime? manualBalanceUpdatedAt;

  const BankAccountSummary({
    required this.accountLast4,
    required this.availableBalance,
    this.latestBalanceSmsAt,
    required this.latestSmsAt,
    required this.smsCount,
    this.issuerSlug,
    this.issuerName,
    this.issuerShortName,
    this.issuerLogoUrl,
    this.isBalanceManuallySet = false,
    this.manualBalanceUpdatedAt,
  });

  factory BankAccountSummary.fromJson(Map<String, dynamic> json) {
    return BankAccountSummary(
      accountLast4: json['accountLast4'] as String,
      availableBalance: json['availableBalanceInr'] == null
          ? null
          : Money.fromRupees(_num(json['availableBalanceInr'])),
      latestBalanceSmsAt: json['latestBalanceSmsAt'] == null
          ? null
          : DateTime.parse(json['latestBalanceSmsAt'] as String),
      latestSmsAt: json['latestSmsAt'] == null
          ? null
          : DateTime.parse(json['latestSmsAt'] as String),
      smsCount: int.tryParse((json['smsCount'] ?? 0).toString()) ?? 0,
      issuerSlug: json['issuerSlug'] as String?,
      issuerName: json['issuerName'] as String?,
      issuerShortName: json['issuerShortName'] as String?,
      issuerLogoUrl: json['issuerLogoUrl'] as String?,
      isBalanceManuallySet: json['isBalanceManuallySet'] == true,
      manualBalanceUpdatedAt: json['manualBalanceUpdatedAt'] == null
          ? null
          : DateTime.parse(json['manualBalanceUpdatedAt'] as String),
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
      readAt: json['read_at'] == null
          ? null
          : DateTime.parse(json['read_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'category': category,
    'severity': severity,
    'title': title,
    'body': body,
    'deep_link': deepLink,
    'read_at': readAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
  };
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
      qualifyingAction:
          program?['qualifying_action'] as String? ?? 'first ranked payment',
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

  const Referral({
    required this.id,
    this.label,
    required this.rewardState,
    required this.createdAt,
  });

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
  final bool isPlaceholder;
  final String? issuerName;

  /// `credit` or `debit` when the SMS or catalogue made that distinction.
  final String? cardType;
  final Money? creditLimit;

  /// True when discovery found the same card already in the wallet. The
  /// suggestion stays visible, but its add action is disabled.
  final bool isAlreadyOwned;

  const DiscoveredCard({
    required this.cardProductId,
    required this.name,
    required this.score,
    required this.evidence,
    required this.last4,
    required this.messageCount,
    required this.sources,
    this.isPlaceholder = false,
    this.issuerName,
    this.cardType,
    this.creditLimit,
    this.isAlreadyOwned = false,
  });

  factory DiscoveredCard.fromJson(Map<String, dynamic> json) => DiscoveredCard(
    cardProductId: json['cardProductId'] as String,
    name: json['name'] as String,
    score: _num(json['score']),
    evidence: ((json['evidence'] as List?) ?? const []).cast<String>(),
    last4: ((json['last4'] as List?) ?? const []).cast<String>(),
    messageCount: (json['messageCount'] as num?)?.toInt() ?? 1,
    sources: ((json['sources'] as List?) ?? const []).cast<String>(),
    isPlaceholder: json['isPlaceholder'] as bool? ?? false,
    issuerName: json['issuerName'] as String?,
    cardType: json['cardType'] as String?,
    creditLimit: json['creditLimitInr'] == null
        ? null
        : Money.fromRupees(_num(json['creditLimitInr'])),
    isAlreadyOwned: json['isAlreadyOwned'] as bool? ?? false,
  );

  DiscoveredCard copyWith({String? name, bool? isAlreadyOwned}) =>
      DiscoveredCard(
        cardProductId: cardProductId,
        name: name ?? this.name,
        score: score,
        evidence: evidence,
        last4: last4,
        messageCount: messageCount,
        sources: sources,
        isPlaceholder: isPlaceholder,
        issuerName: issuerName,
        cardType: cardType,
        creditLimit: creditLimit,
        isAlreadyOwned: isAlreadyOwned ?? this.isAlreadyOwned,
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

class DismissalQueueEntry {
  final String sourceKey;
  final String? sender;
  final String? reason;
  final String? templateText;
  final String? sampleBody;
  final String? family;
  final DateTime queuedAt;

  const DismissalQueueEntry({
    required this.sourceKey,
    this.sender,
    this.reason,
    this.templateText,
    this.sampleBody,
    this.family,
    required this.queuedAt,
  });

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    if (sender != null) 'sender': sender,
    if (reason != null) 'reason': reason,
    if (templateText != null) 'templateText': templateText,
    if (sampleBody != null) 'sampleBody': sampleBody,
    if (family != null) 'family': family,
    'queuedAt': queuedAt.toUtc().toIso8601String(),
  };
}

/// The server-owned identity used to find transactions related to a category
/// edit.  Keep this as an enum so a newly introduced match policy can be
/// displayed or logged without breaking older clients.
enum RelatedTransactionMatchBasis {
  vpa,
  canonicalMerchant,
  strictName,
  unknown;

  static RelatedTransactionMatchBasis fromJson(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'vpa' => RelatedTransactionMatchBasis.vpa,
      'canonical_merchant' ||
      'canonicalmerchant' => RelatedTransactionMatchBasis.canonicalMerchant,
      'strict_name' || 'strictname' => RelatedTransactionMatchBasis.strictName,
      _ => RelatedTransactionMatchBasis.unknown,
    };
  }
}

/// How the server classified a related transaction in a preview.
enum RelatedTransactionSelectionTier {
  defaultSelected,
  manualReview,
  ineligible,
  unknown;

  static RelatedTransactionSelectionTier fromJson(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'default_selected' ||
      'defaultselected' ||
      'selected' => RelatedTransactionSelectionTier.defaultSelected,
      'manual_review' ||
      'manualreview' ||
      'review' => RelatedTransactionSelectionTier.manualReview,
      'ineligible' || 'excluded' => RelatedTransactionSelectionTier.ineligible,
      _ => RelatedTransactionSelectionTier.unknown,
    };
  }
}

/// A transaction returned by the category-related preview endpoint.
///
/// The client treats the IDs, selection tier and row version as server-owned
/// data. It must send selected IDs back unchanged instead of reconstructing a
/// merchant match locally.
class RelatedTransactionCandidate {
  final String id;
  final DateTime occurredAt;
  final Money amount;
  final String? paymentSource;
  final String? currentCategoryId;
  final String? currentUserCategoryId;
  final String? currentCategoryName;
  final String? currentSubcategoryName;
  final RelatedTransactionSelectionTier selectionTier;
  final String? reason;
  final DateTime? updatedAt;
  final String? rowVersion;

  const RelatedTransactionCandidate({
    required this.id,
    required this.occurredAt,
    required this.amount,
    this.paymentSource,
    this.currentCategoryId,
    this.currentUserCategoryId,
    this.currentCategoryName,
    this.currentSubcategoryName,
    required this.selectionTier,
    this.reason,
    this.updatedAt,
    this.rowVersion,
  });

  bool get isDefaultSelected =>
      selectionTier == RelatedTransactionSelectionTier.defaultSelected;
  bool get isSelectable =>
      selectionTier != RelatedTransactionSelectionTier.ineligible;

  String get currentCategoryLabel =>
      currentSubcategoryName == null || currentCategoryName == null
      ? (currentCategoryName ?? 'Other')
      : '$currentCategoryName · $currentSubcategoryName';

  factory RelatedTransactionCandidate.fromJson(Map<String, dynamic> json) {
    final rawCategoryId = _firstString(json, const [
      'currentCategoryId',
      'current_category_id',
      'categoryId',
      'category_id',
    ]);
    final userCategoryId = _firstString(json, const [
      'currentUserCategoryId',
      'current_user_category_id',
      'userCategoryId',
      'user_category_id',
    ]);
    return RelatedTransactionCandidate(
      id: _requiredString(json, const [
        'id',
        'transactionId',
        'transaction_id',
      ]),
      occurredAt: _requiredDateTime(json, const [
        'occurredAt',
        'occurred_at',
        'date',
      ]),
      amount: Money.fromRupees(
        _num(_firstValue(json, const ['amountInr', 'amount_inr', 'amount'])),
      ),
      paymentSource: _firstString(json, const [
        'paymentSource',
        'payment_source',
        'cardDisplayName',
        'card_display_name',
        'accountLabel',
        'account_label',
        'merchantName',
        'merchant_name',
      ]),
      currentCategoryId: rawCategoryId,
      currentUserCategoryId: userCategoryId,
      currentCategoryName: _firstString(json, const [
        'currentCategoryName',
        'current_category_name',
        'categoryName',
        'category_name',
      ]),
      currentSubcategoryName: _firstString(json, const [
        'currentSubcategoryName',
        'current_subcategory_name',
        'subcategoryName',
        'subcategory_name',
      ]),
      selectionTier: RelatedTransactionSelectionTier.fromJson(
        _firstValue(json, const ['selectionTier', 'selection_tier', 'tier']),
      ),
      reason: _firstString(json, const [
        'reason',
        'ineligibleReason',
        'ineligible_reason',
      ]),
      updatedAt: _optionalDateTime(json, const ['updatedAt', 'updated_at']),
      rowVersion: _firstString(json, const [
        'rowVersion',
        'row_version',
        'version',
      ]),
    );
  }
}

/// The server snapshot used to render and later validate the review sheet.
class RelatedCategoryPreview {
  final String previewId;
  final String sourceTransactionId;
  final String? targetCategoryId;
  final String? targetUserCategoryId;
  final String? targetCategoryName;
  final RelatedTransactionMatchBasis matchBasis;
  final int totalCandidateCount;
  final int selectableCandidateCount;
  final int defaultSelectedCount;
  final bool overflow;
  final List<RelatedTransactionCandidate> candidates;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  const RelatedCategoryPreview({
    required this.previewId,
    required this.sourceTransactionId,
    this.targetCategoryId,
    this.targetUserCategoryId,
    this.targetCategoryName,
    required this.matchBasis,
    required this.totalCandidateCount,
    required this.selectableCandidateCount,
    required this.defaultSelectedCount,
    required this.overflow,
    required this.candidates,
    this.createdAt,
    this.expiresAt,
  });

  List<String> get defaultSelectedTransactionIds => [
    for (final candidate in candidates)
      if (candidate.isDefaultSelected) candidate.id,
  ];

  factory RelatedCategoryPreview.fromJson(Map<String, dynamic> json) {
    final rawCandidates = _firstValue(json, const [
      'candidates',
      'transactions',
      'relatedTransactions',
      'related_transactions',
    ]);
    final candidates = rawCandidates is List
        ? rawCandidates
              .whereType<Map>()
              .map(
                (item) => RelatedTransactionCandidate.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .toList(growable: false)
        : const <RelatedTransactionCandidate>[];
    final defaultCount =
        _firstInt(json, const [
          'defaultSelectedCount',
          'default_selected_count',
        ]) ??
        candidates.where((candidate) => candidate.isDefaultSelected).length;
    return RelatedCategoryPreview(
      previewId: _requiredString(json, const ['previewId', 'preview_id', 'id']),
      sourceTransactionId: _requiredString(json, const [
        'sourceTransactionId',
        'source_transaction_id',
        'transactionId',
        'transaction_id',
      ]),
      targetCategoryId: _firstString(json, const [
        'targetCategoryId',
        'target_category_id',
        'categoryId',
        'category_id',
      ]),
      targetUserCategoryId: _firstString(json, const [
        'targetUserCategoryId',
        'target_user_category_id',
        'userCategoryId',
        'user_category_id',
      ]),
      targetCategoryName: _firstString(json, const [
        'targetCategoryName',
        'target_category_name',
        'categoryName',
        'category_name',
      ]),
      matchBasis: RelatedTransactionMatchBasis.fromJson(
        _firstValue(json, const ['matchBasis', 'match_basis']),
      ),
      totalCandidateCount:
          _firstInt(json, const [
            'totalCandidateCount',
            'total_candidate_count',
            'totalCount',
            'total_count',
          ]) ??
          candidates.length,
      selectableCandidateCount:
          _firstInt(json, const [
            'selectableCandidateCount',
            'selectable_candidate_count',
            'selectableCount',
            'selectable_count',
          ]) ??
          candidates.where((candidate) => candidate.isSelectable).length,
      defaultSelectedCount: defaultCount,
      overflow:
          _firstBool(json, const ['overflow', 'hasOverflow', 'has_overflow']) ??
          false,
      candidates: candidates,
      createdAt: _optionalDateTime(json, const ['createdAt', 'created_at']),
      expiresAt: _optionalDateTime(json, const ['expiresAt', 'expires_at']),
    );
  }
}

/// Result returned after an atomic category bulk apply.
class CategoryBulkApplyResult {
  final String operationId;
  final int changedCount;
  final int unchangedCount;
  final String? targetCategoryId;
  final String? targetUserCategoryId;
  final List<String> affectedTransactionIds;

  const CategoryBulkApplyResult({
    required this.operationId,
    required this.changedCount,
    required this.unchangedCount,
    this.targetCategoryId,
    this.targetUserCategoryId,
    this.affectedTransactionIds = const [],
  });

  factory CategoryBulkApplyResult.fromJson(Map<String, dynamic> json) {
    final ids = _firstValue(json, const [
      'affectedTransactionIds',
      'affected_transaction_ids',
      'changedTransactionIds',
      'changed_transaction_ids',
      'transactionIds',
      'transaction_ids',
    ]);
    return CategoryBulkApplyResult(
      operationId: _requiredString(json, const [
        'operationId',
        'operation_id',
        'id',
      ]),
      changedCount:
          _firstInt(json, const ['changedCount', 'changed_count']) ?? 0,
      unchangedCount:
          _firstInt(json, const ['unchangedCount', 'unchanged_count']) ?? 0,
      targetCategoryId: _firstString(json, const [
        'targetCategoryId',
        'target_category_id',
        'categoryId',
        'category_id',
      ]),
      targetUserCategoryId: _firstString(json, const [
        'targetUserCategoryId',
        'target_user_category_id',
        'userCategoryId',
        'user_category_id',
      ]),
      affectedTransactionIds: ids is List
          ? ids.whereType<String>().toList(growable: false)
          : const [],
    );
  }
}

/// A 409 means the review snapshot is stale and the caller should fetch a
/// fresh preview. It is intentionally distinct from a generic API failure so
/// the UI can retain its selection/retry affordance.
class CategoryBulkConflictException extends ApiException {
  CategoryBulkConflictException(String debugMessage)
    : super(
        debugMessage,
        userMessage:
            'Some transactions changed since this list was shown. Review the refreshed list.',
      );
}

dynamic _firstValue(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    if (json.containsKey(key) && json[key] != null) return json[key];
  }
  return null;
}

String? _firstString(Map<String, dynamic> json, List<String> keys) {
  final value = _firstValue(json, keys);
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _requiredString(Map<String, dynamic> json, List<String> keys) {
  final value = _firstString(json, keys);
  if (value == null) {
    throw const FormatException('Missing required string in API response');
  }
  return value;
}

int? _firstInt(Map<String, dynamic> json, List<String> keys) {
  final value = _firstValue(json, keys);
  if (value is int) return value;
  if (value is num) return value.toInt();
  return value is String ? int.tryParse(value) : null;
}

bool? _firstBool(Map<String, dynamic> json, List<String> keys) {
  final value = _firstValue(json, keys);
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  return null;
}

DateTime _requiredDateTime(Map<String, dynamic> json, List<String> keys) {
  final value = _firstString(json, keys);
  if (value == null) {
    throw const FormatException('Missing required date in API response');
  }
  return DateTime.parse(value);
}

DateTime? _optionalDateTime(Map<String, dynamic> json, List<String> keys) {
  final value = _firstString(json, keys);
  return value == null ? null : DateTime.tryParse(value);
}

class UserCardsRepository {
  final List<DismissalQueueEntry> _dismissalRetryQueue = [];
  final Future<SmsDismissalOutbox> Function()? dismissalOutbox;

  List<DismissalQueueEntry> get dismissalRetryQueue =>
      List.unmodifiable(_dismissalRetryQueue);
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  /// The server accepted this stable manual mutation, including an outbox
  /// retry. Local tag links can now move from local-outbox:<mutation> to id.
  final void Function(String clientMutationId, String transactionId)?
  onTransactionSaved;
  final Future<void> Function(SmsBatchMessage)? onSmsCaptured;
  final Future<void> Function(List<SmsBatchMessage>)? onSmsBatchCaptured;
  final Future<void> Function(
    List<SmsBatchMessage>,
    List<Map<String, dynamic>>,
    bool,
  )?
  onSmsUploaded;

  UserCardsRepository({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
    this.onTransactionSaved,
    this.onSmsCaptured,
    this.onSmsBatchCaptured,
    this.onSmsUploaded,
    this.dismissalOutbox,
  }) : _client = client ?? http.Client();
  Future<void> captureSmsMessages(List<SmsBatchMessage> messages) async {
    if (onSmsBatchCaptured != null) {
      await onSmsBatchCaptured!(messages);
      return;
    }
    for (final message in messages) {
      await onSmsCaptured?.call(message);
    }
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<List<UserCard>> fetchUserCards({bool includeArchived = false}) async {
    final uri = Uri.parse('$apiBaseUrl/user-cards').replace(
      queryParameters: includeArchived ? {'includeArchived': 'true'} : null,
    );
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /user-cards failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['userCards'] as List)
        .cast<Map<String, dynamic>>()
        .map(UserCard.fromJson)
        .toList();
  }

  /// Returns the newly-created `user_cards.id`. A9 (Card Details Setup)
  /// needs real ids to PATCH per-card right after adding a batch — this
  /// used to return void because nothing needed the id back until A7/A9
  /// existed; POST /user-cards already returns it (`{userCard: {id, ...}}`),
  /// this just stops discarding it.
  Future<String> addCard(
    String cardProductId, {
    String? nickname,
    String? last4,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/user-cards'),
          headers: _headers,
          body: jsonEncode({
            'cardProductId': cardProductId,
            'nickname': ?nickname,
            'last4': ?last4,
          }),
        )
        .timeout(const Duration(seconds: 60));
    // 201 means a new row was created; 200 means discovery enriched the
    // single existing product-only placeholder with its detected last four.
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw ApiException(
        'POST /user-cards failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['userCard'] as Map<String, dynamic>)['id'] as String;
  }

  Future<void> archiveCard(String userCardId) async {
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/user-cards/$userCardId/archive'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw ApiException(
        'archive failed: ${response.statusCode} ${response.body}',
      );
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
      throw ApiException(
        'set default failed: ${response.statusCode} ${response.body}',
      );
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
      throw ApiException(
        'unarchive failed: ${response.statusCode} ${response.body}',
      );
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
      throw ApiException(
        'reorder failed: ${response.statusCode} ${response.body}',
      );
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
    // Three-state, unlike the other optional fields: null means "don't
    // touch it", '' means "clear the stored digits", and four digits set
    // them. The null-aware `?` below skips only null, so an empty string
    // really does reach the server as a clear — which is what Edit Card
    // relies on when the user empties the field.
    String? last4,
  }) async {
    final body = <String, dynamic>{
      'nickname': ?nickname,
      'creditLimitInr': ?creditLimitInr,
      'statementDay': ?statementDay,
      'dueDay': ?dueDay,
      'pointsBalance': ?pointsBalance,
      'last4': ?last4,
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
      throw ApiException(
        'update failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Saves the customer's fee offer separately from the general card-edit
  /// contract. Keeping this as a dedicated method preserves compatibility
  /// with lightweight repository fakes and makes the three states explicit:
  /// catalogue fee, a custom fee, or lifetime free (zero).
  Future<void> updateAnnualFeeOverride(
    String userCardId, {
    double? annualFeeOverrideInr,
    bool clear = false,
  }) async {
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/user-cards/$userCardId'),
      headers: _headers,
      body: jsonEncode({
        'annualFeeOverrideInr': clear ? null : annualFeeOverrideInr,
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'annual fee update failed: ${response.statusCode} ${response.body}',
      );
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
  ///
  /// [userCardId] is required only for a credit-card entry. Migration 0040
  /// opened this route to cash, debit, UPI-from-bank, income and
  /// investments; those have no card by definition, and requiring one is
  /// what previously made them impossible to record at all. A non-card
  /// entry counts toward spend totals and budgets but moves NO card state —
  /// caps, milestones, points and fee waivers describe one card's billing
  /// cycle, and a cash purchase moves none of them.
  Future<String> logTransaction({
    String? userCardId,
    required Money amount,
    String? categoryId,
    String? userCategoryId,
    String? merchantName,
    String? merchantVpa,
    String? mcc,
    DateTime? occurredAt,
    String? note,
    String? rail,
    TxnInstrument instrument = TxnInstrument.creditCard,
    TxnEntryKind entryKind = TxnEntryKind.spend,
    String? clientMutationId,
  }) async {
    final mutationId = clientMutationId ?? const Uuid().v4();
    final customCategoryId =
        userCategoryId ??
        (categoryId != null && categoryId.startsWith('custom:')
            ? categoryId.substring('custom:'.length)
            : null);
    final serverCategoryId =
        categoryId != null && categoryId.startsWith('custom:')
        ? null
        : categoryId;
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/transactions'),
          headers: _headers,
          body: jsonEncode({
            'userCardId': ?userCardId,
            'amountInr': amount.rupees,
            'categoryId': ?serverCategoryId,
            'userCategoryId': ?customCategoryId,
            'merchantName': ?merchantName,
            'merchantVpa': ?merchantVpa,
            'mcc': ?mcc,
            'occurredAt': occurredAt?.toIso8601String(),
            'note': ?note,
            'rail': ?rail,
            'instrument': instrument.wireValue,
            'entryKind': entryKind.wireValue,
            'clientMutationId': mutationId,
          }),
        )
        .timeout(const Duration(seconds: 60));
    // A 200 is an exact retry whose first response was lost. The canonical
    // transaction is returned in both cases and must leave the outbox.
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw ApiException(
        'POST /transactions failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final id = (body['transaction'] as Map<String, dynamic>)['id'] as String;
    try {
      onTransactionSaved?.call(mutationId, id);
    } catch (_) {
      // A local follow-up cannot turn an accepted financial write into a
      // failed transaction. The tag outbox still holds its resolvable alias.
    }
    return id;
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
      throw ApiException(
        'note update failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Design 18 "Split this expense" — the current split set for one
  /// transaction, empty when it has never been split.
  Future<List<TransactionSplit>> fetchSplits(String transactionId) async {
    return (await fetchSplitDocument(transactionId)).splits;
  }

  Future<TransactionSplitDocument> fetchSplitDocument(
    String transactionId,
  ) async {
    final response = await _client
        .get(
          Uri.parse('$apiBaseUrl/transactions/$transactionId/splits'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw ApiException(
        'GET splits failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return TransactionSplitDocument.fromJson(body);
  }

  /// Replaces the whole split set. Replace rather than append is the
  /// server's contract too — a split is a partition of one amount, so the
  /// set is the only coherent unit of edit. An empty list clears the
  /// splits.
  Future<List<TransactionSplit>> saveSplits(
    String transactionId,
    List<TransactionSplit> splits,
  ) async {
    return (await saveSplitDocument(
      transactionId,
      TransactionSplitDocument(splits),
    )).splits;
  }

  Future<TransactionSplitDocument> saveSplitDocument(
    String transactionId,
    TransactionSplitDocument document,
  ) async {
    final response = await _client
        .put(
          Uri.parse('$apiBaseUrl/transactions/$transactionId/splits'),
          headers: _headers,
          body: jsonEncode({
            'splits': [for (final s in document.splits) s.toRequestJson()],
            if (document.fingerprint != null)
              'expectedFingerprint': document.fingerprint,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw ApiException(
        'save splits failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return TransactionSplitDocument.fromJson(body);
  }

  /// UA-5.3 (Chunk 31): SMS auto-import. Sends the raw SMS sender+body to
  /// POST /transactions/from-sms, which does the server-side regex parse
  /// (parser_patterns) and, on a match, the exact same cap/milestone/
  /// points/fee-waiver update as [logTransaction] above.
  ///
  /// [userCardId] is now OPTIONAL. It used to be required, because the
  /// parser extracts amount/merchant/last4/date but not which owned card a
  /// message belongs to — so the listener had to ask the user, once per
  /// message. The server now resolves it from `user_cards.last4` or from
  /// the issuer behind the matched pattern (api/src/import_resolvers.js),
  /// and when it can't be sure it records a cardless spend instead of asking
  /// the user to classify every message. Passing an explicit id still wins.
  ///
  /// A 200 with `parsed: false` is not an error — it means the message was
  /// not a successful transaction (for example an OTP or decline), or it did
  /// not contain enough fields to create one. Successful spend messages return
  /// `parsed: true` and are stored without a manual review step.
  Future<SmsImportResult> logTransactionFromSms({
    String? userCardId,
    required String sender,
    required String body,
    DateTime? occurredAt,
    bool backfill = false,
  }) async {
    final message = SmsBatchMessage(
      userCardId: userCardId,
      sender: sender,
      body: body,
      occurredAt: occurredAt ?? DateTime.now(),
    );
    await onSmsCaptured?.call(message);
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/transactions/from-sms'),
          headers: _headers,
          body: jsonEncode({
            'userCardId': ?userCardId,
            'sender': sender,
            'body': body,
            if (occurredAt != null)
              'occurredAt': occurredAt.toUtc().toIso8601String(),
            if (backfill) 'backfill': true,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw ApiException(
        'POST /transactions/from-sms failed: ${response.statusCode} ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    await onSmsUploaded?.call(
      [message],
      [
        {
          'index': 0,
          'outcome': json['parsed'] == true ? 'imported' : 'unparsed',
          'reason': json['reason'],
          'transactionId': (json['transaction'] as Map?)?['id'],
          'transaction': json['transaction'],
        },
      ],
      false,
    );
    return SmsImportResult(
      parsed: json['parsed'] == true,
      reason: json['reason'] as String?,
      duplicate: json['duplicate'] == true,
      needsReview: json['needsReview'] == true,
      categoryId: json['resolvedCategoryId'] as String?,
      dueDayUpdated: json['dueDayUpdated'] == true,
      statementDayUpdated: json['statementDayUpdated'] == true,
    );
  }

  /// Repairs safe legacy SMS replays and reclassifies transactions imported
  /// before merchant-category resolution was enabled. The server operation is
  /// user-scoped and idempotent; it never inserts a second transaction.
  Future<SmsReconciliationResult> reconcileSmsHistory() async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/transactions/reconcile-sms'),
      headers: _headers,
    );
    // Older production API images may still be serving the app while the
    // backend deployment is rolling out. Reconciliation is an enhancement to
    // the normal SMS sync, not a reason to fail the entire startup pass; the
    // next resume will retry once the route exists.
    if (response.statusCode == 400 || response.statusCode == 404) {
      return const SmsReconciliationResult.zero();
    }
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /transactions/reconcile-sms failed: ${response.statusCode} ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SmsReconciliationResult(
      reconciliationVersion:
          (json['reconciliationVersion'] as num?)?.toInt() ?? 0,
      duplicateSuppressed: (json['duplicateSuppressed'] as num?)?.toInt() ?? 0,
      crossSourceCandidatesCreated:
          (json['crossSourceCandidatesCreated'] as num?)?.toInt() ?? 0,
      linkedCards: (json['linkedCards'] as num?)?.toInt() ?? 0,
      reclassified: (json['reclassified'] as num?)?.toInt() ?? 0,
      classificationReclassified:
          (json['classificationReclassified'] as num?)?.toInt() ?? 0,
      remappedTransactions:
          (json['remappedTransactions'] as num?)?.toInt() ?? 0,
      remainingLegacyRows: (json['remainingLegacyRows'] as num?)?.toInt() ?? 0,
    );
  }

  /// Returns the server-side SMS observation count used by the background
  /// inbox reconciler to detect an account reset. This is deliberately a
  /// count, not message content: the device remains the source of truth for
  /// the inbox and the API only tells it whether its local checkpoint is no
  /// longer represented on the server.
  Future<SmsImportState> fetchSmsImportState() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/transactions/sms-import-state'),
      headers: _headers,
    );
    if (response.statusCode == 404) {
      // Older production API images may still be serving the app while this
      // recovery route rolls out. Keep the existing date-checkpoint behavior
      // until the next launch rather than making SMS import fail closed.
      return const SmsImportState.unavailable();
    }
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /transactions/sms-import-state failed: ${response.statusCode} ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SmsImportState(
      smsObservationCount: (json['smsObservationCount'] as num?)?.toInt() ?? 0,
      latestSmsObservedAt: json['latestSmsObservedAt'] == null
          ? null
          : DateTime.parse(json['latestSmsObservedAt'] as String),
    );
  }

  /// SMS intelligence Phase 2: uploads one typed-facts envelope to
  /// POST /sms/facts. The envelope carries NO raw body — source key, sender,
  /// body hash and the validated fact set only. Returns true when the caller
  /// should drop the envelope: accepted or idempotently replayed. A 404 means an older production
  /// image is still being served during rollout; returning false keeps the
  /// row queued for the next sync instead of failing SMS import.
  Future<bool> logSmsFacts({required Map<String, dynamic> envelope}) async {
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/sms/facts'),
          headers: _headers,
          body: jsonEncode(envelope),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) return false;
    // Preserve rejected facts for a future compatible build and diagnostics.
    // A server contract change must not silently erase the only durable copy.
    if (response.statusCode == 400) {
      throw ApiException('POST /sms/facts rejected: ${response.body}');
    }
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /sms/facts failed: ${response.statusCode} ${response.body}',
      );
    }
    return true;
  }

  Future<bool> logSmsRuleExposures({
    required List<Map<String, dynamic>> exposures,
  }) async {
    if (exposures.isEmpty) return true;
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/sms/rule-exposures'),
          headers: _headers,
          body: jsonEncode({'exposures': exposures}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) return false;
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /sms/rule-exposures failed: ${response.statusCode} ${response.body}',
      );
    }
    return true;
  }

  /// SMS intelligence Phase 4: uploads one structured correction for one
  /// fact slot of one source. A 404 means facts have not arrived yet and is
  /// retryable; a 400 is retained by the local outbox for repair/compatibility.
  Future<bool> overrideSmsFact({
    required String sourceKey,
    required int factIndex,
    required Map<String, dynamic> patch,
    String? reason,
    String? templateText,
    String? sampleBody,
  }) async {
    final safeTemplate = redactSmsLearningText(templateText);
    final safeSample = redactSmsLearningText(sampleBody);
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/sms/facts/overrides'),
          headers: _headers,
          body: jsonEncode({
            'sourceKey': sourceKey,
            'factIndex': factIndex,
            'patch': patch,
            'reason': ?reason,
            'templateText': ?safeTemplate,
            'sampleBody': ?safeSample,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) return false;
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /sms/facts/overrides failed: ${response.statusCode} ${response.body}',
      );
    }
    return true;
  }

  /// SMS intelligence Phase 3/5: uploads a structured dismissal signal for negative learning.
  /// Handles offline/network errors gracefully by recording to local retry queue so
  /// user experience is never disrupted.
  Future<bool> dismissSms({
    required String sourceKey,
    String? sender,
    String? reason,
    String? templateText,
    String? sampleBody,
    String? family,
  }) async {
    final safeTemplate = redactSmsLearningText(templateText);
    final safeSample = redactSmsLearningText(sampleBody);
    // A credential-bearing message has no safe learning evidence. The user's
    // local dismissal is already complete, so don't enqueue or transmit it.
    final hadEvidence =
        (templateText?.trim().isNotEmpty ?? false) ||
        (sampleBody?.trim().isNotEmpty ?? false);
    if (hadEvidence && safeTemplate == null && safeSample == null) return true;
    final entry = DismissalQueueEntry(
      sourceKey: sourceKey,
      sender: sender,
      reason: reason,
      templateText: safeTemplate,
      sampleBody: safeSample,
      family: family,
      queuedAt: DateTime.now(),
    );
    final payload = entry.toJson();
    SmsDismissalOutbox? durable;
    try {
      durable = await dismissalOutbox?.call();
      durable?.enqueue(sourceKey, payload);
    } catch (_) {
      // Keep the existing in-process retry as a fallback if local storage is
      // temporarily unavailable; never block the user's review decision.
    }
    try {
      final response = await _client
          .post(
            Uri.parse('$apiBaseUrl/sms/dismiss'),
            headers: _headers,
            body: jsonEncode({
              'sourceKey': sourceKey,
              'sender': ?sender,
              'reason': ?reason,
              'templateText': ?safeTemplate,
              'sampleBody': ?safeSample,
              'family': ?family,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        durable?.acknowledge(sourceKey);
        _dismissalRetryQueue.removeWhere((e) => e.sourceKey == sourceKey);
        return true;
      }
      if (!_dismissalRetryQueue.any((e) => e.sourceKey == sourceKey)) {
        _dismissalRetryQueue.add(entry);
      }
      return false;
    } catch (_) {
      // Offline / network failure: record to retry queue so user experience is not disrupted.
      if (!_dismissalRetryQueue.any((e) => e.sourceKey == sourceKey)) {
        _dismissalRetryQueue.add(entry);
      }
      return false;
    }
  }

  /// Retries queued dismissals that previously failed due to offline/network issues.
  Future<int> flushDismissalQueue() async {
    SmsDismissalOutbox? durable;
    try {
      durable = await dismissalOutbox?.call();
    } catch (_) {}
    final toRetry = List<DismissalQueueEntry>.from(_dismissalRetryQueue);
    for (final payload
        in durable?.pending() ?? const <Map<String, dynamic>>[]) {
      final sourceKey = payload['sourceKey'] as String?;
      if (sourceKey == null || toRetry.any((e) => e.sourceKey == sourceKey))
        continue;
      toRetry.add(
        DismissalQueueEntry(
          sourceKey: sourceKey,
          sender: payload['sender'] as String?,
          reason: payload['reason'] as String?,
          templateText: payload['templateText'] as String?,
          sampleBody: payload['sampleBody'] as String?,
          family: payload['family'] as String?,
          queuedAt:
              DateTime.tryParse(payload['queuedAt'] as String? ?? '') ??
              DateTime.now(),
        ),
      );
    }
    if (toRetry.isEmpty) return 0;
    var succeeded = 0;
    for (final entry in toRetry) {
      try {
        final response = await _client
            .post(
              Uri.parse('$apiBaseUrl/sms/dismiss'),
              headers: _headers,
              body: jsonEncode({
                'sourceKey': entry.sourceKey,
                if (entry.sender != null) 'sender': entry.sender,
                if (entry.reason != null) 'reason': entry.reason,
                if (entry.templateText != null)
                  'templateText': entry.templateText,
                if (entry.sampleBody != null) 'sampleBody': entry.sampleBody,
                if (entry.family != null) 'family': entry.family,
              }),
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          durable?.acknowledge(entry.sourceKey);
          _dismissalRetryQueue.removeWhere(
            (e) => e.sourceKey == entry.sourceKey,
          );
          succeeded++;
        }
      } catch (_) {
        // Keep in queue for next retry
      }
    }
    return succeeded;
  }

  /// SMS intelligence Phase 5: queues an unresolved SMS for server AI classification.
  /// Server deduplicates on (profile_id, source_id); retrying returns the same
  /// job ID and does not burn quota. Server refusals (400, 429, 503) return null
  /// so callers can distinguish explicit refusals from network errors.
  /// Transport/network exceptions are rethrown so transient failures are not
  /// swallowed as permanent rejections.
  Future<String?> submitAiJob({
    required String sourceKey,
    required String sender,
    required String body,
    DateTime? occurredAt,
    bool retryFailed = false,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/ai/jobs'),
          headers: _headers,
          body: jsonEncode({
            'sourceKey': sourceKey,
            'sender': sender,
            'body': body,
            if (retryFailed) 'retryFailed': true,
            if (occurredAt != null)
              'occurredAt': occurredAt.toUtc().toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return decoded['jobId'] as String?;
    }
    return null;
  }

  /// Returns redacted status for a previously queued SMS. The body and lease
  /// token are never returned; callers use this only to refresh local review
  /// state after the background worker finishes.
  ///
  /// Returns null ONLY on HTTP 404 (job not found). Throws [ApiException] on
  /// non-200 / non-404 server responses, and rethrows transport/network
  /// exceptions so callers can distinguish missing jobs from transient drops.
  Future<Map<String, dynamic>?> fetchAiJobStatus(String sourceKey) async {
    final response = await _client
        .get(
          Uri.parse('$apiBaseUrl/ai/jobs/source/$sourceKey'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /ai/jobs/source failed: ${response.statusCode} ${response.body}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Task S-1a: the batched form of [logTransactionFromSms], for backup-file
  /// import.
  ///
  /// The screen used to make one request per message in a sequential loop —
  /// a five-thousand-message export was five thousand round trips, which is
  /// slow enough that users background the app mid-import. The server caps a
  /// batch at 200; callers are expected to chunk.
  ///
  /// [backfill] skips the cap/milestone/fee-waiver state machine. Historical
  /// messages are real transactions but they are not progress the user made
  /// this cycle, and running years of them through the current cycle's
  /// counters is the D2 bug this exists to avoid.
  Future<SmsBatchImportResult> logTransactionsFromSmsBatch({
    required List<SmsBatchMessage> messages,
    bool backfill = true,
    bool captureLocally = true,
    bool notifyNewTransactions = false,
  }) async {
    if (captureLocally) await captureSmsMessages(messages);
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/transactions/from-sms/batch'),
          headers: _headers,
          body: jsonEncode({
            'backfill': backfill,
            'messages': [
              for (final m in messages)
                {
                  'userCardId': ?m.userCardId,
                  'sender': m.sender,
                  'body': m.body,
                  'occurredAt': m.occurredAt.toUtc().toIso8601String(),
                },
            ],
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /transactions/from-sms/batch failed: ${response.statusCode} ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final summary = json['summary'] as Map<String, dynamic>? ?? const {};
    final results = (json['results'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .toList();
    await onSmsUploaded?.call(messages, results, notifyNewTransactions);
    return SmsBatchImportResult(
      imported: (summary['imported'] as num?)?.toInt() ?? 0,
      duplicate: (summary['duplicate'] as num?)?.toInt() ?? 0,
      unparsed: (summary['unparsed'] as num?)?.toInt() ?? 0,
      invalid: (summary['invalid'] as num?)?.toInt() ?? 0,
      needsReview: (summary['needsReview'] as num?)?.toInt() ?? 0,
      errored: (summary['error'] as num?)?.toInt() ?? 0,
      dueDatesUpdated: (summary['dueDatesUpdated'] as num?)?.toInt() ?? 0,
      statementDaysUpdated:
          (summary['statementDaysUpdated'] as num?)?.toInt() ?? 0,
      // Indices are batch-relative; the caller maps them back to its own
      // list so callers can report genuinely unparsed messages without
      // turning successful cardless spends into a manual workflow.
      unparsedIndices: [
        for (final r in results)
          if (r['outcome'] == 'unparsed' || r['outcome'] == 'needs_review')
            (r['index'] as num).toInt(),
      ],
      reasonByIndex: {
        for (final r in results)
          if (r['reason'] != null)
            (r['index'] as num).toInt(): r['reason'] as String,
      },
    );
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
    String? userCategoryId,
    String? source,
    String? query,
  }) async {
    final params = <String, String>{
      if (from != null) 'from': _dateOnly(from),
      if (to != null) 'to': _dateOnly(to),
      'cardId': ?cardId,
      if (categoryId != null && categoryId.startsWith('custom:'))
        'userCategoryId': categoryId.substring('custom:'.length)
      else
        'categoryId': ?categoryId,
      'userCategoryId': ?userCategoryId,
      'source': ?source,
      // Server-side match over merchant name and note. Blank/whitespace is
      // dropped rather than sent, so an empty search box is "no filter"
      // rather than a query that matches everything with a wildcard.
      if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
    };
    final uri = Uri.parse(
      '$apiBaseUrl/transactions',
    ).replace(queryParameters: params.isEmpty ? null : params);
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(_transactionRequestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /transactions failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['transactions'] as List)
        .cast<Map<String, dynamic>>()
        .map(TransactionEntry.fromJson)
        .toList();
  }

  /// Soft-deleted transactions stay available here so users can recover an
  /// accidental delete without exposing them in the normal Activity feed.
  Future<List<TransactionEntry>> fetchDeletedTransactions() async {
    final uri = Uri.parse(
      '$apiBaseUrl/transactions',
    ).replace(queryParameters: const {'status': 'deleted'});
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(_transactionRequestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /transactions?status=deleted failed: ${response.statusCode} ${response.body}',
      );
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
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/transactions/$id'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /transactions/:id failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return TransactionEntry.fromJson(
      body['transaction'] as Map<String, dynamic>,
    );
  }

  /// Task D-3 (ui-spec D3 Edit Transaction). Only non-null fields are sent.
  Future<void> editTransaction(
    String id, {
    double? amountInr,
    DateTime? occurredAt,
    String? categoryId,
    String? userCategoryId,
    bool clearCategory = false,
    String? merchantName,
    TxnRail? rail,
    String? userCardId,
    TxnInstrument? instrument,
    TxnEntryKind? entryKind,
  }) async {
    if (clearCategory && (categoryId != null || userCategoryId != null)) {
      throw ArgumentError(
        'clearCategory cannot be combined with categoryId or userCategoryId',
      );
    }
    final customCategoryId =
        userCategoryId ??
        (categoryId != null && categoryId.startsWith('custom:')
            ? categoryId.substring('custom:'.length)
            : null);
    final serverCategoryId =
        categoryId != null && categoryId.startsWith('custom:')
        ? null
        : categoryId;
    final body = <String, dynamic>{
      'amountInr': ?amountInr,
      if (occurredAt != null) 'occurredAt': occurredAt.toIso8601String(),
      if (clearCategory) 'categoryId': null,
      if (clearCategory) 'userCategoryId': null,
      if (!clearCategory) 'categoryId': ?serverCategoryId,
      if (!clearCategory) 'userCategoryId': ?customCategoryId,
      'merchantName': ?merchantName,
      if (rail != null) 'rail': _railToJson(rail),
      'userCardId': ?userCardId,
      if (instrument != null) 'instrument': instrument.wireValue,
      if (entryKind != null) 'entryKind': entryKind.wireValue,
    };
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/transactions/$id'),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'PATCH /transactions/:id failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Explicitly clears both built-in and custom category identities. This is
  /// also available as a dedicated operation for callers that do not already
  /// have an edit payload.
  Future<void> clearTransactionCategory(String id) async {
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/transactions/$id'),
      headers: _headers,
      body: jsonEncode(const {'categoryId': null, 'userCategoryId': null}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'PATCH /transactions/:id (clear category) failed: '
        '${response.statusCode} ${response.body}',
      );
    }
  }

  /// Fetches the server-owned candidate set for applying a category to other
  /// transactions related to [transactionId]. The server derives merchant
  /// identity and eligibility from the source row; the client never supplies
  /// a merchant name or VPA for matching.
  Future<RelatedCategoryPreview> fetchCategoryRelatedPreview(
    String transactionId, {
    String? categoryId,
    String? userCategoryId,
    String? targetCategoryId,
    String? targetUserCategoryId,
  }) async {
    final resolvedCategoryId = targetCategoryId ?? categoryId;
    final resolvedUserCategoryId = targetUserCategoryId ?? userCategoryId;
    if (resolvedCategoryId == null && resolvedUserCategoryId == null) {
      throw ArgumentError(
        'A target category id or user category id is required',
      );
    }
    final query = <String, String>{
      if (resolvedCategoryId != null) 'targetCategoryId': resolvedCategoryId,
      if (resolvedUserCategoryId != null)
        'targetUserCategoryId': resolvedUserCategoryId,
    };
    final uri = Uri.parse(
      '$apiBaseUrl/transactions/$transactionId/category-related-preview',
    ).replace(queryParameters: query);
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(_transactionRequestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /transactions/:id/category-related-preview failed: '
        '${response.statusCode} ${response.body}',
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final payload = decoded['preview'] is Map
        ? Map<String, dynamic>.from(decoded['preview'] as Map)
        : decoded;
    return RelatedCategoryPreview.fromJson(payload);
  }

  /// Applies exactly the selected IDs from a previously returned preview in
  /// one server-side atomic operation. A fresh idempotency key must be used
  /// for a new user action; retrying the same key is safe and returns the
  /// original result from the server.
  Future<CategoryBulkApplyResult> applyCategoryBulk({
    required String previewId,
    required Iterable<String> selectedTransactionIds,
    String? categoryId,
    String? userCategoryId,
    String? targetCategoryId,
    String? targetUserCategoryId,
    String? idempotencyKey,
  }) async {
    final resolvedCategoryId = targetCategoryId ?? categoryId;
    final resolvedUserCategoryId = targetUserCategoryId ?? userCategoryId;
    if (resolvedCategoryId == null && resolvedUserCategoryId == null) {
      throw ArgumentError(
        'A target category id or user category id is required',
      );
    }
    final selected = selectedTransactionIds.toSet().toList(growable: false);
    if (selected.length > 500) {
      throw ArgumentError.value(
        selected.length,
        'selectedTransactionIds',
        'cannot contain more than 500 transactions',
      );
    }
    final key = idempotencyKey ?? const Uuid().v4();
    final body = <String, dynamic>{
      'previewId': previewId,
      'selectedTransactionIds': selected,
      if (resolvedCategoryId != null) 'targetCategoryId': resolvedCategoryId,
      if (resolvedUserCategoryId != null)
        'targetUserCategoryId': resolvedUserCategoryId,
      'idempotencyKey': key,
    };
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/transactions/category-bulk-apply'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(_transactionRequestTimeout);
    final debug =
        'POST /transactions/category-bulk-apply failed: '
        '${response.statusCode} ${response.body}';
    if (response.statusCode == 409) {
      throw CategoryBulkConflictException(debug);
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw ApiException(debug);
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final payload = decoded['result'] is Map
        ? Map<String, dynamic>.from(decoded['result'] as Map)
        : decoded;
    return CategoryBulkApplyResult.fromJson(payload);
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
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/transactions/$id/ignore'),
          headers: _headers,
          body: jsonEncode({'reason': reason}),
        )
        .timeout(_transactionRequestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /transactions/:id/ignore failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  Future<void> restoreTransaction(String id) async {
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/transactions/$id/restore'),
          headers: _headers,
        )
        .timeout(_transactionRequestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /transactions/:id/restore failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Task D-5 (ui-spec D5 Duplicate Review). Pending pairs only.
  Future<List<DuplicateCandidate>> fetchDuplicateCandidates() async {
    final response = await _client
        .get(Uri.parse('$apiBaseUrl/duplicate-candidates'), headers: _headers)
        .timeout(_transactionRequestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /duplicate-candidates failed: ${response.statusCode} ${response.body}',
      );
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
    final response = await _client
        .post(
          Uri.parse('$apiBaseUrl/duplicate-candidates/$id/resolve'),
          headers: _headers,
          body: jsonEncode({
            'resolution': resolution,
            'keepTransactionId': ?keepTransactionId,
          }),
        )
        .timeout(_transactionRequestTimeout);
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
      throw ApiException(
        'GET /user-cards/:id/points-ledger failed: ${response.statusCode} ${response.body}',
      );
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
    String? reason,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/user-cards/$userCardId/points-adjustment'),
      headers: _headers,
      body: jsonEncode({
        'newBalance': newBalance,
        if (expiresOn != null) 'expiresOn': _dateOnly(expiresOn),
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /user-cards/:id/points-adjustment failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Task E6: GET/POST /lounge-usage.
  Future<List<LoungeVisit>> fetchLoungeUsage() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/lounge-usage'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /lounge-usage failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['loungeUsage'] as List)
        .cast<Map<String, dynamic>>()
        .map(LoungeVisit.fromJson)
        .toList();
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
      throw ApiException(
        'POST /lounge-usage failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// "Find my cards" over forwarded bank email and, on Android, SMS bodies
  /// the device reads locally. [smsBodies] are sent for this request only
  /// and never stored server-side — see POST /card-discovery.
  Future<CardDiscoveryResult> discoverCards({
    List<String> smsBodies = const [],
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/card-discovery'),
      headers: _headers,
      body: jsonEncode({'smsBodies': smsBodies}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /card-discovery failed: ${response.statusCode} ${response.body}',
      );
    }
    return CardDiscoveryResult.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Design 25's Invite friends screen, in one call.
  Future<ReferralInfo> fetchReferrals() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/referrals'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /referrals failed: ${response.statusCode} ${response.body}',
      );
    }
    return ReferralInfo.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Design 19's inbox. Newest first, last seven days only; the server does
  /// no filtering by local day — the client trims to seven local calendar
  /// days in the device's own timezone.
  Future<({List<AppNotification> items, int unreadCount})>
  fetchNotifications() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/notifications'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /notifications failed: ${response.statusCode} ${response.body}',
      );
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
      throw ApiException(
        'POST /notifications/read failed: ${response.statusCode} ${response.body}',
      );
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
        // NotificationGate displays this event locally. Remote push is an
        // explicit server-side action, otherwise one event becomes two banners
        // after FCM is configured.
        'sendRemote': false,
      }),
    );
    if (response.statusCode != 201 && response.statusCode != 204) {
      throw ApiException(
        'POST /notifications failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Design 01 header: GET /home-summary. Sends the device's current instant
  /// and IANA zone so month/streak buckets use the user's calendar, not a
  /// server clock that may be behind the device.
  Future<HomeSummary?> fetchHomeSummary({
    DateTime? anchor,
    String? timeZone,
  }) async {
    final query = {
      if (anchor != null) 'anchor': anchor.toUtc().toIso8601String(),
      if (timeZone != null && timeZone.isNotEmpty) 'tz': timeZone,
    };
    final uri = Uri.parse(
      '$apiBaseUrl/home-summary',
    ).replace(queryParameters: query.isEmpty ? null : query);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /home-summary failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final summary = body['homeSummary'];
    return summary == null
        ? null
        : HomeSummary.fromJson(summary as Map<String, dynamic>);
  }

  /// Records a referral-program engagement day only after the user visits
  /// Home and receives a fresh signed receipt from the server. A repeated
  /// submission is safe: the database enforces one credited day per user and
  /// campaign date. The receipt is deliberately never written to local cache.
  Future<bool> recordHomeEngagementCheckIn({
    DateTime? anchor,
    String? timeZone,
  }) async {
    final summary = await fetchHomeSummary(anchor: anchor, timeZone: timeZone);
    final receipt = summary?.engagementReceiptToken;
    if (receipt == null || receipt.isEmpty) return false;

    final response = await _client.post(
      Uri.parse('$apiBaseUrl/engagement/check-in'),
      headers: _headers,
      body: jsonEncode({'receiptToken': receipt}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /engagement/check-in failed: '
        '${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['recorded'] == true || body['qualified'] == true;
  }

  /// Returns distinct masked bank accounts observed in SMS imports and the
  /// latest explicitly reported available balance for each one.
  Future<List<BankAccountSummary>> fetchBankAccountSummaries() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/account-summaries'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /account-summaries failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ((body['accounts'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(BankAccountSummary.fromJson)
        .toList();
  }

  /// Task E9: GET /monthly-reports. Null [month] means "the current month."
  Future<MonthlyReport?> fetchMonthlyReport({DateTime? month}) async {
    final params = month == null
        ? null
        : {'month': _dateOnly(DateTime(month.year, month.month, 1))};
    final uri = Uri.parse(
      '$apiBaseUrl/monthly-reports',
    ).replace(queryParameters: params);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /monthly-reports failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final report = body['monthlyReport'];
    return report == null
        ? null
        : MonthlyReport.fromJson(report as Map<String, dynamic>);
  }

  /// Task E12: GET /my-contributions (network-wide aggregate only — see
  /// ContributionNetworkStats' doc-comment for why) and the contributions
  /// opt-in toggle, which mirrors H4 per the plan.
  Future<ContributionNetworkStats> fetchContributionNetworkStats() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/my-contributions'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /my-contributions failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ContributionNetworkStats.fromJson(
      body['networkStats'] as Map<String, dynamic>,
    );
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

class TransactionObservation {
  final String source;
  final String? sourceKey;
  final DateTime? observedAt;
  final String? reference;

  const TransactionObservation({
    required this.source,
    this.sourceKey,
    this.observedAt,
    this.reference,
  });

  factory TransactionObservation.fromJson(Map<String, dynamic> json) =>
      TransactionObservation(
        source: json['source'] as String? ?? 'unknown',
        sourceKey: json['source_key'] as String?,
        observedAt: DateTime.tryParse(json['observed_at'] as String? ?? ''),
        reference: json['reference'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'source': source,
    'source_key': sourceKey,
    'observed_at': observedAt?.toIso8601String(),
    'reference': reference,
  };
}

/// Account-private transaction context; archiving retains historical links.
class TransactionTag {
  final String id;
  final String name;
  final String? color;
  final DateTime? archivedAt;
  final DateTime? updatedAt;

  const TransactionTag({
    required this.id,
    required this.name,
    this.color,
    this.archivedAt,
    this.updatedAt,
  });

  bool get isArchived => archivedAt != null;

  factory TransactionTag.fromJson(Map<String, dynamic> json) => TransactionTag(
    id: json['id'] as String,
    name: json['name'] as String,
    color: json['color'] as String?,
    archivedAt: _date(json['archivedAt'] ?? json['archived_at']),
    updatedAt: _date(json['updatedAt'] ?? json['updated_at']),
  );

  static DateTime? _date(dynamic value) =>
      value == null ? null : DateTime.parse(value as String);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': color,
    'archivedAt': archivedAt?.toUtc().toIso8601String(),
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
  };
}

class TransactionEntry {
  final String? sourceKey;
  final String id;
  final Money amount;
  final DateTime occurredAt;
  final String? merchantName;

  /// UPI address of the counterparty, when the source transaction includes it.
  final String? merchantVpa;
  final String? categoryId;

  /// The reporting parent category. For a private subcategory, [categoryId]
  /// is the custom child id while this remains the built-in/user parent id.
  final String? parentCategoryId;
  final String? parentUserCategoryId;
  final String? userCategoryId;
  final String? categoryName;
  final String? subcategoryName;
  final String? cardDisplayName; // nickname if set, else the card's own name
  /// Last four digits extracted from a card SMS when the saved card is not
  /// linked yet. This is masked evidence only, never a full card number.
  final String? cardLast4;

  /// Last four digits of the source bank account for a cardless debit.
  /// This stays separate from cardLast4 so it cannot attach a payment to a
  /// physical card with matching digits.
  final String? accountLast4;

  /// Task D-1/D-2/D-3: added alongside the D1 rebuild — `GET /transactions`
  /// already selected `t.source`/`t.note` (Task C-0c) and `t.user_card_id`/
  /// `t.rail`/`t.status` (always present in the row) but nothing parsed
  /// them into the client model until D2 (Transaction Detail, "source"/
  /// "reconciliation status") and D3 (Edit, needs every field) needed them.
  final String? userCardId;
  final TxnRail rail;
  final TxnInstrument instrument;

  /// Older production API images did not include `instrument` in the detail
  /// response. Keep that distinction so the UI never guesses "Credit card"
  /// for a cardless UPI transaction while the API rolls out.
  final bool instrumentKnown;
  final TxnEntryKind entryKind;
  final String source;

  /// The latest time an SMS observation for this transaction was received by
  /// the device. This is intentionally separate from [occurredAt]: the bank's
  /// transaction date drives accounting, while the activity row should show
  /// the actual SMS time when the source is SMS.
  final DateTime? smsReceivedAt;

  /// Privacy-safe records of the channels that reported this payment.
  final List<TransactionObservation> observations;
  final String status;
  final String rewardState;
  final String? note;

  /// Optional display snapshot. The tags repository owns local assignment
  /// intent (including removals) and takes precedence over stale snapshots.
  final List<TransactionTag> tags;

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
    this.sourceKey,
    required this.id,
    required this.amount,
    required this.occurredAt,
    this.merchantName,
    this.merchantVpa,
    this.categoryId,
    this.parentCategoryId,
    this.parentUserCategoryId,
    this.userCategoryId,
    this.categoryName,
    this.subcategoryName,
    this.cardDisplayName,
    this.cardLast4,
    this.accountLast4,
    this.userCardId,
    this.rail = TxnRail.unknown,
    this.instrument = TxnInstrument.creditCard,
    this.instrumentKnown = true,
    this.entryKind = TxnEntryKind.spend,
    required this.source,
    this.smsReceivedAt,
    this.observations = const [],
    required this.status,
    this.rewardState = 'estimated',
    this.note,
    this.rewardValue,
    this.tags = const [],
  });

  String get categoryLabel => subcategoryName == null || categoryName == null
      ? (categoryName ?? 'Other')
      : '$categoryName · $subcategoryName';

  /// Local snapshot form. This intentionally mirrors only the fields needed
  /// by [fromJson]; it is not a write payload and must never be sent back to
  /// the API as a transaction mutation.
  Map<String, dynamic> toJson() {
    final rawCategoryId = categoryId;
    final customCategoryId =
        rawCategoryId != null && rawCategoryId.startsWith('custom:')
        ? rawCategoryId.substring('custom:'.length)
        : null;
    return {
      'id': id,
      'source_key': sourceKey,
      'amount_inr': amount.rupees,
      'occurred_at': occurredAt.toIso8601String(),
      'merchant_name': merchantName,
      'merchant_vpa': merchantVpa,
      'category_id': customCategoryId == null ? categoryId : null,
      'parent_category_id': parentCategoryId,
      'parent_user_category_id': parentUserCategoryId,
      'user_category_id': userCategoryId ?? customCategoryId,
      'category_name': categoryName,
      'subcategory_name': subcategoryName,
      'card_name': cardDisplayName,
      'card_nickname': null,
      'card_last4': cardLast4,
      'account_last4': accountLast4,
      'user_card_id': userCardId,
      'rail': instrumentKnown ? _railToJson(rail) : null,
      'instrument': instrumentKnown ? instrument.wireValue : null,
      'entry_kind': entryKind.wireValue,
      'source': source,
      'sms_received_at': smsReceivedAt?.toIso8601String(),
      'observations': observations
          .map((observation) => observation.toJson())
          .toList(),
      'status': status,
      'reward_state': rewardState,
      'note': note,
      'expected_value_inr': rewardValue?.rupees,
      'tags': tags.map((tag) => tag.toJson()).toList(),
    };
  }

  TransactionEntry copyWith({
    String? status,
    String? note,
    bool clearNote = false,
  }) {
    return TransactionEntry(
      sourceKey: sourceKey,
      id: id,
      amount: amount,
      occurredAt: occurredAt,
      merchantName: merchantName,
      merchantVpa: merchantVpa,
      categoryId: categoryId,
      parentCategoryId: parentCategoryId,
      parentUserCategoryId: parentUserCategoryId,
      userCategoryId: userCategoryId,
      categoryName: categoryName,
      subcategoryName: subcategoryName,
      cardDisplayName: cardDisplayName,
      cardLast4: cardLast4,
      accountLast4: accountLast4,
      userCardId: userCardId,
      rail: rail,
      instrument: instrument,
      instrumentKnown: instrumentKnown,
      entryKind: entryKind,
      source: source,
      smsReceivedAt: smsReceivedAt,
      observations: observations,
      status: status ?? this.status,
      rewardState: rewardState,
      note: clearNote ? null : (note ?? this.note),
      tags: tags,
      rewardValue: rewardValue,
    );
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

  factory TransactionEntry.fromJson(Map<String, dynamic> json) {
    final nickname = json['card_nickname'] as String?;
    final cardName = json['card_name'] as String?;
    final rawCategoryId = json['category_id'] as String?;
    final userCategoryId = json['user_category_id'] as String?;
    return TransactionEntry(
      sourceKey: json['source_key'] as String?,
      id: json['id'] as String,
      amount: Money.fromRupees(_num(json['amount_inr'])),
      occurredAt: DateTime.parse(json['occurred_at'] as String),
      merchantName: json['merchant_name'] as String?,
      merchantVpa: json['merchant_vpa'] as String?,
      categoryId: userCategoryId == null
          ? rawCategoryId
          : 'custom:$userCategoryId',
      parentCategoryId: json['parent_category_id'] as String? ?? rawCategoryId,
      parentUserCategoryId: json['parent_user_category_id'] as String?,
      userCategoryId: userCategoryId,
      categoryName: _displayCategoryName(json['category_name'] as String?),
      // A missing subcategory is not an "Other" category. Activity's
      // category label uses the parent name when there is no child category.
      subcategoryName: json['subcategory_name'] == null
          ? null
          : _displayCategoryName(json['subcategory_name'] as String?),
      cardDisplayName: (nickname?.isNotEmpty == true) ? nickname : cardName,
      cardLast4: json['card_last4'] as String?,
      accountLast4: json['account_last4'] as String?,
      userCardId: json['user_card_id'] as String?,
      rail: _parseRail(json['rail'] as String?),
      instrument: TxnInstrument.fromJson(json['instrument'] as String?),
      instrumentKnown: json['instrument'] != null,
      entryKind: TxnEntryKind.fromJson(json['entry_kind'] as String?),
      source: json['source'] as String? ?? 'manual',
      smsReceivedAt: json['sms_received_at'] == null
          ? null
          : DateTime.parse(json['sms_received_at'] as String),
      observations: (json['observations'] as List? ?? const [])
          .map(
            (item) =>
                TransactionObservation.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      status: json['status'] as String? ?? 'active',
      rewardState: json['reward_state'] as String? ?? 'estimated',
      note: json['note'] as String?,
      rewardValue: json['expected_value_inr'] == null
          ? null
          : Money.fromRupees(_num(json['expected_value_inr'])),
      tags: (json['tags'] as List? ?? const [])
          .map((item) => TransactionTag.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  static TxnRail _parseRail(String? value) {
    if (value == null) return TxnRail.unknown;
    final camel = value.split('_').indexed.map((e) {
      final (i, part) = e;
      if (part.isEmpty) return '';
      return i == 0 ? part : part[0].toUpperCase() + part.substring(1);
    }).join();
    return TxnRail.values.firstWhere(
      (r) => r.name == camel,
      orElse: () => TxnRail.unknown,
    );
  }

  static String? _displayCategoryName(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (value == null ||
        value.trim().isEmpty ||
        normalized == 'uncategorized' ||
        normalized == 'unclassified') {
      return 'Other';
    }
    return value;
  }
}

/// UA-5.3 (Chunk 31): the outcome of a POST /transactions/from-sms call.
/// [parsed] false with a [reason] is a normal, expected outcome for a
/// non-spend or malformed message — not exceptional.
class SmsImportResult {
  final bool parsed;
  final String? reason;

  /// True when the server recognised this exact message as already imported
  /// (migration 0036's `source_key`). Distinct from `parsed: false` — the
  /// message DID parse, it just didn't need inserting again. Callers must
  /// not count it as a new transaction, and must not add it to needs-review.
  final bool duplicate;

  /// Kept for API compatibility with older servers. Current servers record
  /// an unresolvable successful spend as a cardless transaction, so normal
  /// SMS auto-import does not require this manual outcome.
  final bool needsReview;

  /// The category assigned during the same SMS import transaction. This is
  /// returned for observability; the server remains the source of truth for
  /// the category UUID and the transaction row is already persisted before
  /// the request succeeds.
  final String? categoryId;

  /// True when this alert filled a previously missing recurring due day on
  /// the matched card. This can happen for a bill reminder that is not a
  /// purchase, so it must be propagated separately from [parsed].
  final bool dueDayUpdated;
  final bool statementDayUpdated;

  const SmsImportResult({
    required this.parsed,
    this.reason,
    this.duplicate = false,
    this.needsReview = false,
    this.categoryId,
    this.dueDayUpdated = false,
    this.statementDayUpdated = false,
  });
}

/// The server-side checkpoint for device SMS reconciliation.
class SmsImportState {
  final int? smsObservationCount;
  final DateTime? latestSmsObservedAt;

  const SmsImportState({
    required this.smsObservationCount,
    this.latestSmsObservedAt,
  });

  const SmsImportState.unavailable()
    : smsObservationCount = null,
      latestSmsObservedAt = null;
}

class SmsReconciliationResult {
  final int reconciliationVersion;
  final int duplicateSuppressed;
  final int crossSourceCandidatesCreated;
  final int linkedCards;
  final int reclassified;
  final int classificationReclassified;
  final int remappedTransactions;
  final int remainingLegacyRows;

  const SmsReconciliationResult({
    required this.reconciliationVersion,
    required this.duplicateSuppressed,
    required this.crossSourceCandidatesCreated,
    required this.linkedCards,
    required this.reclassified,
    required this.classificationReclassified,
    required this.remappedTransactions,
    required this.remainingLegacyRows,
  });

  const SmsReconciliationResult.zero()
    : reconciliationVersion = 0,
      duplicateSuppressed = 0,
      crossSourceCandidatesCreated = 0,
      linkedCards = 0,
      reclassified = 0,
      classificationReclassified = 0,
      remappedTransactions = 0,
      remainingLegacyRows = 0;
}

/// Task S-1a: one message in a batched backup import.
class SmsBatchMessage {
  /// Optional since the server resolves it — see [logTransactionFromSms].
  /// A backup-file import that maps a last4 group to a card still passes it
  /// explicitly; one that can't leaves it null and lets the server record it
  /// cardlessly.
  final String? userCardId;
  final String sender;
  final String body;

  /// The message's ORIGINAL timestamp. Required, not optional: without it
  /// the server can't build a stable `source_key`, so re-import protection
  /// silently stops working for exactly the bulk case that needs it most.
  final DateTime occurredAt;

  const SmsBatchMessage({
    this.userCardId,
    required this.sender,
    required this.body,
    required this.occurredAt,
  });
}

/// Task S-1a: outcome counts for one batch.
class SmsBatchImportResult {
  final int imported;
  final int duplicate;
  final int unparsed;
  final int invalid;

  /// Kept for compatibility with older batch responses. Current successful
  /// messages are counted as imported even when card attribution is unknown.
  final int needsReview;
  final int errored;
  final int dueDatesUpdated;
  final int statementDaysUpdated;
  final List<int> unparsedIndices;
  final Map<int, String> reasonByIndex;

  const SmsBatchImportResult({
    required this.imported,
    required this.duplicate,
    required this.unparsed,
    required this.invalid,
    this.needsReview = 0,
    required this.errored,
    this.dueDatesUpdated = 0,
    this.statementDaysUpdated = 0,
    this.unparsedIndices = const [],
    this.reasonByIndex = const {},
  });
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
      txnA: DuplicateTransactionSummary.fromJson(
        json['txn_a'] as Map<String, dynamic>,
      ),
      txnB: DuplicateTransactionSummary.fromJson(
        json['txn_b'] as Map<String, dynamic>,
      ),
      matchScore: _num(json['match_score']),
      matchReason: json['match_reason'] as String,
    );
  }
}
