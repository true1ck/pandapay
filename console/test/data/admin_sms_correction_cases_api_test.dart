import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/data/admin_api.dart';

void main() {
  test('fetches explicit correction cases from the feedback-events route',
      () async {
    Uri? requested;
    final api = AdminApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'admin-token',
      client: MockClient((request) async {
        requested = request.url;
        expect(request.headers['authorization'], 'Bearer admin-token');
        return http.Response(
          jsonEncode({
            'correctionCases': [
              {
                'eventId': '11111111-2222-4333-8444-555555555555',
                'factKey': '${'a' * 64}:0',
                'correctionKind': 'misclassified_category',
                'decisionOrigin': 'ai',
                'decisionRuleId': null,
                'redactedPattern': 'Spent {AMOUNT} at {MERCHANT}',
                'originalDecision': {
                  'kind': 'transaction',
                  'origin': 'ai',
                  'ruleId': null,
                  'fields': {'categorySlug': 'travel'},
                },
                'correctedFields': {'categorySlug': 'dining'},
                'categorySlug': 'dining',
                'originalCategorySlug': 'travel',
                'commitmentCategory': null,
                'support': {'users': 7, 'messages': 23},
                'disagreement': {'users': 1},
                'supersededAt': null,
                'supersededByEventId': null,
              },
            ],
          }),
          200,
        );
      }),
    );

    final rows = await api.fetchSmsCorrectionCases();
    expect(requested?.path, '/admin/sms-learning/feedback-events');
    expect(requested?.queryParameters['limit'], '100');
    final row = rows.single;
    expect(row['correctionKind'], 'misclassified_category');
    expect(row['decisionOrigin'], 'ai');
    expect((row['support'] as Map)['users'], 7);
    expect(row['supersededAt'], isNull);
  });

  test('surfaces the API error when the endpoint is unavailable', () async {
    final api = AdminApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'admin-token',
      client: MockClient((request) async =>
          http.Response('{"error":"not_found"}', 404)),
    );

    await expectLater(
      api.fetchSmsCorrectionCases(),
      throwsA(isA<AdminApiException>()),
    );
  });

  test('posts correction case review with decision and required reason', () async {
    http.Request? requested;
    final api = AdminApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'admin-token',
      client: MockClient((request) async {
        requested = request;
        return http.Response('{}', 200);
      }),
    );

    await api.reviewSmsCorrectionCase(
      eventId: '11111111-2222-4333-8444-555555555555',
      decision: 'approved',
      reason: 'Evidence matches the correction',
    );

    expect(requested?.method, 'POST');
    expect(requested?.url.path,
        '/admin/sms-learning/feedback-events/11111111-2222-4333-8444-555555555555/review');
    expect(jsonDecode(requested!.body), {
      'decision': 'approved',
      'reason': 'Evidence matches the correction',
    });
  });
}
