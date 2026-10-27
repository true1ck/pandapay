import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/data/admin_api.dart';

void main() {
  test('loads aggregate category proposals from the admin endpoint', () async {
    Uri? requested;
    final api = AdminApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'admin-token',
      client: MockClient((request) async {
        requested = request.url;
        expect(request.headers['authorization'], 'Bearer admin-token');
        return http.Response(
          jsonEncode({
            'proposals': [
              {
                'merchant_key': 'EXAMPLE CAFE',
                'category_slug': 'food_dining',
                'support_count': 12,
                'agreement_rate': 0.95,
                'status': null,
              },
            ],
          }),
          200,
        );
      }),
    );

    final rows = await api.fetchSmsCategoryProposals();
    expect(requested?.path, '/admin/sms-rules/category-proposals');
    expect(rows.single['merchant_key'], 'EXAMPLE CAFE');
    expect(rows.single['support_count'], 12);
  });

  test('reviews category proposal with reason and decision', () async {
    http.Request? sent;
    final api = AdminApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'admin-token',
      client: MockClient((request) async {
        sent = request;
        return http.Response('{"ok":true}', 200);
      }),
    );

    await api.reviewSmsCategoryProposal(
      merchantKey: 'EXAMPLE CAFE',
      categorySlug: 'food_dining',
      decision: 'approved',
      reason: 'Evidence reviewed',
    );
    expect(sent?.url.path, '/admin/sms-rules/category-proposals/review');
    expect(sent?.headers['authorization'], 'Bearer admin-token');
    expect(jsonDecode(sent!.body), {
      'merchantKey': 'EXAMPLE CAFE',
      'categorySlug': 'food_dining',
      'decision': 'approved',
      'reason': 'Evidence reviewed',
    });
  });

  test('loads parser proposals with the hash bound to the reviewed rule', () async {
    final hash = List.filled(64, 'a').join();
    Uri? requested;
    final api = AdminApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'admin-token',
      client: MockClient((request) async {
        requested = request.url;
        return http.Response(
          jsonEncode({
            'proposals': [
              {
                'candidateId': 'candidate-1',
                'currentRuleSha256': hash,
                'stageMetrics': {'precision': 0.99},
              },
            ],
          }),
          200,
        );
      }),
    );

    final rows = await api.fetchSmsParserProposals();
    expect(requested?.path, '/admin/sms-rules/parser-proposals');
    expect(rows.single['currentRuleSha256'], hash);
  });

  test('reviews parser proposal using candidate id and exact rule hash', () async {
    final hash = List.filled(64, 'b').join();
    http.Request? sent;
    final api = AdminApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'admin-token',
      client: MockClient((request) async {
        sent = request;
        return http.Response('{"ok":true}', 200);
      }),
    );

    await api.reviewSmsParserProposal(
      candidateId: 'candidate-1',
      ruleSha256: hash,
      decision: 'rejected',
      reason: 'Insufficient evidence',
    );
    expect(sent?.url.path, '/admin/sms-rules/parser-proposals/review');
    expect(jsonDecode(sent!.body), {
      'candidateId': 'candidate-1',
      'ruleSha256': hash,
      'decision': 'rejected',
      'reason': 'Insufficient evidence',
    });
  });
}
