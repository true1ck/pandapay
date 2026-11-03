import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2_template.dart';

import '../../../data/local/sms_intake_repository.dart';
import '../storage/outbox_store.dart';
import '../storage/sync_state_store.dart';
import '../storage/template_origin_store.dart';

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
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final SmsIntakeRepository intake;
  final OutboxStore queue;
  final http.Client client;
  final Uri baseUri;
  final Future<Map<String, String>> Function() headers;
  final Future<bool> Function() hasConsent;
  final bool Function() accountIsCurrent;
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
        item['templateHash'] == smsTemplateHash(brand, body);
  }

  static final _unsafe = RegExp(
    r'\d{6,}|https?://|www\.|[\w.+-]+@[\w.-]+|\b[a-z0-9-]+\.(?:com|in|co|io|ly|me|net|org)(?:\b|/)',
    caseSensitive: false,
  );

  Future<void> drain() async {
    if (!await _canShare()) return;
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
      final brand = smsTemplateBrand(message.sender);
      final hash = smsTemplateHash(brand, safe);
      final payload = <String, Object?>{
        'templateHash': hash,
        'senderBrand': brand,
        'redactedBody': safe,
        'observedAt': message.receivedAt.toUtc().toIso8601String(),
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
          .take(50)
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
                      ])
                        key: record.json[key],
                    },
                ],
              }),
            )
            .timeout(const Duration(seconds: 30));
        if (!await _canShare()) return;
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
