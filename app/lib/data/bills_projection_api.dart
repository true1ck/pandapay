import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// A server projection shown by Bills & Commitments.
///
/// This is intentionally a wire model, separate from [Commitment]. Local
/// commitments remain editable and durable offline; central projections are
/// evidence-backed read-only rows until the user chooses a local action.
class BillProjection {
  final String id;
  final String projectionKind;
  final String projectionKey;
  final String status;
  final Map<String, dynamic> projection;
  final String? sourceKey;
  final List<String> sourceFactIds;
  final int projectionVersion;
  final DateTime? updatedAt;

  const BillProjection({
    required this.id,
    required this.projectionKind,
    required this.projectionKey,
    required this.status,
    required this.projection,
    required this.sourceKey,
    required this.sourceFactIds,
    required this.projectionVersion,
    required this.updatedAt,
  });

  factory BillProjection.fromJson(Map<String, dynamic> json) {
    final rawProjection = json['projection'];
    final rawFactIds = json['sourceFactIds'];
    return BillProjection(
      id: json['id'] as String? ?? '',
      projectionKind: json['projectionKind'] as String? ?? '',
      projectionKey: json['projectionKey'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      projection: rawProjection is Map
          ? Map<String, dynamic>.from(rawProjection)
          : const {},
      sourceKey: json['sourceKey'] as String?,
      sourceFactIds: rawFactIds is List
          ? rawFactIds.whereType<String>().toList(growable: false)
          : const [],
      projectionVersion: (json['projectionVersion'] as num?)?.toInt() ?? 1,
      updatedAt: _date(json['updatedAt']),
    );
  }

  double? number(String key) => (projection[key] as num?)?.toDouble();

  String? text(String key) {
    final value = projection[key];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  DateTime? get dueDate => _date(projection['dueDate']);
  DateTime? get asOfAt => _date(projection['asOfAt']);
  double? get amountInr => number('amountInr');
  double? get authorizationLimitInr => number('authorizationLimitInr');
  String? get billerName => text('billerName') ?? text('merchant');
  String? get serviceName => text('serviceName') ?? text('merchant');
  String? get last4 => text('last4');

  static DateTime? _date(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}

class BillProjectionSnapshot {
  final bool available;
  final List<BillProjection> projections;

  const BillProjectionSnapshot({required this.available, required this.projections});

  const BillProjectionSnapshot.unavailable()
      : available = false,
        projections = const [];

  factory BillProjectionSnapshot.fromJson(Map<String, dynamic> json) {
    final raw = json['projections'];
    return BillProjectionSnapshot(
      available: json['available'] as bool? ?? true,
      projections: raw is List
          ? raw
              .whereType<Map>()
              .map((row) => BillProjection.fromJson(Map<String, dynamic>.from(row)))
              .toList(growable: false)
          : const [],
    );
  }
}

class BillsProjectionApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  BillsProjectionApi({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Future<BillProjectionSnapshot> fetch({
    bool includeMandates = true,
    bool includeClosed = false,
    int limit = 100,
  }) async {
    final kinds = includeMandates
        ? 'bill_obligation,bill_payment,mandate'
        : 'bill_obligation,bill_payment';
    final uri = Uri.parse('$apiBaseUrl/bills/projections').replace(
      queryParameters: {
        'kinds': kinds,
        'includeClosed': '$includeClosed',
        'limit': '$limit',
      },
    );
    final response = await _client.get(uri, headers: {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
    });
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /bills/projections failed: ${response.statusCode} ${response.body}',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw ApiException('GET /bills/projections returned an invalid response');
    }
    return BillProjectionSnapshot.fromJson(Map<String, dynamic>.from(decoded));
  }
}
