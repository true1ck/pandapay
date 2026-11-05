import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/features/consent/sms_reading_consent.dart';
import 'package:pandapay/features/sms_import/sms_import_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('flutter.baseflow.com/permissions/methods');

void main() {
  late List<int> requests;
  late Map<int, int> statuses;
  late List<Map<String, Object?>> posted;
  late http.Client client;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    statuses = {};
    posted = [];
    client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/consents') {
        posted.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response('{}', 201);
      }
      return http.Response('{"consents": []}', 200);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'checkPermissionStatus') {
            return statuses[call.arguments as int] ?? 0;
          }
          if (call.method == 'requestPermissions') {
            final permissions = (call.arguments as List).cast<int>();
            requests.addAll(permissions);
            return {
              for (final permission in permissions)
                permission: statuses[permission] = 1,
            };
          }
          return false;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          smsReadingConsentProvider.overrideWith((ref) async => false),
          userCardsProvider.overrideWith((ref) async => const []),
          profileProvider.overrideWith((ref) async => null),
          consentsApiProvider.overrideWithValue(
            ConsentsApi(
              apiBaseUrl: 'https://api.test',
              accessToken: 'token',
              client: client,
            ),
          ),
        ],
        child: const MaterialApp(home: SmsImportScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the disclosure comes before the SMS permission prompt', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Grant SMS permission'), findsOneWidget);

    await tester.tap(find.text('Grant SMS permission'));
    await tester.pumpAndSettle();
    expect(
      find.text('PandaPay reads your bank SMS on this phone'),
      findsOneWidget,
    );
    expect(requests, isEmpty);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(posted.single['purpose'], 'sms_reading');
    expect(posted.single['sourceScreen'], 'sms_import');
    expect(requests, [Permission.sms.value]);
  });

  testWidgets('Not now never reaches the permission prompt', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Grant SMS permission'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(requests, isEmpty);
    expect(posted, isEmpty);
    expect(find.text('Grant SMS permission'), findsOneWidget);
  });
}
