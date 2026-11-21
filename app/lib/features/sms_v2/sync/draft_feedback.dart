import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';

import '../../../data/local/sms_intake_repository.dart';
import '../storage/draft_verdict_store.dart';
import '../storage/outbox_store.dart';
import '../storage/sync_state_store.dart';
import '../storage/template_origin_store.dart';
import 'draft_check.dart';
import 'template_upload.dart';

/// Checks AI drafts on this phone against the SMS they were drafted for, and
/// queues a report for each one that fails.
///
/// A draft is checked once per draft id (see [DraftVerdictStore]). With no
/// original message left on the phone it is not checked at all: it stays as it
/// is and nothing is reported. A failed draft is never adopted (the
/// ProvisionalStore skips it) and its message stays in manual review.
class DraftVerifier {
  DraftVerifier({
    required this.intake,
    required this.queue,
    required this.accountIsCurrent,
    this.check = checkDraftOffThread,
  });

  final SmsIntakeRepository intake;
  final OutboxStore queue;
  final bool Function() accountIsCurrent;
  final Future<DraftCheck> Function({
    required Map<String, Object?> sharedJson,
    required Map<String, Object?> result,
    required String senderBrand,
    required List<DraftMessage> messages,
  })
  check;

  /// Drafts checked per pass, and original messages compared per draft. A
  /// layout can have many messages; the newest few are the ones that raised it.
  static const maxDraftsPerRun = 3;
  static const maxMessagesPerDraft = 3;

  /// Newest open review items looked at to find originals. History is never
  /// scanned.
  static const _reviewWindow = 50;

  /// Returns how many drafts got a verdict.
  Future<int> verifyPending(RuleBundle shared) async {
    final state = SyncStateStore(queue.db, namespace: queue.namespace);
    final verdicts = DraftVerdictStore(state);
    final origins = TemplateOriginStore(state);
    final pending = <({String hash, String draftId, Map<String, Object?> result})>[];
    for (final row in queue.db.select(
      "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%' AND CASE WHEN json_valid(value) THEN json_extract(value,'\$.status') END='ready'",
      [queue.namespace],
    )) {
      try {
        final result = (jsonDecode(row['value'] as String) as Map)
            .cast<String, Object?>();
        final hash = result['templateHash'];
        final draftId = DraftVerdictStore.draftIdOf(result);
        if (hash is! String ||
            row['key'] != 'ai:$hash' ||
            result['rule'] is! Map ||
            draftId == null ||
            verdicts.get(hash)?.draftId == draftId ||
            origins.get(hash) == null) {
          continue;
        }
        pending.add((hash: hash, draftId: draftId, result: result));
      } catch (_) {
        continue;
      }
    }
    if (pending.isEmpty) return 0;

    // Newest first: this phone's own messages of unread layouts, by layout.
    final byLocalHash = <String, List<DraftMessage>>{};
    for (final row in queue.db.select(
      "SELECT payload FROM v2_review_items WHERE namespace=? AND kind='template' AND status='open' ORDER BY rowid DESC LIMIT $_reviewWindow",
      [queue.namespace],
    )) {
      try {
        final key = (jsonDecode(row['payload'] as String) as Map)['sourceKey'];
        if (key is! String) continue;
        final message = intake.capturedById(queue.namespace, key)?.message;
        if (message == null) continue;
        final localHash = smsTemplateHash(
          smsTemplateBrand(message.sender),
          smsSkeleton(message.body),
        );
        byLocalHash.putIfAbsent(localHash, () => []).add((
          sender: message.sender,
          body: message.body,
          receivedAt: message.receivedAt,
        ));
      } catch (_) {
        continue;
      }
    }

    Map<String, Object?>? sharedJson;
    var decided = 0;
    for (final draft in pending) {
      if (decided >= maxDraftsPerRun) break;
      final origin = origins.get(draft.hash)!;
      final messages = <DraftMessage>[
        for (final hash in origin.localHashes) ...?byLocalHash[hash],
      ].take(maxMessagesPerDraft).toList();
      if (messages.isEmpty) continue;
      sharedJson ??= shared.toJson();
      final verdict = await check(
        sharedJson: sharedJson,
        result: draft.result,
        senderBrand: origin.senderBrand,
        messages: messages,
      );
      if (!accountIsCurrent()) return decided;
      // The result may have been replaced, or consent withdrawn, meanwhile.
      final now = state.get('ai:${draft.hash}');
      final stillThere =
          now != null &&
          DraftVerdictStore.draftIdOf((jsonDecode(now) as Map)) == draft.draftId;
      if (!stillThere) continue;
      queue.db.execute('SAVEPOINT sms_v2_draft_verdict');
      try {
        verdicts.put(
          draft.hash,
          draft.draftId,
          rejected: verdict != DraftCheck.pass,
        );
        if (verdict != DraftCheck.pass) {
          queue.enqueue('draft_rejection', draft.draftId, {
            'draftId': draft.draftId,
            'reason': verdict.wire,
          });
        }
        queue.db.execute('RELEASE sms_v2_draft_verdict');
      } catch (_) {
        queue.db.execute('ROLLBACK TO sms_v2_draft_verdict');
        queue.db.execute('RELEASE sms_v2_draft_verdict');
        rethrow;
      }
      decided++;
    }
    return decided;
  }
}

/// Sends the queued `draft_rejection` reports: `{draftId, reason}`, nothing
/// else. What the server's answer means here:
/// * 200 (recorded or already_recorded): done, the report leaves the queue.
/// * 404 `draft_not_delivered`: the server never gave this phone that draft;
///   retrying cannot change that, so the report is dropped.
/// * 400: the report itself is malformed; dropped.
/// * 403: consent or attestation is not accepted right now; the pass stops and
///   the report waits (backed off). It is deleted if consent is withdrawn.
/// * 429: held until Retry-After (5 minutes to 6 hours), like layout uploads.
/// * 5xx, any other status, a timeout or no connection: retried later with a
///   growing wait; the pass stops.
class DraftRejectionUpload {
  DraftRejectionUpload({
    required this.queue,
    required this.client,
    required this.baseUri,
    required this.headers,
    required this.hasConsent,
    this.consentWithdrawn,
    required this.accountIsCurrent,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final OutboxStore queue;
  final http.Client client;
  final Uri baseUri;
  final Future<Map<String, String>> Function() headers;
  final Future<bool> Function() hasConsent;

  /// See [TemplateUpload.consentWithdrawn].
  final Future<bool> Function()? consentWithdrawn;
  final bool Function() accountIsCurrent;
  final DateTime Function() clock;

  static const kind = 'draft_rejection';
  static const _waitKey = 'draft:wait';
  static const reasons = {'no_match', 'invalid_facts', 'unsafe_rule'};

  Future<bool> _canShare() async {
    if (!accountIsCurrent()) return false;
    final bool consent;
    try {
      consent = await hasConsent();
    } catch (_) {
      return false;
    }
    if (!accountIsCurrent()) return false;
    if (!consent) {
      final gone = consentWithdrawn == null || await consentWithdrawn!();
      if (!accountIsCurrent()) return false;
      if (gone) TemplateUpload.forgetSharedState(queue);
    }
    return consent;
  }

  Future<int> drain() async {
    if (!await _canShare()) return 0;
    final state = SyncStateStore(queue.db, namespace: queue.namespace);
    final holdUntil = DateTime.tryParse(state.get(_waitKey) ?? '');
    if (holdUntil != null && clock().isBefore(holdUntil)) return 0;
    var sent = 0;
    for (var handled = 0; handled < 20 && accountIsCurrent(); handled++) {
      final pending = queue
          .due(clock(), limit: 500, kind: kind)
          .firstOrNull;
      if (pending == null) return sent;
      final Map<String, Object?> payload;
      try {
        payload = pending.json;
      } catch (_) {
        queue.acknowledge(pending);
        continue;
      }
      final draftId = payload['draftId'], reason = payload['reason'];
      if (draftId is! String ||
          draftId.isEmpty ||
          !reasons.contains(reason)) {
        queue.acknowledge(pending);
        continue;
      }
      try {
        final admission = await headers();
        if (!await _canShare()) return sent;
        final response = await client
            .post(
              baseUri.resolve('/sms/v2/draft-rejections'),
              headers: {...admission, 'Content-Type': 'application/json'},
              body: jsonEncode({'draftId': draftId, 'reason': reason}),
            )
            .timeout(const Duration(seconds: 30));
        if (!await _canShare()) return sent;
        final status = response.statusCode;
        if (status == 200) {
          if (queue.acknowledge(pending)) sent++;
        } else if (status == 400 ||
            (status == 404 && _error(response) == 'draft_not_delivered')) {
          queue.acknowledge(pending);
        } else if (status == 429) {
          final wait = Duration(
            seconds: (int.tryParse(response.headers['retry-after'] ?? '') ?? 3600)
                .clamp(300, 21600),
          );
          queue.retry(pending, clock(), after: wait);
          state.put(_waitKey, clock().add(wait).toUtc().toIso8601String());
          return sent;
        } else {
          // 403 (consent / attestation), 5xx, anything else: later.
          queue.retry(pending, clock());
          return sent;
        }
      } catch (_) {
        queue.retry(pending, clock());
        return sent;
      }
    }
    return sent;
  }

  static String? _error(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {}
    return null;
  }
}
