import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/env.dart';

/// The single Gmail scope this app ever requests: read‑only. No compose, no
/// send, no modify. Kept here so the connect flow, the consent screen copy,
/// and the OAuth‑setup doc all point at one constant.
const String gmailReadonlyScope = 'https://www.googleapis.com/auth/gmail.readonly';

/// Persisted "the user connected Gmail on this device" state. Purely local —
/// SharedPreferences, same mechanism as `onboardingCompleteProvider`. Nothing
/// here is uploaded; the account email is kept only so the UI can show which
/// inbox is connected and offer a Disconnect.
class GmailConnection {
  final String email;
  final DateTime? lastScanAt;
  final int? lastCardsFound;

  const GmailConnection({required this.email, this.lastScanAt, this.lastCardsFound});

  GmailConnection copyWith({DateTime? lastScanAt, int? lastCardsFound}) => GmailConnection(
        email: email,
        lastScanAt: lastScanAt ?? this.lastScanAt,
        lastCardsFound: lastCardsFound ?? this.lastCardsFound,
      );
}

const _kEmailKey = 'pandapay_app.gmail_connected_email_v1';
const _kLastScanKey = 'pandapay_app.gmail_last_scan_iso_v1';
const _kLastFoundKey = 'pandapay_app.gmail_last_found_v1';

final gmailConnectControllerProvider =
    StateNotifierProvider<GmailConnectController, AsyncValue<GmailConnection?>>(
  (ref) => GmailConnectController(),
);

/// Owns the on‑device Google Sign‑In for Gmail read‑only access.
///
/// The access token is handed straight to [GmailDiscoveryService] for
/// device‑to‑Google calls and is never persisted or sent anywhere else. Only
/// the connected account's email address is stored locally, so the UI can
/// show it and offer Disconnect.
class GmailConnectController extends StateNotifier<AsyncValue<GmailConnection?>> {
  GmailConnectController({GoogleSignIn? googleSignIn})
      : _google = googleSignIn ??
            GoogleSignIn(
              scopes: const [gmailReadonlyScope],
              // Android matches the OAuth client by package + SHA‑1, so no id
              // is needed there. iOS/macOS need the client id explicitly (plus
              // the reversed‑client‑id URL scheme in Info.plist).
              clientId: (!kIsWeb && (Platform.isIOS || Platform.isMacOS) && Env.iosGoogleClientId.isNotEmpty)
                  ? Env.iosGoogleClientId
                  : null,
            ),
        super(const AsyncValue.loading()) {
    _load();
  }

  final GoogleSignIn _google;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString(_kEmailKey);
      if (email == null || email.isEmpty) {
        state = const AsyncValue.data(null);
        return;
      }
      final lastScanIso = prefs.getString(_kLastScanKey);
      state = AsyncValue.data(GmailConnection(
        email: email,
        lastScanAt: lastScanIso == null ? null : DateTime.tryParse(lastScanIso),
        lastCardsFound: prefs.getInt(_kLastFoundKey),
      ));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Runs the full connect flow and returns a fresh Gmail access token, or
  /// `null` if the user dismissed the account picker / consent.
  ///
  /// Throws [StateError] with user‑facing copy for every actionable failure
  /// (OAuth client not registered, scope denied, app not yet verified, …).
  Future<String?> connectAndGetToken() async {
    GoogleSignInAccount? account;
    try {
      account = await _google.signInSilently();
      account ??= await _google.signIn();
    } on PlatformException catch (e) {
      throw StateError(describeSignInFailure(e));
    }
    if (account == null) return null; // user cancelled

    // signIn() doesn't always carry the readonly grant on Android.
    var hasScope = true;
    try {
      hasScope = await _google.canAccessScopes(const [gmailReadonlyScope]);
    } catch (_) {
      // canAccessScopes is unsupported on some platforms — assume granted and
      // let the API 403 surface a precise message if it wasn't.
    }
    if (!hasScope) {
      final granted = await _google.requestScopes(const [gmailReadonlyScope]);
      if (!granted) {
        throw StateError(
          'PandaPay needs read‑only access to your Gmail to find bank statement '
          'emails. Nothing is uploaded — parsing happens on your device.',
        );
      }
    }

    final auth = await account.authentication;
    final token = auth.accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Google did not return an access token. Please try connecting again.');
    }

    await _persistEmail(account.email);
    return token;
  }

  /// Best‑effort token for a re‑scan without re‑prompting. Returns `null` if
  /// the silent grant is gone (user must tap Connect again).
  Future<String?> silentToken() async {
    try {
      final account = await _google.signInSilently();
      if (account == null) return null;
      final auth = await account.authentication;
      return auth.accessToken;
    } catch (_) {
      return null;
    }
  }

  Future<void> recordScan({required int cardsFound}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final now = DateTime.now();
    state = AsyncValue.data(current.copyWith(lastScanAt: now, lastCardsFound: cardsFound));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastScanKey, now.toIso8601String());
      await prefs.setInt(_kLastFoundKey, cardsFound);
    } catch (_) {}
  }

  /// Revokes the Google grant for this app and clears local state.
  Future<void> disconnect() async {
    try {
      await _google.disconnect();
    } catch (_) {
      // Even if revoke fails (offline), still forget locally.
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kEmailKey);
      await prefs.remove(_kLastScanKey);
      await prefs.remove(_kLastFoundKey);
    } catch (_) {}
    state = const AsyncValue.data(null);
  }

  Future<void> _persistEmail(String email) async {
    state = AsyncValue.data(GmailConnection(
      email: email,
      lastScanAt: state.valueOrNull?.lastScanAt,
      lastCardsFound: state.valueOrNull?.lastCardsFound,
    ));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kEmailKey, email);
    } catch (_) {}
  }
}

/// Maps a `google_sign_in` [PlatformException] to copy that tells the user (or
/// a tester) what to do. Code 10 / DEVELOPER_ERROR means the OAuth client for
/// this build's package + signing certificate isn't registered in Google
/// Cloud yet — see `docs/gmail-oauth-setup.md`.
String describeSignInFailure(PlatformException e) {
  final detail = '${e.code} ${e.message ?? ''}'.toLowerCase();
  if (detail.contains('developer_error') ||
      detail.contains('10:') ||
      detail.contains('not been registered') ||
      detail.contains('invalid_audience')) {
    return 'Gmail connect isn\'t configured for this build yet — the app\'s '
        'Google OAuth client still needs to be set up (see docs/gmail-oauth-setup.md).';
  }
  if (detail.contains('12501') || detail.contains('canceled') || detail.contains('cancelled')) {
    return 'Sign‑in was cancelled.';
  }
  if (detail.contains('network')) {
    return 'Couldn\'t reach Google. Check your connection and try again.';
  }
  if (detail.contains('access_denied') ||
      detail.contains('verification') ||
      detail.contains('blocked') ||
      detail.contains('has not completed')) {
    return 'Google is blocking access because this app is still in review. Ask '
        'the team to add your Google account as a test user, or use SMS / the '
        'catalogue instead.';
  }
  return 'Google sign‑in failed (${e.code}). Please try again or use another import option.';
}
