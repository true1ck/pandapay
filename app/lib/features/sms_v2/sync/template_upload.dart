import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2_template.dart';

import '../../../data/local/sms_intake_repository.dart';
import '../storage/outbox_store.dart';
import '../storage/sync_state_store.dart';
import '../storage/template_origin_store.dart';

/// Whether the wording of a message (the message as it is, only its numbers made up) goes next to the layout, for the
/// AI to read. The owner chose this on 15 Nov 2026. NOTE: the consent text and privacy policy still say that only
/// layouts are shared (section 12 of docs/SMS_AI_PIPELINE_REDESIGN_PLAN_2026-11-15.md).
const bool smsShareWording = true;

/// Unknown templates enter this queue only with current sharing consent.
class TemplateUpload {
  TemplateUpload({
    required this.intake,
    required this.queue,
    required this.client,
    required this.baseUri,
    required this.headers,
    required this.hasConsent,
    required this.accountIsCurrent,
    this.shareWording = smsShareWording,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final SmsIntakeRepository intake;
  final OutboxStore queue;
  final http.Client client;
  final Uri baseUri;
  final Future<Map<String, String>> Function() headers;
  final Future<bool> Function() hasConsent;
  final bool Function() accountIsCurrent;
  final bool shareWording;
  final DateTime Function() clock;

  /// When consent was last confirmed during this drain. A pass checks it before
  /// every batch and again after the answer; each check is a call to the server
  /// (a slow, busy one on a bad day), so 36 calls went out for 16 batches.
  /// Within ten seconds of a confirmation the answer stands; a "no" is never
  /// remembered, and a new drain always asks again.
  Stopwatch? _consentConfirmed;

  Future<bool> _canShare() async {
    if (!accountIsCurrent()) return false;
    final confirmed = _consentConfirmed;
    if (confirmed != null && confirmed.elapsed < const Duration(seconds: 10)) {
      return true;
    }
    final bool consent;
    try {
      consent = await hasConsent();
    } catch (_) {
      return false;
    }
    if (!accountIsCurrent()) return false;
    if (!consent) {
      _consentConfirmed = null;
      forgetSharedState(queue);
    } else {
      _consentConfirmed = Stopwatch()..start();
    }
    return consent;
  }

  /// Consent is gone: drop everything that came from sharing, including the
  /// drafts, this phone's verdicts on them and any report still waiting.
  static void forgetSharedState(OutboxStore queue) {
    queue.db.execute('SAVEPOINT sms_v2_template_revoke');
    try {
      queue.db.execute(
        "DELETE FROM v2_sync_state WHERE namespace=? AND (key LIKE 'ai:%' OR key LIKE 'template:sent:%' OR key LIKE 'template:origins:%' OR key LIKE 'template:scanned:%' OR key LIKE 'draft:%')",
        [queue.namespace],
      );
      queue.db.execute(
        "DELETE FROM v2_outbox WHERE namespace=? AND kind IN ('template','draft_rejection')",
        [queue.namespace],
      );
      queue.db.execute('RELEASE sms_v2_template_revoke');
    } catch (_) {
      queue.db.execute('ROLLBACK TO sms_v2_template_revoke');
      queue.db.execute('RELEASE sms_v2_template_revoke');
      rethrow;
    }
  }

  bool _validUpload(Map<String, Object?> item) {
    final brand = item['senderBrand'], body = item['redactedBody'];
    return brand is String &&
        RegExp(r'^[A-Z0-9]{1,32}$').hasMatch(brand) &&
        body is String &&
        body.isNotEmpty &&
        body.length <= 20000 &&
        !_unsafe.hasMatch(body) &&
        // The sample is optional; when there is one it is short and holds no link or address.
        (item['sample'] == null ||
            (item['sample'] is String &&
                (item['sample'] as String).length <= 2000 &&
                !RegExp(r'@|https?://|www\.', caseSensitive: false).hasMatch(item['sample'] as String))) &&
        item['templateHash'] == smsTemplateHash(brand, body);
  }

  static final _unsafe = RegExp(
    r'\d{6,}|https?://|www\.|[\w.+-]+@[\w.-]+|\b[a-z0-9-]+\.(?:com|in|co|io|ly|me|net|org)(?:\b|/)',
    caseSensitive: false,
  );

  /// Layouts per request. The server allows 50 a day per person and refuses a
  /// whole request that would pass it, so a big batch can fail for ever once a
  /// few have been sent; small ones always fit what is left.
  static const _batchSize = 10;

  /// Flat wait after a failure that is the session's or the server's, not the layout's.
  static const _transientRetry = Duration(seconds: 60);

  /// How long to wait after a 5xx: the server's Retry-After when it sent one
  /// (a paused intake says an hour), never under a minute, never over an hour.
  static Duration _serverWait(http.Response response) => Duration(
    seconds: (int.tryParse(response.headers['retry-after'] ?? '') ?? 60).clamp(
      60,
      3600,
    ),
  );

  /// Earlier builds held the whole queue for up to six hours after a 429 and
  /// pushed a failed layout's next try out to 30 minutes by doubling. A phone
  /// that updates would keep honouring those waits, so layouts that were
  /// already waiting would still sit unsent. Once per account, after the
  /// update, make them due now and forget the old hold.
  void _clearWaitsLeftByOlderBuilds() {
    final state = SyncStateStore(queue.db, namespace: queue.namespace);
    const marker = 'template:waits:cleared:v2';
    if (state.get(marker) != null) return;
    queue.db.execute(
      "UPDATE v2_outbox SET next_attempt_at=0 WHERE namespace=? AND kind='template'",
      [queue.namespace],
    );
    queue.db.execute(
      "DELETE FROM v2_sync_state WHERE namespace=? AND key='template:wait'",
      [queue.namespace],
    );
    state.put(marker, clock().toUtc().toIso8601String());
  }

  Future<void> drain() async {
    _consentConfirmed = null; // every pass asks the server afresh
    // One layout the server refuses (400) must not hold up the ones behind it:
    // after a 400 the next requests carry one layout each until it is found.
    var singly = false;
    var refused = 0;
    if (!await _canShare()) return;
    _clearWaitsLeftByOlderBuilds();
    // The server told us to wait (HTTP 429): hold the whole queue until then.
    final holdUntil = DateTime.tryParse(
      SyncStateStore(
            queue.db,
            namespace: queue.namespace,
          ).get('template:wait') ??
          '',
    );
    if (holdUntil != null && clock().isBefore(holdUntil)) return;
    // Previous builds queued the original hash with a different redacted body.
    // Rebuild those entries from the retained local capture before retrying.
    for (final row in queue.db.select(
      "SELECT id,payload FROM v2_outbox WHERE namespace=? AND kind='template'",
      [queue.namespace],
    )) {
      var valid = false;
      try {
        valid = _validUpload(
          (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
        );
      } catch (_) {
        // A malformed old queue entry cannot be uploaded.
      }
      if (!valid) {
        queue.db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
          queue.namespace,
          row['id'],
        ]);
      }
    }
    final state = SyncStateStore(queue.db, namespace: queue.namespace);
    final origins = TemplateOriginStore(state);
    var processed = 0;
    for (final row in queue.db.select(
      "SELECT payload FROM v2_review_items WHERE namespace=? AND kind='template' AND status='open'",
      [queue.namespace],
    )) {
      final review = jsonDecode(row['payload'] as String) as Map;
      final key = review['sourceKey'];
      if (key is! String) continue;
      // Waiting for history, or already read by it: no rule can be drafted.
      if (review['aiHold'] != null) continue;
      // Already queued or sent on an earlier pass: skip the redaction, which is
      // the costly part (about a second for 1,500 open items, on the UI thread,
      // at every pass). The marker holds the layout's hash; if its sent mark and
      // its queue entry are both gone (a re-send, a cleaned-up entry), the item
      // is processed afresh.
      final scanned = state.get('template:scanned:$key');
      if (scanned != null &&
          (state.get('template:sent:$scanned') != null ||
              queue.db.select(
                'SELECT 1 FROM v2_outbox WHERE namespace=? AND id=?',
                [queue.namespace, 'template:$scanned'],
              ).isNotEmpty)) {
        continue;
      }
      final message = intake.capturedById(queue.namespace, key)?.message;
      if (message == null) continue;
      final salt = base64UrlEncode(
        List.generate(32, (_) => Random.secure().nextInt(256)),
      );
      final redacted = redactSms(
        sender: message.sender,
        body: message.body,
        observedAt: message.receivedAt,
        options: SmsRedactionOptions(salt: salt),
      );
      final safe = smsSkeleton(redacted.body);
      // The message as it is with only its numbers made up, for the AI; null (the layout alone goes) when an original
      // number could survive. The same salt gives the same made-up numbers as the layout was made with.
      final sample = shareWording
          ? smsSample(
              original: message.body,
              redacted: redactSms(
                sender: message.sender,
                body: message.body,
                observedAt: message.receivedAt,
                options: SmsRedactionOptions(salt: salt, keepNames: true),
              ).body,
            )
          : null;
      final brand = smsTemplateBrand(message.sender);
      final hash = smsTemplateHash(brand, safe);
      final payload = <String, Object?>{
        'templateHash': hash,
        'senderBrand': brand,
        'redactedBody': safe,
        'observedAt': message.receivedAt.toUtc().toIso8601String(),
        'sample': ?sample,
      };
      if (!_validUpload(payload) ||
          !origins.remember(
            remoteHash: hash,
            localHash: smsTemplateHash(brand, smsSkeleton(message.body)),
            senderBrand: brand,
          )) {
        continue;
      }
      if (state.get('template:sent:$hash') == null &&
          queue.db.select(
            'SELECT 1 FROM v2_outbox WHERE namespace=? AND id=?',
            [queue.namespace, 'template:$hash'],
          ).isEmpty) {
        queue.enqueue('template', hash, payload);
      }
      state.put('template:scanned:$key', hash);
      // Hand the thread back every few items so a long backlog never freezes the screen.
      if (++processed % 20 == 0) await Future<void>.delayed(Duration.zero); // perf-ok: a chunk is 20 items (~15 ms) and the first big scan only; later passes skip them
    }
    while (accountIsCurrent()) {
      if (!await _canShare()) return;
      final records = queue
          .due(clock(), limit: 2500)
          .where((item) => item.kind == 'template')
          .take(singly ? 1 : _batchSize)
          .toList();
      if (records.isEmpty) return;
      try {
        final admission = await headers();
        if (!await _canShare()) return;
        final response = await client
            .post(
              baseUri.resolve('/sms/v2/unknown-templates'),
              headers: {...admission, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'items': [
                  for (final record in records)
                    {
                      for (final key in [
                        'templateHash',
                        'senderBrand',
                        'redactedBody',
                        'observedAt',
                        'sample',
                      ])
                        key: ?record.json[key],
                    },
                ],
              }),
            )
            .timeout(const Duration(seconds: 30));
        if (!await _canShare()) return;
        if (response.statusCode == 429) {
          // A limit the server applies (counted phones have none unless the
          // owner sets one): try again within a couple of minutes, whatever
          // Retry-After says. It can be a whole day, and waiting that long left
          // a backlog of formats unsent for hours.
          final wait = Duration(
            seconds:
                (int.tryParse(response.headers['retry-after'] ?? '') ?? 60)
                    .clamp(30, 120),
          );
          for (final record in records) {
            queue.retry(record, clock(), after: wait);
          }
          SyncStateStore(
            queue.db,
            namespace: queue.namespace,
          ).put('template:wait', clock().add(wait).toUtc().toIso8601String());
          return;
        }
        if (response.statusCode == 400) {
          // The server refused the request as invalid. With several layouts in
          // it, send them one at a time to find the one it dislikes; a single
          // refused layout is set aside for six hours (not lost, and it blocks
          // nothing), then the rest carry on in tens again.
          // A server that refuses everything is not one bad layout: after six
          // refusals in a pass, stop and leave the rest for the next pass.
          if (++refused >= 6) return;
          if (records.length > 1) {
            singly = true;
            continue;
          }
          queue.retry(records.single, clock(), after: const Duration(hours: 6));
          singly = false;
          continue;
        }
        if (response.statusCode == 401 ||
            response.statusCode == 408 ||
            response.statusCode >= 500) {
          // The session or the server is the problem, not the layout: try again
          // soon at a flat pace (or when the server said). The usual doubling
          // back-off pushed the next try out to 30 minutes.
          final wait = response.statusCode >= 500
              ? _serverWait(response)
              : _transientRetry;
          for (final record in records) {
            queue.retry(record, clock(), after: wait);
          }
          return;
        }
        if (response.statusCode != 200 && response.statusCode != 202) {
          throw const FormatException('Template upload failed');
        }
        final accepted =
            ((jsonDecode(response.body) as Map)['accepted'] as List).toSet();
        for (final record in records) {
          if (accepted.contains(record.json['templateHash'])) {
            if (queue.acknowledge(record)) {
              queue.db.execute(
                'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value',
                [
                  queue.namespace,
                  'template:sent:${record.json['templateHash']}',
                  clock().toUtc().toIso8601String(),
                ],
              );
            }
          } else {
            queue.retry(record, clock());
          }
        }
        if (accepted.isEmpty) return;
      } catch (error) {
        // A timeout or a dropped connection says nothing about the layout either.
        final transient = error is TimeoutException || error is http.ClientException;
        for (final record in records) {
          queue.retry(record, clock(), after: transient ? _transientRetry : null);
        }
        return;
      }
    }
  }
}
