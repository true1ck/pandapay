import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart' as app;
import '../providers/ai_status_provider.dart';
import '../providers/data_providers.dart';
import '../providers/runtime_provider.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import '../sync/ai_status.dart';
import '../sync/template_retry.dart';

/// The "Try again" button of a Needs review card whose format the AI could not
/// read. Clears this phone's marks for the format ([TemplateRetry.reset]), then,
/// in the background, asks the server to retry it ([requestServerRetry], once)
/// and runs a sync so the upload goes at once. A server that does not answer or
/// does not know the call changes nothing the person sees: the retry has already
/// gone from the phone. Returns false when there was nothing to retry (the
/// format was never sent, or was retried less than five minutes ago).
Future<bool> tryAgainFor(WidgetRef ref, List<LocalReviewItem> group) async {
  final namespace = ref.read(app.cacheNamespaceProvider);
  final cache = await ref.read(app.responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  SmsV2Schema.ensure(db);
  final retry = TemplateRetry(db, namespace: namespace);
  final hashes = <String>[];
  final byFormat = <String, List<String>>{};
  for (final item in group) {
    final format = item.payload['templateHash'];
    final source = item.payload['sourceKey'];
    if (format is String) {
      (byFormat[format] ??= []).addAll([if (source is String) source]);
    }
  }
  final reader = AiStatusReader(SyncStateStore(db, namespace: namespace));
  for (final MapEntry(key: format, value: sources) in byFormat.entries) {
    // Never reset a layout the AI answered with a working rule (or is still
    // drafting): that would delete the rule this phone reads with.
    final state = reader.templateState(format);
    if (state != AiTemplateState.none && state != AiTemplateState.unavailable) {
      continue;
    }
    hashes.addAll(retry.reset(format, sourceKeys: sources));
  }
  ref.invalidate(aiReviewStatusProvider);
  if (hashes.isEmpty) return false;
  final runtime = await ref.read(smsV2RuntimeProvider.future);
  if (runtime != null) {
    unawaited(() async {
      // The server first, so a layout it has marked failed is open again when the upload reaches it.
      await requestServerRetry(
        client: runtime.client,
        baseUri: runtime.baseUri,
        headers: runtime.headers,
        templateHashes: hashes.toSet().toList(),
      );
      try {
        await runtime.sync();
      } catch (_) {
        // The next sync does it.
      }
    }());
  }
  return true;
}
