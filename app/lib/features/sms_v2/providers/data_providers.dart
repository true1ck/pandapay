import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../app/providers.dart' as app;
import '../../../data/local/sms_intake_repository.dart';
import '../../../data/local/sms_learning_feedback.dart';
import '../ledger/providers.dart';
import '../storage/schema.dart';
import '../storage/fact_store.dart';
import '../storage/event_store.dart';

final merchantPromptMinimumOccurrencesProvider = Provider<int>((ref) => 2);
final merchantPromptLargeAmountProvider = Provider<int>((ref) => 200000);

final instrumentsProvider = FutureProvider<List<Instrument>>((ref) async {
  return (await ref.watch(smsV2LedgerReadModelProvider.future)).instruments;
});

final eventsProvider = FutureProvider<List<Event>>((ref) async {
  return (await ref.watch(smsV2LedgerReadModelProvider.future)).ledger.events;
});

final ledgerTotalsProvider =
    FutureProvider.family<Totals, ({DateTime from, DateTime to})>((
      ref,
      period,
    ) async {
      final model = await ref.watch(smsV2LedgerReadModelProvider.future);
      return model.snapshot().totals(period.from, period.to);
    });

class LocalReviewItem {
  const LocalReviewItem({
    required this.id,
    required this.kind,
    required this.payload,
    this.message,
  });
  final String id;
  final String kind;
  final Map<String, Object?> payload;
  final SmsIntakeEntry? message;
  String get groupKey => payload['templateHash'] as String? ?? id;
}

final reviewItemsProvider = FutureProvider<List<LocalReviewItem>>((ref) async {
  ref.watch(app.financialStoreRevisionProvider('needs_review'));
  ref.watch(app.financialStoreRevisionProvider('observations'));
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  final intake = SmsIntakeRepository(cache.financialStore.database);
  final factsStore = FactStore(db, namespace: namespace);
  final eventsStore = EventStore(db, namespace: namespace);
  Map<String, Object?> enrich(Map<String, Object?> payload) {
    final fact = payload['factId'] is String
        ? factsStore.get(payload['factId'] as String)
        : null;
    final event = payload['eventId'] is String
        ? eventsStore.get(payload['eventId'] as String)
        : null;
    final source =
        payload['sourceKey'] as String? ??
        fact?.sourceKey ??
        (event == null
            ? null
            : factsStore.get(event.legs.first.factId)?.sourceKey);
    final facts = source == null
        ? const <Fact>[]
        : factsStore.forSource(source);
    final movement = facts.whereType<MovementFact>().firstOrNull;
    return {
      ...payload,
      'sourceKey': ?source,
      'hasReading': movement != null || event != null,
      if (payload['candidates'] is List)
        'candidates': [
          for (final raw in payload['candidates'] as List)
            for (final candidate in [(raw as Map).cast<String, Object?>()])
              for (final fact in [
                candidate['factId'] is String
                    ? factsStore.get(candidate['factId'] as String)
                    : null,
              ])
                {
                  ...candidate,
                  'label': fact == null
                      ? 'Payment details unavailable'
                      : '${fact.counterparty?.name ?? 'Payment'} • ₹${(fact.amounts.where((a) => a.role == AmountRole.posted).firstOrNull?.minor ?? 0) / 100} • ${fact.effectiveAt.toLocal().toIso8601String().substring(0, 10)} ••${fact.instrument?.maskDigits ?? 'unknown'}',
                },
        ],
      if (movement != null)
        'reading':
            '${movement.direction.wire} ₹${(movement.amounts.where((a) => a.role == AmountRole.posted).firstOrNull?.minor ?? 0) / 100} ${movement.counterparty?.name ?? ''}',
    };
  }

  final model = await ref.watch(smsV2LedgerReadModelProvider.future);
  final factsById = {for (final fact in model.facts) fact.factId: fact};
  final merchantEvents = <String, List<Event>>{};
  for (final event in model.snapshot().events) {
    final decision = model.ledger.categoryByEvent[event.eventId];
    if (event.type != EventType.purchase ||
        decision?.source == CategorySource.user ||
        decision?.slug != 'other') {
      continue;
    }
    final money = event.legs
        .map((l) => factsById[l.factId])
        .whereType<MovementFact>()
        .firstOrNull;
    final merchant = money?.counterparty?.name;
    if (merchant == null) continue;
    merchantEvents
        .putIfAbsent(normalizeMerchantText(merchant), () => [])
        .add(event);
  }
  final cards = model.instruments
      .where(
        (i) =>
            i.kind == InstrumentKind.creditCard &&
            i.status == InstrumentStatus.confirmed,
      )
      .toList();
  final unresolvedBillIds = {
    for (final entry in model.ledger.entries)
      if (entry.to is OwnUnresolvedEndpoint &&
          (entry.to as OwnUnresolvedEndpoint).kind == InstrumentKind.creditCard)
        entry.eventId,
  };
  return [
    if (cards.length > 1)
      for (final event in model.ledger.events.where(
        (e) =>
            e.type == EventType.cardBillPayment &&
            unresolvedBillIds.contains(e.eventId),
      ))
        if (factsById[event.eventId]?.sourceKey case final source?)
          LocalReviewItem(
            id: 'bill-target:${event.eventId}',
            kind: 'bill_target',
            payload: {
              'sourceKey': source,
              'eventId': event.eventId,
              'hasReading': true,
            },
            message: intake.capturedById(namespace, source),
          ),
    for (final row in db.select(
      "SELECT review_id,kind,payload FROM v2_review_items WHERE namespace=? AND status='open' ORDER BY review_id",
      [namespace],
    ))
      for (final json in [
        enrich(
          (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
        ),
      ])
        LocalReviewItem(
          id: row['review_id'] as String,
          kind: json['reason'] == 'ambiguous_link'
              ? 'link'
              : row['kind'] as String,
          payload: json,
          message: json['sourceKey'] is String
              ? intake.capturedById(namespace, json['sourceKey'] as String)
              : null,
        ),
    for (final merchant in merchantEvents.entries)
      if (merchant.value.length >=
              ref.watch(merchantPromptMinimumOccurrencesProvider) ||
          merchant.value.any(
            (e) =>
                e.amountMinor >= ref.watch(merchantPromptLargeAmountProvider),
          ))
        for (final event in merchant.value)
          for (final source in [factsById[event.eventId]?.sourceKey])
            if (source != null)
              LocalReviewItem(
                id: 'category:${event.eventId}',
                kind: 'category',
                payload: {
                  'sourceKey': source,
                  'eventId': event.eventId,
                  'templateHash': merchant.key,
                  'hasReading': true,
                },
                message: intake.capturedById(namespace, source),
              ),
  ];
});

/// Unknown-format messages the user marked "not financial", newest first.
///
/// A dismissal leaves the review item `resolved` and saves an ignore rule for
/// the message format; the two together identify a dismissal (a resolved item
/// whose format has no rule was resolved some other way, for instance by a
/// rule that now reads it). A message whose text is no longer on the phone
/// cannot be matched to its rule and is not listed.
final dismissedReviewItemsProvider = FutureProvider<List<LocalReviewItem>>((
  ref,
) async {
  ref.watch(app.financialStoreRevisionProvider('needs_review'));
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final database = cache.financialStore.database;
  SmsV2Schema.ensure(database.db);
  return readDismissedReviewItems(
    db: database.db,
    intake: SmsIntakeRepository(database),
    feedback: SmsLearningFeedback(database, namespace: namespace),
    namespace: namespace,
  );
});

/// The query behind [dismissedReviewItemsProvider], without Riverpod.
List<LocalReviewItem> readDismissedReviewItems({
  required Database db,
  required SmsIntakeRepository intake,
  required SmsLearningFeedback feedback,
  required String namespace,
}) {
  final items = <LocalReviewItem>[];
  for (final row in db.select(
    "SELECT review_id,kind,payload FROM v2_review_items WHERE namespace=? AND kind='template' AND status='resolved' ORDER BY review_id",
    [namespace],
  )) {
    final payload = (jsonDecode(row['payload'] as String) as Map)
        .cast<String, Object?>();
    final source = payload['sourceKey'];
    if (source is! String) continue;
    final message = intake.capturedById(namespace, source);
    if (message == null) continue;
    if (!feedback.matchesFalseTransactionRuleSync(
      sender: message.message.sender,
      body: message.message.body,
    )) {
      continue;
    }
    items.add(
      LocalReviewItem(
        id: row['review_id'] as String,
        kind: 'template',
        payload: payload,
        message: message,
      ),
    );
  }
  return items;
}
