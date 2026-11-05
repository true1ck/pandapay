import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/app/admin_identity.dart';
import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/features/system/system_status_screen.dart';

Map<String, Object?> _status() {
  final now = DateTime.now().toUtc();
  String ago(Duration d) => now.subtract(d).toIso8601String();
  return {
    'version': 1,
    'generatedAt': now.toIso8601String(),
    'release': {
      'source': 'checkout',
      'commit': '33ee22fc45587a7d0c1e2f3a4b5c6d7e8f901234',
      'branch': 'codex/ios-shortcuts-prototype',
      'startedAt': ago(const Duration(hours: 3)),
      'runtime': 'Node 22.11.0',
    },
    'database': {'ok': true, 'latencyMs': 2, 'version': 'PostgreSQL 18.4'},
    'services': [
      {
        'key': 'api',
        'name': 'Customer API',
        'purpose': 'Serves the app.',
        'health': 'probe',
      },
      {
        'key': 'auth',
        'name': 'Auth service',
        'purpose': 'Sign-in.',
        'health': 'probe',
      },
      {
        'key': 'postgres',
        'name': 'Product database',
        'purpose': 'PostgreSQL.',
        'health': 'database',
      },
      {
        'key': 'backup',
        'name': 'Backup',
        'purpose': 'Nightly.',
        'health': 'job:backup',
      },
      {
        'key': 'rewards-worker',
        'name': 'Rewards worker',
        'purpose': 'Rewards.',
        'health': 'none',
        'runs': 'always_on',
      },
      {
        'key': 'db-migrate',
        'name': 'Database migrations',
        'purpose': 'Migrations.',
        'health': 'none',
        'runs': 'per_deploy',
      },
      {
        'key': 'admin-api',
        'name': 'Admin API',
        'purpose': 'This console.',
        'health': 'self',
      },
    ],
    'checks': [
      {
        'key': 'api',
        'host': 'api.pandapath.site',
        'ok': true,
        'httpStatus': 200,
        'latencyMs': 113,
      },
      {
        'key': 'auth',
        'host': 'auth.pandapath.site',
        'ok': false,
        'httpStatus': null,
        'latencyMs': 3000,
        'error': 'timeout',
      },
    ],
    'jobs': [
      {
        'key': 'backup',
        'name': 'Database backup',
        'expectedEveryHours': 26,
        'state': 'overdue',
        'lastRunAt': ago(const Duration(hours: 30)),
        'lastStatus': 'success',
      },
      {
        'key': 'scraper',
        'name': 'Issuer page scraper',
        'expectedEveryHours': 192,
        'state': 'ok',
        'lastRunAt': ago(const Duration(days: 2)),
        'lastStatus': 'success',
      },
    ],
    'repository': {
      'branch': 'master',
      'total': 2,
      'branches': [
        {
          'name': 'master',
          'commit': 'aaaaaaaaaaaa',
          'current': true,
          'location': 'in_sync',
          'updatedAt': ago(const Duration(hours: 1)),
          'lastAction': 'commit: release',
        },
        {
          'name': 'feature/cards',
          'commit': 'bbbbbbbbbbbb',
          'current': false,
          'location': 'local_only',
          'updatedAt': ago(const Duration(days: 1)),
          'lastAction': null,
        },
      ],
    },
  };
}

void main() {
  testWidgets('system status shows servers, problems, jobs and branches', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = MockClient(
      (request) async => switch (request.url.path) {
        '/admin/system/status' => http.Response(jsonEncode(_status()), 200),
        _ => http.Response('{}', 404),
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 't'),
          adminIdentityProvider.overrideWithValue(
            const AdminIdentity(
              role: 'owner',
              environment: AdminEnvironment.local,
              permissions: {
                'operations.read',
                'admin.audit.read',
              },
            ),
          ),
          adminApiProvider.overrideWithValue(
            AdminApi(
              apiBaseUrl: 'http://status.invalid',
              accessToken: 't',
              client: client,
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: SystemStatusScreen())),
      ),
    );
    await tester.pumpAndSettle();

    // Auth timeout and the overdue backup are the two problems.
    expect(find.text('2 need attention'), findsOneWidget);
    expect(find.text('Auth service · Backup'), findsOneWidget);

    expect(find.text('Up · 113 ms'), findsOneWidget);
    expect(find.text('No answer in 3 s'), findsOneWidget);
    expect(find.text('Up · 2 ms'), findsOneWidget);
    expect(find.text('Not monitored yet'), findsOneWidget);
    expect(find.text('Runs during deploys'), findsOneWidget);
    expect(find.text('Always on · Rewards.'), findsOneWidget);
    expect(find.textContaining('Overdue · last ran'), findsNWidgets(2));
    expect(find.text('Local checkout'), findsOneWidget);
    expect(find.text('33ee22fc4558'), findsOneWidget);

    expect(find.text('master  (current)'), findsOneWidget);
    expect(find.text('Not pushed'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'feature');
    await tester.pumpAndSettle();
    expect(find.text('master  (current)'), findsNothing);
    expect(find.text('feature/cards'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
