import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_cards_repository.dart' show AppNotification;
import 'package:pandapay/features/notifications/notifications_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

final _now = DateTime(2026, 10, 25, 12);

AppNotification _notification(String title, DateTime createdAt) =>
    AppNotification(
      id: title,
      category: 'bills',
      severity: 'info',
      title: title,
      createdAt: createdAt,
    );

Widget _inbox(List<AppNotification> items, {int unreadCount = 0}) =>
    ProviderScope(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'token'),
        clockProvider.overrideWithValue(TestClock(_now)),
        notificationsProvider.overrideWith(
          (ref) async => (items: items, unreadCount: unreadCount),
        ),
      ],
      child: const MaterialApp(home: NotificationsScreen()),
    );

void main() {
  testWidgets('groups today and the past week, dropping older rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _inbox([
        _notification('From today', _now.subtract(const Duration(hours: 2))),
        _notification('Three days ago', _now.subtract(const Duration(days: 3))),
        _notification('Ten days ago', _now.subtract(const Duration(days: 10))),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('PAST WEEK'), findsOneWidget);
    expect(find.text('EARLIER'), findsNothing);

    expect(find.text('From today'), findsOneWidget);
    expect(find.text('Three days ago'), findsOneWidget);
    expect(find.text('Ten days ago'), findsNothing);
  });

  testWidgets('says nothing this week when every row has aged out', (
    tester,
  ) async {
    await tester.pumpWidget(
      _inbox([
        _notification('Ten days ago', _now.subtract(const Duration(days: 10))),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing this week'), findsOneWidget);
    expect(find.text('Nothing yet'), findsNothing);
    expect(find.text('Ten days ago'), findsNothing);
  });
}
