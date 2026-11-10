import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:pandapay_domain/sms_v2.dart' show uploadSenderBrand;

import '../storage/outbox_store.dart';
import '../storage/sync_state_store.dart';

class UploadBatch {
  const UploadBatch(this.records, this.body, this.gzipBytes, this.backfill);
  final List<OutboxRecord> records;
  final Map<String, Object?> body;
  final List<int> gzipBytes;
  final bool backfill;
  bool get categoryOnly => records.firstOrNull?.categoryOnly ?? false;
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

  /// The server answered "rejected" for a record this many times: it will say
  /// the same every time, so the phone stops sending it.
  static const _settleAfterAttempts = 2;

  /// How many records the server refused for good since this phone was set up.
  static const refusedKey = 'upload:refused-total';

  UploadBatch? nextBatch({bool ignoreBackoff = false}) {
    final pending = queue.due(
      ignoreBackoff ? clock().add(const Duration(days: 3650)) : clock(),
      limit: 2500,
    );
    final position = {
      for (final (index, row) in pending.indexed) row.id: index,
    };
    pending.sort((a, b) {
      final rank = _order(a.kind).compareTo(_order(b.kind));
      return rank == 0 ? position[a.id]!.compareTo(position[b.id]!) : rank;
    });
    final history = pending.firstOrNull?.backfill ?? false;
    final categoryOnly = pending.firstOrNull?.categoryOnly ?? false;
    final counts = <String, int>{};
    final candidates = <OutboxRecord>[];
    for (final record in pending) {
      if (record.backfill != history || record.categoryOnly != categoryOnly) {
        continue;
      }
      if (!const {
        'source',
        'instrument',
        'event',
        'ledger',
      }.contains(record.kind)) {
        continue;
      }
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
        if (record.kind == 'source') _sendable(record),
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
  ///
  /// [settleRefused] (the "Refresh rules" button) sends every waiting record
  /// now, ignoring the wait between tries, and sets aside at once any record
  /// the server refuses, so nothing stays stuck behind it.
  Future<int> drain({bool backfill = false, bool settleRefused = false}) {
    final running = _running;
    if (running != null) return running;
    late final Future<int> operation;
    operation = _drain(backfill: backfill, settleRefused: settleRefused)
        .whenComplete(() {
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

  /// Requests one drain may spend finding the record inside a failing batch.
  static const _isolationBudget = 60;

  /// Why records were set aside, counted by reason (`event_leg_role_conflict`,
  /// `http_500`), for the refresh sheet.
  static const refusedReasonsKey = 'upload:refused-reasons';

  /// Whether the server answers an empty batch with 200. A record that fails
  /// alone is only set aside when it does: if the server is failing for
  /// everything (an outage, a bad deploy), the record is not the problem.
  Future<bool> _serverAnswers() async {
    try {
      final body = _body(const []);
      final response = await client
          .post(
            baseUri.resolve('/sms/v2/facts:batch'),
            headers: {
              ...await headers(),
              'Content-Type': 'application/json',
              'Content-Encoding': 'gzip',
              'X-Sms-Device-Id': deviceId,
            },
            body: gzip.encode(utf8.encode(jsonEncode(body))),
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Source records leave the phone with the brand the server stores. A record
  /// queued by an older build may still carry a header the server refuses.
  Map<String, Object?> _sendable(OutboxRecord record) {
    final json = record.json;
    final brand = json['senderBrand'];
    if (record.kind != 'source' || brand is! String) return json;
    final clean = uploadSenderBrand(brand);
    return clean == brand ? json : {...json, 'senderBrand': clean};
  }

  UploadBatch _batchOf(List<OutboxRecord> records, UploadBatch like) {
    final body = _body(records);
    return UploadBatch(
      records,
      body,
      gzip.encode(utf8.encode(jsonEncode(body))),
      like.backfill,
    );
  }

  Future<int> _drain({
    required bool backfill,
    bool settleRefused = false,
  }) async {
    var acknowledged = 0;
    var isolationRequests = 0;
    while (accountIsCurrent()) {
      final batch = nextBatch(ignoreBackoff: settleRefused);
      if (batch == null) return acknowledged;
      final sent = await _send(
        batch,
        backfill: backfill,
        settleRefused: settleRefused,
      );
      acknowledged += sent.acknowledged;
      if (sent.outcome == _Outcome.progressed) continue;
      if (sent.outcome != _Outcome.refusedWhole) return acknowledged;
      // The server answered the whole batch with an error that does not say
      // which record is at fault (a record it cannot store, a request it finds
      // invalid). Retrying the same batch would block every record behind it,
      // forever. Split it until the record is alone.
      final found = await _isolate(
        batch,
        backfill: backfill,
        settleRefused: settleRefused,
        budget: _isolationBudget - isolationRequests,
        status: sent.status,
      );
      acknowledged += found.acknowledged;
      isolationRequests += found.requests;
      if (!found.progressed) return acknowledged;
    }
    return acknowledged;
  }

  /// Sends the halves of a failing batch until each failing record is alone.
  ///
  /// A record that fails alone while the rest are accepted is the problem: it
  /// is retried once on the usual wait, then set aside with the phone's copy
  /// kept. When nothing is accepted the server is failing for everything, and
  /// every record is simply retried later.
  Future<({int acknowledged, int requests, bool progressed})> _isolate(
    UploadBatch failed, {
    required bool backfill,
    required bool settleRefused,
    required int budget,
    required int? status,
  }) async {
    var acknowledged = 0, requests = 0;
    var progressed = false;
    final work = <List<OutboxRecord>>[failed.records];
    final suspects = <OutboxRecord>[];
    var stopped = false;
    while (work.isNotEmpty && accountIsCurrent()) {
      final part = work.removeAt(0);
      if (part.length == 1 && failed.records.length == 1) {
        suspects.add(part.single);
        continue;
      }
      if (requests >= budget) {
        work.insert(0, part);
        break;
      }
      final sent = await _send(
        _batchOf(part, failed),
        backfill: backfill,
        settleRefused: settleRefused,
        retryFailures: false,
      );
      requests++;
      acknowledged += sent.acknowledged;
      switch (sent.outcome) {
        case _Outcome.progressed:
          progressed = true;
        case _Outcome.noProgress:
          break;
        case _Outcome.refusedWhole:
          if (part.length == 1) {
            suspects.add(part.single);
          } else {
            final middle = part.length ~/ 2;
            work.insertAll(0, [part.sublist(0, middle), part.sublist(middle)]);
          }
        case _Outcome.stopped:
          // The network or the account changed: keep every record for later.
          work.insert(0, part);
          stopped = true;
      }
      if (stopped) break;
    }
    for (final part in work) {
      for (final record in part) {
        queue.retry(record, clock());
      }
    }
    final healthy = suspects.isEmpty
        ? false
        : progressed || await _serverAnswers();
    for (final record in suspects) {
      if (healthy &&
          (settleRefused || record.attempts + 1 >= _settleAfterAttempts)) {
        _setAside(record, reason: 'http_${status ?? 0}');
        progressed = true;
      } else {
        queue.retry(record, clock());
      }
    }
    return (
      acknowledged: acknowledged,
      requests: requests,
      progressed: progressed,
    );
  }

  /// Stops sending [record] and counts it, keeping the phone's own copy.
  void _setAside(OutboxRecord record, {required String reason}) {
    if (!queue.acknowledge(record)) return;
    if (record.kind != 'source') _markClean(record);
    final state = SyncStateStore(queue.db, namespace: queue.namespace);
    state.put(
      refusedKey,
      '${(int.tryParse(state.get(refusedKey) ?? '') ?? 0) + 1}',
    );
    Map<String, Object?> reasons;
    try {
      reasons = (jsonDecode(state.get(refusedReasonsKey) ?? '{}') as Map)
          .cast<String, Object?>();
    } catch (_) {
      reasons = {};
    }
    reasons[reason] = ((reasons[reason] as int?) ?? 0) + 1;
    state.put(refusedReasonsKey, jsonEncode(reasons));
  }

  /// Sends [batch] once. [retryFailures] false leaves a failed batch's records
  /// alone, for the caller that is about to split it.
  Future<_Sent> _send(
    UploadBatch batch, {
    required bool backfill,
    required bool settleRefused,
    bool retryFailures = true,
  }) async {
    void retryAll() {
      if (!retryFailures) return;
      for (final record in batch.records) {
        queue.retry(record, clock());
      }
    }

    try {
      final response = await client
          .post(
            baseUri
                .resolve(
                  batch.categoryOnly
                      ? '/sms/v2/categories:batch'
                      : '/sms/v2/facts:batch',
                )
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
      if (!accountIsCurrent()) return const _Sent(_Outcome.stopped);
      // 400 (a request the server finds invalid), 413 (too large) and 500 (the
      // server could not store something in it) mean "something in this batch".
      // Anything else (sign-in, rate limit, outage) is not about the records.
      if (const {400, 413, 422, 500}.contains(response.statusCode)) {
        return _Sent(_Outcome.refusedWhole, status: response.statusCode);
      }
      if (response.statusCode != 200) {
        retryAll();
        return const _Sent(_Outcome.stopped);
      }
      final json = jsonDecode(response.body) as Map;
      final accepted = <String>{
        for (final result in json['results'] as List)
          if (result['status'] == 'accepted' ||
              result['status'] == 'duplicate')
            '${result['kind']}:${result['id']}',
      };
      final refused = <String, String>{
        for (final result in json['results'] as List)
          if (result['status'] == 'rejected')
            '${result['kind']}:${result['id']}':
                '${((result['errors'] as List?)?.firstOrNull as Map?)?['code'] ?? 'rejected'}',
      };
      var acknowledged = 0;
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
          } else if (ids.any(refused.containsKey) &&
              (settleRefused || record.attempts >= _settleAfterAttempts)) {
            // Refused for good (for example the server already holds a
            // different version of this event): keep the phone's own copy,
            // stop sending, and count it so the person can be told.
            _setAside(
              record,
              reason: refused[ids.firstWhere(refused.containsKey)]!,
            );
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
      return _Sent(
        progressed ? _Outcome.progressed : _Outcome.noProgress,
        acknowledged: acknowledged,
      );
    } catch (_) {
      retryAll();
      return const _Sent(_Outcome.stopped);
    }
  }
}

enum _Outcome { progressed, noProgress, refusedWhole, stopped }

class _Sent {
  const _Sent(this.outcome, {this.acknowledged = 0, this.status});
  final _Outcome outcome;
  final int acknowledged;
  final int? status;
}
