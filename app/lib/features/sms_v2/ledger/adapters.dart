import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../../../data/commitments_repository.dart';
import '../../../data/card_bill_ledger.dart';
import '../../../data/pending_bills.dart';
import '../../../data/spend_reports_repository.dart';
import 'subscription_state.dart';

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

/// "issuer|digits" of a fact's instrument, or '' when it names none.
String _instKey(v2.Fact f) {
  final i = f.instrument;
  if (i?.issuerSlug == null || i?.maskDigits == null) return '';
  return '${i!.issuerSlug}|${i.maskDigits}';
}

/// One service seen under two names ("SPOTIFY" and "SPOTIFY SI", "NETFLIX" and
/// "NETFLIX INDIA") is one subscription: the shorter name is the service, the
/// longer one adds words to it. They merge only when they run on the same
/// instrument, or when either does not name an instrument at all, so two
/// different services that merely share a first word stay apart.
Map<String, String> _canonicalSeries(
  Iterable<String> keys,
  Map<String, String> instrumentOf,
) {
  final sorted = keys.toList()
    ..sort((a, b) {
      final byLength = a.length.compareTo(b.length);
      return byLength != 0 ? byLength : a.compareTo(b);
    });
  final canon = <String, String>{};
  for (final k in sorted) {
    var target = k;
    for (final c in sorted) {
      if (c == k) break;
      if (canon[c] != c || !k.startsWith('$c ')) continue;
      final a = instrumentOf[c] ?? '';
      final b = instrumentOf[k] ?? '';
      if (a.isEmpty || b.isEmpty || a == b) {
        target = c;
        break;
      }
    }
    canon[k] = target;
  }
  return canon;
}

Map<String, v2.Fact> _facts(Iterable<v2.Fact> facts) => {
  for (final f in facts) f.factId: f,
};
/// The posted amount in whatever currency it was charged: (currency, minor).
(String, int)? _postedAny(v2.Fact f) {
  final a = f.amounts.where((a) => a.role == v2.AmountRole.posted).firstOrNull;
  return a == null ? null : (a.unit, a.minor);
}

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

/// One charge seen twice under two names is one service. A payment aggregator's
/// receipt names the service ("Example Labs") while the bank prints its own
/// payee ("EXAMPLE TEC"); the linker already joins the receipt to the bank debit
/// as one charge event, so every name on that event is the same subscription.
/// The service's own name (the receipt's) is the one shown. Returns, for each
/// such key, the key it is merged into.
Map<String, String> _chargeAliases(
  Map<String, v2.Fact> byId,
  Iterable<v2.Event> events,
) {
  final parent = <String, String>{};
  final preferred = <String>{};
  String find(String k) {
    var root = k;
    while (parent[root] != null && parent[root] != root) {
      root = parent[root]!;
    }
    parent[k] = root;
    return root;
  }

  void union(String a, String b) {
    final ra = find(a), rb = find(b);
    if (ra != rb) parent[rb] = ra;
  }

  for (final e in events) {
    if (e.type != v2.EventType.subscriptionCharge || !_usable(e)) continue;
    final charge = moneyFactForEvent(e, byId);
    if (charge == null) continue;
    final original = e.legs
        .where((l) => l.role == v2.LegRole.original)
        .map((l) => byId[l.factId])
        .whereType<v2.MandateFact>()
        .firstOrNull;
    final base = _seriesKey(original ?? charge);
    find(base);
    for (final l in e.legs.where((l) => l.role == v2.LegRole.duplicateNotice)) {
      final receipt = byId[l.factId];
      if (receipt is! v2.MovementFact || receipt.counterparty?.name == null) {
        continue;
      }
      final key = _seriesKey(receipt);
      if (key.isEmpty || key == 'UNKNOWN SERVICE') continue;
      preferred.add(key);
      union(base, key);
    }
  }
  final members = <String, List<String>>{};
  for (final k in parent.keys) {
    members.putIfAbsent(find(k), () => []).add(k);
  }
  final alias = <String, String>{};
  for (final group in members.values) {
    if (group.length < 2) continue;
    final target =
        (group.where(preferred.contains).toList()..sort()).firstOrNull ??
        (group.toList()..sort()).first;
    for (final k in group) {
      if (k != target) alias[k] = target;
    }
  }
  return alias;
}

/// Mandate facts and charge events of the ledger, grouped one group per
/// service (two spellings of one service merged). Shared by the subscription
/// list and its history so both read the same grouping.
class _SubscriptionGroups {
  _SubscriptionGroups(
    this.byId,
    this.mergedGroups,
    this.mergedCharges,
    this.keyOf,
  );
  final Map<String, v2.Fact> byId;
  final Map<String, List<v2.Fact>> mergedGroups;
  final Map<String, List<(v2.Event, v2.MovementFact)>> mergedCharges;
  final String Function(v2.Fact) keyOf;
}

_SubscriptionGroups _groupSubscriptions(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events,
) {
  final byId = _facts(facts);
  final alias = _chargeAliases(byId, events);
  String K(String key) => alias[key] ?? key;
  final groups = <String, List<v2.Fact>>{};
  final excluded = <String>{};
  for (final f in byId.values.whereType<v2.MandateFact>()) {
    if (f.oneTime == true ||
        {
          v2.MandatePurpose.ipo,
          v2.MandatePurpose.sip,
          v2.MandatePurpose.loan,
          // A utility, card or insurance AutoPay is a bill, owned by Bills.
          v2.MandatePurpose.bill,
        }.contains(f.mandatePurpose)) {
      excluded.add(f.factId);
      continue;
    }
    groups.putIfAbsent(K(_seriesKey(f)), () => []).add(f);
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
    final key = K(_seriesKey(original ?? f));
    groups.putIfAbsent(key, () => []);
    charges.putIfAbsent(key, () => []).add((e, f));
    // A receipt that names the service differently is part of this service.
    for (final l in e.legs.where((l) => l.role == v2.LegRole.duplicateNotice)) {
      final receipt = byId[l.factId];
      if (receipt is v2.MovementFact) groups[key]!.add(receipt);
    }
  }
  // The same service under two names is one subscription.
  final groupInstrument = <String, String>{
    for (final g in groups.entries)
      g.key: [
        ...g.value,
        ...?charges[g.key]?.map((c) => c.$2),
      ].map(_instKey).firstWhere((k) => k.isNotEmpty, orElse: () => ''),
  };
  final canon = _canonicalSeries(groups.keys, groupInstrument);
  String keyOf(v2.Fact f) {
    final own = K(_seriesKey(f));
    final known = canon[own];
    if (known != null) return known;
    final inst = _instKey(f);
    for (final c in canon.values.toSet()) {
      if (!own.startsWith('$c ')) continue;
      final g = groupInstrument[c] ?? '';
      if (g.isEmpty || inst.isEmpty || g == inst) return c;
    }
    return own;
  }

  final mergedGroups = <String, List<v2.Fact>>{};
  for (final g in groups.entries) {
    mergedGroups.putIfAbsent(canon[g.key]!, () => []).addAll(g.value);
  }
  final mergedCharges = <String, List<(v2.Event, v2.MovementFact)>>{};
  for (final c in charges.entries) {
    mergedCharges.putIfAbsent(canon[c.key] ?? c.key, () => []).addAll(c.value);
  }
  return _SubscriptionGroups(byId, mergedGroups, mergedCharges, keyOf);
}

/// Everything the ledger says about each subscription, with no clock in it:
/// the rows `SubscriptionStore` keeps. Whether one is past, paused or late is
/// decided later, when a screen reads it ([seriesFromSubscriptionStates]).
List<SubscriptionState> subscriptionStatesFromLedger(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events,
) {
  final grouped = _groupSubscriptions(facts, events);
  final byId = grouped.byId;
  final mergedGroups = grouped.mergedGroups;
  final mergedCharges = grouped.mergedCharges;
  final keyOf = grouped.keyOf;
  // One pass over the attempts, bucketed by service. (Filtering every fact once
  // per service made this O(services x facts).)
  final failuresByKey = <String, List<v2.AttemptFact>>{};
  final scheduledByKey = <String, List<v2.AttemptFact>>{};
  for (final f in byId.values.whereType<v2.AttemptFact>()) {
    if (f.status == v2.AttemptStatus.failed) {
      failuresByKey.putIfAbsent(keyOf(f), () => []).add(f);
    } else if (f.status == v2.AttemptStatus.scheduled && f.dueAt != null) {
      scheduledByKey.putIfAbsent(keyOf(f), () => []).add(f);
    }
  }
  final result = <SubscriptionState>[];
  final nameless = normalizeMerchantText('Unknown service');
  for (final group in mergedGroups.entries) {
    final mandates = group.value.whereType<v2.MandateFact>().toList()
      ..sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));
    final latest = mandates.lastOrNull;
    final paid = mergedCharges[group.key] ?? [];
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
    final observed = intervals.isEmpty ? 0 : intervals[intervals.length ~/ 2];
    final stated = _cadence(latest?.frequency);
    // The stated frequency is trusted until the charges disagree with it: three
    // or more charges (two intervals) whose median is more than half off the
    // stated cycle show what the service really does (a "monthly" mandate that
    // bills every 90 days, or a yearly one billed monthly).
    final cadence = stated == null
        ? observed
        : (intervals.length >= 2 && (observed - stated).abs() > stated * 0.5)
        ? observed
        : stated;
    final last = paid.lastOrNull;
    final failures = [...?failuresByKey[group.key]]
      ..sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));
    // Announced debit dates after the last charge: the screen picks the first
    // one that is still ahead of it.
    final dueAts =
        ([
              for (final f in scheduledByKey[group.key] ?? const <v2.AttemptFact>[])
                if (last == null || f.dueAt!.isAfter(last.$1.occurredAt))
                  f.dueAt!,
            ]..sort())
            .reversed
            .take(SubscriptionState.maxDueAts)
            .toList()
            .reversed
            .toList();
    result.add(
      SubscriptionState(
        kind: SubscriptionStateKind.mandate,
        key: group.key,
        // The plain service name, not a longer variant a later notice used.
        name: _name(
          [
            ...group.value,
            ...paid.map((c) => c.$2),
          ].firstWhere((f) => _seriesKey(f) == group.key, orElse: () => anchor),
        ),
        cadence: cadence,
        chargeCount: paid.length,
        firstChargeAt: paid.firstOrNull?.$1.occurredAt,
        lastChargeAt: last?.$1.occurredAt,
        lastAmountMinor: last == null
            ? null
            : _amount(last.$2, v2.AmountRole.posted),
        ceilingMinor: latest == null
            ? null
            : _amount(latest, v2.AmountRole.ceiling),
        latestPhase: latest?.phase.wire,
        latestPhaseAt: latest?.effectiveAt,
        firstMandateAt: mandates.firstOrNull?.effectiveAt,
        mandateReference: latest?.references['umrn'],
        lastFailureAt: failures.lastOrNull?.effectiveAt,
        dueAts: dueAts,
        sourceKey: anchor.sourceKey,
        unnamed: group.key == nameless && paid.isEmpty,
      ),
    );
  }
  result.addAll(_patternStates(byId, events, mergedGroups.keys));
  result.addAll(_noticeStates(byId, mergedGroups.keys));
  return result;
}

/// Mandate history plus actual charge events, as the series a screen shows as
/// of [now]. Attempts never add a charge or an amount; a failed payment is a
/// lifecycle state on the same subscription. Prefer reading the saved rows
/// (`subscriptionStatesProvider`): this walks the whole ledger.
List<RecurringSeries> subscriptionsFromLedger(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events, {
  required DateTime now,
}) => seriesFromSubscriptionStates(
  subscriptionStatesFromLedger(facts, events),
  now,
);

/// One dated thing that happened to a subscription, in the order a person
/// would tell it: set up, charged, price changed, paused, cancelled...
enum SubscriptionHistoryKind {
  setup,
  setupAgain,
  limitChanged,
  charge,
  priceChange,
  failedPayment,
  paused,
  resumed,
  cancelled,
  expired,
  stopped,
  upcoming,
}

class SubscriptionHistoryEntry {
  const SubscriptionHistoryEntry({
    required this.kind,
    required this.at,
    this.amountMinor,
    this.previousAmountMinor,
    this.sourceKey,
  });

  final SubscriptionHistoryKind kind;
  final DateTime at;

  /// A charge, a failed charge, a price or the limit set at setup.
  final int? amountMinor;

  /// The price before a [SubscriptionHistoryKind.priceChange].
  final int? previousAmountMinor;

  /// The message this came from, when one message says it.
  final String? sourceKey;
}

/// The whole story of each subscription, newest first, keyed by the series id
/// [subscriptionsFromLedger] gives it (`v2:<service>`). It is read from the same
/// facts and charges as the list, so the two cannot disagree: the last entry
/// of a cancelled row is its cancellation.
Map<String, List<SubscriptionHistoryEntry>> subscriptionHistoryFromLedger(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events, {
  required DateTime now,
}) {
  final grouped = _groupSubscriptions(facts, events);
  final byId = grouped.byId;
  // Bucketed by service once: filtering every attempt per service (and building
  // the key for each) made this O(services x attempts).
  final attemptsByKey = <String, List<v2.AttemptFact>>{};
  for (final a in byId.values.whereType<v2.AttemptFact>()) {
    attemptsByKey.putIfAbsent(grouped.keyOf(a), () => []).add(a);
  }
  final history = <String, List<SubscriptionHistoryEntry>>{};
  for (final group in grouped.mergedGroups.entries) {
    final entries = <SubscriptionHistoryEntry>[];
    final mandates = group.value.whereType<v2.MandateFact>().toList()
      ..sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));
    // A card standing instruction re-sends "created" with every charge, and two
    // alerts can announce one activation; neither is a fresh setup.
    final chargeSources = {
      for (final c in grouped.mergedCharges[group.key] ?? const []) c.$2.sourceKey,
    };
    DateTime? lastSetupAt;
    for (final m in mandates) {
      switch (m.phase) {
        case v2.MandatePhase.created:
          final first = !entries.any(
            (e) =>
                e.kind == SubscriptionHistoryKind.setup ||
                e.kind == SubscriptionHistoryKind.setupAgain,
          );
          final withCharge = chargeSources.contains(m.sourceKey);
          final sameActivation =
              lastSetupAt != null &&
              m.effectiveAt.difference(lastSetupAt).inHours.abs() < 48;
          if (first || (!withCharge && !sameActivation)) {
            entries.add(
              SubscriptionHistoryEntry(
                kind: first
                    ? SubscriptionHistoryKind.setup
                    : SubscriptionHistoryKind.setupAgain,
                at: m.effectiveAt,
                amountMinor: _amount(m, v2.AmountRole.ceiling),
                sourceKey: m.sourceKey,
              ),
            );
            lastSetupAt = m.effectiveAt;
          }
        case v2.MandatePhase.modified:
          entries.add(
            SubscriptionHistoryEntry(
              kind: SubscriptionHistoryKind.limitChanged,
              at: m.effectiveAt,
              amountMinor: _amount(m, v2.AmountRole.ceiling),
              sourceKey: m.sourceKey,
            ),
          );
        case v2.MandatePhase.paused:
          entries.add(
            SubscriptionHistoryEntry(
              kind: SubscriptionHistoryKind.paused,
              at: m.effectiveAt,
              sourceKey: m.sourceKey,
            ),
          );
        case v2.MandatePhase.resumed:
          entries.add(
            SubscriptionHistoryEntry(
              kind: SubscriptionHistoryKind.resumed,
              at: m.effectiveAt,
              sourceKey: m.sourceKey,
            ),
          );
        case v2.MandatePhase.revoked:
        case v2.MandatePhase.expired:
          entries.add(
            SubscriptionHistoryEntry(
              kind: m.phase == v2.MandatePhase.revoked
                  ? SubscriptionHistoryKind.cancelled
                  : SubscriptionHistoryKind.expired,
              at: m.effectiveAt,
              sourceKey: m.sourceKey,
            ),
          );
      }
    }
    final paid = [...?grouped.mergedCharges[group.key]]
      ..sort((a, b) => a.$1.occurredAt.compareTo(b.$1.occurredAt));
    int? previous;
    for (final c in paid) {
      final amount = _amount(c.$2, v2.AmountRole.posted);
      final changed = previous != null && amount != null && amount != previous;
      entries.add(
        SubscriptionHistoryEntry(
          kind: changed
              ? SubscriptionHistoryKind.priceChange
              : SubscriptionHistoryKind.charge,
          at: c.$1.occurredAt,
          amountMinor: amount,
          previousAmountMinor: changed ? previous : null,
          sourceKey: c.$2.sourceKey,
        ),
      );
      if (amount != null) previous = amount;
    }
    for (final f in attemptsByKey[group.key] ?? const <v2.AttemptFact>[]) {
      if (f.status == v2.AttemptStatus.failed) {
        entries.add(
          SubscriptionHistoryEntry(
            kind: SubscriptionHistoryKind.failedPayment,
            at: f.effectiveAt,
            amountMinor:
                _amount(f, v2.AmountRole.scheduled) ??
                _amount(f, v2.AmountRole.posted),
            sourceKey: f.sourceKey,
          ),
        );
      } else if (f.status == v2.AttemptStatus.scheduled &&
          f.dueAt != null &&
          f.dueAt!.isAfter(now)) {
        entries.add(
          SubscriptionHistoryEntry(
            kind: SubscriptionHistoryKind.upcoming,
            at: f.dueAt!,
            amountMinor:
                _amount(f, v2.AmountRole.scheduled) ??
                _amount(f, v2.AmountRole.posted),
            sourceKey: f.sourceKey,
          ),
        );
      }
    }
    entries.sort((a, b) => b.at.compareTo(a.at));
    history['v2:${group.key}'] = entries;
  }
  return history;
}

/// A bank or app that announces an upcoming AutoPay debit to a service ("your
/// account will be debited with Rs 81 towards Amazon Pay for the recurring bill
/// payments") is telling us a mandate exists, even when the setup message and
/// the debits themselves were never seen. Two or more such notices, on
/// different months, for a service with no mandate row are listed for review:
/// never as a confirmed subscription, because no money was seen moving.
Iterable<SubscriptionState> _noticeStates(
  Map<String, v2.Fact> byId,
  Iterable<String> knownKeys,
) sync* {
  final byService = <String, List<v2.AttemptFact>>{};
  for (final f in byId.values.whereType<v2.AttemptFact>()) {
    if (f.status != v2.AttemptStatus.scheduled || f.dueAt == null) continue;
    final name = f.counterparty?.name?.trim();
    if (name == null || name.length < 3) continue;
    final key = normalizeMerchantText(name);
    if (key.isEmpty) continue;
    byService.putIfAbsent(key, () => []).add(f);
  }
  final known = knownKeys.toList();
  for (final entry in byService.entries) {
    if (known.any(
      (k) =>
          k == entry.key ||
          entry.key.startsWith('$k ') ||
          k.startsWith('${entry.key} '),
    )) {
      continue;
    }
    final notices = entry.value..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
    // One notice, or several for one billing date, proves nothing recurs.
    final months = {
      for (final n in notices) '${n.dueAt!.year}-${n.dueAt!.month}',
    };
    if (months.length < 2) continue;
    final last = notices.last;
    final gaps = [
      for (var i = 1; i < notices.length; i++)
        notices[i].dueAt!.difference(notices[i - 1].dueAt!).inDays,
    ]..removeWhere((d) => d < 20);
    gaps.sort();
    yield SubscriptionState(
      kind: SubscriptionStateKind.notice,
      key: entry.key,
      name: _name(last),
      cadence: gaps.isEmpty ? 0 : gaps[gaps.length ~/ 2],
      lastAmountMinor: _amount(last, v2.AmountRole.scheduled),
      firstMandateAt: notices.first.dueAt,
      dueAts: [
        for (final n in notices.skip(
          notices.length > SubscriptionState.maxDueAts
              ? notices.length - SubscriptionState.maxDueAts
              : 0,
        ))
          n.dueAt!,
      ],
      sourceKey: last.sourceKey,
      reviewReason:
          'Your bank announced ${notices.length} upcoming AutoPay debits '
          '(${months.length} different months), but no setup message or '
          'debit was seen, so this cannot be confirmed.',
    );
  }
}

/// Subscriptions that never sent a mandate message: the same merchant charged the
/// same amount on a steady monthly (or weekly) rhythm at least three times. It is
/// flagged as detected by pattern, not confirmed by a mandate, so the screen can
/// say so. A person, an own account, an EMI or a bill (whose amount moves) is
/// never read this way, and a service that already has a mandate is not repeated.
Iterable<SubscriptionState> _patternStates(
  Map<String, v2.Fact> byId,
  Iterable<v2.Event> events,
  Iterable<String> mandateKeys,
) sync* {
  final byMerchant = <String, List<(v2.Event, v2.MovementFact)>>{};
  for (final e in events.where(
    (e) => e.type == v2.EventType.purchase && _usable(e),
  )) {
    final f = moneyFactForEvent(e, byId);
    if (f == null || f.evidenceOnly == true) continue;
    final cp = f.counterparty;
    if (cp?.kind == v2.CounterpartyKind.person ||
        cp?.kind == v2.CounterpartyKind.own) {
      continue;
    }
    final name = cp?.name;
    if (name == null || name.trim().isEmpty) continue;
    final key = normalizeMerchantText(name);
    if (key.isEmpty) continue;
    byMerchant.putIfAbsent('$key|${_instKey(f)}', () => []).add((e, f));
  }
  final known = mandateKeys.toList();
  for (final entry in byMerchant.entries) {
    final merchant = entry.key.split('|').first;
    if (known.any(
      (k) =>
          k == merchant ||
          merchant.startsWith('$k ') ||
          k.startsWith('$merchant '),
    )) {
      continue;
    }
    // The commonest amount in one currency, charged at least three times. A
    // foreign charge is read in its own currency: the rupee figure on the
    // statement moves with the exchange rate, the dollar price does not.
    final byAmount = <String, List<(v2.Event, v2.MovementFact)>>{};
    for (final c in entry.value) {
      final a = _postedAny(c.$2);
      if (a != null && a.$2 > 0) {
        byAmount.putIfAbsent('${a.$1}|${a.$2}', () => []).add(c);
      }
    }
    final run =
        (byAmount.values.toList()..sort((a, b) => b.length.compareTo(a.length)))
            .firstOrNull;
    if (run == null || run.length < 3) continue;
    run.sort((a, b) => a.$1.occurredAt.compareTo(b.$1.occurredAt));
    final gaps = [
      for (var i = 1; i < run.length; i++)
        run[i].$1.occurredAt.difference(run[i - 1].$1.occurredAt).inDays,
    ];
    final monthly = gaps.every((d) => d >= 26 && d <= 35);
    final weekly = gaps.every((d) => d >= 6 && d <= 8);
    if (!monthly && !weekly) continue;
    final cadence = (List.of(gaps)..sort())[gaps.length ~/ 2];
    final last = run.last;
    final posted = _postedAny(last.$2)!;
    final foreign = posted.$1 != 'INR';
    yield SubscriptionState(
      kind: SubscriptionStateKind.pattern,
      key: entry.key,
      name: _name(last.$2),
      cadence: cadence,
      chargeCount: run.length,
      firstChargeAt: run.first.$1.occurredAt,
      lastChargeAt: last.$1.occurredAt,
      lastAmountMinor: posted.$2,
      currency: posted.$1,
      annualFactor: monthly ? 12 : 52,
      sourceKey: last.$2.sourceKey,
      reviewReason: foreign
          ? 'Charged ${(posted.$2 / 100).toStringAsFixed(2)} ${posted.$1} '
                '${run.length} times, about every $cadence days, with no '
                'subscription message.'
          : 'Charged the same amount ${run.length} times, about every '
                '$cadence days, with no subscription message.',
    );
  }
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

/// A card or account known only by its kind and last digits: the sender is not in
/// the registry, so no issuer could be named.
bool _digitsOnly(v2.Fact f) =>
    f.instrument?.issuerSlug == null &&
    f.instrument?.maskDigits != null &&
    f.instrument?.kind != null;

bool _sameInstrument(v2.Fact a, v2.Fact b) {
  final x = a.instrument;
  final y = b.instrument;
  if (x?.issuerSlug != null && y?.issuerSlug != null) {
    return x!.issuerSlug == y!.issuerSlug &&
        x.maskDigits == y.maskDigits &&
        (x.kind == null || y.kind == null || x.kind == y.kind);
  }
  // One side has no issuer (an unregistered sender's message): the kind and last
  // digits must both be known and equal.
  if (x == null || y == null) return false;
  return x.maskDigits != null &&
      x.kind != null &&
      x.maskDigits == y.maskDigits &&
      x.kind == y.kind &&
      (x.issuerSlug == null || y.issuerSlug == null);
}

String _billIdentity(v2.BillDueFact f) => f.instrument?.issuerSlug != null
    ? _instrumentKey(f)
    : _digitsOnly(f)
    ? 'anon|${f.instrument!.kind!.wire}|${f.instrument!.maskDigits}'
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
                (fact.instrument?.issuerSlug != null || _digitsOnly(fact)
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
    this.entries = const [],
  });
  final String platform;
  final int putInMinor, takenOutMinor, dividendMinor;

  /// The movements behind the totals, newest first; each opens as a transaction.
  final List<InvestmentEntry> entries;
  final int? balanceMinor;
  int get netInvestedMinor => putInMinor - takenOutMinor;
}

/// One movement of an investment platform: money put in, taken out or a
/// dividend. [eventId] opens the full transaction.
class InvestmentEntry {
  const InvestmentEntry({
    required this.eventId,
    required this.kind,
    required this.label,
    required this.amountMinor,
    required this.occurredAt,
  });
  final String eventId;

  /// `put_in`, `taken_out` or `dividend`.
  final String kind;
  final String label;
  final int amountMinor;
  final DateTime occurredAt;
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
  final entriesByGroup = <String, List<InvestmentEntry>>{};
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
    entriesByGroup.putIfAbsent(key, () => []).add(
      InvestmentEntry(
        eventId: e.eventId,
        kind: e.type == v2.EventType.investmentWithdrawal
            ? 'taken_out'
            : e.type == v2.EventType.dividend
            ? 'dividend'
            : 'put_in',
        label: e.type == v2.EventType.ipoApplication
            ? (f.counterparty?.name ?? 'IPO application')
            : named ?? 'Investment',
        amountMinor: e.amountMinor,
        occurredAt: e.occurredAt,
      ),
    );
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
        entries: [...?entriesByGroup[g.key]]
          ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt)),
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
    this.noAllotmentNoticeAt,
  });
  final String eventId, company, status;

  /// When an exchange / registrar "no allotment" notice arrived for this
  /// application (matched only when it can be about no other open one).
  final DateTime? noAllotmentNoticeAt;
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
  // A "no allotment" notice names no company the contract can carry, so it joins an
  // application only when exactly ONE application is still waiting (blocked, not
  // older than 60 days at the notice). Otherwise it stays an activity-only notice.
  final notices =
      byId.values
          .whereType<v2.InfoFact>()
          .where((f) => kIpoNoAllotmentRules.contains(f.provenance.ruleId))
          .map((f) => f.effectiveAt)
          .toList()
        ..sort();
  for (final notice in notices) {
    final waiting = [
      for (var i = 0; i < result.length; i++)
        if (result[i].status == 'blocked' &&
            result[i].appliedAt != null &&
            !result[i].appliedAt!.isAfter(notice) &&
            notice.difference(result[i].appliedAt!).inDays <= 60)
          i,
    ];
    if (waiting.length != 1) continue;
    final a = result[waiting.single];
    result[waiting.single] = IpoApplication(
      eventId: a.eventId,
      company: a.company,
      status: a.status,
      blockedMinor: a.blockedMinor,
      investedMinor: a.investedMinor,
      releasedMinor: a.releasedMinor,
      accountMask: a.accountMask,
      platform: a.platform,
      appliedAt: a.appliedAt,
      updatedAt: a.updatedAt,
      noAllotmentNoticeAt: notice,
    );
  }
  result.sort(
    (a, b) => (b.appliedAt ?? b.updatedAt ?? DateTime.utc(1900)).compareTo(
      a.appliedAt ?? a.updatedAt ?? DateTime.utc(1900),
    ),
  );
  return result;
}

/// Rule ids (from the shipped rule bundle) whose info fact means "no allotment".
const kIpoNoAllotmentRules = {'INV-IPO-NOALLOT-01'};

RecurringReport recurringReportFromLedger(
  Iterable<v2.Fact> facts,
  Iterable<v2.Event> events, {
  required DateTime now,
}) => _recurringReport(subscriptionsFromLedger(facts, events, now: now));

/// The report a screen shows, from the saved subscription rows as of [now].
RecurringReport recurringReportFromSubscriptionStates(
  Iterable<SubscriptionState> states, {
  required DateTime now,
}) => _recurringReport(seriesFromSubscriptionStates(states, now));

RecurringReport _recurringReport(List<RecurringSeries> series) =>
    RecurringReport(
      series: series,
      totalAnnual: Money.fromPaise(
        series
            .where(
              (s) =>
                  !s.reviewCandidate &&
                  (s.lifecycleStatus == 'active' ||
                      s.lifecycleStatus == 'failed_payment'),
            )
            .fold(0, (sum, s) => sum + s.annualCost.paise),
      ),
    );

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
