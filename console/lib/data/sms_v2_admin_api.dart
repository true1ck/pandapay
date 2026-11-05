import 'admin_api.dart';

class SmsV2AdminApi {
  const SmsV2AdminApi(this.admin);
  final AdminApi admin;

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) => admin.smsV2Request(method, '/admin/sms/v2/$path', body: body);

  Future<List<Map<String, dynamic>>> rules() async =>
      _rows((await request('GET', 'rules'))['rules']);
  Future<Map<String, dynamic>> detail(String id) =>
      request('GET', 'rules/${Uri.encodeComponent(id)}');
  Future<Map<String, dynamic>> save(Map<String, dynamic> rule) => request(
    'PUT',
    'rules/${Uri.encodeComponent(rule['id'] as String)}/draft',
    body: rule,
  );
  Future<Map<String, dynamic>> candidate(
    String id,
    int version,
    String cohort,
  ) => request(
    'GET',
    'rules/${Uri.encodeComponent(id)}/candidate?version=$version&cohort=$cohort',
  );
  Future<Map<String, dynamic>> publish(
    String id,
    int version,
    String cohort,
    Map<String, dynamic> report,
  ) => request(
    'POST',
    'rules/${Uri.encodeComponent(id)}/publish',
    body: {'version': version, 'cohort': cohort, 'goldenReport': report},
  );
  Future<Map<String, dynamic>> pause(String id, int version, String reason) =>
      request(
        'POST',
        'rules/${Uri.encodeComponent(id)}/pause?version=$version',
        body: {'reason': reason},
      );
  Future<Map<String, dynamic>> rollback(
    String id,
    int version,
    String reason,
  ) => request(
    'POST',
    'rules/${Uri.encodeComponent(id)}/rollback',
    body: {'toVersion': version, 'reason': reason},
  );
  Future<List<Map<String, dynamic>>> templates() async =>
      _rows((await request('GET', 'templates'))['templates']);
  Future<Map<String, dynamic>> templateDraft(String hash) =>
      request('POST', 'templates/${Uri.encodeComponent(hash)}/draft');
  Future<Map<String, dynamic>> rejectTemplate(
    String hash,
    String reason,
    String? note,
  ) => request(
    'POST',
    'templates/${Uri.encodeComponent(hash)}/reject',
    body: {'reason': reason, 'note': ?note},
  );
  Future<List<Map<String, dynamic>>> correctionGroups() async =>
      _rows((await request('GET', 'corrections?groupBy=template'))['groups']);
  Future<Map<String, dynamic>> decide(
    String id,
    String decision,
    String reason,
  ) => request(
    'POST',
    'corrections/${Uri.encodeComponent(id)}/decision',
    body: {'decision': decision, 'reason': reason},
  );
  Future<Map<String, dynamic>> prepareExample(
    String id,
    Map<String, dynamic> example,
  ) => request(
    'PUT',
    'corrections/${Uri.encodeComponent(id)}/example',
    body: example,
  );
  Future<Map<String, dynamic>> exportCase(String id) =>
      request('GET', 'corrections/${Uri.encodeComponent(id)}/export');
  Future<Map<String, dynamic>> metrics() => request('GET', 'metrics');
  Future<List<Map<String, dynamic>>> bundles() async =>
      _rows((await request('GET', 'bundles'))['bundles']);
  Future<Map<String, dynamic>> categories() => request('GET', 'category-rules');
  Future<Map<String, dynamic>> saveCategory(
    String id,
    Map<String, dynamic> rule,
  ) => request(
    'PUT',
    'category-rules/${Uri.encodeComponent(id)}/draft',
    body: rule,
  );
  Future<Map<String, dynamic>> categoryCandidates(
    String id,
    int revision,
  ) => request(
    'GET',
    'category-rules/${Uri.encodeComponent(id)}/candidate?revision=$revision',
  );
  Future<Map<String, dynamic>> publishCategory(
    String id,
    int revision,
    String reason,
    Map<String, dynamic> reports,
  ) => request(
    'POST',
    'category-rules/${Uri.encodeComponent(id)}/publish',
    body: {'revision': revision, 'reason': reason, 'goldenReports': reports},
  );

  // ---- Controls for everything the loop does (learning-loop B7).
  Future<Map<String, dynamic>> requeueTemplate(String hash, String reason) =>
      request(
        'POST',
        'templates/${Uri.encodeComponent(hash)}/requeue',
        body: {'reason': reason},
      );
  Future<Map<String, dynamic>> blockTemplate(String hash, String reason) =>
      request(
        'POST',
        'templates/${Uri.encodeComponent(hash)}/block',
        body: {'reason': reason},
      );
  Future<Map<String, dynamic>> askAgain(String merchantKey, String reason) =>
      request(
        'POST',
        'merchant-suggestions/${Uri.encodeComponent(merchantKey)}/ask-again',
        body: {'reason': reason},
      );
  Future<Map<String, dynamic>> learningReporters({int days = 7}) =>
      request('GET', 'learning/reporters?days=$days');
  Future<List<Map<String, dynamic>>> audit({int limit = 50}) async =>
      _rows((await request('GET', 'audit?limit=$limit'))['entries']);

  // ---- Shop names (merchant aliases, learning-loop A8).
  Future<Map<String, dynamic>> saveAlias(String id, Map<String, dynamic> alias) =>
      request('PUT', 'merchant-aliases/${Uri.encodeComponent(id)}/draft', body: alias);
  Future<Map<String, dynamic>> aliasCandidates(String id, int revision) => request(
    'GET',
    'merchant-aliases/${Uri.encodeComponent(id)}/candidate?revision=$revision',
  );
  Future<Map<String, dynamic>> publishAlias(
    String id,
    int revision,
    String reason,
    Map<String, dynamic> reports,
  ) => request(
    'POST',
    'merchant-aliases/${Uri.encodeComponent(id)}/publish',
    body: {'revision': revision, 'reason': reason, 'goldenReports': reports},
  );

  // ---- Learning page (learning-loop A7): counted, k-anonymous candidates.
  Future<Map<String, dynamic>> learningSummary({int days = 30}) =>
      request('GET', 'learning/summary?days=$days');
  Future<Map<String, dynamic>> learningCategories({int days = 90}) =>
      request('GET', 'learning/categories?days=$days');
  Future<Map<String, dynamic>> learningMerchantNames({int days = 90}) =>
      request('GET', 'learning/merchant-names?days=$days');
  Future<Map<String, dynamic>> learningUncategorised({int days = 90}) =>
      request('GET', 'learning/uncategorised?days=$days');
  Future<Map<String, dynamic>> recordLearningDecision({
    required String kind,
    required String merchantKey,
    required String value,
    required String decision,
    required String reason,
  }) => request(
    'POST',
    'learning/decisions',
    body: {
      'kind': kind,
      'merchantKey': merchantKey,
      'value': value,
      'decision': decision,
      'reason': reason,
    },
  );

  // ---- Settings and per-user limits (learning-loop A4).
  Future<List<Map<String, dynamic>>> settings() async =>
      _rows((await request('GET', 'settings'))['settings']);
  Future<Map<String, dynamic>> saveSetting(
    String key,
    Object? value,
    String reason,
    String? expectedUpdatedAt,
  ) => request(
    'PUT',
    'settings/${Uri.encodeComponent(key)}',
    body: {
      'value': value,
      'reason': reason,
      'expectedUpdatedAt': expectedUpdatedAt,
    },
  );
  Future<List<Map<String, dynamic>>> userLimits() async =>
      _rows((await request('GET', 'user-limits'))['limits']);
  Future<Map<String, dynamic>> saveUserLimit(
    String profileId,
    String key,
    int value,
    DateTime expiresAt,
    String reason,
  ) => request(
    'PUT',
    'user-limits/${Uri.encodeComponent(profileId)}/${Uri.encodeComponent(key)}',
    body: {
      'value': value,
      'expiresAt': expiresAt.toUtc().toIso8601String(),
      'reason': reason,
    },
  );
  Future<Map<String, dynamic>> deleteUserLimit(
    String profileId,
    String key,
    String reason,
  ) => request(
    'DELETE',
    'user-limits/${Uri.encodeComponent(profileId)}/${Uri.encodeComponent(key)}',
    body: {'reason': reason},
  );

  static List<Map<String, dynamic>> _rows(Object? rows) => [
    for (final row in rows as List? ?? const [])
      (row as Map).cast<String, dynamic>(),
  ];
}
