import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/providers.dart' as app;
import '../pipeline/ai_doubt.dart' show AiDoubt;
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import '../sync/ai_status.dart';
import '../ledger/providers.dart';
import 'ai_review_doubt.dart';
import 'data_providers.dart';
import 'runtime_provider.dart';

/// What the AI check says about the open Needs review items.
class AiReviewStatus {
  const AiReviewStatus({
    this.checkingTemplates = const {},
    this.resolved = const {},
    this.readings = const AiOpenReadings(),
  });

  /// Local template hashes whose format was uploaded and awaits an answer.
  final Set<String> checkingTemplates;

  /// Source key -> the AI rule that read it.
  final Map<String, AiResolution> resolved;

  /// Which of those AI readings the AI was sure about (they are AI
  /// auto-resolved, not questions) and which need the person (they stay on
  /// Needs review with the "AI suggested" badge).
  final AiOpenReadings readings;

  /// An open question that is only an AI reading the AI was sure about: it does
  /// not belong on Needs review.
  bool settledByAi(LocalReviewItem item) => readings.settles(item);

  /// Why the person is asked about an AI reading, when it is one.
  AiDoubt? doubtOf(LocalReviewItem item) {
    final source = item.payload['sourceKey'];
    return source is String ? readings.doubtful[source] : null;
  }

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
  final model = await ref.watch(smsV2LedgerReadModelProvider.future);
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
  return AiReviewStatus(
    checkingTemplates: checking,
    resolved: resolved,
    readings: classifyOpenAiReadings(
      items: items,
      aiRead: resolved.keys.toSet(),
      factsBySource: model.factsBySource,
    ),
  );
});

/// What this phone itself holds about the AI check (answers saved, links back
/// to its own formats, AI rules in use, messages an AI rule read). Computed
/// only while the person has the "phone details" line open, and dropped when
/// it is closed.
final aiPhoneDiagnosticsProvider = FutureProvider.autoDispose<AiPhoneDiagnostics>((
  ref,
) async {
  final namespace = ref.watch(app.cacheNamespaceProvider);
  final cache = await ref.watch(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  final reader = AiStatusReader(SyncStateStore(db, namespace: namespace));
  final runtime = await ref.watch(smsV2RuntimeProvider.future);
  final bundle = await runtime?.activeBundle();
  // The engine's rules with a `:local:` suffix are the AI answers it is using.
  final active = [
    for (final rule in bundle?.rules ?? const <Rule>[])
      if (rule.id.startsWith('AI-') && rule.id.contains(':local:')) rule,
  ];
  return reader.diagnostics().withActiveAiRules(active.length);
});
