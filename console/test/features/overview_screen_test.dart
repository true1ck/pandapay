import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/data/private_admin_auth.dart';
import 'package:pandapay_console/main.dart';

const _ownerPermissions = [
  'catalogue.read',
  'reference.read',
  'operations.read',
  'review.write',
  'catalogue.edit',
  'support.resolve',
  'scraper.configure',
  'scraper.run',
  'learning.read',
  'catalogue.publish',
  'learning.publish',
  'referrals.control',
  'admin.audit.read',
  'admin.audit.run',
  'support.evidence.read',
  'financial.evidence.read',
  'referrals.read',
];

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

Future<List<String>> _pumpConsole(
  WidgetTester tester, {
  required Map<String, dynamic> admin,
}) async {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final requested = <String>[];
  final client = MockClient((request) async {
    final path = request.url.path;
    requested.add(path);
    return switch (path) {
      '/admin/me' => _json({'isAdmin': true}),
      '/admin/data-quality-dashboard' => _json({
        'dashboard': {
          'alerts_open': '2',
          'error_reports_pending': '1',
          'support_tickets_pending': '0',
          'conflicts_pending': '0',
          'card_requests_pending': '3',
          'scrape_failures_7d': '1',
          'cards_stale_180d': '0',
          'cards_published': '20',
          'merchants_total': '4',
          'merchants_published': '1',
          'merchants_high_conf': '0',
          'locations_total': '2',
        },
      }),
      '/admin/anonymization-audit-runs' => _json({
        'auditRuns': [
          {
            'passed': true,
            'checks_total': 12,
            'checks_failed': 0,
            'ran_at': DateTime.now()
                .subtract(const Duration(hours: 2))
                .toIso8601String(),
          },
        ],
      }),
      '/admin/sms-rules/category-proposals' => _json({
        'proposals': [
          {'status': null},
          {'status': 'approved'},
        ],
      }),
      '/admin/sms-rules/parser-proposals' => _json({'proposals': []}),
      '/admin/alerts' => _json({'alerts': []}),
      // The learning-loop tiles: nothing waiting, AI drafting healthy.
      '/admin/sms/v2/learning/summary' => _json({
        'candidates': {'total': 0},
      }),
      '/admin/sms/v2/settings' => _json({'settings': []}),
      '/admin/sms/v2/metrics' => _json({'ai': []}),
      _ => _json({'cards': []}),
    };
  });

  final auth = PrivateAdminAuthApi()..administrator = admin;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionInitProvider.overrideWith((ref) async {}),
        accessTokenProvider.overrideWith((ref) => 'console-browser-session'),
        authApiProvider.overrideWithValue(auth),
        adminApiProvider.overrideWithValue(
          AdminApi(
            apiBaseUrl: 'http://overview.invalid',
            accessToken: 'console-browser-session',
            client: client,
          ),
        ),
      ],
      child: const PandaPayConsoleApp(),
    ),
  );
  await tester.pumpAndSettle();
  return requested;
}

void main() {
  testWidgets('owner lands on an accurate overview and a tile opens its queue', (
    tester,
  ) async {
    await _pumpConsole(
      tester,
      admin: {
        'email': 'owner@pandapay.test',
        'role': 'owner',
        'permissions': _ownerPermissions,
        'environment': 'local',
      },
    );

    expect(find.text('LOCAL WORKSPACE'), findsOneWidget);
    // 2 alerts + 1 error report + 1 SMS review + 0 tickets + 0 conflicts
    // + 3 card requests.
    expect(find.text('7'), findsOneWidget);
    expect(find.text('awaiting review'), findsOneWidget);
    expect(find.text('1 category'), findsOneWidget);
    expect(find.text('Passed'), findsOneWidget);
    expect(find.textContaining('PRODUCTION'), findsNothing);

    await tester.tap(find.text('Open policy alerts'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Review detected issuer policy changes and inspect the evidence behind each alert.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'production is flagged everywhere and a readonly role sees only what it can open',
    (tester) async {
      final requested = await _pumpConsole(
        tester,
        admin: {
          'email': 'viewer@pandapay.test',
          'role': 'readonly',
          'permissions': [
            'catalogue.read',
            'reference.read',
            'operations.read',
          ],
          'environment': 'production',
        },
      );

      expect(
        find.text('PRODUCTION · Changes here affect live PandaPay users.'),
        findsOneWidget,
      );
      expect(find.text('PRODUCTION WORKSPACE'), findsOneWidget);

      // Navigation hides screens the role cannot read.
      expect(find.text('Policy Alerts'), findsOneWidget);
      expect(find.text('Error Reports'), findsNothing);
      expect(find.text('SMS Rule Approvals'), findsNothing);
      expect(find.text('Anonymization Audit'), findsNothing);
      expect(find.text('Referral Operations'), findsNothing);

      // Overview tiles follow the same rule, and no refused request is made.
      expect(find.text('Open policy alerts'), findsOneWidget);
      expect(find.text('Pending error reports'), findsNothing);
      expect(find.text('SMS rules to review'), findsNothing);
      expect(requested, isNot(contains('/admin/sms-rules/category-proposals')));
      expect(requested, isNot(contains('/admin/anonymization-audit-runs')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a session without an environment is treated as production', (
    tester,
  ) async {
    await _pumpConsole(
      tester,
      admin: {'role': 'owner', 'permissions': _ownerPermissions},
    );
    expect(
      find.text(
        'The gateway did not report its environment. Treat this as production.',
      ),
      findsOneWidget,
    );
  });
}
