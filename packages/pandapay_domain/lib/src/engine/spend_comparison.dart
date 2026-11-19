import '../card_rules/card_rules.dart';
import '../card_rules/merchant_directory.dart';
import '../money/money.dart';
import 'engine.dart';
import 'historical_comparison.dart';
import 'reward_engine_v2.dart';

/// Categories issuers often leave out of rewards (rent, wallet loads, fuel,
/// insurance, government, education, EMI, utilities).
///
/// A catalogue entry is frequently silent about them, and silence is not a
/// promise to pay: a card whose entry says "2% on everything" and nothing about
/// rent very likely still pays nothing on rent. Even a verified entry lists
/// many of these exclusions by MCC only, and a past spend has no MCC to match
/// them against. So in these categories another card only counts as the better
/// choice when the rule that pays names the category itself (see
/// [SpendComparer]).
const Set<String> rewardSensitiveCategorySlugs = {
  'rent',
  'wallet',
  'fuel',
  'insurance',
  'government',
  'education',
  'emi',
  'bills',
};

/// The smallest gap [SpendComparer] reports by default: ₹5. On the owner's two
/// years of spends this keeps 96% of the total gap in 147 rows instead of 580
/// (a ₹3 floor keeps 228, ₹1 keeps 580): the rest is rounding between two
/// points schemes.
const Money kDefaultMinimumMissedGain = Money.fromPaise(500);

// A statement line routed through a payment gateway is an online payment. The
// bank prints the gateway in the merchant text ("PYU*Flipkar", "Runnr
// Razorpay"), and nothing else in an SMS says online or in-store. Same patterns
// as the server's `inferRail` (api/src/card_state_v2.js), so a spend is priced
// here exactly as it was when its reward was stored.
final RegExp _gatewayPrefix = RegExp(
  r'^\s*(?:PYU|PAYU|RAZ|RZP|PHP|CCAV|CCA|BD|BILLDESK|CFR|CASHFREE|IPAY|PPSL)\s*\*',
  caseSensitive: false,
);
final RegExp _gatewayWord = RegExp(
  r'\b(?:razorpay|payu|billdesk|ccavenue|cashfree|instamojo)\b',
  caseSensitive: false,
);

/// The rail to price a spend on: the one the message stated, else "online" when
/// the merchant text names a payment gateway, else unknown. Never overrides a
/// rail the message did state.
TxnRail inferSpendRail(TxnRail rail, String? merchantName) {
  if (rail != TxnRail.unknown) return rail;
  final name = merchantName;
  if (name == null || name.isEmpty) return rail;
  return _gatewayPrefix.hasMatch(name) || _gatewayWord.hasMatch(name)
      ? TxnRail.online
      : rail;
}

/// What the comparison needs to know about one past purchase.
class SpendProbe {
  final Money amount;
  final DateTime occurredAt;

  /// The category id the card rules are written against (`spend_categories.id`).
  final String? categoryId;

  /// The category's slug ('dining', 'rent'), used to spot the categories in
  /// [rewardSensitiveCategorySlugs]. Null when it is not known.
  final String? categorySlug;
  final String? merchantName;
  final String? merchantVpa;
  final TxnRail rail;

  const SpendProbe({
    required this.amount,
    required this.occurredAt,
    this.categoryId,
    this.categorySlug,
    this.merchantName,
    this.merchantVpa,
    this.rail = TxnRail.unknown,
  });
}

/// One wallet card the person could have paid with.
class WalletCardOption {
  final CardProduct product;

  /// The earliest day the card could have been used: its issue date when the
  /// person entered one, else its first recorded use. Null means no limit.
  /// A card is never offered as the better choice for a spend before this.
  final DateTime? usableFrom;

  const WalletCardOption(this.product, {this.usableFrom});
}

/// A spend where another wallet card would clearly have paid more.
class SpendComparison extends HistoricalCardComparison {
  /// What each card pays as a share of the spend (0.05 is 5%).
  final double usedRate;
  final double betterRate;

  /// The catalogue's own plain-language line for the rule that paid on the
  /// better card ("10% cashback on eligible Swiggy app transactions."), when it
  /// has one.
  final String? betterNote;

  const SpendComparison({
    required super.usedCard,
    required super.actualValue,
    required CardProduct super.betterCard,
    required super.betterValue,
    required this.usedRate,
    required this.betterRate,
    this.betterNote,
  });
}

/// The answer for one spend.
class SpendCheck {
  /// True when at least one other wallet card could have been used for this
  /// spend (it was in hand at the time and fits the payment) and was priced.
  /// False means nothing was compared, so "no better card" must not be read as
  /// "the best card was used".
  final bool compared;

  /// Set only when another card would clearly have paid more.
  final SpendComparison? better;

  const SpendCheck({required this.compared, this.better});

  static const skipped = SpendCheck(compared: false);
}

/// Prices past spends on the person's other wallet cards with the reward
/// engine itself, so "what this card would have paid" is the same answer Home's
/// ranking and the server's stored rewards give (merchant rules such as "10% on
/// Swiggy", minimum spends, exclusions and rounding all apply).
///
/// What it does NOT use, because the schema keeps no history of it: caps and
/// milestones as they stood on the day. Every card is priced as if its limits
/// were unused, on both sides, so the gap is an upper estimate for cards with
/// caps.
///
/// A card counts as the better choice only when it was a real option:
///  - it was in hand on the day ([WalletCardOption.usableFrom]);
///  - it is a credit card, and not the same product as the card used;
///  - for a spend known to be a UPI payment, it is UPI-linkable;
///  - in a [rewardSensitiveCategorySlugs] category, the rule that pays names
///    the category;
///  - it beats the card used by at least [minimumGain].
class SpendComparer {
  /// Cards in the wallet, one per product (the earliest `usableFrom` wins when
  /// the wallet holds the same product twice).
  final List<WalletCardOption> _options;
  final MerchantDirectory? directory;

  /// A gap smaller than this is rounding between two points schemes (a
  /// "1 coin per ₹100" card against a "2 points per ₹100" card on a ₹300 meal),
  /// not a mistake worth listing. See [kDefaultMinimumMissedGain].
  final Money minimumGain;

  SpendComparer({
    required Iterable<WalletCardOption> wallet,
    this.directory,
    this.minimumGain = kDefaultMinimumMissedGain,
  }) : _options = _onePerProduct(wallet);

  static List<WalletCardOption> _onePerProduct(
    Iterable<WalletCardOption> wallet,
  ) {
    final byProduct = <String, WalletCardOption>{};
    for (final option in wallet) {
      final product = option.product;
      final type = product.cardType?.toLowerCase();
      if (type != null && type != 'credit') continue;
      final existing = byProduct[product.id];
      if (existing == null) {
        byProduct[product.id] = option;
        continue;
      }
      final a = existing.usableFrom;
      final b = option.usableFrom;
      // Null is "no limit", which is earlier than any date.
      if (a != null && (b == null || b.isBefore(a))) {
        byProduct[product.id] = option;
      }
    }
    return byProduct.values.toList(growable: false);
  }

  /// Whether the wallet holds at least two different credit-card products: the
  /// only case where "another card would have paid more" has an answer.
  bool get canCompare => _options.length >= 2;

  RewardEvaluation? _price(CardProduct product, RecommendationContext context) {
    try {
      return RecommendationEngine.evaluateRewardV2(
        product,
        context,
        directory: directory,
      );
    } catch (_) {
      // A malformed catalogue row must cost one card its answer, not the page.
      return null;
    }
  }

  static Money _valueOf(RewardEvaluation evaluation, Money amount) {
    final value = Money.fromRupees(evaluation.valueInr);
    if (value.isNegative) return const Money.zero();
    return value > amount ? amount : value;
  }

  /// Whether to believe [evaluation] as what a card pays on [spend]. Outside
  /// the sensitive categories the engine's answer stands; inside them only an
  /// earning rule for that very category does.
  bool _believable(RewardEvaluation evaluation, SpendProbe spend) {
    final slug = spend.categorySlug;
    if (slug == null || !rewardSensitiveCategorySlugs.contains(slug)) {
      return true;
    }
    final rule = evaluation.rule;
    return rule != null &&
        rule.categoryId != null &&
        rule.categoryId == spend.categoryId;
  }

  /// Compares [spend], paid with [used], against the rest of the wallet.
  SpendCheck check(CardProduct used, SpendProbe spend) {
    final amount = spend.amount;
    if (amount.paise <= 0) return SpendCheck.skipped;
    final context = RecommendationContext(
      amount: amount,
      categoryId: spend.categoryId,
      categorySlug: spend.categorySlug,
      vpa: spend.merchantVpa,
      rail: inferSpendRail(spend.rail, spend.merchantName),
      merchantName: spend.merchantName,
      now: spend.occurredAt,
    );
    final isUpi = context.rail == TxnRail.upiQr;
    // A card that cannot take UPI was not used for a UPI payment: the data
    // disagree, so nothing sound can be said.
    if (isUpi && !used.isUpiLinkable) return SpendCheck.skipped;
    final usedEvaluation = _price(used, context);
    if (usedEvaluation == null) return SpendCheck.skipped;
    final usedValue = _valueOf(usedEvaluation, amount);

    CardProduct? best;
    RewardEvaluation? bestEvaluation;
    var bestValue = const Money.zero();
    var compared = false;
    for (final option in _options) {
      final product = option.product;
      if (product.id == used.id) continue;
      final from = option.usableFrom;
      if (from != null && spend.occurredAt.isBefore(from)) continue;
      if (isUpi && !product.isUpiLinkable) continue;
      final evaluation = _price(product, context);
      if (evaluation == null) continue;
      compared = true;
      if (evaluation.excluded) continue;
      if (!_believable(evaluation, spend)) continue;
      final value = _valueOf(evaluation, amount);
      final better =
          best == null ||
          value > bestValue ||
          (value == bestValue && product.id.compareTo(best.id) < 0);
      if (better) {
        best = product;
        bestEvaluation = evaluation;
        bestValue = value;
      }
    }
    if (best == null || bestEvaluation == null) {
      return SpendCheck(compared: compared);
    }
    if (bestValue - usedValue < minimumGain) {
      return SpendCheck(compared: compared);
    }
    final note = bestEvaluation.rule?.displayNote?.trim();
    return SpendCheck(
      compared: true,
      better: SpendComparison(
        usedCard: used,
        actualValue: usedValue,
        betterCard: best,
        betterValue: bestValue,
        usedRate: usedValue.paise / amount.paise,
        betterRate: bestValue.paise / amount.paise,
        betterNote: note == null || note.isEmpty ? null : note,
      ),
    );
  }
}
