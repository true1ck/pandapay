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
                'merchant_key': 'ACME SHOP',
                'sender_key': 'AD-HDFCBK',
                'context_key': 'GROCERY',
                'fact_family': 'posted_movement',
                'category_slug': 'groceries',
                'support_count': 12,
                'agreement_rate': 0.95,
                'status': null,
                'redacted_pattern': 'GROCERY purchase at {MERCHANT} for {AMOUNT}',
                'redacted_samples': ['GROCERY purchase at {MERCHANT} for {AMOUNT}'],
              },
            ],
          }),
          200,
        );
      }),
    );

    final rows = await api.fetchSmsCategoryProposals();
    expect(requested?.path, '/admin/sms-rules/category-proposals');
    expect(rows.single['merchant_key'], 'ACME SHOP');
    expect(rows.single['sender_key'], 'AD-HDFCBK');
    expect(rows.single['context_key'], 'GROCERY');
    expect(rows.single['fact_family'], 'posted_movement');
    expect(rows.single['support_count'], 12);
    expect(rows.single['redacted_pattern'], 'GROCERY purchase at {MERCHANT} for {AMOUNT}');
    expect(rows.single['redacted_samples'], [
      'GROCERY purchase at {MERCHANT} for {AMOUNT}',
    ]);
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
      merchantKey: 'ACME SHOP',
      senderKey: 'AD-HDFCBK',
      contextKey: 'GROCERY',
      factFamily: 'posted_movement',
      categorySlug: 'groceries',
      decision: 'approved',
      reason: 'Evidence reviewed',
    );
    expect(sent?.url.path, '/admin/sms-rules/category-proposals/review');
    expect(sent?.headers['authorization'], 'Bearer admin-token');
    expect(jsonDecode(sent!.body), {
      'merchantKey': 'ACME SHOP',
      'senderKey': 'AD-HDFCBK',
      'contextKey': 'GROCERY',
      'factFamily': 'posted_movement',
      'categorySlug': 'groceries',
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
