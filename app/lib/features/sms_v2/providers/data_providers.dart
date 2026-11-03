import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/providers.dart' as app;
import '../../../data/local/sms_intake_repository.dart';
import '../flag.dart';
import '../ledger/providers.dart';
import '../storage/schema.dart';

final instrumentsProvider = FutureProvider<List<Instrument>>((ref) async {
  if (!ref.watch(smsPipelineV2EnabledProvider)) return const [];
  return (await ref.watch(smsV2LedgerReadModelProvider.future)).instruments;
});

final eventsProvider = FutureProvider<List<Event>>((ref) async {
  if (!ref.watch(smsPipelineV2EnabledProvider)) return const [];
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
  if (!ref.watch(smsPipelineV2EnabledProvider)) return const [];
  ref.watch(app.financialStoreRevisionProvider('needs_review'));
  ref.watch(app.financialStoreRevisionProvider('observations'));
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  final intake = SmsIntakeRepository(cache.financialStore.database);
  return [
    for (final row in db.select(
      "SELECT review_id,kind,payload FROM v2_review_items WHERE namespace=? AND status='open' ORDER BY review_id",
      [namespace],
    ))
      for (final json in [
        (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
      ])
        LocalReviewItem(
          id: row['review_id'] as String,
          kind: row['kind'] as String,
          payload: json,
          message: json['sourceKey'] is String
              ? intake.capturedById(namespace, json['sourceKey'] as String)
              : null,
        ),
  ];
});
