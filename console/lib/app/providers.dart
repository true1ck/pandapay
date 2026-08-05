import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/admin_api.dart';
import '../data/token_store.dart';

const authBaseUrl = 'http://localhost:3210';
const apiBaseUrl = 'http://localhost:4000';

final authApiProvider = Provider<AuthApi>((ref) => AuthApi(authBaseUrl: authBaseUrl));

final tokenStoreProvider = FutureProvider<TokenStore>((ref) => TokenStore.load());

/// The signed-in access token, or null when signed out. Chunk 10: seeded on
/// startup from sessionInitProvider (which resolves a stored refresh token
/// through the real auth/ /auth/refresh endpoint), and login_screen.dart
/// persists both tokens on a fresh OTP sign-in — a reload no longer forces
/// the OTP flow again.
final accessTokenProvider = StateProvider<String?>((ref) => null);

/// Runs once on startup: if a refresh token is stored, exchange it for a
/// fresh access token and seed accessTokenProvider; otherwise (or on
/// failure — expired/reused/invalid) clear storage and stay signed out.
/// _AuthGate waits on this before deciding whether to show the login screen,
/// so a valid stored session never flashes the login screen first.
final sessionInitProvider = FutureProvider<void>((ref) async {
  final store = await ref.watch(tokenStoreProvider.future);
  final refreshToken = store.refreshToken;
  if (refreshToken == null) return;

  final authApi = ref.read(authApiProvider);
  try {
    final tokens = await authApi.refresh(refreshToken);
    await store.save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken);
    ref.read(accessTokenProvider.notifier).state = tokens.accessToken;
  } catch (_) {
    await store.clear();
  }
});

final adminApiProvider = Provider<AdminApi?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return AdminApi(apiBaseUrl: apiBaseUrl, accessToken: token);
});

/// AD-0.3.2: whether the signed-in account is an active admin_users row —
/// resolved by calling GET /admin/me for real, not inferred client-side.
/// Built on adminApiProvider (not a fresh AdminApi(...)) so tests can
/// override just that provider with a fake and exercise this without a
/// real network call.
final isAdminProvider = FutureProvider<bool>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return false;
  return api.isAdmin();
});

final adminCardsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchAdminCards();
});

final cardRequestGroupsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchCardRequestGroups();
});

final errorReportsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchErrorReports();
});
