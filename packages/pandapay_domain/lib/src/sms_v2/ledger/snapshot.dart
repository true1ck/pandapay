import '../contract/enums.dart';
import '../contract/event.dart';
import '../contract/fact.dart';
import '../contract/instrument.dart';
import '../contract/interfaces.dart';
import '../contract/ledger_entry.dart';
import '../contract/rule_bundle.dart';
import '../contract/types.dart';
import '../category/category_resolver.dart';
import '../category/merchant_key.dart';
import 'projector.dart';

/// An immutable reporting snapshot, including explicit refund category context.
/// Build from persisted facts after a restart; there is no per-process cache.
class LedgerSnapshot {
  LedgerSnapshot({
    required Iterable<LedgerEntry> entries,
    required Iterable<Event> events,
    Map<String, CategoryDecision> categoryByEvent = const {},
  }) : entries = List.unmodifiable(entries),
       events = List.unmodifiable(events),
       categoryByEvent = Map.unmodifiable(categoryByEvent);

  factory LedgerSnapshot.project({
    required Iterable<Event> events,
    required Map<String, Fact> factsById,
    required Map<String, Instrument> instrumentsById,
    required RuleBundle bundle,
    List<CategoryRule> userRules = const [],
    Map<String, String> confirmedHistory = const {},
    Map<String, String> senderBySource = const {},
    Map<String, String> instrumentIdByFactId = const {},
    Map<String, CategoryDecision> lockedCategories = const {},
  }) {
    final list = events.toList();
    final resolver = DefaultCategoryResolver(aliases: bundle.merchantAliases);
    final categories = <String, CategoryDecision>{...lockedCategories};
    final counterparties = <String, Counterparty?>{};
    final ownerByFact = <String, Event>{};
    for (final event in list) {
      if (spendEventTypes.contains(event.type)) {
        // A corrected money leg can change while the original anchor stays
        // first for stable event identity and linked-refund references.
        ownerByFact[event.eventId] = event;
        for (final leg in event.legs) {
          if (moneyLegRoles.contains(leg.role) ||
              (leg.role == LegRole.original &&
                  factsById[leg.factId] is MovementFact)) {
            ownerByFact[leg.factId] = event;
          }
        }
      }
    }
    CategoryDecision? decide(Event event) {
      final fact = moneyFactForEvent(event, factsById);
      if (fact == null) return null;
      CategoryDecision? linked;
      if (event.type == EventType.refund) {
        for (final leg in event.legs) {
          final purchase = leg.role == LegRole.original
              ? ownerByFact[leg.factId]
              : null;
          if (purchase != null) {
            linked = decide(purchase);
            break;
          }
        }
      }
      var cp = fact.counterparty;
      // The linker has already typed a partial-wallet load as a purchase.
      // Its merchant comes from bundle data, not issuer-specific code.
      if (event.type == EventType.purchase &&
          fact.purpose == MovementPurpose.walletTopup) {
        for (final rule in bundle.counterpartyPurposes) {
          final matches =
              (rule.vpaPattern != null &&
                  cp?.vpa != null &&
                  RegExp(
                    rule.vpaPattern!,
                    caseSensitive: false,
                  ).hasMatch(cp!.vpa!)) ||
              (rule.namePattern != null &&
                  cp?.name != null &&
                  RegExp(
                    rule.namePattern!,
                    caseSensitive: false,
                  ).hasMatch(cp!.name!));
          if (!matches) continue;
          final sender = bundle.senders
              .where(
                (s) =>
                    s.issuerSlug == rule.targetInstrument?.issuerSlug &&
                    s.walletSpendVisibility == WalletSpendVisibility.partial,
              )
              .firstOrNull;
          if (sender != null) {
            cp = Counterparty(
              name: sender.brand,
              kind: CounterpartyKind.merchant,
            );
          }
          break;
        }
      }
      counterparties[event.eventId] = cp;
      if (categories.containsKey(event.eventId)) {
        return categories[event.eventId];
      }
      final rule = bundle.rules
          .where((r) => r.id == fact.provenance.ruleId)
          .firstOrNull;
      final sender =
          senderBySource[fact.sourceKey] ??
          rule?.senders.where((s) => s != '*').firstOrNull ??
          '';
      final value = resolver.decide(
        eventType: event.type,
        linkedPurchase: linked,
        input: CategoryInput(
          counterparty: cp,
          senderBrand: sender,
          bundleRules: bundle.categoryRules,
          userRules: userRules,
          confirmedHistory: confirmedHistory,
        ),
      );
      if (value != null) categories[event.eventId] = value;
      return value;
    }

    for (final event in list) {
      decide(event);
    }
    final projector = DefaultLedgerProjector(
      categoryByEvent: categories,
      instrumentIdByFactId: instrumentIdByFactId,
      keyer: MerchantKeyer(bundle.merchantAliases),
    );
    final entries = <LedgerEntry>[];
    for (final event in list) {
      final projected = projector.project(
        event,
        factsById,
        instrumentsById,
        categories[event.eventId],
      );
      // The external merchant of a partial wallet must use the same key as its
      // category resolver (AMAZON rather than an own-account top-up descriptor).
      if (projected.isNotEmpty && event.type == EventType.purchase) {
        final fact = moneyFactForEvent(event, factsById);
        if (fact?.purpose == MovementPurpose.walletTopup) {
          final key = resolver.keyer.keyFor(counterparties[event.eventId]);
          if (key != null && key.isNotEmpty) {
            entries.add(
              LedgerEntry.fromJson({
                ...projected.single.toJson(),
                'to': {'external': key},
              }),
            );
            continue;
          }
        }
      }
      entries.addAll(projected);
    }
    return LedgerSnapshot(
      entries: entries,
      events: list,
      categoryByEvent: categories,
    );
  }

  final List<LedgerEntry> entries;
  final List<Event> events;
  final Map<String, CategoryDecision> categoryByEvent;

  Totals totals(DateTime from, DateTime to) => DefaultLedgerProjector(
    categoryByEvent: categoryByEvent,
  ).totals(entries, events, from, to);
}

/// The money fact supplies the merchant and method, never an original purchase,
/// mandate, hold or duplicate receipt attached to the same event.
MovementFact? moneyFactForEvent(Event event, Map<String, Fact> facts) {
  final inward =
      incomeEventTypes.contains(event.type) ||
      event.type == EventType.refund ||
      event.type == EventType.investmentWithdrawal;
  final candidates = <MovementFact>[
    for (final l in event.legs)
      if (moneyLegRoles.contains(l.role) && facts[l.factId] is MovementFact)
        facts[l.factId] as MovementFact,
  ].where((f) => f.evidenceOnly != true).toList();
  return candidates
          .where(
            (f) => f.direction == (inward ? Direction.credit : Direction.debit),
          )
          .firstOrNull ??
      candidates.firstOrNull;
}
