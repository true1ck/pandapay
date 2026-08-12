import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Plan Phase 4 — the transport half of multi-device sync.
///
/// A local edit that has not yet reached the server. `fieldClocks` is what
/// makes the merge per-field rather than per-row: each entry is the wall-clock
/// millisecond at which THAT field was last changed on this device, so the
/// server can accept a newer note and reject an older category in the same
/// push without either device having to know about the other.
///
/// Clocks are device wall-clock time, and that is a real limitation worth
/// naming: a phone with a badly wrong clock will win or lose every conflict
/// against a correct one. A Lamport or hybrid logical clock would fix it and
/// is the right eventual answer; wall-clock is chosen here because the
/// alternative needs a per-entity counter synchronised across devices, which
/// is a much larger change, and because the practical damage is bounded — the
/// losing value is always recorded in the conflict log rather than lost.
class SyncChange {
  final String entity;
  final String entityId;
  final String op; // 'update' | 'delete'
  final Map<String, Object?> payload;
  final Map<String, int> fieldClocks;
  final int clientSeq;

  const SyncChange({
    required this.entity,
    required this.entityId,
    required this.op,
    required this.payload,
    required this.fieldClocks,
    required this.clientSeq,
  });

  Map<String, Object?> toJson() => {
    'entity': entity,
    'entityId': entityId,
    'op': op,
    'payload': payload,
    'fieldClocks': fieldClocks,
    'clientSeq': clientSeq,
  };
}

/// The server's verdict on one pushed change. Per-change rather than per-batch
/// so the client can drop exactly what landed and retain the rest — a batch
/// that reports only an overall success or failure forces an all-or-nothing
/// retry, which is how one permanently-rejected change blocks every later edit
/// from ever syncing.
class SyncPushResult {
  final int? clientSeq;
  final bool applied;
  final int conflicts;
  final String? reason;

  const SyncPushResult({
    required this.clientSeq,
    required this.applied,
    required this.conflicts,
    this.reason,
  });

  factory SyncPushResult.fromJson(Map<String, dynamic> json) => SyncPushResult(
    clientSeq: (json['clientSeq'] as num?)?.toInt(),
    applied: json['applied'] == true,
    conflicts: (json['conflicts'] as num?)?.toInt() ?? 0,
    reason: json['reason'] as String?,
  );

  /// Whether the server will ever accept this change. A `not_found` or
  /// `malformed` result is permanent — retrying it forever is what turns a
  /// single bad row into a queue that never drains.
  bool get isPermanentFailure =>
      !applied && (reason == 'not_found' || reason == 'malformed' || reason == 'unknown_entity' || reason == 'rejected');
}

class SyncPullBatch {
  final List<Map<String, dynamic>> changes;
  final List<SyncConflict> conflicts;
  final bool hasMore;
  final int latestServerSeq;

  const SyncPullBatch({
    required this.changes,
    required this.conflicts,
    required this.hasMore,
    required this.latestServerSeq,
  });

  factory SyncPullBatch.fromJson(Map<String, dynamic> json) => SyncPullBatch(
    changes: (json['changes'] as List).cast<Map<String, dynamic>>(),
    conflicts: (json['conflicts'] as List)
        .cast<Map<String, dynamic>>()
        .map(SyncConflict.fromJson)
        .toList(),
    hasMore: json['hasMore'] == true,
    latestServerSeq: (json['latestServerSeq'] as num?)?.toInt() ?? 0,
  );
}

/// One automatically-resolved disagreement, kept so it can be shown.
///
/// The resolution already happened — this is not a prompt. It exists because
/// "the app changed my note and told me what it used to be" and "the app
/// changed my note" are very different experiences in a product holding
/// someone's financial records.
class SyncConflict {
  final String id;
  final String entity;
  final String entityId;
  final String field;
  final Object? localValue;
  final Object? serverValue;
  final Object? chosenValue;
  final DateTime createdAt;

  const SyncConflict({
    required this.id,
    required this.entity,
    required this.entityId,
    required this.field,
    required this.localValue,
    required this.serverValue,
    required this.chosenValue,
    required this.createdAt,
  });

  factory SyncConflict.fromJson(Map<String, dynamic> json) => SyncConflict(
    id: json['id'] as String,
    entity: json['entity'] as String,
    entityId: json['entity_id'] as String,
    field: json['field'] as String,
    localValue: json['local_value'],
    serverValue: json['server_value'],
    chosenValue: json['chosen_value'],
    createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
  );

  /// True when the value this device had was the one discarded — the only case
  /// worth telling the user about, since a conflict they won looks identical
  /// to no conflict at all from where they're sitting.
  bool get lostLocalValue => jsonEncode(chosenValue) != jsonEncode(localValue);
}

class SyncApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  SyncApi({required this.apiBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<String> registerDevice({
    required String platform,
    String? label,
    String? appVersion,
    String? deviceId,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/sync/register-device'),
      headers: _headers,
      body: jsonEncode({
        'platform': platform,
        'label': ?label,
        'appVersion': ?appVersion,
        'deviceId': ?deviceId,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /sync/register-device failed: ${response.statusCode} ${response.body}',
      );
    }
    return (jsonDecode(response.body) as Map<String, dynamic>)['deviceId'] as String;
  }

  Future<List<SyncPushResult>> push({
    required String deviceId,
    required List<SyncChange> changes,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/sync/push'),
      headers: _headers,
      body: jsonEncode({
        'deviceId': deviceId,
        'changes': changes.map((c) => c.toJson()).toList(),
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException('POST /sync/push failed: ${response.statusCode} ${response.body}');
    }
    return ((jsonDecode(response.body) as Map<String, dynamic>)['results'] as List)
        .cast<Map<String, dynamic>>()
        .map(SyncPushResult.fromJson)
        .toList();
  }

  Future<SyncPullBatch> pull({required String deviceId, required int since, int limit = 500}) async {
    final uri = Uri.parse('$apiBaseUrl/sync/pull').replace(
      queryParameters: {'deviceId': deviceId, 'since': '$since', 'limit': '$limit'},
    );
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /sync/pull failed: ${response.statusCode} ${response.body}');
    }
    return SyncPullBatch.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> ack({required String deviceId, required int serverSeq}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/sync/ack'),
      headers: _headers,
      body: jsonEncode({'deviceId': deviceId, 'serverSeq': serverSeq}),
    );
    if (response.statusCode != 200) {
      throw ApiException('POST /sync/ack failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<void> acknowledgeConflict(String conflictId) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/sync/conflicts/$conflictId/acknowledge'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /sync/conflicts/$conflictId/acknowledge failed: ${response.statusCode}',
      );
    }
  }
}
