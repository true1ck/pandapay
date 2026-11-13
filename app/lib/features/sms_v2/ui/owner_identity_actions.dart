import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../app/providers.dart' as app;
import '../../../data/user_cards_repository.dart';
import '../personal/owner_identity_store.dart';
import '../providers/runtime_provider.dart';
import '../storage/event_store.dart';
import '../similar/fact_keys.dart';
import '../similar/similar_finder.dart';
import '../storage/fact_store.dart';

/// What happened when the person marked a payment as a self transfer.
enum MarkOutcome {
  /// The payee is remembered: this and every other payment to it is a transfer.
  marked,

  /// The message prints nothing that could be recognised next time (no full
  /// name, handle or account), so nothing was saved.
  nothingToRecognise,
}

/// The kind of transfer a person marks a payment as.
enum TransferMark { self, family }

/// How far a mark reaches: this one payment, or the payee for good (the earlier
/// payments to it and every future one).
enum MarkScope { once, always }

/// What the person is told before they choose a [MarkScope].
class MarkPlan {
  const MarkPlan({
    required this.payee,
    required this.canRemember,
    required this.canMarkOnce,
    required this.earlier,
    this.isShop = false,
    this.offerSelf = true,
    this.offerFamily = true,
  });

  /// The message names a shop (Amazon, Flipkart, a sea park), not a person or
  /// one of the owner's accounts: neither transfer is offered for it.
  final bool isShop;

  /// "Transfer between my accounts" fits: not a shop, not clearly a person.
  final bool offerSelf;

  /// "Transfer to family" fits: not a shop, not clearly the owner's own account.
  final bool offerFamily;

  /// The payee as printed, for the question.
  final String? payee;

  /// The message prints a full name, a UPI ID or an account, so "always" works.
  final bool canRemember;

  /// The payment has a message to point at, so "only this payment" works.
  final bool canMarkOnce;

  /// How many other payments to the same payee "always" would also change.
  final int earlier;
}

/// Everything the screens do to the account owner's identity, in one place:
/// change the stored identity, then read the affected messages again so the
/// earlier transactions agree.
class OwnerIdentityActions {
  OwnerIdentityActions(this._ref);
  final WidgetRef _ref;

  Future<({OwnerIdentityStore store, Database db, String namespace})>
  _open() async {
    final cache = await _ref.read(app.responseCacheProvider.future);
    final namespace = _ref.read(app.cacheNamespaceProvider);
    final db = cache.financialStore.database.db;
    return (
      store: OwnerIdentityStore(db, namespace: namespace),
      db: db,
      namespace: namespace,
    );
  }

  /// The name on the account's profile, when it is a real name (a username is
  /// ignored by the identity).
  Future<String?> profileName() async {
    final cache = await _ref.read(app.responseCacheProvider.future);
    return cache.financialStore.database.profileDisplayName(
      _ref.read(app.cacheNamespaceProvider),
    );
  }

  Future<List<OwnerEntry>> entries() async => (await _open()).store.list();

  /// Reads again the earlier messages that depend on who the owner is. Returns
  /// how many messages changed their reading.
  Future<int> recheck({bool revert = false}) async {
    final runtime = await _ref.read(smsV2RuntimeProvider.future);
    return runtime == null
        ? 0
        : runtime.recheckOwnTransfers(revertUnmatched: revert);
  }

  /// The person typed their name. Throws [ArgumentError] when it needs a first
  /// and a last name.
  Future<int> addName({
    required String first,
    String? middle,
    required String last,
  }) async {
    (await _open()).store.addName(first: first, middle: middle, last: last);
    return recheck();
  }

  Future<int> remove(String entry) async {
    (await _open()).store.remove(entry);
    return recheck(revert: true);
  }

  /// The payee behind a transaction: the printed name, handle or account.
  Counterparty? _counterpartyOf(Database db, String namespace, String eventId) {
    final event = EventStore(db, namespace: namespace).get(eventId);
    if (event == null) return null;
    final facts = FactStore(db, namespace: namespace);
    for (final leg in event.legs) {
      final fact = facts.get(leg.factId);
      if (fact is MovementFact && fact.counterparty != null) {
        return fact.counterparty;
      }
    }
    return null;
  }

  /// What the person can choose for this payment, shown before they choose.
  Future<MarkPlan> plan(TransactionEntry entry) async {
    final id = entry.eventId;
    if (id == null) {
      return const MarkPlan(
        payee: null,
        canRemember: false,
        canMarkOnce: false,
        earlier: 0,
      );
    }
    final o = await _open();
    final cp = _counterpartyOf(o.db, o.namespace, id);
    final remember = cp != null && _recognisable(cp);
    var earlier = 0;
    if (remember) {
      try {
        // One indexed count of the other payments printed with the same payee.
        final anchor = FactStore(o.db, namespace: o.namespace).get(id);
        final key = anchor == null ? null : FactKeys.of(anchor).merchantKey;
        if (key != null) {
          earlier = SimilarFinder(
            o.db,
            namespace: o.namespace,
          ).count(SimilarCriteria.shop(key), excludeEventId: id);
        }
      } catch (_) {
        earlier = 0;
      }
    }
    // A shop is what the reader says it is, or a printed name that is not a
    // person's name (one word, a brand) with no account number behind it.
    final kind = cp?.kind;
    final hasName = (cp?.name ?? '').trim().isNotEmpty;
    final hasMask = _digits.hasMatch(cp?.accountMask ?? '');
    final looksShop =
        kind == CounterpartyKind.merchant ||
        (kind != CounterpartyKind.person &&
            kind != CounterpartyKind.own &&
            kind != CounterpartyKind.bank &&
            hasName &&
            OwnerName.parse(cp!.name) == null &&
            !hasMask);
    return MarkPlan(
      offerSelf: !looksShop && kind != CounterpartyKind.person,
      offerFamily:
          !looksShop &&
          kind != CounterpartyKind.own &&
          kind != CounterpartyKind.bank,
      payee: (cp?.name ?? '').trim().isNotEmpty ? cp!.name!.trim() : cp?.vpa,
      canRemember: remember,
      canMarkOnce: (entry.sourceKey ?? '').isNotEmpty,
      earlier: earlier,
      isShop: looksShop,
    );
  }

  static final _digits = RegExp(r'^\d{4,}$');

  static bool _recognisable(Counterparty cp) =>
      OwnerName.parse(cp.name) != null ||
      (cp.vpa?.contains('@') ?? false) ||
      _digits.hasMatch(cp.accountMask ?? '');

  /// The person marked a payment as a transfer: [mark] says to which kind, and
  /// [scope] whether it is this payment only or the payee for good (the earlier
  /// payments to it and every future one).
  Future<({MarkOutcome outcome, int changed})> mark(
    TransactionEntry entry,
    TransferMark mark,
    MarkScope scope,
  ) async {
    final id = entry.eventId;
    if (id == null)
      return (outcome: MarkOutcome.nothingToRecognise, changed: 0);
    final o = await _open();
    if (scope == MarkScope.once) {
      final key = entry.sourceKey;
      if (key == null || key.isEmpty) {
        return (outcome: MarkOutcome.nothingToRecognise, changed: 0);
      }
      o.store.markOnce(sourceKey: key, family: mark == TransferMark.family);
      return (outcome: MarkOutcome.marked, changed: await recheck());
    }
    final cp = _counterpartyOf(o.db, o.namespace, id);
    if (cp == null || !_recognisable(cp)) {
      return (outcome: MarkOutcome.nothingToRecognise, changed: 0);
    }
    switch (mark) {
      case TransferMark.self:
        o.store.markOwn(name: cp.name, vpa: cp.vpa, mask: cp.accountMask);
      case TransferMark.family:
        o.store.markFamily(name: cp.name, vpa: cp.vpa, mask: cp.accountMask);
    }
    // A single-payment mark made earlier is now covered by the payee mark.
    final key = entry.sourceKey;
    if (key != null && key.isNotEmpty) o.store.clearOnce(key);
    return (outcome: MarkOutcome.marked, changed: await recheck());
  }

  /// Takes back what [mark] did, as the "Undo" button does.
  Future<int> undoMark(
    TransactionEntry entry,
    TransferMark mark,
    MarkScope scope,
  ) async {
    final id = entry.eventId;
    if (id == null) return 0;
    final o = await _open();
    if (scope == MarkScope.once) {
      final key = entry.sourceKey;
      if (key != null) o.store.clearOnce(key);
    } else {
      final cp = _counterpartyOf(o.db, o.namespace, id);
      if (cp != null) {
        switch (mark) {
          case TransferMark.self:
            o.store.unmarkOwn(name: cp.name, vpa: cp.vpa, mask: cp.accountMask);
          case TransferMark.family:
            o.store.unmarkFamily(
              name: cp.name,
              vpa: cp.vpa,
              mask: cp.accountMask,
            );
        }
      }
    }
    return recheck(revert: true);
  }

  /// "This is not a transfer": takes back every mark that makes this payment one
  /// (its own and its payee's) and, for a payee that only looked like the
  /// person's own name, says it is not them.
  Future<int> unmark(TransactionEntry entry) async {
    final id = entry.eventId;
    if (id == null) return 0;
    final o = await _open();
    final key = entry.sourceKey;
    if (key != null && key.isNotEmpty) o.store.clearOnce(key);
    final cp = _counterpartyOf(o.db, o.namespace, id);
    if (cp != null) {
      if (entry.isFamilyTransfer) {
        o.store.unmarkFamily(name: cp.name, vpa: cp.vpa, mask: cp.accountMask);
      } else {
        o.store.markNotOwn(name: cp.name, vpa: cp.vpa, mask: cp.accountMask);
      }
    }
    return recheck(revert: true);
  }

  /// A line the settings list can show for a single-payment mark, from the
  /// transaction it was made on, or null when that transaction is gone.
  Future<String?> describePayment(String sourceKey) async {
    final o = await _open();
    final rows = o.db.select(
      "SELECT payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND source_key=? LIMIT 1",
      [o.namespace, sourceKey],
    );
    if (rows.isEmpty) return null;
    try {
      final t = TransactionEntry.fromJson(
        (jsonDecode(rows.first['payload'] as String) as Map)
            .cast<String, dynamic>(),
      );
      final d = t.occurredAt.toLocal();
      final who = (t.merchantName ?? '').trim();
      final paise = t.amount.paise;
      final rupees = (paise / 100).toStringAsFixed(paise % 100 == 0 ? 0 : 2);
      return '${who.isEmpty ? 'Payment' : who} · ₹$rupees · ${d.day}/${d.month}/${d.year}';
    } catch (_) {
      return null;
    }
  }
}
