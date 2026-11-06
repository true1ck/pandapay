import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:pandapay/features/settings/notification_settings_screen.dart';

Future<void> _mount(
  WidgetTester tester, {
  required PermissionStatus status,
  Future<PermissionStatus> Function()? request,
  Future<bool> Function()? openSettings,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: NotificationPermissionBanner(
        readStatus: () async => status,
        request: request,
        openSettings: openSettings,
      ),
    ),
  ),
);

void main() {
  testWidgets('shows nothing when notifications are already allowed', (
    tester,
  ) async {
    await _mount(tester, status: PermissionStatus.granted);
    await tester.pumpAndSettle();
    expect(find.textContaining('Notifications are off'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('asks through the system prompt, then hides once allowed', (
    tester,
  ) async {
    var asked = 0;
    await _mount(
      tester,
      status: PermissionStatus.denied,
      request: () async {
        asked++;
        return PermissionStatus.granted;
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('Notifications are off on this phone'), findsOneWidget);
    await tester.tap(find.text('Turn on notifications'));
    await tester.pumpAndSettle();
    expect(asked, 1);
    expect(find.textContaining('Notifications are off'), findsNothing);
  });

  testWidgets('stays visible if the user declines the prompt', (tester) async {
    await _mount(
      tester,
      status: PermissionStatus.denied,
      request: () async => PermissionStatus.denied,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn on notifications'));
    await tester.pumpAndSettle();
    expect(find.text('Notifications are off on this phone'), findsOneWidget);
  });

  testWidgets(
    'when Android will not ask again it opens system settings instead',
    (tester) async {
      var asked = 0, opened = 0;
      await _mount(
        tester,
        status: PermissionStatus.permanentlyDenied,
        request: () async {
          asked++;
          return PermissionStatus.denied;
        },
        openSettings: () async {
          opened++;
          return true;
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('Open settings'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(asked, 0, reason: 'a blocked prompt is never shown again');
    },
  );
}
