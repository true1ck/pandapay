import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Plan Phase 1.4 — linked-device management.
///
/// Unlike every other repository in this directory this one talks to `auth/`,
/// not `api/`: `user_devices` is the auth service's table and is populated by
/// its own sign-in path (`authRoutes.js` upserts a row on every OTP verify),
/// so device enumeration and revocation live there. Base URL is therefore
/// `authBaseUrl`.
///
/// The backend for this has existed and gone unused the whole time —
/// `settings_hub_screen.dart` said in a doc comment that "Linked devices"
/// couldn't be built because "auth/ has no session-enumeration endpoint",
/// which was simply not true of `GET /users/me/devices`. That comment is
/// corrected as part of this change.
class LinkedDevice {
  final String deviceIdentifier;
  final String? platform;
  final String? model;
  final String? osVersion;
  final String? appVersion;
  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;

  const LinkedDevice({
    required this.deviceIdentifier,
    this.platform,
    this.model,
    this.osVersion,
    this.appVersion,
    this.firstSeenAt,
    this.lastSeenAt,
  });

  factory LinkedDevice.fromJson(Map<String, dynamic> json) {
    DateTime? parse(Object? v) => v == null ? null : DateTime.tryParse(v as String)?.toLocal();
    return LinkedDevice(
      deviceIdentifier: json['device_identifier'] as String,
      platform: json['device_platform'] as String?,
      model: json['device_model'] as String?,
      osVersion: json['os_version'] as String?,
      appVersion: json['app_version'] as String?,
      firstSeenAt: parse(json['first_seen_at']),
      lastSeenAt: parse(json['last_seen_at']),
    );
  }

  /// What the row says when the device never reported a model — better than
  /// rendering an empty tile, and deliberately not guessed at from the
  /// platform string, which would be inventing information.
  String get displayName => model ?? platform ?? 'Unknown device';
}

/// Thrown when `auth/` answers a revoke with its `step_up_required` 403.
///
/// A distinct type rather than a generic [ApiException] because the UI has to
/// do something specific and non-obvious with it: revocation is gated behind
/// a *recent* OTP (`STEP_UP_OTP_WINDOW_MINUTES`, 5 by default), so a user who
/// signed in an hour ago gets refused even though they are perfectly
/// authenticated. Reporting that as "something went wrong" would be actively
/// misleading — nothing went wrong, they just need to re-verify.
class StepUpRequiredException extends ApiException {
  StepUpRequiredException(super.debugMessage, {super.userMessage});
}

class DevicesApi {
  final String authBaseUrl;
  final String accessToken;
  final http.Client _client;

  DevicesApi({required this.authBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  /// Active devices only — the route filters `is_active = true` server-side,
  /// so a revoked device disappears from this list rather than lingering as a
  /// tombstone.
  Future<List<LinkedDevice>> fetchDevices() async {
    final response = await _client.get(
      Uri.parse('$authBaseUrl/users/me/devices'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException('GET /users/me/devices failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['devices'] as List)
        .cast<Map<String, dynamic>>()
        .map(LinkedDevice.fromJson)
        .toList();
  }

  /// Marks the device inactive and revokes its refresh tokens, so it is
  /// signed out for real rather than merely hidden from this list.
  Future<void> revokeDevice(String deviceIdentifier) async {
    final response = await _client.delete(
      Uri.parse('$authBaseUrl/users/me/devices/$deviceIdentifier'),
      headers: _headers,
    );
    if (response.statusCode == 403) {
      throw StepUpRequiredException(
        'DELETE /users/me/devices/$deviceIdentifier refused: step_up_required',
        userMessage:
            'Revoking a device needs a fresh verification. Sign in again to confirm it\'s you, '
            'then try once more.',
      );
    }
    if (response.statusCode != 200) {
      throw ApiException(
        'DELETE /users/me/devices/$deviceIdentifier failed: '
        '${response.statusCode} ${response.body}',
      );
    }
  }
}
