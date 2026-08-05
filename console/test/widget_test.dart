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
}
