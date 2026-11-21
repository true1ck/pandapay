import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/providers.dart' as app;
import '../pipeline/ai_doubt.dart' show AiDoubt;
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import '../sync/ai_status.dart';
import '../sync/template_retry.dart';
import '../ui/review_clustering.dart' show isReceiptQuestion;
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
    this.retryable = const {},
    this.retrying = const {},
  });

  /// Local template hashes of formats the AI could not read (failed or turned down, or no answer and nothing in
  /// progress) that "Try again" may be offered for: sharing is on and the layout was not retried in the last five
  /// minutes.
  final Set<String> retryable;

  /// Local template hashes whose retry was pressed and has no new answer yet ("Trying again").
  final Set<String> retrying;

  bool canRetry(LocalReviewItem item) =>
      item.kind == 'template' && retryable.contains(item.payload['templateHash']);

  bool isRetrying(LocalReviewItem item) =>
      item.kind == 'template' && retrying.contains(item.payload['templateHash']);

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
  final retryable = <String>{};
  final retrying = <String>{};
  final resolved = <String, AiResolution>{};
  // "Try again" only makes sense while sharing is on: nothing is sent without it.
  var sharingOn = false;
  try {
    sharingOn =
        (await ref.watch(app.smsSharedLearningConsentProvider.future))
            ?.granted ==
        true;
  } catch (_) {
    // No answer (offline, signed out): no retry is offered.
  }
  final retry = TemplateRetry(db, namespace: namespace);
  final origins = retry.index();
  final judged = <String>{}; // one look per message format, however many messages share it
  for (final item in items) {
    if (item.kind != 'template') continue;
    final source = item.payload['sourceKey'];
    final hash = item.payload['templateHash'];
    if (item.payload['hasReading'] == true && source is String) {
      final resolution = reader.resolution(source, sharedRuleIds: shared);
      if (resolution != null) resolved[source] = resolution;
    } else if (hash is String && judged.add(hash)) {
      final remote = origins[hash] ?? const <String>[];
      if (retry.isRetryingHashes(remote)) {
        retrying.add(hash);
        continue;
      }
      final state = reader.templateState(hash);
      if (state == AiTemplateState.checking) {
        checking.add(hash);
      } else if (sharingOn &&
          // Only where the AI has nothing usable for the format: it failed or was
          // turned down (or this phone turned its draft down), or no answer and
          // nothing in progress. A `ready` answer is a working rule: resetting
          // would delete it, so no retry is offered while it stands.
          (state == AiTemplateState.none ||
              state == AiTemplateState.unavailable) &&
          remote.isNotEmpty &&
          item.payload['aiHold'] == null &&
          !isReceiptQuestion(item) &&
          retry.canTryHashes(remote)) {
        // The AI could not read it (failed or turned down), or nothing is in
        // progress for it.
        retryable.add(hash);
      }
    }
  }
  return AiReviewStatus(
    checkingTemplates: checking,
    retryable: retryable,
    retrying: retrying,
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
