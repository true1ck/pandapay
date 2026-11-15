import 'dart:convert';

import '../storage/sync_state_store.dart';

/// Where one of this account's unreadable formats stands with the AI check.
enum AiTemplateState {
  /// Never uploaded for an AI answer (no sharing consent, or not sent yet).
  none,

  /// Uploaded, and the server has not answered yet.
  checking,

  /// The server answered with a private rule; the next capture applies it.
  ready,

  /// The AI could not make a rule, or the admin rejected it.
  unavailable,
}

/// An AI rule that read one of this account's messages.
class AiResolution {
  const AiResolution({required this.ruleId, required this.verified});

  /// The shared id of the AI rule, `AI-<template hash>` (no local suffix).
  final String ruleId;

  /// True once the rule is in the signed shared bundle, i.e. an admin approved
  /// and published it. Until then the reading is the AI's, not yet verified.
  final bool verified;
}

/// Reads the AI check state kept in the local sync state. Read-only.
class AiStatusReader {
  const AiStatusReader(
    this.state, {
    this.now,
    this.checkingFor = const Duration(hours: 24),
  });
  final SyncStateStore state;

  /// The clock, for tests. Defaults to the device time.
  final DateTime Function()? now;

  /// How long an unanswered upload keeps saying "checking". A layout that is
  /// held, blocked or never drafted would otherwise wait forever.
  final Duration checkingFor;

  static final _localSuffix = RegExp(r':local:[a-f0-9]{64}$');

  /// State of the uploaded format that this message format (its local hash)
  /// belongs to.
  AiTemplateState templateState(String localHash) {
    for (final row in state.db.select(
      "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'template:origins:%'",
      [state.namespace],
    )) {
      final remote = (row['key'] as String).substring(
        'template:origins:'.length,
      );
      try {
        final origin = jsonDecode(row['value'] as String) as Map;
        if (!(origin['localHashes'] as List).contains(localHash)) continue;
        if (state.get('template:sent:$remote') == null) {
          return AiTemplateState.none;
        }
        final raw = state.get('ai:$remote');
        final status = raw == null ? null : (jsonDecode(raw) as Map)['status'];
        if (status == 'ready') return AiTemplateState.ready;
        if (status == 'rejected' || status == 'failed') {
          return AiTemplateState.unavailable;
        }
        final sentAt = DateTime.tryParse(state.get('template:sent:$remote')!);
        final current = (now ?? DateTime.now)();
        if (sentAt != null && current.difference(sentAt) > checkingFor) {
          return AiTemplateState.none;
        }
        return AiTemplateState.checking;
      } catch (_) {
        continue;
      }
    }
    return AiTemplateState.none;
  }

  /// Whether any uploaded format of this account is still waiting for the AI's
  /// answer. Cheap (one query, no message data) so a notification sweep can ask
  /// it without building the review list.
  bool hasChecking() {
    for (final row in state.db.select(
      "SELECT key FROM v2_sync_state WHERE namespace=? AND key LIKE 'template:origins:%'",
      [state.namespace],
    )) {
      final remote = (row['key'] as String).substring('template:origins:'.length);
      final sent = state.get('template:sent:$remote');
      if (sent == null) continue;
      try {
        final raw = state.get('ai:$remote');
        final status = raw == null ? null : (jsonDecode(raw) as Map)['status'];
        if (status == 'ready' || status == 'rejected' || status == 'failed') {
          continue;
        }
        final sentAt = DateTime.tryParse(sent);
        final current = (now ?? DateTime.now)();
        if (sentAt != null && current.difference(sentAt) > checkingFor) continue;
        return true;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  /// The AI rule that read this source, from the decision trace saved when it
  /// was read. [sharedRuleIds] are the rule ids in the signed bundle.
  AiResolution? resolution(
    String sourceKey, {
    required Set<String> sharedRuleIds,
  }) {
    final raw = state.get('trace:$sourceKey');
    if (raw == null) return null;
    try {
      final id = (jsonDecode(raw) as Map)['ruleId'];
      if (id is! String || !id.startsWith('AI-')) return null;
      final shared = id.replaceFirst(_localSuffix, '');
      return AiResolution(
        ruleId: shared,
        verified: sharedRuleIds.contains(shared) || !_localSuffix.hasMatch(id),
      );
    } catch (_) {
      return null;
    }
  }
}

/// True when a format this phone uploaded in the last [within] has no final answer yet: no result, or one still
/// `pending`. A draft takes seconds on the server, so the phone looks for it soon instead of waiting minutes for the
/// next ordinary sync. The window is short on purpose: a layout the server never drafts (one a rule already covers
/// stays `pending` for ever) must not keep the phone asking.
bool hasFormatWaitingForAnswer(
  SyncStateStore state, {
  required DateTime now,
  Duration within = const Duration(minutes: 10),
}) {
  final cutoff = now.toUtc().subtract(within).toIso8601String();
  return state.db.select(
    "SELECT 1 FROM v2_sync_state s WHERE s.namespace=? AND s.key LIKE 'template:sent:%' AND s.value>? "
    "AND NOT EXISTS (SELECT 1 FROM v2_sync_state a WHERE a.namespace=s.namespace "
    "AND a.key='ai:' || substr(s.key, 15) "
    "AND json_extract(a.value, '\$.status') IN ('ready', 'rejected', 'failed')) LIMIT 1",
    [state.namespace, cutoff],
  ).isNotEmpty;
}
