import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../category/category_snapshot.dart';
import '../ledger/projection_writer.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';
import '../storage/schema.dart';

/// What [ReceiptReviews.confirm] did.
enum ReceiptConfirmation {
  /// The payment now counts once, as the receipt's event type.
  counted,

  /// A funding debit already counts for this receipt: nothing was added.
  alreadyCounted,
}

/// The receipt question: a bill-payment receipt (evidence only) that no
/// funding debit ever matched.
///
/// - [sweep] raises one review item for each such receipt from the current IST
///   calendar month once it has waited [kReceiptWaitPeriod]; receipts from
///   earlier months are skipped silently (see `receipt_policy.dart`).
/// - [resolveJoined] closes an open item when a funding debit later joins its
///   receipt, so the debit counts once and the question goes away.
/// - [confirm], [dismiss] are the user's answers.
///
/// A receipt never counts by itself; only [confirm] makes it count, once.
class ReceiptReviews {
  ReceiptReviews({
    required this.financial,
    required this.namespace,
    required this.bundle,
    DateTime Function()? clock,
    this.categoryIdBySlug = const {},
  }) : clock = clock ?? DateTime.now;

  final FinancialStore financial;
  final String namespace;
  final RuleBundle bundle;
  final DateTime Function() clock;
  final Map<String, String> categoryIdBySlug;

  Database get _db => financial.database.db;

  // ------------------------------------------------------------------ sweep

  /// Raises the question for every receipt that is due. Returns how many items
  /// were created. Safe to call as often as needed: an item that exists in any
  /// status (open, answered, dismissed) is never raised again.
  int sweep() {
    SmsV2Schema.ensure(_db);
    final now = clock().toUtc();
    // A receipt early in the month may be joined by a debit a few days before.
    final from = istMonthStart(now).subtract(const Duration(days: 7));
    if (!_hasReceipts(from)) return 0;
    final facts = FactStore(_db, namespace: namespace);
    final raised = <String>{};
    for (final row in _db.select(
      "SELECT review_id, json_extract(payload,'\$.reviewId') AS rid, "
      "json_extract(payload,'\$.dedupeKey') AS dedupe "
      'FROM v2_review_items WHERE namespace=?',
      [namespace],
    )) {
      raised
        ..add(row['review_id'] as String)
        ..addAll([
          if (row['rid'] case final String id) id,
          if (row['dedupe'] case final String key) key,
        ]);
    }
    final result = RuleDrivenLinker.fromBundle(bundle, clock: () => now)
        .reviewReceipts(
          now: now,
          context: RuleLinkContext(
            recentFacts: facts.since(from),
            openEvents: const [],
            knownEvents: EventStore(
              _db,
              namespace: namespace,
            ).contextSince(from),
            instrumentsById: {
              for (final i in InstrumentStore(_db, namespace: namespace).list())
                i.instrumentId: i,
            },
            instrumentIdByFactId: facts.instrumentIdsSince(from),
          ),
          rules: bundle.linkRules,
          alreadyRaised: raised,
        );
    var created = 0;
    financial.batch(() {
      for (final raised in result.ambiguous) {
        final item = _withApp(raised, facts);
        final id = item.payload['reviewId'] as String;
        _db.execute(
          'INSERT INTO v2_review_items (namespace, review_id, kind, payload, status) '
          "VALUES (?, ?, ?, ?, 'open') ON CONFLICT(namespace, review_id) DO NOTHING",
          [namespace, id, item.kind.name, jsonEncode(item.payload)],
        );
        created += _db.updatedRows;
      }
      if (created > 0) {
        financial.notifyExternalChanges(namespace, const ['needs_review']);
      }
    });
    return created;
  }

  /// Names the app that sent the receipt (from the message's sender), so the
  /// question can say "through {app}". A receipt's own counterparty is usually
  /// the biller or the card issuer, not the app.
  ReviewItem _withApp(ReviewItem item, FactStore facts) {
    final fact = facts.get(item.payload['factId'] as String);
    final sender = fact == null
        ? null
        : SmsIntakeRepository(
            financial.database,
          ).capturedById(namespace, fact.sourceKey)?.message.sender;
    if (sender == null) return item;
    final brand = normalizeSenderBrand(sender, bundle.senders).brand;
    final entry = bundle.senders.where((e) => e.brand == brand).firstOrNull;
    final raw = entry?.issuerSlug ?? brand;
    final app = raw.isEmpty
        ? null
        : '${raw[0].toUpperCase()}${raw.substring(1).toLowerCase()}';
    if (app == null) return item;
    final cardBill = item.payload['cardBill'] == true;
    final at = DateTime.parse(item.payload['receiptAt'] as String);
    return ReviewItem(
      kind: item.kind,
      payload: {
        ...item.payload,
        'app': app,
        'message': kReceiptReviewTextEn.question(
          cardBill: cardBill,
          amount: formatReceiptRupees(item.payload['amountMinor'] as int),
          date: formatReceiptDate(at),
          app: app,
        ),
      },
    );
  }

  bool _hasReceipts(DateTime from) => _db.select(
    "SELECT 1 FROM v2_facts WHERE namespace=? AND observed_at>=? AND fact_type='movement' "
    "AND json_extract(payload,'\$.attrs.evidenceOnly')=1 LIMIT 1",
    [namespace, _timestamp(from)],
  ).isNotEmpty;

  // Matches FactStore: fixed-width fractions keep TEXT range scans ordered.
  static String _timestamp(DateTime value) {
    final utc = value.toUtc();
    final iso = utc.toIso8601String();
    return utc.microsecond == 0
        ? '${iso.substring(0, iso.length - 1)}000Z'
        : iso;
  }

  // ---------------------------------------------------------------- joined

  /// Closes the open question of every receipt that [events] now hold as a
  /// duplicate notice: a funding debit arrived, the debit counts once, and the
  /// user need not answer.
  static void resolveJoined(
    Database db,
    String namespace,
    Iterable<Event> events,
  ) {
    final receipts = <String>{
      for (final event in events)
        if (event.type != EventType.unknown)
          for (final leg in event.legs)
            if (leg.role == LegRole.duplicateNotice) leg.factId,
    };
    if (receipts.isEmpty) return;
    final open = db.select(
      "SELECT review_id, json_extract(payload,'\$.factId') AS fact "
      'FROM v2_review_items WHERE namespace=? AND status!=? '
      "AND json_extract(payload,'\$.reason')=?",
      [namespace, 'resolved', kReceiptWithoutPaymentReason],
    );
    for (final row in open) {
      if (!receipts.contains(row['fact'])) continue;
      db.execute(
        "UPDATE v2_review_items SET status='resolved', "
        "payload=json_set(payload,'\$.answer','matched') "
        'WHERE namespace=? AND review_id=?',
        [namespace, row['review_id']],
      );
    }
  }

  // --------------------------------------------------------------- answers

  /// "Yes, I paid it": the payment counts once, as a card payment for a card
  /// bill (an own transfer, never spending) and as the receipt's own type for
  /// anything else. [fundingInstrumentId] is the account the user says paid it;
  /// null is "another account" (the money leaves an account the app does not
  /// know). Calling it again changes nothing.
  ReceiptConfirmation confirm({
    required String reviewId,
    String? fundingInstrumentId,
  }) {
    SmsV2Schema.ensure(_db);
    final item = _openItem(reviewId);
    final facts = FactStore(_db, namespace: namespace);
    final receipt = facts.get(item['factId'] as String);
    if (receipt is! MovementFact ||
        receipt.evidenceOnly != true ||
        receipt.direction != Direction.debit) {
      throw ArgumentError('This receipt is no longer available');
    }
    final funding = fundingInstrumentId == null
        ? null
        : InstrumentStore(_db, namespace: namespace).get(fundingInstrumentId);
    if (fundingInstrumentId != null &&
        (funding == null ||
            funding.status == InstrumentStatus.rejected ||
            (funding.kind != InstrumentKind.bankAccount &&
                funding.kind != InstrumentKind.wallet))) {
      throw ArgumentError('Choose an account of yours');
    }
    final events = EventStore(_db, namespace: namespace);
    // A funding debit that already counts for this receipt: never count twice.
    final counted = events.findByFactId(receipt.factId).any((e) {
      if (e.type == EventType.unknown) return false;
      return e.legs.any(
        (l) =>
            l.role == LegRole.debitLeg ||
            l.role == LegRole.charge ||
            l.role == LegRole.creditLeg,
      );
    });
    if (counted) {
      _close(reviewId, 'matched');
      return ReceiptConfirmation.alreadyCounted;
    }

    final userFactId = sha256
        .convert(utf8.encode('user-receipt|${receipt.factId}'))
        .toString();
    final json = receipt.toJson();
    final attrs = (json['attrs']! as Map).cast<String, Object?>();
    final counterparty = receipt.counterparty;
    final user = Fact.fromJson({
      ...json,
      'factId': userFactId,
      'sourceKey': 'correction:receipt:${receipt.factId}',
      'instrument': funding == null
          ? null
          : InstrumentMention(
              kind: funding.kind,
              issuerSlug: funding.issuerSlug,
              maskDigits: funding.maskDigits,
              maskLength: funding.maskDigits?.length,
            ).toJson(),
      // The biller's text names no card the app can match by name; keep the
      // printed card ending so the payment reaches the right card.
      if (counterparty != null)
        'counterparty': {...counterparty.toJson(), 'name': null},
      'attrs': {...attrs, 'evidenceOnly': false},
      'provenance': {
        ...receipt.provenance.toJson(),
        'engine': Engine.user.wire,
        'ruleId': kReceiptConfirmedRuleId,
        'ruleVersion': 1,
      },
      'confidence': 1.0,
    });

    financial.batch(() {
      _db.execute('SAVEPOINT sms_v2_receipt_confirm');
      try {
        facts.insert(user, instrumentId: funding?.instrumentId);
        final posted = receipt.amount(AmountRole.posted)!.minor;
        final event = events.upsert(
          Event(
            eventId: userFactId,
            type: receiptConfirmedEventType(receipt),
            status: EventStatus.userConfirmed,
            legs: [
              EventLeg(factId: userFactId, role: LegRole.debitLeg),
              EventLeg(factId: receipt.factId, role: LegRole.duplicateNotice),
            ],
            linkRuleId: 'LINK-RECEIPT',
            confidence: 1,
            occurredAt: receipt.effectiveAt,
            amountMinor: posted,
          ),
          fromUser: true,
        );
        final outbox = OutboxStore(_db, namespace: namespace);
        outbox.enqueue('source', user.sourceKey, {
          'sourceKey': user.sourceKey,
          'senderBrand': 'USER',
          'observedAt': user.observedAt.toUtc().toIso8601String(),
          'bodyHash': sha256.convert(utf8.encode(user.sourceKey)).toString(),
          'facts': [
            {
              ...user.toJson(),
              'evidence': <Object?>[],
              if (user.instrument != null)
                'instrument': {...user.instrument!.toJson(), 'raw': null},
            },
          ],
        });
        outbox.enqueue('event', event.eventId, event.toJson());
        _project(event, {receipt.factId: receipt, user.factId: user});
        _close(reviewId, 'yes');
        _db.execute('RELEASE sms_v2_receipt_confirm');
      } catch (_) {
        _db.execute('ROLLBACK TO sms_v2_receipt_confirm');
        _db.execute('RELEASE sms_v2_receipt_confirm');
        rethrow;
      }
    });
    financial.notifyExternalChanges(namespace, const [
      'needs_review',
      'transactions',
      'observations',
    ]);
    return ReceiptConfirmation.counted;
  }

  /// "No, someone else paid it": nothing is counted and the question is closed.
  void dismiss({required String reviewId}) {
    SmsV2Schema.ensure(_db);
    _openItem(reviewId);
    financial.batch(() => _close(reviewId, 'no'));
    financial.notifyExternalChanges(namespace, const ['needs_review']);
  }

  Map<String, Object?> _openItem(String reviewId) {
    final rows = _db.select(
      'SELECT payload, status FROM v2_review_items WHERE namespace=? AND review_id=?',
      [namespace, reviewId],
    );
    if (rows.isEmpty) throw ArgumentError('This question is no longer open');
    final payload = (jsonDecode(rows.first['payload'] as String) as Map)
        .cast<String, Object?>();
    if (payload['reason'] != kReceiptWithoutPaymentReason) {
      throw ArgumentError('Not a receipt question');
    }
    if (rows.first['status'] == 'resolved') {
      throw StateError('This question was already answered');
    }
    return payload;
  }

  void _close(String reviewId, String answer) => _db.execute(
    "UPDATE v2_review_items SET status='resolved', "
    "payload=json_set(payload,'\$.answer',?) WHERE namespace=? AND review_id=?",
    [answer, namespace, reviewId],
  );

  void _project(Event event, Map<String, Fact> own) {
    final facts = FactStore(_db, namespace: namespace);
    final ledger = LedgerStore(_db, namespace: namespace);
    final instruments = {
      for (final i in InstrumentStore(_db, namespace: namespace).list())
        i.instrumentId: i,
    };
    final instrumentIds = facts.instrumentIdsSince(DateTime.utc(1900));
    final categories = CategorySnapshot.load(
      financial.database,
      namespace: namespace,
      aliases: bundle.merchantAliases,
    );
    final snapshot = LedgerSnapshot.project(
      events: [event],
      factsById: own,
      instrumentsById: instruments,
      bundle: bundle,
      lockedCategories: const {},
      instrumentIdByFactId: instrumentIds,
      userRules: categories.userRules,
      confirmedHistory: categories.confirmedHistory,
    );
    ProjectionWriter(financial, ledger).write(
      snapshot,
      factsById: own,
      instrumentsById: instruments,
      categoryIdBySlug: categoryIdBySlug,
      instrumentIdByFactId: instrumentIds,
    );
    final outbox = OutboxStore(_db, namespace: namespace);
    for (final entry in snapshot.entries) {
      outbox.enqueue('ledger', entry.entryId, entry.toJson());
    }
  }
}
