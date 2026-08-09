import 'dart:convert';
import 'package:http/http.dart' as http;

/// Talks to auth/ (OTP + JWT) and api/'s /admin/* surface. AD-0.3.1: no
/// signup path — this only ever calls the OTP login flow, same as the user
/// app; whether the resulting account is actually an operator is entirely
/// determined server-side by api/'s requireAdmin (pandapay.is_admin()), not
/// by anything client-side.
class AuthApi {
  final String authBaseUrl;
  final http.Client _client;
  AuthApi({required this.authBaseUrl, http.Client? client}) : _client = client ?? http.Client();

  Future<void> requestOtp(String phoneNumber) async {
    final response = await _client.post(
      Uri.parse('$authBaseUrl/auth/request-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': phoneNumber}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('OTP request failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Returns both tokens — AD-0.3's session needs the refresh token too, to
  /// survive a page reload without asking for OTP again (Chunk 10).
  Future<AuthTokens> verifyOtp(String phoneNumber, String code, String deviceId) async {
    final response = await _client.post(
      Uri.parse('$authBaseUrl/auth/verify-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': phoneNumber, 'code': code, 'device_id': deviceId}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('OTP verify failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AuthTokens(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String?,
    );
  }

  /// Exchanges a stored refresh token for a fresh access token on startup —
  /// the real auth/'s POST /auth/refresh, not a stub. A 401 here means the
  /// refresh token is invalid/expired/reused; callers should treat that as
  /// signed-out, not retry.
  Future<AuthTokens> refresh(String refreshToken) async {
    final response = await _client.post(
      Uri.parse('$authBaseUrl/auth/refresh'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': refreshToken}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('Refresh failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AuthTokens(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String? ?? refreshToken,
    );
  }
}

class AuthTokens {
  final String accessToken;
  final String? refreshToken;
  const AuthTokens({required this.accessToken, this.refreshToken});
}

class AdminApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  AdminApi({required this.apiBaseUrl, required this.accessToken, http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  Future<bool> isAdmin() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/me'), headers: _headers);
    if (response.statusCode != 200) return false;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['isAdmin'] as bool? ?? false;
  }

  Future<List<Map<String, dynamic>>> fetchAdminCards() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/cards'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/cards failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['cards'] as List).cast<Map<String, dynamic>>();
  }

  /// AD-1.1.3 typed writer, client side: only ever sends `rate` (+ optional
  /// audit reason), never a raw JSON blob of the whole rule.
  Future<void> updateRewardRuleRate(String ruleId, double rate, {String? reason}) async {
    final response = await _client.put(
      Uri.parse('$apiBaseUrl/admin/reward-rules/$ruleId'),
      headers: _headers,
      body: jsonEncode({'rate': rate, 'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('PUT /admin/reward-rules/$ruleId failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-1.1.4 state machine transition: draft->in_review->published->archived
  /// (and in_review->draft to send back). Publishing sets verified_at/by
  /// server-side — this is the human verification pass, not automatic.
  Future<Map<String, dynamic>> changeCardStatus(String cardId, String status, {String? reason}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/cards/$cardId/status'),
      headers: _headers,
      body: jsonEncode({'status': status, 'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('POST /admin/cards/$cardId/status failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['card'] as Map<String, dynamic>;
  }

  /// AD-1.1.2 tabbed rule-family editor, client side. Mirrors the backend's
  /// declarative factory (admin_rule_families.js) one-for-one: same shape
  /// for all 8 non-reward-rules families (cap-rules, milestone-rules,
  /// fee-waiver-rules, card-benefits, redemption-options as "list"
  /// families; forex-rules, fuel-surcharge-rules, billing-cycle-rules as
  /// "single row per card" families), so the tab widgets don't need 8
  /// near-identical client methods either — `urlSegment` selects the
  /// family, `fields` is exactly the JSON body the typed server-side
  /// validator checks.
  Future<Map<String, dynamic>> createRuleFamilyRow(
    String urlSegment, {
    required String cardProductId,
    required Map<String, dynamic> fields,
    String? reason,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/$urlSegment'),
      headers: _headers,
      body: jsonEncode({'cardProductId': cardProductId, ...fields, 'reason': ?reason}),
    );
    if (response.statusCode != 201) {
      throw AdminApiException('POST /admin/$urlSegment failed: ${response.statusCode} ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateRuleFamilyRow(
    String urlSegment,
    String id, {
    required Map<String, dynamic> fields,
    String? reason,
  }) async {
    final response = await _client.put(
      Uri.parse('$apiBaseUrl/admin/$urlSegment/$id'),
      headers: _headers,
      body: jsonEncode({...fields, 'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('PUT /admin/$urlSegment/$id failed: ${response.statusCode} ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> deleteRuleFamilyRow(String urlSegment, String id, {String? reason}) async {
    final response = await _client.delete(
      Uri.parse('$apiBaseUrl/admin/$urlSegment/$id'),
      headers: _headers,
      body: jsonEncode({'reason': ?reason}),
    );
    if (response.statusCode != 204) {
      throw AdminApiException('DELETE /admin/$urlSegment/$id failed: ${response.statusCode} ${response.body}');
    }
  }

  /// singlePerCard families: forex-rules / fuel-surcharge-rules / billing-cycle-rules.
  Future<Map<String, dynamic>> upsertSinglePerCardRuleFamily(
    String urlSegment, {
    required String cardProductId,
    required Map<String, dynamic> fields,
    String? reason,
  }) async {
    final response = await _client.put(
      Uri.parse('$apiBaseUrl/admin/$urlSegment/by-card/$cardProductId'),
      headers: _headers,
      body: jsonEncode({...fields, 'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('PUT /admin/$urlSegment/by-card/$cardProductId failed: ${response.statusCode} ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// AD-2.1: card requests grouped by issuer+product with counts.
  Future<List<Map<String, dynamic>>> fetchCardRequestGroups() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/card-requests'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/card-requests failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['requestGroups'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> startScrapingSource({
    required String issuerName,
    String? productName,
    required String baseUrl,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/card-requests/start-scraping'),
      headers: _headers,
      body: jsonEncode({'issuerName': issuerName, 'productName': ?productName, 'baseUrl': baseUrl}),
    );
    if (response.statusCode != 201) {
      throw AdminApiException('POST start-scraping failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-2.2: data error reports, shown vs claimed against the live value.
  Future<List<Map<String, dynamic>>> fetchErrorReports() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/error-reports'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/error-reports failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['errorReports'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> approveErrorReport(String reportId) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/error-reports/$reportId/approve'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw AdminApiException('approve failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<void> rejectErrorReport(String reportId, {String? reason}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/error-reports/$reportId/reject'),
      headers: _headers,
      body: jsonEncode({'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('reject failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-4.2/AD-5: the unified policy-change alert queue.
  Future<List<Map<String, dynamic>>> fetchAlerts() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/alerts'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/alerts failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['alerts'] as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> fetchAlertDetail(String alertId) async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/alerts/$alertId'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/alerts/$alertId failed: ${response.statusCode} ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> decideAlert(String alertId, String decision, {String? note}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/alerts/$alertId/decide'),
      headers: _headers,
      body: jsonEncode({'decision': decision, 'note': ?note}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('decide failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-6.1: merchant list, filterable — see api/'s GET /admin/merchants for
  /// the scope note (a filtered table, not a real flutter_map/OSM view).
  Future<List<Map<String, dynamic>>> fetchMerchants({
    String? categoryId,
    double? minConfidenceScore,
    bool? published,
    String? query,
  }) async {
    final params = <String, String>{
      'categoryId': ?categoryId,
      'minConfidenceScore': ?minConfidenceScore?.toString(),
      'published': ?published?.toString(),
      if (query != null && query.isNotEmpty) 'q': query,
    };
    final uri = Uri.parse('$apiBaseUrl/admin/merchants').replace(queryParameters: params);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/merchants failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['merchants'] as List).cast<Map<String, dynamic>>();
  }

  /// AD-6.2.1: full detail for one merchant — locations, contribution
  /// history, and any conflicts.
  Future<Map<String, dynamic>> fetchMerchantDetail(String merchantId) async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/merchants/$merchantId'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/merchants/$merchantId failed: ${response.statusCode} ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// AD-6.2.2: manual override/merge — sets operator_locked server-side.
  Future<void> overrideMerchant(
    String merchantId, {
    String? displayName,
    String? categoryId,
    String? mcc,
    String? reason,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/merchants/$merchantId/override'),
      headers: _headers,
      body: jsonEncode({
        'displayName': ?displayName,
        'categoryId': ?categoryId,
        'mcc': ?mcc,
        'reason': ?reason,
      }),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('override failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-6.2.3: unpublish a record found to be wrong or poisoned.
  Future<void> unpublishMerchant(String merchantId, {String? reason}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/merchants/$merchantId/unpublish'),
      headers: _headers,
      body: jsonEncode({'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('unpublish failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-6.3.1: pending merchant conflicts — cases the automatic
  /// majority-wins rule doesn't confidently resolve.
  Future<List<Map<String, dynamic>>> fetchMerchantConflicts() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/merchant-conflicts'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/merchant-conflicts failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['conflicts'] as List).cast<Map<String, dynamic>>();
  }

  /// AD-6.3.3: resolve a conflict — writes the value, locks the record.
  Future<void> resolveMerchantConflict(String conflictId, String resolvedValue, {String? reason}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/merchant-conflicts/$conflictId/resolve'),
      headers: _headers,
      body: jsonEncode({'resolvedValue': resolvedValue, 'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('resolve failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-6.4.1: unresolved abuse signals (burst submissions, impossible
  /// geography, high conflict rate) awaiting an operator's block decision.
  Future<List<Map<String, dynamic>>> fetchAbuseSignals() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/abuse-signals'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/abuse-signals failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['abuseSignals'] as List).cast<Map<String, dynamic>>();
  }

  /// AD-6.4.2: block a device hash, bulk-reverting its contributions.
  Future<void> blockAbuseSignal(String abuseSignalId, {String? reason}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/abuse-signals/$abuseSignalId/block'),
      headers: _headers,
      body: jsonEncode({'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('block failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-7.1: acceptance-summary rows filtered by network/rail/published —
  /// same "filtered table, not a real map" scope note as fetchMerchants.
  Future<List<Map<String, dynamic>>> fetchAcceptanceSummary({String? network, String? rail, bool? published}) async {
    final params = <String, String>{
      'network': ?network,
      'rail': ?rail,
      'published': ?published?.toString(),
    };
    final uri = Uri.parse('$apiBaseUrl/admin/acceptance-summary').replace(queryParameters: params);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/acceptance-summary failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['acceptanceSummary'] as List).cast<Map<String, dynamic>>();
  }

  /// AD-7.2: one acceptance-summary row's detail — report counts + confidence.
  Future<Map<String, dynamic>> fetchAcceptanceDetail(String merchantId, String network, String rail) async {
    final uri = Uri.parse('$apiBaseUrl/admin/acceptance-summary/$merchantId')
        .replace(queryParameters: {'network': network, 'rail': rail});
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET acceptance detail failed: ${response.statusCode} ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// AD-7.2: publish gate mirroring the merchant gate.
  Future<void> publishAcceptanceSummary(
    String merchantId,
    String network,
    String rail, {
    required bool published,
    String? reason,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/acceptance-summary/publish'),
      headers: _headers,
      body: jsonEncode({
        'merchantId': merchantId,
        'network': network,
        'rail': rail,
        'published': published,
        'reason': ?reason,
      }),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('publish failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-7.3/7.4: effective rate monitor + cap-ceiling detection, with a
  /// best-effort AD-5/AD-6-alert link per row (AD-7.5).
  Future<List<Map<String, dynamic>>> fetchEffectiveRateSummary({
    String? cardProductId,
    String? categoryId,
    bool? divergentOnly,
  }) async {
    final params = <String, String>{
      'cardProductId': ?cardProductId,
      'categoryId': ?categoryId,
      if (divergentOnly == true) 'divergentOnly': 'true',
    };
    final uri = Uri.parse('$apiBaseUrl/admin/effective-rate-summary').replace(queryParameters: params);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/effective-rate-summary failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['effectiveRateSummary'] as List).cast<Map<String, dynamic>>();
  }

  /// AD-7.3 detail: the raw samples behind one summary row.
  Future<List<Map<String, dynamic>>> fetchEffectiveRateSamples(
    String cardProductId,
    String categoryId,
    String periodMonth,
  ) async {
    final uri = Uri.parse('$apiBaseUrl/admin/effective-rate-summary/$cardProductId/$categoryId/samples')
        .replace(queryParameters: {'periodMonth': periodMonth});
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET effective-rate samples failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['samples'] as List).cast<Map<String, dynamic>>();
  }

  /// AD-8.1: single-query dashboard over v_data_quality_dashboard. See
  /// api/'s GET /admin/data-quality-dashboard doc comment for what's
  /// explicitly NOT here (trend lines, alerting) and why.
  Future<Map<String, dynamic>> fetchDataQualityDashboard() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/data-quality-dashboard'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/data-quality-dashboard failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['dashboard'] as Map<String, dynamic>;
  }

  /// AD-9.1: full anonymization-audit run history.
  Future<List<Map<String, dynamic>>> fetchAnonymizationAuditRuns() async {
    final response =
        await _client.get(Uri.parse('$apiBaseUrl/admin/anonymization-audit-runs'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/anonymization-audit-runs failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['auditRuns'] as List).cast<Map<String, dynamic>>();
  }

  /// AD-9.4: trigger a run now (also used by the nightly cron script and,
  /// separately, the CI gate — see .github/workflows/anonymization-audit.yml,
  /// which calls the SQL function directly rather than through this route).
  Future<Map<String, dynamic>> runAnonymizationAuditNow() async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/anonymization-audit-runs/run'),
      headers: _headers,
    );
    if (response.statusCode != 201) {
      throw AdminApiException('run failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['auditRun'] as Map<String, dynamic>;
  }

  /// UA-5.3/AD-4.3 follow-up (Chunk 35): the parser_patterns CRUD routes
  /// (built in Chunk 31 alongside SMS import) had no console client at all
  /// — sms_parser.js can't parse a single real SMS without at least one
  /// active pattern to match against, so this is what actually makes that
  /// feature reachable end to end, not just its own screen.
  Future<List<Map<String, dynamic>>> fetchParserPatterns({String? channel, bool? isActive}) async {
    final query = {
      'channel': ?channel,
      if (isActive != null) 'isActive': isActive.toString(),
    };
    final uri = Uri.parse('$apiBaseUrl/admin/parser-patterns').replace(queryParameters: query.isEmpty ? null : query);
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/parser-patterns failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['parserPatterns'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> createParserPattern({
    required String channel,
    required String regex,
    required Map<String, dynamic> fieldMap,
    String? issuerId,
    String? senderPattern,
    String? sampleText,
    String? reason,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/parser-patterns'),
      headers: _headers,
      body: jsonEncode({
        'channel': channel,
        'regex': regex,
        'fieldMap': fieldMap,
        'issuerId': ?issuerId,
        'senderPattern': ?senderPattern,
        'sampleText': ?sampleText,
        'reason': ?reason,
      }),
    );
    if (response.statusCode != 201) {
      throw AdminApiException('POST /admin/parser-patterns failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<void> updateParserPattern(
    String id, {
    String? regex,
    Map<String, dynamic>? fieldMap,
    bool? isActive,
    String? reason,
  }) async {
    final response = await _client.put(
      Uri.parse('$apiBaseUrl/admin/parser-patterns/$id'),
      headers: _headers,
      body: jsonEncode({
        'regex': ?regex,
        'fieldMap': ?fieldMap,
        'isActive': ?isActive,
        'reason': ?reason,
      }),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('PUT /admin/parser-patterns/$id failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<void> deleteParserPattern(String id, {String? reason}) async {
    final response = await _client.delete(
      Uri.parse('$apiBaseUrl/admin/parser-patterns/$id'),
      headers: _headers,
      body: jsonEncode({'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('DELETE /admin/parser-patterns/$id failed: ${response.statusCode} ${response.body}');
    }
  }

  // ---- AD-3 scraper source registry -----------------------------------------

  Future<List<Map<String, dynamic>>> fetchSources() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/sources'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/sources failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['sources'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> createSource({
    required String kind,
    required String name,
    required String baseUrl,
    String? issuerId,
    String? tosNote,
    String? reason,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/sources'),
      headers: _headers,
      body: jsonEncode({
        'kind': kind,
        'name': name,
        'baseUrl': baseUrl,
        'issuerId': ?issuerId,
        'tosNote': ?tosNote,
        'reason': ?reason,
      }),
    );
    if (response.statusCode != 201) {
      throw AdminApiException('POST /admin/sources failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-3.2 typed writer: only tos_reviewed/tos_note/is_enabled/crawl
  /// frequency are ever sent — never base_url/kind/name (a "new source"
  /// action, not a review-status update).
  Future<void> updateSource(
    String id, {
    bool? tosReviewed,
    String? tosNote,
    bool? isEnabled,
    int? crawlFrequencyDays,
    String? reason,
  }) async {
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/admin/sources/$id'),
      headers: _headers,
      body: jsonEncode({
        'tosReviewed': ?tosReviewed,
        'tosNote': ?tosNote,
        'isEnabled': ?isEnabled,
        'crawlFrequencyDays': ?crawlFrequencyDays,
        'reason': ?reason,
      }),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('PATCH /admin/sources/$id failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<List<Map<String, dynamic>>> fetchSourcePages(String sourceId) async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/sources/$sourceId/pages'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/sources/$sourceId/pages failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['sourcePages'] as List).cast<Map<String, dynamic>>();
  }

  // ---- AD-4 change detection / diff review -----------------------------------

  Future<List<Map<String, dynamic>>> fetchScrapeRuns() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/scrape-runs'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/scrape-runs failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['scrapeRuns'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> fetchSourcePageSnapshots(String sourcePageId) async {
    final response =
        await _client.get(Uri.parse('$apiBaseUrl/admin/source-pages/$sourcePageId/snapshots'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException(
          'GET /admin/source-pages/$sourcePageId/snapshots failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['snapshots'] as List).cast<Map<String, dynamic>>();
  }
}

class AdminApiException implements Exception {
  final String message;
  AdminApiException(this.message);
  @override
  String toString() => message;
}
