import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/main.dart';

http.Client _mockClient(Map<String, dynamic> Function(Uri) responder) {
  return MockClient((request) async {
    final body = responder(request.url);
    return http.Response(jsonEncode(body), 200);
  });
}

void main() {
  testWidgets('signed-out (no token) shows the login screen, not the console shell',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: PandaPayConsoleApp()));
    await tester.pumpAndSettle();

    expect(find.text('PandaPay Console'), findsOneWidget);
    expect(find.text('Send OTP'), findsOneWidget);
  });

  testWidgets('a signed-in non-admin token is redirected to the dead end, not the catalogue',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'fake-non-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-non-admin-token',
              client: _mockClient((uri) => {'isAdmin': false}),
            ),
          ),
        ],
        child: const PandaPayConsoleApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('This console is internal-only.'), findsOneWidget);
  });

  testWidgets('a signed-in admin token reaches the catalogue screen with real card data',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: _mockClient((uri) {
                if (uri.path == '/admin/me') return {'isAdmin': true};
                return {
                  'cards': [
                    {
                      'id': 'card-1',
                      'name': 'Test Card',
                      'status': 'draft',
                      'network': 'rupay',
                      'data_version': 1,
                      'is_upi_linkable': true,
                      'reward_rules': [
                        {'id': 'rule-1', 'unit': 'cashback_percent', 'rate': 5},
                      ],
                    },
                  ],
                };
              }),
            ),
          ),
        ],
        child: const PandaPayConsoleApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Test Card — draft'), findsOneWidget);
  });

  testWidgets('AD-2.1: admin sees card requests grouped by issuer+product with counts',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: _mockClient((uri) {
                if (uri.path == '/admin/me') return {'isAdmin': true};
                if (uri.path == '/admin/card-requests') {
                  return {
                    'requestGroups': [
                      {
                        'issuer_name': 'IDFC First Bank',
                        'product_name': 'FIRST Millennia',
                        'network_guess': 'visa',
                        'total_requests': 15,
                        'distinct_reporters': 2,
                      },
                    ],
                  };
                }
                return {'cards': <Map<String, dynamic>>[]};
              }),
            ),
          ),
        ],
        child: const PandaPayConsoleApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Card Requests'));
    await tester.pumpAndSettle();

    expect(find.text('IDFC First Bank — FIRST Millennia'), findsOneWidget);
    expect(find.text('15 requests · 2 reporters · visa'), findsOneWidget);
  });

  testWidgets('AD-2.2: admin sees error reports with shown vs claimed and can approve',
      (tester) async {
    var approveCalled = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: MockClient((request) async {
                if (request.url.path == '/admin/me') {
                  return http.Response(jsonEncode({'isAdmin': true}), 200);
                }
                if (request.url.path.endsWith('/approve')) {
                  approveCalled = true;
                  return http.Response(jsonEncode({'changeId': 'change-1'}), 200);
                }
                if (request.url.path == '/admin/error-reports') {
                  return http.Response(
                    jsonEncode({
                      'errorReports': [
                        {
                          'id': 'report-1',
                          'card_name': 'SBI Cashback Card',
                          'field_path': 'reward_rules.rule-1.rate',
                          'shown_value': '5',
                          'claimed_value': '4.5',
                          'source_url': 'https://example.com',
                          'state': 'pending',
                        },
                      ],
                    }),
                    200,
                  );
                }
                return http.Response(jsonEncode({'cards': <Map<String, dynamic>>[]}), 200);
              }),
            ),
          ),
        ],
        child: const PandaPayConsoleApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Error Reports'));
    await tester.pumpAndSettle();

    expect(find.text('SBI Cashback Card — reward_rules.rule-1.rate'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('4.5'), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(approveCalled, isTrue);
  });
}
