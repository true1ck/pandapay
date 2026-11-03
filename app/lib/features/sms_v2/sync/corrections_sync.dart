import 'dart:convert';

import 'package:http/http.dart' as http;

import '../storage/outbox_store.dart';

/// A correction is uploaded after fact/event sync, so the server can verify
/// account ownership of the referenced facts. Retries retain its stable ID.
class CorrectionsSync {
  CorrectionsSync({
    required this.queue,
    required this.client,
    required this.baseUri,
    required this.headers,
    required this.accountIsCurrent,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final OutboxStore queue;
  final http.Client client;
  final Uri baseUri;
  final Future<Map<String, String>> Function() headers;
  final bool Function() accountIsCurrent;
  final DateTime Function() clock;
  Future<int>? _running;

  Future<int> drain() =>
      _running ??= _drain().whenComplete(() => _running = null);

  Future<int> _drain() async {
    var sent = 0;
    while (accountIsCurrent()) {
      final pending = queue
          .due(clock(), limit: 500)
          .where((record) => record.kind == 'correction')
          .firstOrNull;
      if (pending == null) return sent;
      try {
        final requestHeaders = await headers();
        if (!accountIsCurrent()) return sent;
        final response = await client
            .post(
              baseUri.resolve('/sms/v2/corrections'),
              headers: {...requestHeaders, 'Content-Type': 'application/json'},
              body: jsonEncode(pending.json),
            )
            .timeout(const Duration(seconds: 30));
        if (!accountIsCurrent()) return sent;
        if (response.statusCode != 200) {
          queue.retry(pending, clock());
          return sent;
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! Map ||
            decoded.length != 1 ||
            decoded['caseId'] is! String ||
            (decoded['caseId'] as String).isEmpty) {
          throw const FormatException('Invalid correction response');
        }
        final caseId = decoded['caseId'] as String;
        queue.db.execute('SAVEPOINT sms_v2_correction_ack');
        try {
          if (queue.acknowledge(pending)) {
            queue.db.execute(
              'UPDATE v2_review_items SET payload=json_set(payload,\'\$.caseId\',?),status=\'open\' '
              'WHERE namespace=? AND review_id=?',
              [caseId, queue.namespace, pending.id],
            );
            sent++;
          }
          queue.db.execute('RELEASE sms_v2_correction_ack');
        } catch (_) {
          queue.db.execute('ROLLBACK TO sms_v2_correction_ack');
          queue.db.execute('RELEASE sms_v2_correction_ack');
          rethrow;
        }
      } catch (_) {
        queue.retry(pending, clock());
        return sent;
      }
    }
    return sent;
  }

  /// Apply the owner-scoped status rows delivered by the normal sync response.
  /// This participates in the puller's existing transaction.
  void applyStatuses(List<Map<String, Object?>> statuses) {
    for (final status in statuses) {
      final caseId = status['caseId'];
      if (caseId is! String ||
          !['open', 'decided'].contains(status['status'])) {
        throw const FormatException('Invalid correction status');
      }
      queue.db.execute(
        "UPDATE v2_review_items SET status=?,payload=json_set(payload,'\$.serverStatus',json(?)) "
        "WHERE namespace=? AND kind='correction' AND json_extract(payload,'\$.caseId')=?",
        [status['status'], jsonEncode(status), queue.namespace, caseId],
      );
    }
  }
}
