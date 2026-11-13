// Interfaces every later SMS pipeline v2 package implements (WP-02 to WP-07).
// Signatures are frozen with the contracts; changing one needs a contract
// change request. This file holds types and interfaces only, no behaviour.

import 'enums.dart';
import 'event.dart';
import 'fact.dart';
import 'instrument.dart';
import 'ledger_entry.dart';
import 'rule_bundle.dart';
import 'types.dart';

class SmsMessage {
  final String sender; // as received, e.g. VM-HDFCBK-S
  final String body; // original text; never leaves the phone
  final DateTime observedAt; // UTC
  final String sourceKey;
  final String? iosFilter; // iPhone filter tag, e.g. smsft_fi or smsfp; null on Android
  const SmsMessage({
    required this.sender,
    required this.body,
    required this.observedAt,
    required this.sourceKey,
    this.iosFilter,
  });
}

enum InterpretOutcome { matched, ignored, unknown }

class InterpretResult {
  final InterpretOutcome outcome;
  final List<Fact> facts; // matched: 1..n facts; ignored: one InfoFact; unknown: empty
  final String? ruleId;
  final int? ruleVersion;
  final String templateHash; // same algorithm as WP-00 `cluster`
  const InterpretResult({
    required this.outcome,
    required this.facts,
    this.ruleId,
    this.ruleVersion,
    required this.templateHash,
  });
}

abstract interface class SmsInterpreter {
  InterpretResult interpret(SmsMessage message, RuleBundle bundle, {required String appVersion});
}

abstract interface class InstrumentResolver {
  InstrumentResolution resolve(
    InstrumentMention mention,
    Iterable<Instrument> known, {
    required String profileId,
    required DateTime observedAt,
  });
}

abstract interface class EventLinker {
  LinkResult link({
    required List<Fact> incoming,
    required LinkContext context,
    required List<LinkRule> rules,
  });
}

abstract interface class CategoryResolver {
  CategoryDecision resolve(CategoryInput input);
}

abstract interface class LedgerProjector {
  List<LedgerEntry> project(
    Event event,
    Map<String, Fact> factsById,
    Map<String, Instrument> instrumentsById,
    CategoryDecision? category,
  );
  Totals totals(Iterable<LedgerEntry> entries, Iterable<Event> events, DateTime from, DateTime to);
}

// ---- supporting value types ----

/// The instrument a mention resolved to, and whether it was created for it.
class InstrumentResolution {
  final Instrument instrument;
  final bool created;
  const InstrumentResolution({required this.instrument, required this.created});
}

/// What the linker may look at: facts in the last 120 days, open events with
/// status `awaiting_leg`, and instruments by id.
class LinkContext {
  final List<Fact> recentFacts;
  final List<Event> openEvents;
  final Map<String, Instrument> instrumentsById;
  const LinkContext({
    required this.recentFacts,
    required this.openEvents,
    required this.instrumentsById,
  });
}

/// Kinds of review item, as stored in `v2_review_items.kind`.
enum ReviewKind { template, event, instrument }

/// A thing that needs a person: an unknown template, an ambiguous event or an
/// unresolved instrument.
class ReviewItem {
  final ReviewKind kind;
  final Map<String, Object?> payload;
  const ReviewItem({required this.kind, required this.payload});
}

class LinkResult {
  final List<Event> created;
  final List<Event> updated;
  final List<ReviewItem> ambiguous;
  const LinkResult({required this.created, required this.updated, required this.ambiguous});
}

class CategoryInput {
  final Counterparty? counterparty;
  final String senderBrand;
  final List<String> contextTokens;
  final String? mcc;
  final List<CategoryRule> userRules;
  final List<CategoryRule> bundleRules;

  /// Merchant key to the category the user confirmed for it before.
  final Map<String, String> confirmedHistory;
  const CategoryInput({
    this.counterparty,
    required this.senderBrand,
    this.contextTokens = const [],
    this.mcc,
    this.userRules = const [],
    this.bundleRules = const [],
    this.confirmedHistory = const {},
  });
}

class CategoryDecision {
  final String slug;
  final CategorySource source;
  final String? ruleId;
  final double confidence;
  const CategoryDecision({
    required this.slug,
    required this.source,
    this.ruleId,
    required this.confidence,
  });
}

class Totals {
  final int spendMinor;
  final int refundMinor;
  final int incomeMinor;

  /// Net invested: contributions minus withdrawals. Kept for the Investments
  /// screens and golden fixtures; Money in / Money out use the two gross
  /// figures below so a withdrawal never makes Money out smaller.
  final int investmentMinor;

  /// Gross money put into investments (SIPs, broker top-ups, IPO debits).
  final int investmentOutMinor;

  /// Gross money taken back out of investments (redemptions, broker payouts).
  /// Not earned income: it is mostly the user's own principal coming home.
  final int investmentReturnMinor;

  /// Spending the person chose not to count ("Don't count in spending"), net
  /// of refunds against it. It is not in [spendMinor], budgets or breakdowns,
  /// but it did leave their account, so Money out still includes it.
  final int excludedSpendMinor;
  final int transactionCount;
  final Map<String, int> byCategory;
  const Totals({
    required this.spendMinor,
    required this.refundMinor,
    required this.incomeMinor,
    required this.investmentMinor,
    this.investmentOutMinor = 0,
    this.investmentReturnMinor = 0,
    this.excludedSpendMinor = 0,
    required this.transactionCount,
    required this.byCategory,
  });

  /// Everything that left the user's accounts for spending or investing.
  /// Transfers between the user's own accounts and card-bill payments are not
  /// in it. Spend is already net of refunds.
  int get moneyOutMinor => spendMinor + excludedSpendMinor + investmentOutMinor;

  /// All spend on the cards and accounts, including what the person left out
  /// of their own spending. Card-side figures (what the bank bills, utilisation)
  /// use this; spending views use [spendMinor].
  int get allSpendMinor => spendMinor + excludedSpendMinor;

  /// Everything that arrived from outside: income plus money back from
  /// investments. Refunds are netted inside [spendMinor] instead.
  int get moneyInMinor => incomeMinor + investmentReturnMinor;
}
