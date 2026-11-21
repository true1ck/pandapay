import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../app/providers.dart' as app;
import '../../../data/local/sms_intake_repository.dart';
import '../../sms_import/sms_background_queue.dart';
import '../ledger/providers.dart';
import '../storage/fact_store.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import '../sync/ai_status.dart';
import 'ai_review_doubt.dart';
import 'data_providers.dart';

/// The messages whose open template question is only an AI reading the AI was
/// sure about (so it is AI auto-resolved, not a question), worked out from the
/// database alone: the same [classifyOpenAiReadings] the Needs review screen and
/// its count use, for callers that have no review list (the sign-out warning,
/// the tag on a transaction row). Reads only the open template rows, the facts
/// and message text of the sources an AI rule read.
///
/// [factsBySource] is the read model's facts when the caller has it; without it
/// each source's facts are read from the database (bounded by the open AI
/// readings).
Set<String> confidentAiOpenSources(
  Database db,
  String namespace, {
  Map<String, List<Fact>>? factsBySource,
}) {
  final items = <String, LocalReviewItem>{};
  for (final row in db.select(
    "SELECT review_id,payload FROM v2_review_items WHERE namespace=? AND status='open' AND kind='template'",
    [namespace],
  )) {
    final payload = (jsonDecode(row['payload'] as String) as Map)
        .cast<String, Object?>();
    final source = payload['sourceKey'];
    if (source is! String || items.containsKey(source)) continue;
    items[source] = LocalReviewItem(
      id: row['review_id'] as String,
      kind: 'template',
      payload: {...payload, 'hasReading': true},
    );
  }
  if (items.isEmpty) return const {};
  final aiRead = AiStatusReader(
    SyncStateStore(db, namespace: namespace),
  ).aiReadSources(items.keys);
  if (aiRead.isEmpty) return const {};
  final facts = <String, List<Fact>>{
    for (final source in aiRead)
      source:
          factsBySource?[source] ??
          FactStore(db, namespace: namespace).forSource(source),
  };
  // The message text, for the direction check (one query per 400 sources).
  final withText = <LocalReviewItem>[];
  final bodies = <String, ({String sender, String body})>{};
  final keys = aiRead.toList();
  for (var start = 0; start < keys.length; start += 400) {
    final chunk = keys.sublist(start, (start + 400).clamp(0, keys.length));
    try {
      for (final row in db.select(
        'SELECT id,sender,body FROM sms_captured_messages WHERE namespace=? '
        'AND id IN (${List.filled(chunk.length, '?').join(',')})',
        [namespace, ...chunk],
      )) {
        bodies[row['id'] as String] = (
          sender: row['sender'] as String,
          body: row['body'] as String,
        );
      }
    } catch (_) {
      // No message table (a test database): only confidence is judged.
    }
  }
  for (final source in aiRead) {
    final item = items[source]!;
    final text = bodies[source];
    withText.add(
      LocalReviewItem(
        id: item.id,
        kind: item.kind,
        payload: item.payload,
        message: text == null
            ? null
            : SmsIntakeEntry(
                source,
                QueuedSms(
                  sender: text.sender,
                  body: text.body,
                  receivedAt: DateTime.fromMillisecondsSinceEpoch(0),
                ),
              ),
      ),
    );
  }
  return classifyOpenAiReadings(
    items: withText,
    aiRead: aiRead,
    factsBySource: facts,
  ).confident;
}

/// How many questions are open on Needs review, as the person would count them
/// for a warning: open rows, less the AI readings the AI was sure about (they are
/// hidden from Needs review, see [confidentAiOpenSources]).
int countOpenQuestions(Database db, String namespace) {
  final total = db.select(
    "SELECT COUNT(*) AS n FROM v2_review_items WHERE namespace=? AND status='open'",
    [namespace],
  ).single['n'] as int;
  final settled = confidentAiOpenSources(db, namespace);
  if (settled.isEmpty) return total;
  var hidden = 0;
  for (final row in db.select(
    "SELECT payload FROM v2_review_items WHERE namespace=? AND status='open' AND kind='template'",
    [namespace],
  )) {
    final source = (jsonDecode(row['payload'] as String) as Map)['sourceKey'];
    if (source is String && settled.contains(source)) hidden++;
  }
  return total - hidden;
}

/// The source keys and event ids of the messages that are open questions on
/// Needs review right now (AI readings the AI was sure about are not). The "AI"
/// tag on a transaction row uses it: a message that is a question has no card in
/// AI auto-resolved, so its row carries no tag. One query over the open rows,
/// never the review list (docs/PERFORMANCE_RULEBOOK.md R6).
Set<String> openReviewKeys(
  Database db,
  String namespace, {
  Map<String, List<Fact>>? factsBySource,
}) {
  final settled = confidentAiOpenSources(
    db,
    namespace,
    factsBySource: factsBySource,
  );
  final keys = <String>{};
  for (final row in db.select(
    "SELECT kind,payload FROM v2_review_items WHERE namespace=? AND status='open'",
    [namespace],
  )) {
    final payload = (jsonDecode(row['payload'] as String) as Map)
        .cast<String, Object?>();
    final source = payload['sourceKey'];
    if (row['kind'] == 'template' && source is String) {
      if (!settled.contains(source)) keys.add(source);
      continue;
    }
    if (source is String) keys.add(source);
    if (payload['eventId'] is String) keys.add(payload['eventId']! as String);
  }
  return keys;
}

/// [openReviewKeys], following the review table.
final openReviewKeysProvider = FutureProvider<Set<String>>((ref) async {
  ref.watch(reviewListBuildsProvider);
  ref.watch(app.financialStoreRevisionProvider('needs_review'));
  ref.watch(app.financialStoreRevisionProvider('observations'));
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  final model = await ref.watch(smsV2LedgerReadModelProvider.future);
  return openReviewKeys(db, namespace, factsBySource: model.factsBySource);
});
