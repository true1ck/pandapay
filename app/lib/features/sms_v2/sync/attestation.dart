import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../../../app/local_sms_rig_build.dart';

/// App Check headers for the phone sync client. The installation ID is stored
/// by the caller and is an admission identifier rather than a hardware claim.
final class DeviceAttestation {
  DeviceAttestation({
    required this.deviceId,
    DateTime Function()? now,
    this._fetchToken,
    this._fetchLimitedUseToken,
  }) : _now = now ?? DateTime.now {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId');
    }
  }

  final String deviceId;
  final DateTime Function() _now;
  final Future<String?> Function(bool forceRefresh)? _fetchToken;
  final Future<String?> Function()? _fetchLimitedUseToken;
  String? _token;
  DateTime? _expiresAt;
  DateTime? _nextAttemptAt;
  Future<String?>? _pending;
  Future<void>? _activation;

  Future<Map<String, String>> headers() async {
    final token = await _getToken();
    return {'X-Sms-Device-Id': deviceId, 'X-Device-Attestation': ?token};
  }

  /// Headers carrying a limited-use App Check token for routes where the
  /// server consumes tokens (replay protection, LO-10). Every call fetches a
  /// new single-use token and none is cached; the server accepts them only
  /// when SMS_V2_APPCHECK_REPLAY_PROTECTION is on. Failures fall back to the
  /// installation ID alone, like [headers].
  Future<Map<String, String>> limitedUseHeaders() async {
    String? token;
    try {
      token = await (_fetchLimitedUseToken ?? _fetchFirebaseLimitedUseToken)();
    } catch (_) {
      token = null;
    }
    if (token != null && _expiry(token)?.isAfter(_now()) != true) token = null;
    return {'X-Sms-Device-Id': deviceId, 'X-Device-Attestation': ?token};
  }

  Future<String?> _getToken() async {
    final now = _now();
    if (_expiresAt != null &&
        now.isBefore(_expiresAt!.subtract(const Duration(minutes: 5)))) {
      return _token;
    }
    if (_nextAttemptAt != null && now.isBefore(_nextAttemptAt!)) {
      return _expiresAt?.isAfter(now) == true ? _token : null;
    }
    return _pending ??= _refresh().whenComplete(() => _pending = null);
  }

  Future<String?> _refresh() async {
    _nextAttemptAt = _now().add(const Duration(seconds: 30));
    try {
      final token = await (_fetchToken ?? _fetchFirebaseToken)(_token != null);
      final expiry = _expiry(token);
      if (token != null && expiry != null && expiry.isAfter(_now())) {
        _token = token;
        _expiresAt = expiry;
      }
    } catch (_) {
      // Monitor mode continues at lower limits when attestation is unavailable.
      // Enforcement is decided by the server and the sync client keeps its queue.
    }
    return _expiresAt?.isAfter(_now()) == true ? _token : null;
  }

  Future<String?> _fetchFirebaseToken(bool forceRefresh) async {
    if (kIsWeb ||
        !{
          TargetPlatform.android,
          TargetPlatform.iOS,
        }.contains(defaultTargetPlatform)) {
      return null;
    }
    try {
      await (_activation ??= _activate());
    } catch (_) {
      _activation = null;
      rethrow;
    }
    return FirebaseAppCheck.instance.getToken(forceRefresh);
  }

  Future<String?> _fetchFirebaseLimitedUseToken() async {
    if (kIsWeb ||
        !{
          TargetPlatform.android,
          TargetPlatform.iOS,
        }.contains(defaultTargetPlatform)) {
      return null;
    }
    try {
      await (_activation ??= _activate());
    } catch (_) {
      _activation = null;
      rethrow;
    }
    return FirebaseAppCheck.instance.getLimitedUseToken();
  }

  Future<void> _activate() async {
    await Firebase.initializeApp();
    await FirebaseAppCheck.instance.activate(
      providerAndroid: LocalSmsRigBuild.controlsEnabled
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
      providerApple: LocalSmsRigBuild.controlsEnabled
          ? const AppleDebugProvider()
          : const AppleAppAttestProvider(),
    );
  }

  static DateTime? _expiry(String? token) {
    if (token == null || token.length > 8192) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final expiry = payload is Map ? payload['exp'] : null;
      return expiry is int
          ? DateTime.fromMillisecondsSinceEpoch(expiry * 1000, isUtc: true)
          : null;
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }
}
