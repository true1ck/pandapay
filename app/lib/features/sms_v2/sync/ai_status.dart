import 'dart:convert';

import '../storage/draft_verdict_store.dart';
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

/// What this phone itself holds about the AI check, for the "phone details"
/// line of the Needs review bar. Counts only, no message text.
class AiPhoneDiagnostics {
  const AiPhoneDiagnostics({
    this.answersReady = 0,
    this.answersFailed = 0,
    this.linksSaved = 0,
    this.readyWithLink = 0,
    this.unknownMessages = 0,
    this.unknownWithText = 0,
    this.readByAiRule = 0,
    this.activeAiRules = 0,
    this.lastErasedAt,
    this.restoresTried = 0,
    this.lastPullProblem,
    this.lastPullProblemAt,
  });

  /// Answers the server sent that carry a usable rule.
  final int answersReady;

  /// Answers that say the AI could not draft the format, or it was rejected.
  final int answersFailed;

  /// Links from a shared format back to this phone's own message formats. An
  /// answer is applied only through such a link.
  final int linksSaved;

  /// Ready answers that have their link: the only ones the phone can apply.
  final int readyWithLink;

  /// Messages the phone has marked unknown, and how many still have their text
  /// on the phone (a message without its text cannot be read again).
  final int unknownMessages;
  final int unknownWithText;

  /// Messages whose saved reading names an AI rule.
  final int readByAiRule;

  /// AI rules the engine is using right now (set by the caller, who has the
  /// rule bundle).
  final int activeAiRules;

  /// When the phone last erased its AI answers (sharing withdrawn), if ever.
  final String? lastErasedAt;

  /// How many times the phone asked the server to send its answers again.
  final int restoresTried;

  /// What stopped the last sync pull, as "Type: message", and when. Null when
  /// the last pull did not fail. Local only: it can name a row or a merchant.
  final String? lastPullProblem;
  final String? lastPullProblemAt;

  AiPhoneDiagnostics withActiveAiRules(int count) => AiPhoneDiagnostics(
    answersReady: answersReady,
    answersFailed: answersFailed,
    linksSaved: linksSaved,
    readyWithLink: readyWithLink,
    unknownMessages: unknownMessages,
    unknownWithText: unknownWithText,
    readByAiRule: readByAiRule,
    activeAiRules: count,
    lastErasedAt: lastErasedAt,
    restoresTried: restoresTried,
    lastPullProblem: lastPullProblem,
    lastPullProblemAt: lastPullProblemAt,
  );
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

  /// Counts of what this phone holds, in a few small queries. Meant to be run
  /// when the person asks to see them, not on every redraw.
  AiPhoneDiagnostics diagnostics() {
    final ns = state.namespace;
    final linked = <String>{};
    for (final row in state.db.select(
      "SELECT key FROM v2_sync_state WHERE namespace=? AND key LIKE 'template:origins:%'",
      [ns],
    )) {
      linked.add((row['key'] as String).substring('template:origins:'.length));
    }
    var ready = 0, failed = 0, readyWithLink = 0;
    for (final row in state.db.select(
      "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%'",
      [ns],
    )) {
      try {
        final value = jsonDecode(row['value'] as String);
        if (value is! Map) continue;
        final hash = (row['key'] as String).substring('ai:'.length);
        final status = value['status'];
        if (status == 'ready' && value['rule'] is Map) {
          ready++;
          if (linked.contains(hash)) readyWithLink++;
        } else if (status == 'failed' || status == 'rejected') {
          failed++;
        }
      } catch (_) {
        continue; // not an answer (a timestamp or another marker)
      }
    }
    var unknown = 0, unknownWithText = 0;
    try {
      unknown = state.db.select(
        "SELECT count(*) AS n FROM sms_source_decisions WHERE namespace=? AND decision='unknown'",
        [ns],
      ).first['n'] as int;
      unknownWithText = state.db.select(
        "SELECT count(*) AS n FROM sms_source_decisions d WHERE d.namespace=? AND d.decision='unknown' "
        'AND EXISTS (SELECT 1 FROM sms_captured_messages m WHERE m.namespace=d.namespace AND m.id=d.source_key)',
        [ns],
      ).first['n'] as int;
    } catch (_) {
      // The message tables are not there (a test database): nothing to count.
    }
    var readByAi = 0;
    for (final row in state.db.select(
      "SELECT value FROM v2_sync_state WHERE namespace=? AND key LIKE 'trace:%' AND value LIKE '%\"AI-%'",
      [ns],
    )) {
      try {
        final id = (jsonDecode(row['value'] as String) as Map)['ruleId'];
        if (id is String && id.startsWith('AI-')) readByAi++;
      } catch (_) {
        continue;
      }
    }
    String? problem, problemAt;
    try {
      final raw = state.get('pull:error');
      if (raw != null) {
        final record = jsonDecode(raw) as Map;
        problem = '${record['type']}: ${record['message']}';
        problemAt = record['at'] as String?;
      }
    } catch (_) {
      // An unreadable record is as good as none.
    }
    return AiPhoneDiagnostics(
      answersReady: ready,
      answersFailed: failed,
      linksSaved: linked.length,
      readyWithLink: readyWithLink,
      unknownMessages: unknown,
      unknownWithText: unknownWithText,
      readByAiRule: readByAi,
      lastErasedAt: state.get('wipe:ai:at'),
      restoresTried: int.tryParse(state.get('restore:ai:count') ?? '') ?? 0,
      lastPullProblem: problem,
      lastPullProblemAt: problemAt,
    );
  }

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
        if (status == 'ready') {
          // A draft this phone refused is as good as none.
          final draftId = DraftVerdictStore.draftIdOf(jsonDecode(raw!) as Map);
          return DraftVerdictStore(state).isRejected(remote, draftId)
              ? AiTemplateState.unavailable
              : AiTemplateState.ready;
        }
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
    final id = raw == null ? null : _aiRuleId(raw);
    if (id == null) return null;
    final shared = id.replaceFirst(_localSuffix, '');
    return AiResolution(
      ruleId: shared,
      verified: sharedRuleIds.contains(shared) || !_localSuffix.hasMatch(id),
    );
  }

  /// Of [sourceKeys], the messages an AI rule read: the same test as
  /// [resolution], answered in a few statements instead of one per message.
  /// For counts that must not walk the review list.
  Set<String> aiReadSources(Iterable<String> sourceKeys) {
    final keys = sourceKeys.toSet().toList();
    final read = <String>{};
    for (var start = 0; start < keys.length; start += 400) {
      final chunk = keys.sublist(start, (start + 400).clamp(0, keys.length));
      for (final row in state.db.select(
        'SELECT key,value FROM v2_sync_state WHERE namespace=? AND key IN (${List.filled(chunk.length, '?').join(',')})',
        [state.namespace, for (final key in chunk) 'trace:$key'],
      )) {
        if (_aiRuleId(row['value'] as String) != null) {
          read.add((row['key'] as String).substring('trace:'.length));
        }
      }
    }
    return read;
  }

  /// The rule id in a `trace:` entry when it is an AI rule, else null.
  static String? _aiRuleId(String raw) {
    try {
      final id = (jsonDecode(raw) as Map)['ruleId'];
      return id is String && id.startsWith('AI-') ? id : null;
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
