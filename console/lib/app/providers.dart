import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../data/admin_api.dart';
import '../data/token_store.dart';

/// Same `--dart-define` contract as the user app's `app/lib/app/env.dart`
/// (plan Phase 0.3) — kept as two plain consts here rather than a shared
/// package because the console is a separate Flutter target that does not
/// depend on `app/`, and duplicating two `String.fromEnvironment` calls is
/// cheaper than a package just to hold them. These origins apply to native
/// console callers. Web uses the same-origin /browser gateway, which must
/// be served alongside the static bundle during development and deployment.
///
/// ```bash
/// flutter build web --release \
///   --dart-define=PANDAPAY_API_BASE_URL=https://api.pandapay.example \
///   --dart-define=PANDAPAY_AUTH_BASE_URL=https://auth.pandapay.example
/// ```
const authBaseUrl = String.fromEnvironment(
  'PANDAPAY_AUTH_BASE_URL',
  defaultValue: 'http://localhost:3210',
);
const apiBaseUrl = String.fromEnvironment(
  'PANDAPAY_API_BASE_URL',
  defaultValue: 'http://localhost:4000',
);

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(
    authBaseUrl: authBaseUrl,
    versionedOtpEnabled: const bool.fromEnvironment(
      'PANDAPAY_OTP_V2_ENABLED',
      defaultValue: false,
    ),
  ),
);

final tokenStoreProvider = FutureProvider<TokenStore>(
  (ref) => TokenStore.load(),
);

/// Native access token or in-memory browser-session marker; null when signed
/// out. Browser bearer credentials remain on the server. Native credentials
/// retain their existing compatibility storage and require careful custody.
final accessTokenProvider = StateProvider<String?>((ref) => null);

/// Restores the browser cookie session or exchanges the native refresh token.
/// A definitive 401 clears local sign-in state; transient failures are
/// surfaced by the auth gate for retry.
/// _AuthGate waits on this before deciding whether to show the login screen,
/// so a valid stored session never flashes the login screen first.
final sessionInitProvider = FutureProvider<void>((ref) async {
  final store = await ref.watch(tokenStoreProvider.future);
  final authApi = ref.read(authApiProvider);
  final refreshToken = store.refreshToken;
  if (!authApi.browserSessions && refreshToken == null) return;
  try {
    final tokens = await authApi.refresh(refreshToken ?? '');
    await store.save(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
    );
    ref.read(accessTokenProvider.notifier).state = tokens.accessToken;
  } on AdminApiException catch (error) {
    if (error.statusCode == 401) {
      await store.clear();
      ref.read(accessTokenProvider.notifier).state = null;
      return;
    }
    rethrow;
  }
});

final adminApiProvider = Provider<AdminApi?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  final auth = ref.read(authApiProvider);
  return AdminApi(
    apiBaseUrl: auth.browserSessions
        ? '${auth.browserBaseUrl}/api'
        : apiBaseUrl,
    accessToken: token,
    csrfToken: auth.browserSessions ? () => auth.browserCsrf : null,
  );
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

final referralOperationsProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const {};
  return api.fetchReferralOperations();
});

final adminCardsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchAdminCards();
});

final cardRequestGroupsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchCardRequestGroups();
});

final supportTicketsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchSupportTickets();
});

final errorReportsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchErrorReports();
});

final alertsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchAlerts();
});

/// AD-3: scraper source registry.
final sourcesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchSources();
});

/// AD-4: recent scrape run history across every source.
final scrapeRunsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchScrapeRuns();
});

/// AD-6.1: merchant table filter state — plain fields, not a class, so
/// merchantsProvider (below) can .watch() each one independently and only
/// the filters that actually changed trigger a refetch.
final merchantCategoryFilterProvider = StateProvider<String?>((ref) => null);
final merchantMinConfidenceFilterProvider = StateProvider<double?>(
  (ref) => null,
);
final merchantPublishedFilterProvider = StateProvider<bool?>((ref) => null);
final merchantSearchFilterProvider = StateProvider<String>((ref) => '');

final merchantsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchMerchants(
    categoryId: ref.watch(merchantCategoryFilterProvider),
    minConfidenceScore: ref.watch(merchantMinConfidenceFilterProvider),
    published: ref.watch(merchantPublishedFilterProvider),
    query: ref.watch(merchantSearchFilterProvider),
  );
});

final merchantConflictsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchMerchantConflicts();
});

final abuseSignalsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchAbuseSignals();
});

/// AD-6.1.4's category filter needs id->name; /categories is public
/// (same policy as /catalogue) so this doesn't need the admin API wrapper.
final categoriesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final auth = ref.read(authApiProvider);
  if (auth.browserSessions) return auth.categories();
  final response = await http.get(Uri.parse('$apiBaseUrl/categories'));
  if (response.statusCode != 200) return const [];
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return (body['categories'] as List).cast<Map<String, dynamic>>();
});

/// AD-7.1: acceptance-summary filter state, same shape as the merchant
/// filters above.
final acceptanceNetworkFilterProvider = StateProvider<String?>((ref) => null);
final acceptancePublishedFilterProvider = StateProvider<bool?>((ref) => null);

final acceptanceSummaryProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchAcceptanceSummary(
    network: ref.watch(acceptanceNetworkFilterProvider),
    published: ref.watch(acceptancePublishedFilterProvider),
  );
});

/// AD-7.3: effective-rate monitor filter state.
final effectiveRateDivergentOnlyProvider = StateProvider<bool>((ref) => false);

final effectiveRateSummaryProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) async {
    final api = ref.watch(adminApiProvider);
    if (api == null) return const [];
    return api.fetchEffectiveRateSummary(
      divergentOnly: ref.watch(effectiveRateDivergentOnlyProvider),
    );
  },
);

final dataQualityDashboardProvider = FutureProvider<Map<String, dynamic>?>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return null;
  return api.fetchDataQualityDashboard();
});

final smsAiSummaryProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const {};
  return api.fetchSmsAiSummary();
});

final smsLearningCandidatesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
      final api = ref.watch(adminApiProvider);
      if (api == null) return const [];
      return api.fetchSmsLearningCandidates();
    });

final smsLearningOperationsProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const {};
  return api.fetchSmsLearningOperations();
});

final smsAiJobStatusFilterProvider = StateProvider<String?>((ref) => null);

final smsAiJobsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchSmsAiJobs(
    status: ref.watch(smsAiJobStatusFilterProvider),
    limit: 100,
  );
});

final smsAiQuotaProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchSmsAiQuota();
});

final smsAiJobTimelineProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      jobId,
    ) async {
      final api = ref.watch(adminApiProvider);
      if (api == null) return const [];
      return api.fetchSmsAiJobTimeline(jobId);
    });
/// Resolved rollout booleans plus the raw feature-flag rows behind them.
final smsRolloutProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const {};
  return api.fetchSmsRolloutStatus();
});

final smsRuleBundlesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchSmsRuleBundles();
});

final smsCategoryProposalsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchSmsCategoryProposals();
});

final smsParserProposalsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchSmsParserProposals();
});

final smsAiProposalsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchSmsAiProposals();
});

/// C7: explicit user-correction cases (typed correction envelope). Admin
/// review affects candidate eligibility only; final rule approval remains
/// separate.
final smsCorrectionCasesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchSmsCorrectionCases();
});


final anonymizationAuditRunsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
      final api = ref.watch(adminApiProvider);
      if (api == null) return const [];
      return api.fetchAnonymizationAuditRuns();
    });

final parserPatternsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final api = ref.watch(adminApiProvider);
  if (api == null) return const [];
  return api.fetchParserPatterns();
});
