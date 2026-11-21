import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart' as app;
import '../../../data/local/sms_intake_repository.dart';
import '../ledger/providers.dart';
import '../storage/event_store.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import '../sync/ai_status.dart';
import '../ui/review_clustering.dart';
import 'ai_review_doubt.dart';
import 'data_providers.dart';

/// "1 review left" / "38 reviews left": how the count reads everywhere outside
/// the Needs review screen.
String reviewsLeftText(int count) =>
    count == 1 ? '1 review left' : '$count reviews left';

/// How many reviews are left: the number the Needs review tab shows, and the
/// number shown outside that screen (Insights, the import summary, the
/// notification).
///
/// It counts questions, not messages: a format shared by many messages is one
/// question, Pay Later messages from one provider are one, and a message an AI
/// rule already read is filed under "AI suggested", not here. It is worked out
/// from the same pieces as the screen ([reviewRowReading], [reviewKindOf],
/// [reviewQuestionCount], [AiStatusReader]) but without resolving every item
/// against SQLite the way [reviewItemsProvider] does: one statement for the
/// open rows, one for their messages and one for the AI traces, so a badge
/// never builds the list (docs/PERFORMANCE_RULEBOOK.md R6).
final reviewQuestionCountProvider = FutureProvider<int>((ref) async {
  // Screens invalidate the list after an answer (a `v2_review_items` update
  // notifies no revision); this follows that, without building the list.
  ref.watch(reviewListBuildsProvider);
  ref.watch(app.financialStoreRevisionProvider('needs_review'));
  ref.watch(app.financialStoreRevisionProvider('observations'));
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final database = cache.financialStore.database;
  final db = database.db;
  SmsV2Schema.ensure(db);
  final model = await ref.watch(smsV2LedgerReadModelProvider.future);
  final candidates = reviewCandidates(
    model,
    minimumOccurrences: ref.watch(merchantPromptMinimumOccurrencesProvider),
    largeAmount: ref.watch(merchantPromptLargeAmountProvider),
  );
  final eventsStore = EventStore(db, namespace: namespace);
  final factsById = model.factsById;
  final factsBySource = model.factsBySource;

  // The open rows, read the way the list reads them.
  final rows = <({String id, String kind, Map<String, Object?> payload})>[];
  for (final row in db.select(
    "SELECT review_id,kind,payload FROM v2_review_items WHERE namespace=? AND status='open' ORDER BY review_id",
    [namespace],
  )) {
    final stored = (jsonDecode(row['payload'] as String) as Map)
        .cast<String, Object?>();
    final reading = reviewRowReading(
      stored,
      factFor: (id) => factsById[id],
      eventFor: eventsStore.get,
      factsOfSource: (source) => factsBySource[source] ?? const [],
    );
    rows.add((
      id: row['review_id'] as String,
      kind: stored['reason'] == 'ambiguous_link'
          ? 'link'
          : row['kind'] as String,
      payload: {
        ...stored,
        'sourceKey': ?reading.source,
        'hasReading': reading.hasReading,
      },
    ));
  }

  final sources = <String>{
    for (final row in rows)
      if (row.payload['sourceKey'] case final String source) source,
    for (final target in candidates.billTargets) target.sourceKey,
  };
  final messages = SmsIntakeRepository(
    database,
  ).capturedByIds(namespace, sources);

  final items = <LocalReviewItem>[
    for (final target in candidates.billTargets)
      LocalReviewItem(
        id: 'bill-target:${target.eventId}',
        kind: 'bill_target',
        payload: {
          'sourceKey': target.sourceKey,
          'eventId': target.eventId,
          'hasReading': true,
        },
        message: messages[target.sourceKey],
      ),
    for (final row in rows)
      LocalReviewItem(
        id: row.id,
        kind: row.kind,
        payload: row.payload,
        message: switch (row.payload['sourceKey']) {
          final String source => messages[source],
          _ => null,
        },
      ),
    for (final prompt in candidates.categoryPrompts)
      LocalReviewItem(
        id: 'category:${prompt.eventId}',
        kind: 'category',
        payload: {
          'sourceKey': prompt.sourceKey,
          'eventId': prompt.eventId,
          'templateHash': prompt.merchantKey,
          'hasReading': true,
        },
      ),
  ];

  // A reading an AI rule made and was sure about is AI auto-resolved: it is not
  // a review left. The same test as the screen's [AiReviewStatus]: a template
  // row whose message has a reading, read by an AI rule, with confidence and no
  // direction conflict ([classifyOpenAiReadings]). One the AI is unsure about
  // stays here, with the "AI suggested" badge.
  final aiRead = AiStatusReader(SyncStateStore(db, namespace: namespace))
      .aiReadSources([
        for (final row in rows)
          if (row.kind == 'template' &&
              row.payload['hasReading'] == true &&
              row.payload['sourceKey'] is String)
            row.payload['sourceKey']! as String,
      ]);
  final readings = classifyOpenAiReadings(
    items: items,
    aiRead: aiRead,
    factsBySource: factsBySource,
  );
  return reviewQuestionCount(onePerMessage([
    for (final item in items)
      if (!readings.settles(item)) item,
  ]), reviewKindOf);
});
