import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// S5/S6 (ui-spec System Surfaces, GAP_ANALYSIS.md §3) — forced upgrade /
/// maintenance mode, mirrors `app_status` (db/supabase/migrations/0020_app_status.sql).
class AppStatus {
  final String minSupportedVersion;
  final bool maintenanceMode;
  final String? maintenanceMessage;

  const AppStatus({
    required this.minSupportedVersion,
    required this.maintenanceMode,
    this.maintenanceMessage,
  });

  factory AppStatus.fromJson(Map<String, dynamic> json) => AppStatus(
        minSupportedVersion: json['minSupportedVersion'] as String? ?? '1.0.0',
        maintenanceMode: json['maintenanceMode'] as bool? ?? false,
        maintenanceMessage: json['maintenanceMessage'] as String?,
      );
}

/// Compares two dot-separated version strings as integer components (e.g.
/// "1.10.0" > "1.9.0"). NOT full semver (no pre-release/build-metadata
/// handling) — deliberately simplified, same scope note as
/// whats_new_screen.dart's own `_isNewerVersion`, which this mirrors
/// exactly rather than importing across a features/ -> data/ boundary the
/// rest of this codebase's layering avoids. Returns true if [current] is
/// older than [minimum] — i.e. a forced upgrade is required.
bool isVersionOlderThan(String current, String minimum) {
  if (current == minimum) return false;
  final partsCurrent = current.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final partsMinimum = minimum.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final len = partsCurrent.length > partsMinimum.length ? partsCurrent.length : partsMinimum.length;
  for (var i = 0; i < len; i++) {
    final vc = i < partsCurrent.length ? partsCurrent[i] : 0;
    final vm = i < partsMinimum.length ? partsMinimum[i] : 0;
    if (vc != vm) return vc < vm;
  }
  return false;
}

abstract class AppStatusRepository {
  Future<AppStatus> fetchStatus();
}

class HttpAppStatusRepository implements AppStatusRepository {
  final String baseUrl;
  final http.Client _client;

  HttpAppStatusRepository({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  @override
  Future<AppStatus> fetchStatus() async {
    final response = await _client.get(Uri.parse('$baseUrl/app-status'));
    if (response.statusCode != 200) {
      throw ApiException('GET /app-status failed: ${response.statusCode} ${response.body}');
    }
    return AppStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}
