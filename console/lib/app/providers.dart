import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/admin_api.dart';

const authBaseUrl = 'http://localhost:3210';
const apiBaseUrl = 'http://localhost:4000';

final authApiProvider = Provider<AuthApi>((ref) => AuthApi(authBaseUrl: authBaseUrl));

/// The signed-in access token, or null when signed out. AD-0.3.1: local
/// state only — no persistence yet (no "remember me", closes on refresh).
final accessTokenProvider = StateProvider<String?>((ref) => null);

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
