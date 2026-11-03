import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../storage/outbox_store.dart';

class UploadBatch {
  const UploadBatch(this.records, this.body, this.gzipBytes, this.backfill);
  final List<OutboxRecord> records;
  final Map<String, Object?> body;
  final List<int> gzipBytes;
  final bool backfill;
}

/// Bounded upload and acknowledgement. Source groups precede dependent
/// events so the server can resolve anchors in this or an earlier request.
class FactsUpload {
  FactsUpload({
    required this.queue,
    required this.client,
    required this.baseUri,
    required this.deviceId,
    required this.appVersion,
    required this.headers,
    DateTime Function()? clock,
    this.accountIsCurrent = _alwaysCurrent,
  }) : clock = clock ?? DateTime.now;

  static bool _alwaysCurrent() => true;
  final bool Function() accountIsCurrent;
  final OutboxStore queue;
  final http.Client client;
  final Uri baseUri;
  final String deviceId;
  final String appVersion;
  final Future<Map<String, String>> Function() headers;
  final DateTime Function() clock;
  Future<int>? _running;

  UploadBatch? nextBatch() {
    final pending = queue.due(clock(), limit: 2500);
    final position = {
      for (final (index, row) in pending.indexed) row.id: index,
    };
    pending.sort((a, b) {
      final rank = _order(a.kind).compareTo(_order(b.kind));
      return rank == 0 ? position[a.id]!.compareTo(position[b.id]!) : rank;
    });
    final history = pending.firstOrNull?.backfill ?? false;
    final counts = <String, int>{};
    final candidates = <OutboxRecord>[];
    for (final record in pending) {
      if (record.backfill != history) continue;
      if (!const {
        'source',
        'instrument',
        'event',
        'ledger',
      }.contains(record.kind))
        continue;
      final count = counts[record.kind] ?? 0;
      if (count >= 500) continue;
      candidates.add(record);
      counts[record.kind] = count + 1;
    }
    var length = candidates.length;
    while (length > 0) {
      final records = candidates.take(length).toList();
      final body = _body(records);
      final encoded = utf8.encode(jsonEncode(body));
      if (encoded.length <= 8 * 1024 * 1024) {
        final compressed = gzip.encode(encoded);
        if (compressed.length <= 1024 * 1024) {
          return UploadBatch(records, body, compressed, history);
        }
      }
      length ~/= 2;
    }
    return null;
  }

  static int _order(String kind) => switch (kind) {
    'instrument' => 0,
    'source' => 1,
    'event' => 2,
    'ledger' => 3,
    _ => 4,
  };

  Map<String, Object?> _body(List<OutboxRecord> records) => {
    'contractVersion': '2.0',
    'appVersion': appVersion,
    'deviceId': deviceId,
    'items': [
      for (final record in records)
        if (record.kind == 'source') record.json,
    ],
    'instruments': [
      for (final record in records)
        if (record.kind == 'instrument') record.json,
    ],
    'events': [
      for (final record in records)
        if (record.kind == 'event') record.json,
    ],
    'ledger': [
      for (final record in records)
        if (record.kind == 'ledger') record.json,
    ],
  };

  /// Coalesces start/resume/import triggers. The caller schedules subsequent
  /// foreground ticks. A failing request leaves every sent item durable.
  Future<int> drain({bool backfill = false}) {
    final running = _running;
    if (running != null) return running;
    late final Future<int> operation;
    operation = _drain(backfill: backfill).whenComplete(() {
      if (identical(_running, operation)) _running = null;
    });
    _running = operation;
    return operation;
  }

  void _markClean(OutboxRecord record) {
    if (record.kind == 'source') {
      for (final fact in record.json['facts'] as List) {
        queue.db.execute(
          'UPDATE v2_facts SET uploaded_at=? WHERE namespace=? AND fact_id=?',
          [clock().toUtc().toIso8601String(), queue.namespace, fact['factId']],
        );
      }
      return;
    }
    final table = switch (record.kind) {
      'instrument' => ('v2_instruments', 'instrument_id'),
      'event' => ('v2_events', 'event_id'),
      'ledger' => ('v2_ledger', 'entry_id'),
      _ => throw StateError('Unexpected facts queue kind'),
    };
    queue.db.execute(
      'UPDATE ${table.$1} SET dirty=0 WHERE namespace=? AND ${table.$2}=?',
      [queue.namespace, record.id.substring(record.kind.length + 1)],
    );
  }

  Future<int> _drain({required bool backfill}) async {
    var acknowledged = 0;
    while (accountIsCurrent()) {
      final batch = nextBatch();
      if (batch == null) return acknowledged;
      try {
        final response = await client
            .post(
              baseUri
                  .resolve('/sms/v2/facts:batch')
                  .replace(
                    queryParameters: backfill || batch.backfill
                        ? {'backfill': 'true'}
                        : null,
                  ),
              headers: {
                ...await headers(),
                'Content-Type': 'application/json',
                'Content-Encoding': 'gzip',
                'X-Sms-Device-Id': deviceId,
              },
              body: batch.gzipBytes,
            )
            .timeout(const Duration(seconds: 30));
        if (!accountIsCurrent()) return acknowledged;
        if (response.statusCode != 200) {
          throw const FormatException('Upload failed');
        }
        final json = jsonDecode(response.body) as Map;
        final accepted = <String>{
          for (final result in json['results'] as List)
            if (result['status'] == 'accepted' ||
                result['status'] == 'duplicate')
              '${result['kind']}:${result['id']}',
        };
        var progressed = false;
        queue.db.execute('SAVEPOINT sms_v2_upload_ack');
        try {
          for (final record in batch.records) {
            final ids = record.kind == 'source'
                ? [
                    for (final fact in record.json['facts'] as List)
                      'fact:${fact['factId']}',
                  ]
                : [record.id];
            if (ids.every(accepted.contains)) {
              if (queue.acknowledge(record)) {
                _markClean(record);
                acknowledged++;
              }
              progressed = true;
            } else {
              queue.retry(record, clock());
            }
          }
          queue.db.execute('RELEASE SAVEPOINT sms_v2_upload_ack');
        } catch (_) {
          queue.db.execute('ROLLBACK TO SAVEPOINT sms_v2_upload_ack');
          queue.db.execute('RELEASE SAVEPOINT sms_v2_upload_ack');
          rethrow;
        }
        if (!progressed) return acknowledged;
      } catch (_) {
        for (final record in batch.records) {
          queue.retry(record, clock());
        }
        return acknowledged;
      }
    }
    return acknowledged;
  }
}
