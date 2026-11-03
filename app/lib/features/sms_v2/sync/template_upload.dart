import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';

import '../../../data/local/sms_intake_repository.dart';
import '../storage/outbox_store.dart';

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

  Future<void> drain() async {
    if (!accountIsCurrent() || !await hasConsent() || !accountIsCurrent()) {
      return;
    }
    for (final row in queue.db.select(
      "SELECT payload FROM v2_review_items WHERE namespace=? AND kind='template' AND status='open'",
      [queue.namespace],
    )) {
      final review = jsonDecode(row['payload'] as String) as Map;
      final key = review['sourceKey'];
      if (key is! String) continue;
      final hash = review['templateHash'] as String;
      if (queue.db.select(
        'SELECT 1 FROM v2_outbox WHERE namespace=? AND id=?',
        [queue.namespace, 'template:$hash'],
      ).isNotEmpty) {
        continue;
      }
      final message = intake.capturedById(queue.namespace, key)?.message;
      if (message == null) continue;
      if (queue.db.select(
        'SELECT 1 FROM v2_sync_state WHERE namespace=? AND key=?',
        [queue.namespace, 'template:sent:$hash'],
      ).isNotEmpty) {
        continue;
      }
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
      if (RegExp(
        r'\d{6,}|https?://|www\.|[\w.+-]+@[\w.-]+',
        caseSensitive: false,
      ).hasMatch(safe)) {
        continue;
      }
      queue.enqueue('template', hash, {
        'templateHash': hash,
        'senderBrand': normalizeSenderBrand(message.sender).brand,
        'redactedBody': safe,
        'observedAt': message.receivedAt.toUtc().toIso8601String(),
      });
    }
    while (accountIsCurrent()) {
      if (!await hasConsent() || !accountIsCurrent()) return;
      final records = queue
          .due(clock(), limit: 2500)
          .where((item) => item.kind == 'template')
          .take(50)
          .toList();
      if (records.isEmpty) return;
      try {
        final response = await client
            .post(
              baseUri.resolve('/sms/v2/unknown-templates'),
              headers: {...await headers(), 'Content-Type': 'application/json'},
              body: jsonEncode({
                'items': records.map((record) => record.json).toList(),
              }),
            )
            .timeout(const Duration(seconds: 30));
        if (!accountIsCurrent()) return;
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
