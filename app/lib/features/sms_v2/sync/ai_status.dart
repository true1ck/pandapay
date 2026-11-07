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
  const AiStatusReader(this.state);
  final SyncStateStore state;

  static final _localSuffix = RegExp(r':local:[a-f0-9]{64}$');

  /// State of the uploaded format that this message format (its local hash)
  /// belongs to.
  AiTemplateState templateState(String localHash) {
    for (final row in state.db.select(
      "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'template:origins:%'",
      [state.namespace],
    )) {
      final remote = (row['key'] as String).substring('template:origins:'.length);
      try {
        final origin = jsonDecode(row['value'] as String) as Map;
        if (!(origin['localHashes'] as List).contains(localHash)) continue;
        if (state.get('template:sent:$remote') == null) {
          return AiTemplateState.none;
        }
        final raw = state.get('ai:$remote');
        if (raw == null) return AiTemplateState.checking;
        return switch ((jsonDecode(raw) as Map)['status']) {
          'ready' => AiTemplateState.ready,
          'rejected' || 'failed' => AiTemplateState.unavailable,
          _ => AiTemplateState.checking,
        };
      } catch (_) {
        continue;
      }
    }
    return AiTemplateState.none;
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
