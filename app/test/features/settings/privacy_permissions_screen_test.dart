import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/features/settings/privacy_permissions_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Server {
  _Server({List<Map<String, dynamic>>? consents})
    : latest = consents ?? <Map<String, dynamic>>[];

  final List<Map<String, dynamic>> latest;
  final List<Map<String, dynamic>> posted = [];

  late final http.Client client = MockClient((request) async {
    if (request.method == 'POST' && request.url.path == '/consents') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      posted.add(body);
      latest.removeWhere((c) => c['purpose'] == body['purpose']);
      latest.add({
        'purpose': body['purpose'],
        'granted': body['granted'],
        'granted_at': '2026-11-15T10:00:00Z',
        'revoked_at': null,
        'policy_version': body['policyVersion'],
        'source_screen': body['sourceScreen'],
      });
      return http.Response('{}', 201);
    }
    if (request.method == 'GET' && request.url.path == '/consents') {
      return http.Response(jsonEncode({'consents': latest}), 200);
    }
    if (request.method == 'GET' && request.url.path == '/consents/history') {
      return http.Response(jsonEncode({'consents': latest}), 200);
    }
    return http.Response('not found', 404);
  });
}

Future<void> _pump(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        profileProvider.overrideWith(
          (ref) async => {'email': 'asha.rao@example.com'},
        ),
        consentsApiProvider.overrideWithValue(
          ConsentsApi(
            apiBaseUrl: 'https://api.test',
            accessToken: 'test-token',
            client: server.client,
          ),
        ),
      ],
      child: const MaterialApp(home: PrivacyPermissionsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _switchFor(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(SwitchListTile));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('SMS reading is off until the account agrees', (tester) async {
    await _pump(tester, _Server());
    expect(find.text('Read my bank SMS'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(_switchFor('Read my bank SMS')).value,
      isFalse,
    );
  });

  testWidgets(
    'turning SMS reading on shows the disclosure and records consent',
    (tester) async {
      final server = _Server();
      await _pump(tester, server);

      await tester.tap(_switchFor('Read my bank SMS'));
      await tester.pumpAndSettle();
      expect(
        find.text('PandaPay reads your bank SMS on this phone'),
        findsOneWidget,
      );
      expect(
        find.textContaining('added to the account a***@example.com.'),
        findsOneWidget,
      );
      expect(server.posted, isEmpty);

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(server.posted, [
        {
          'purpose': 'sms_reading',
          'granted': true,
          'policyVersion': '2026-11-15',
          'sourceScreen': 'privacy_permissions',
        },
      ]);
      expect(
        tester.widget<SwitchListTile>(_switchFor('Read my bank SMS')).value,
        isTrue,
      );
    },
  );

  testWidgets('declining the disclosure leaves SMS reading off', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server);
    await tester.tap(_switchFor('Read my bank SMS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(server.posted, isEmpty);
    expect(
      tester.widget<SwitchListTile>(_switchFor('Read my bank SMS')).value,
      isFalse,
    );
  });

  testWidgets('turning SMS reading off records a withdrawal', (tester) async {
    final server = _Server(
      consents: [
        {
          'purpose': 'sms_reading',
          'granted': true,
          'granted_at': '2026-11-15T10:00:00Z',
          'revoked_at': null,
          'policy_version': '2026-11-15',
          'source_screen': 'onboarding_permissions',
        },
      ],
    );
    await _pump(tester, server);
    expect(
      tester.widget<SwitchListTile>(_switchFor('Read my bank SMS')).value,
      isTrue,
    );

    await tester.tap(_switchFor('Read my bank SMS'));
    await tester.pumpAndSettle();

    expect(server.posted, [
      {
        'purpose': 'sms_reading',
        'granted': false,
        'policyVersion': '2026-11-15',
        'sourceScreen': 'privacy_permissions',
      },
    ]);
    expect(
      tester.widget<SwitchListTile>(_switchFor('Read my bank SMS')).value,
      isFalse,
    );
  });
}
