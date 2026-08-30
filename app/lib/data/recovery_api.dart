import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Plan Phase 1.3 — can this account still be reached if the phone is lost?
///
/// PandaPay's auth is OTP-only and has no password, by design. That means the
/// ability to sign in *is* the ability to receive a code on a channel, and a
/// user whose only verified channel is their phone number loses the entire
/// account along with the SIM — every card, every transaction, the whole
/// history. Both sign-in paths (phone OTP and email OTP) already existed; what
/// was missing was any way for the app to notice the gap and say so.
///
/// Talks to `auth/`, not `api/` — `users.is_email_verified` is the auth
/// service's column.
class RecoveryStatus {
  final bool phoneVerified;
  final bool emailVerified;

  /// False when only one channel is verified: there is no way back in if that
  /// one is lost. This is the field the UI actually acts on.
  final bool hasBackupChannel;

  /// `'email'` or `'phone'` — which channel to offer adding. Null once both
  /// are verified.
  final String? missingChannel;

  /// A masked form (`aa••••••@gmail.com`) for recognition only. The server
  /// deliberately never returns the full secondary address to an ordinary
  /// access token.
  final String? emailHint;

  /// A masked form (`+91•••••••3210`) of the phone on file, or null when there
  /// is none. Returned whenever a number is linked at all, verified or not —
  /// the Email & phone screen uses its presence to tell "linked but unproven"
  /// apart from "no number", and keys the badge off [phoneVerified].
  final String? phoneHint;

  const RecoveryStatus({
    required this.phoneVerified,
    required this.emailVerified,
    required this.hasBackupChannel,
    this.missingChannel,
    this.emailHint,
    this.phoneHint,
  });

  factory RecoveryStatus.fromJson(Map<String, dynamic> json) {
    return RecoveryStatus(
      phoneVerified: json['phone_verified'] == true,
      emailVerified: json['email_verified'] == true,
      hasBackupChannel: json['has_backup_channel'] == true,
      missingChannel: json['missing_channel'] as String?,
      emailHint: json['email_hint'] as String?,
      phoneHint: json['phone_hint'] as String?,
    );
  }
}

class RecoveryApi {
  final String authBaseUrl;
  final String accessToken;
  final http.Client _client;

  RecoveryApi({required this.authBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Future<RecoveryStatus> fetchStatus() async {
    final response = await _client.get(
      Uri.parse('$authBaseUrl/users/me/recovery-status'),
      headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /users/me/recovery-status failed: ${response.statusCode} ${response.body}',
      );
    }
    return RecoveryStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}
