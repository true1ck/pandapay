import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// S5/S6 (ui-spec System Surfaces, GAP_ANALYSIS.md §3) — forced upgrade /
/// maintenance mode, mirrors `app_status` (db/supabase/migrations/0020_app_status.sql).
class AppStatus {
  final String minSupportedVersion;
  final bool maintenanceMode;
  final String? maintenanceMessage;

  /// smsextractionimple.md Task S-1b — server-side kill switch for the SMS
  /// backup-file import entry point. The blast radius of a bad import is the
  /// user's whole transaction history and the input is a file format this
  /// codebase doesn't control, so the tile needs to be withdrawable without
  /// shipping a release.
  ///
  /// Defaults true so an old client, an unreachable server or a pre-0036
  /// database all behave as "feature on" — the same fail-open stance the
  /// rest of this model takes.
  final bool smsBackupImportEnabled;

  const AppStatus({
    required this.minSupportedVersion,
    required this.maintenanceMode,
    this.maintenanceMessage,
    this.smsBackupImportEnabled = true,
  });

  factory AppStatus.fromJson(Map<String, dynamic> json) => AppStatus(
    minSupportedVersion: json['minSupportedVersion'] as String? ?? '1.0.0',
    maintenanceMode: json['maintenanceMode'] as bool? ?? false,
    maintenanceMessage: json['maintenanceMessage'] as String?,
    smsBackupImportEnabled: json['smsBackupImportEnabled'] as bool? ?? true,
  );
}

/// Compares numeric release components to decide whether an upgrade is required.
/// Flavor suffixes (for example `-dev`) and build metadata are ignored so a
/// Dev build of a supported release is not mistaken for patch version zero.
/// This is a release support check, not full semver pre-release ordering.
bool isVersionOlderThan(String current, String minimum) {
  if (current == minimum) return false;
  List<int> releaseParts(String version) => version
      .split(RegExp('[-+]'))
      .first
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final partsCurrent = releaseParts(current);
  final partsMinimum = releaseParts(minimum);
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
    // This is a fail-open advisory check. It must not leave an HTTP socket or
    // router refresh alive indefinitely when the API is unreachable.
    final response = await _client
        .get(Uri.parse('$baseUrl/app-status'))
        .timeout(const Duration(seconds: 2));
    if (response.statusCode != 200) {
      throw ApiException('GET /app-status failed: ${response.statusCode} ${response.body}');
    }
    return AppStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}
