import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/data/admin_api.dart';

void main() {
  test('fetches privacy-safe referral operations status', () async {
    Uri? requested;
    final api = AdminApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'admin-token',
      client: MockClient((request) async {
        requested = request.url;
        expect(request.headers['authorization'], 'Bearer admin-token');
        return http.Response(
          jsonEncode({
            'operations': {
              'access': {'admissionMode': 'open'},
              'campaign': null,
              'workers': [],
              'outbox': {'countsByState': {}, 'oldestPendingAgeSeconds': 0},
              'activeHolds': [],
              'recentAudit': [],
            },
          }),
          200,
        );
      }),
    );

    final result = await api.fetchReferralOperations();
    expect(requested?.path, '/admin/referrals/operations');
    expect(result['access'], {'admissionMode': 'open'});
    expect(result['activeHolds'], isEmpty);
  });

  test(
    'sends typed reason-required hold request to the scope endpoint',
    () async {
      http.Request? request;
      final api = AdminApi(
        apiBaseUrl: 'https://api.test',
        accessToken: 'admin-token',
        client: MockClient((value) async {
          request = value;
          return http.Response(
            jsonEncode({
              'hold': {'scope': 'fulfillment', 'paused': true},
            }),
            200,
          );
        }),
      );

      final result = await api.setReferralHold(
        scope: 'fulfillment',
        paused: true,
        reason: 'delivery incident',
      );
      expect(request?.method, 'PUT');
      expect(request?.url.path, '/admin/referrals/holds/fulfillment');
      expect(jsonDecode(request!.body), {
        'paused': true,
        'reason': 'delivery incident',
      });
      expect(result['paused'], isTrue);
    },
  );

  test(
    'surfaces a rejected hold instead of pretending it was applied',
    () async {
      final api = AdminApi(
        apiBaseUrl: 'https://api.test',
        accessToken: 'admin-token',
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'error': 'campaign_unavailable'}), 409),
        ),
      );

      await expectLater(
        api.setReferralHold(
          scope: 'enrollment',
          paused: true,
          reason: 'incident response',
        ),
        throwsA(isA<AdminApiException>()),
      );
    },
  );
}
