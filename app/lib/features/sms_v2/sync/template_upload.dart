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
      queue.db.execute('SAVEPOINT sms_v2_template_revoke');
      try {
        queue.db.execute(
          "DELETE FROM v2_sync_state WHERE namespace=? AND (key LIKE 'ai:%' OR key LIKE 'template:sent:%' OR key LIKE 'template:origins:%')",
          [queue.namespace],
        );
        queue.db.execute(
          "DELETE FROM v2_outbox WHERE namespace=? AND kind='template'",
          [queue.namespace],
        );
        queue.db.execute('RELEASE sms_v2_template_revoke');
      } catch (_) {
        queue.db.execute('ROLLBACK TO sms_v2_template_revoke');
        queue.db.execute('RELEASE sms_v2_template_revoke');
        rethrow;
      }
    }
    return consent;
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

  Future<void> drain() async {
    if (!await _canShare()) return;
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
    for (final row in queue.db.select(
      "SELECT payload FROM v2_review_items WHERE namespace=? AND kind='template' AND status='open'",
      [queue.namespace],
    )) {
      final review = jsonDecode(row['payload'] as String) as Map;
      final key = review['sourceKey'];
      if (key is! String) continue;
      // Waiting for history, or already read by it: no rule can be drafted.
      if (review['aiHold'] != null) continue;
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
      if (state.get('template:sent:$hash') != null ||
          queue.db.select(
            'SELECT 1 FROM v2_outbox WHERE namespace=? AND id=?',
            [queue.namespace, 'template:$hash'],
          ).isNotEmpty) {
        continue;
      }
      queue.enqueue('template', hash, payload);
    }
    while (accountIsCurrent()) {
      if (!await _canShare()) return;
      final records = queue
          .due(clock(), limit: 2500)
          .where((item) => item.kind == 'template')
          .take(_batchSize)
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
          // Over the daily allowance or the rate limit: come back when the
          // server says, not every few minutes.
          final wait = Duration(
            seconds:
                (int.tryParse(response.headers['retry-after'] ?? '') ?? 3600)
                    .clamp(300, 21600),
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
      } catch (_) {
        for (final record in records) {
          queue.retry(record, clock());
        }
        return;
      }
    }
  }
}
