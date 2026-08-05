import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/main.dart';

http.Client _mockClient(Map<String, dynamic> Function(Uri) responder) {
  return MockClient((request) async {
    final body = responder(request.url);
    return http.Response(jsonEncode(body), 200);
  });
}

/// Chunk 10 added a startup session-resume step (sessionInitProvider) that
/// resolves a stored refresh token via a real SharedPreferences instance —
/// overridden to a no-op in every test here so these stay pure UI tests of
/// the already-signed-in-or-not state, not persistence-layer tests (that
/// would need SharedPreferences.setMockInitialValues, a separate concern).
final _noSessionInit = sessionInitProvider.overrideWith((ref) async {});

void main() {
  testWidgets('signed-out (no token) shows the login screen, not the console shell',
      (tester) async {
    await tester.pumpWidget(ProviderScope(overrides: [_noSessionInit], child: const PandaPayConsoleApp()));
    await tester.pumpAndSettle();

    expect(find.text('PandaPay Console'), findsOneWidget);
    expect(find.text('Send OTP'), findsOneWidget);
  });

  testWidgets('a signed-in non-admin token is redirected to the dead end, not the catalogue',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _noSessionInit,
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
          _noSessionInit,
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

  testWidgets('AD-1.1.4: admin moves a draft card to in_review via the status button',
      (tester) async {
    var cardsCallCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _noSessionInit,
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: MockClient((request) async {
                if (request.url.path == '/admin/me') {
                  return http.Response(jsonEncode({'isAdmin': true}), 200);
                }
                if (request.url.path.startsWith('/admin/cards/') && request.method == 'POST') {
                  return http.Response(
                    jsonEncode({
                      'card': {'id': 'card-1', 'status': 'in_review', 'verified_at': null, 'verified_by': null},
                    }),
                    200,
                  );
                }
                cardsCallCount++;
                final status = cardsCallCount == 1 ? 'draft' : 'in_review';
                return http.Response(
                  jsonEncode({
                    'cards': [
                      {
                        'id': 'card-1',
                        'name': 'Test Card',
                        'status': status,
                        'network': 'rupay',
                        'data_version': 1,
                        'is_upi_linkable': true,
                        'verified_at': null,
                        'reward_rules': [
                          {'id': 'rule-1', 'unit': 'cashback_percent', 'rate': 5},
                        ],
                      },
                    ],
                  }),
                  200,
                );
              }),
            ),
          ),
        ],
        child: const PandaPayConsoleApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Test Card — draft'), findsOneWidget);
    await tester.tap(find.text('Test Card — draft'));
    await tester.pumpAndSettle();

    expect(find.text('Move to in_review'), findsOneWidget);
    await tester.tap(find.text('Move to in_review'));
    await tester.pumpAndSettle();

    expect(find.text('Test Card — in_review'), findsOneWidget);
  });

  testWidgets('AD-2.1: admin sees card requests grouped by issuer+product with counts',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _noSessionInit,
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
          _noSessionInit,
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

  testWidgets('Chunk 10: a stored refresh token resumes the session without asking for OTP again',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'pandapay_console.refresh_token': 'stored-refresh-token',
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authApiProvider.overrideWithValue(
            AuthApi(
              authBaseUrl: 'http://test',
              client: MockClient((request) async {
                expect(request.url.path, '/auth/refresh');
                expect(jsonDecode(request.body), {'refresh_token': 'stored-refresh-token'});
                return http.Response(
                  jsonEncode({'access_token': 'refreshed-access-token', 'refresh_token': 'new-refresh-token'}),
                  200,
                );
              }),
            ),
          ),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'refreshed-access-token',
              client: _mockClient((uri) => {'isAdmin': true}),
            ),
          ),
        ],
        child: const PandaPayConsoleApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Never shows the login screen — session resumed silently.
    expect(find.text('Send OTP'), findsNothing);
    expect(find.text('Catalogue'), findsOneWidget);
  });

  testWidgets('AD-4.2: admin sees a policy alert with evidence and heuristic proposals, can approve',
      (tester) async {
    var decideCalled = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _noSessionInit,
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: MockClient((request) async {
                if (request.url.path == '/admin/me') {
                  return http.Response(jsonEncode({'isAdmin': true}), 200);
                }
                if (request.url.path.endsWith('/decide')) {
                  decideCalled = true;
                  return http.Response(jsonEncode({'ok': true}), 200);
                }
                if (request.url.path == '/admin/alerts/alert-1') {
                  return http.Response(
                    jsonEncode({
                      'alert': {'id': 'alert-1', 'card_name': 'HDFC Millennia', 'state': 'open'},
                      'evidence': [
                        {'signal': 'scrape_diff', 'excerpt': '- 5%\n+ 3%'},
                      ],
                      'proposals': [
                        {
                          'model_name': 'heuristic-regex-v1',
                          'model_confidence': 0.4,
                          'proposed_fields': {
                            'rate_percent': {'old': 5, 'new': 3},
                          },
                        },
                      ],
                    }),
                    200,
                  );
                }
                if (request.url.path == '/admin/alerts') {
                  return http.Response(
                    jsonEncode({
                      'alerts': [
                        {
                          'id': 'alert-1',
                          'card_name': 'HDFC Millennia',
                          'field_label': 'reward_tnc page changed',
                          'signal_count': 1,
                          'distinct_signal_kinds': 1,
                          'corroboration_score': '0.250',
                          'state': 'open',
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
    await tester.tap(find.text('Policy Alerts'));
    await tester.pumpAndSettle();

    expect(find.textContaining('HDFC Millennia — reward_tnc page changed'), findsOneWidget);

    await tester.tap(find.textContaining('HDFC Millennia — reward_tnc page changed'));
    await tester.pumpAndSettle();

    expect(find.textContaining('5%'), findsOneWidget);
    expect(find.textContaining('heuristic-regex-v1'), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(decideCalled, isTrue);
  });

  testWidgets('Chunk 10: an invalid stored refresh token falls back to the login screen',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'pandapay_console.refresh_token': 'expired-refresh-token',
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authApiProvider.overrideWithValue(
            AuthApi(
              authBaseUrl: 'http://test',
              client: MockClient((request) async => http.Response(jsonEncode({'error': 'Invalid refresh token'}), 401)),
            ),
          ),
        ],
        child: const PandaPayConsoleApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Send OTP'), findsOneWidget);
  });

  testWidgets('AD-6: admin sees crowdsourced merchants and can override a name', (tester) async {
    var overrideCalled = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _noSessionInit,
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          categoriesProvider.overrideWith((ref) async => const []),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: MockClient((request) async {
                if (request.url.path == '/admin/me') {
                  return http.Response(jsonEncode({'isAdmin': true}), 200);
                }
                if (request.url.path.endsWith('/override')) {
                  overrideCalled = true;
                  return http.Response(jsonEncode({'merchant': {}}), 200);
                }
                if (request.url.path == '/admin/merchants') {
                  return http.Response(
                    jsonEncode({
                      'merchants': [
                        {
                          'id': 'merchant-1',
                          'vpa': 'chaicorner@okaxis',
                          'display_name': 'Chai Corner',
                          'category_name': 'Dining',
                          'confidence': 'medium',
                          'confidence_score': '0.550',
                          'confirmation_count': 3,
                          'distinct_device_count': 3,
                          'is_published': true,
                          'operator_locked': false,
                        },
                      ],
                    }),
                    200,
                  );
                }
                if (request.url.path == '/admin/merchants/merchant-1') {
                  return http.Response(
                    jsonEncode({
                      'merchant': {
                        'id': 'merchant-1',
                        'vpa': 'chaicorner@okaxis',
                        'display_name': 'Chai Corner',
                        'confidence': 'medium',
                        'confidence_score': '0.550',
                        'confirmation_count': 3,
                        'distinct_device_count': 3,
                        'is_published': true,
                        'operator_locked': false,
                      },
                      'locations': <Map<String, dynamic>>[],
                      'contributions': <Map<String, dynamic>>[],
                      'conflicts': <Map<String, dynamic>>[],
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
    await tester.tap(find.text('Merchants'));
    await tester.pumpAndSettle();

    expect(find.text('Chai Corner'), findsOneWidget);

    await tester.tap(find.text('Chai Corner'));
    await tester.pumpAndSettle();

    // Detail dialog opened — the merchant's confidence line is real detail
    // data, not just the list row repeated.
    expect(find.textContaining('Confidence: medium'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'New display name'), 'Chai Corner (Verified)');
    await tester.pump();
    await tester.tap(find.text('Override name'));
    await tester.pumpAndSettle();

    expect(overrideCalled, isTrue);
  });

  testWidgets('AD-6.3: admin resolves a merchant conflict by picking a competing value', (tester) async {
    var resolveCalled = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _noSessionInit,
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: MockClient((request) async {
                if (request.url.path == '/admin/me') {
                  return http.Response(jsonEncode({'isAdmin': true}), 200);
                }
                if (request.url.path.endsWith('/resolve')) {
                  resolveCalled = true;
                  return http.Response(jsonEncode({'conflict': {}}), 200);
                }
                if (request.url.path == '/admin/merchant-conflicts') {
                  return http.Response(
                    jsonEncode({
                      'conflicts': [
                        {
                          'id': 'conflict-1',
                          'vpa': 'chaicorner@okaxis',
                          'merchant_display_name': 'Chai Corner',
                          'field': 'display_name',
                          'competing_values': [
                            {'value': 'Chai Corner', 'count': 3},
                            {'value': 'Chai Point', 'count': 2},
                          ],
                          'state': 'pending',
                        },
                      ],
                    }),
                    200,
                  );
                }
                if (request.url.path == '/admin/abuse-signals') {
                  return http.Response(jsonEncode({'abuseSignals': <Map<String, dynamic>>[]}), 200);
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
    await tester.tap(find.text('Conflicts'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Chai Corner (3×)'), findsOneWidget);

    await tester.tap(find.textContaining('Chai Corner (3×)'));
    await tester.pumpAndSettle();

    expect(resolveCalled, isTrue);
  });

  testWidgets('AD-7: admin sees acceptance data and effective-rate divergence with a linked alert',
      (tester) async {
    var publishCalled = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _noSessionInit,
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: MockClient((request) async {
                if (request.url.path == '/admin/me') {
                  return http.Response(jsonEncode({'isAdmin': true}), 200);
                }
                if (request.url.path.endsWith('/publish')) {
                  publishCalled = true;
                  return http.Response(jsonEncode({'acceptanceSummary': {}}), 200);
                }
                if (request.url.path == '/admin/acceptance-summary') {
                  return http.Response(
                    jsonEncode({
                      'acceptanceSummary': [
                        {
                          'merchant_id': 'merchant-1',
                          'vpa': 'store@okamex',
                          'display_name': 'Test Store',
                          'network': 'amex',
                          'rail': 'swipe',
                          'accepted_count': 2,
                          'declined_count': 8,
                          'confidence_score': '0.600',
                          'is_published': false,
                        },
                      ],
                    }),
                    200,
                  );
                }
                if (request.url.path == '/admin/effective-rate-summary') {
                  return http.Response(
                    jsonEncode({
                      'effectiveRateSummary': [
                        {
                          'card_product_id': 'card-1',
                          'category_id': 'cat-1',
                          'period_month': '2026-08-01',
                          'sample_count': 12,
                          'distinct_devices': 9,
                          'observed_rate_mean': '4.0000',
                          'published_rate': '5.0000',
                          'divergence_pct': '-20.0000',
                          'observed_cap_ceiling': '800.00',
                          'published_cap_value': '1000.00',
                          'is_divergent': true,
                          'card_name': 'HDFC Millennia',
                          'category_name': 'Online',
                          'linked_alert_id': 'alert-1',
                          'linked_alert_state': 'open',
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
    await tester.tap(find.text('Acceptance & Rates'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Test Store — amex / swipe'), findsOneWidget);

    await tester.tap(find.text('Publish'));
    await tester.pumpAndSettle();
    expect(publishCalled, isTrue);

    await tester.tap(find.text('Effective rate monitor'));
    await tester.pumpAndSettle();

    expect(find.textContaining('HDFC Millennia — Online'), findsOneWidget);
    expect(find.text('Alert: open'), findsOneWidget);
  });

  testWidgets('AD-8: admin sees the data quality dashboard snapshot', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _noSessionInit,
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: MockClient((request) async {
                if (request.url.path == '/admin/me') {
                  return http.Response(jsonEncode({'isAdmin': true}), 200);
                }
                if (request.url.path == '/admin/data-quality-dashboard') {
                  return http.Response(
                    jsonEncode({
                      'dashboard': {
                        'merchants_total': '4',
                        'merchants_published': '1',
                        'merchants_high_conf': '0',
                        'locations_total': '2',
                        'alerts_open': '1',
                        'error_reports_pending': '0',
                        'card_requests_pending': '3',
                        'conflicts_pending': '0',
                        'scrape_failures_7d': '0',
                        'cards_published': '20',
                        'cards_stale_180d': '0',
                      },
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
    await tester.tap(find.text('Data Quality'));
    await tester.pumpAndSettle();

    expect(find.text('Data quality snapshot'), findsOneWidget);
    expect(find.text('20'), findsOneWidget); // cards_published
    expect(find.text('1'), findsNWidgets(2)); // merchants_published + alerts_open both 1
  });

  testWidgets('AD-9: admin sees the latest anonymization audit result and can run a new one',
      (tester) async {
    var runCalled = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _noSessionInit,
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: MockClient((request) async {
                if (request.url.path == '/admin/me') {
                  return http.Response(jsonEncode({'isAdmin': true}), 200);
                }
                if (request.url.path.endsWith('/run')) {
                  runCalled = true;
                  return http.Response(
                    jsonEncode({
                      'auditRun': {
                        'id': 'run-2',
                        'run_by': 'ci',
                        'checks_total': 6,
                        'checks_failed': 0,
                        'findings': <Map<String, dynamic>>[],
                        'passed': true,
                        'git_sha': 'manual-run',
                        'ran_at': '2026-08-06T00:00:00Z',
                      },
                    }),
                    201,
                  );
                }
                if (request.url.path == '/admin/anonymization-audit-runs') {
                  return http.Response(
                    jsonEncode({
                      'auditRuns': [
                        {
                          'id': 'run-1',
                          'run_by': 'ci',
                          'checks_total': 6,
                          'checks_failed': 1,
                          'findings': [
                            {'check': 'no_identity_columns', 'violations': 1},
                          ],
                          'passed': false,
                          'git_sha': 'abc123',
                          'ran_at': '2026-08-05T12:00:00Z',
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
    // Chunk 35: the rail grew to 10 destinations and is now genuinely
    // scrollable on a short viewport (see main.dart) — this one needs
    // scrolling into view before it's tappable, unlike the earlier tabs.
    await tester.scrollUntilVisible(find.text('Anonymization Audit'), 100);
    await tester.tap(find.text('Anonymization Audit'));
    await tester.pumpAndSettle();

    expect(find.text('Latest: FAILED'), findsOneWidget);
    expect(find.textContaining('no_identity_columns (1)'), findsOneWidget);

    await tester.tap(find.text('Run now'));
    await tester.pumpAndSettle();
    expect(runCalled, isTrue);
  });

  testWidgets('Chunk 35: admin sees parser patterns and can add a new one',
      (tester) async {
    var createCalled = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _noSessionInit,
          accessTokenProvider.overrideWith((ref) => 'fake-admin-token'),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://test',
              accessToken: 'fake-admin-token',
              client: MockClient((request) async {
                if (request.url.path == '/admin/me') {
                  return http.Response(jsonEncode({'isAdmin': true}), 200);
                }
                if (request.url.path == '/admin/parser-patterns' && request.method == 'POST') {
                  createCalled = true;
                  return http.Response(jsonEncode({'parserPattern': {}}), 201);
                }
                if (request.url.path == '/admin/parser-patterns') {
                  return http.Response(
                    jsonEncode({
                      'parserPatterns': [
                        {
                          'id': 'pp-1',
                          'issuer_id': null,
                          'channel': 'sms',
                          'sender_pattern': 'HDFCBK',
                          'regex': r'spent Rs\.(\d+)',
                          'field_map': {'amount': 1},
                          'version': 1,
                          'is_active': true,
                          'sample_text': 'You spent Rs.500',
                          'success_count': 3,
                          'failure_count': 1,
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
    await tester.scrollUntilVisible(find.text('Parser Patterns'), 100);
    await tester.tap(find.text('Parser Patterns'));
    await tester.pumpAndSettle();

    expect(find.textContaining('sms · HDFCBK · v1'), findsOneWidget);
    expect(find.textContaining('3 matched · 1 failed'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Regex'), r'debited Rs\.(\d+)');
    await tester.tap(find.text('Add pattern'));
    await tester.pumpAndSettle();
    expect(createCalled, isTrue);
  });
}
