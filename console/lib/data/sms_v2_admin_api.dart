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
  static List<Map<String, dynamic>> _rows(Object? rows) => [
    for (final row in rows as List? ?? const [])
      (row as Map).cast<String, dynamic>(),
  ];
}
