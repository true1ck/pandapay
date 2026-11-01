import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/main.dart';

Future<void> _pumpAdminConsole(
  WidgetTester tester, {
  bool failCatalogue = false,
}) async {
  const token = 'responsive-preview-token';
  final client = MockClient((request) async {
    if (request.url.path == '/admin/me') {
      return http.Response(jsonEncode({'isAdmin': true}), 200);
    }
    if (failCatalogue && request.url.path == '/admin/cards') {
      return http.Response('service unavailable', 503);
    }
    return http.Response(jsonEncode({'cards': <Map<String, Object?>>[]}), 200);
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionInitProvider.overrideWith((ref) async {}),
        accessTokenProvider.overrideWith((ref) => token),
        adminApiProvider.overrideWithValue(
          AdminApi(
            apiBaseUrl: 'http://responsive-preview.invalid',
            accessToken: token,
            client: client,
          ),
        ),
      ],
      child: const PandaPayConsoleApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('catalogue empty state fits a phone-sized console viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpAdminConsole(tester);

    final title = tester.getRect(
      find.text('No card products in this workspace'),
    );
    final message = tester.getRect(
      find.textContaining('No catalogue records have been loaded'),
    );
    expect(title.left, greaterThanOrEqualTo(0));
    expect(title.right, lessThanOrEqualTo(390));
    expect(message.left, greaterThanOrEqualTo(0));
    expect(message.right, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalogue error and retry fit a phone-sized viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpAdminConsole(tester, failCatalogue: true);

    final title = tester.getRect(find.text('Catalogue could not be loaded'));
    final message = tester.getRect(
      find.textContaining('The console could not retrieve this information'),
    );
    expect(title.left, greaterThanOrEqualTo(0));
    expect(title.right, lessThanOrEqualTo(390));
    expect(message.left, greaterThanOrEqualTo(0));
    expect(message.right, lessThanOrEqualTo(390));
    expect(find.text('Try again'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
