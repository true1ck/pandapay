import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/providers.dart' as app;
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import '../sync/ai_status.dart';
import 'data_providers.dart';
import 'runtime_provider.dart';

/// What the AI check says about the open Needs review items.
class AiReviewStatus {
  const AiReviewStatus({
    this.checkingTemplates = const {},
    this.resolved = const {},
  });

  /// Local template hashes whose format was uploaded and awaits an answer.
  final Set<String> checkingTemplates;

  /// Source key -> the AI rule that read it.
  final Map<String, AiResolution> resolved;

  AiResolution? resolutionOf(LocalReviewItem item) {
    final source = item.payload['sourceKey'];
    return source is String ? resolved[source] : null;
  }

  bool isChecking(LocalReviewItem item) =>
      item.kind == 'template' &&
      item.payload['hasReading'] != true &&
      checkingTemplates.contains(item.payload['templateHash']);
}

final aiReviewStatusProvider = FutureProvider<AiReviewStatus>((ref) async {
  final items = await ref.watch(reviewItemsProvider.future);
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  final reader = AiStatusReader(SyncStateStore(db, namespace: namespace));
  final runtime = await ref.watch(smsV2RuntimeProvider.future);
  final bundle = await runtime?.activeBundle();
  // The overlay adds private rules with a `:local:` suffix; the rest are the
  // signed shared rules.
  final shared = <String>{
    for (final rule in bundle?.rules ?? const <Rule>[])
      if (!rule.id.contains(':local:')) rule.id,
  };
  final checking = <String>{};
  final resolved = <String, AiResolution>{};
  for (final item in items) {
    if (item.kind != 'template') continue;
    final source = item.payload['sourceKey'];
    final hash = item.payload['templateHash'];
    if (item.payload['hasReading'] == true && source is String) {
      final resolution = reader.resolution(source, sharedRuleIds: shared);
      if (resolution != null) resolved[source] = resolution;
    } else if (hash is String &&
        reader.templateState(hash) == AiTemplateState.checking) {
      checking.add(hash);
    }
  }
  return AiReviewStatus(checkingTemplates: checking, resolved: resolved);
});
