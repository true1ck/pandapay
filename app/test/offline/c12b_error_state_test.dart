import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/app/design/widgets.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/connectivity/known_connectivity.dart';

Widget _wrap(Widget child, {bool scope = true}) {
  final app = MaterialApp(home: Scaffold(body: child));
  return scope ? ProviderScope(child: app) : app;
}

void main() {
  tearDown(KnownConnectivity.reset);

  testWidgets('online, healthy: unchanged copy', (tester) async {
    await tester.pumpWidget(_wrap(const ErrorState(message: 'Boom', onRetry: _noop)));
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Boom'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
  });

  testWidgets('works without a ProviderScope', (tester) async {
    await tester.pumpWidget(_wrap(const ErrorState(message: 'Boom'), scope: false));
    expect(find.text('Something went wrong'), findsOneWidget);
  });

  testWidgets('offline-like error shows the neutral state', (tester) async {
    await tester.pumpWidget(_wrap(ErrorState(
      message: 'Boom',
      onRetry: _noop,
      error: http.ClientException('x'),
    )));
    expect(find.text("Can't reach PandaPay"), findsOneWidget);
    expect(find.text('Connect to the internet and try again.'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('known offline + cached data', (tester) async {
    KnownConnectivity.online = false;
    await tester.pumpWidget(_wrap(const ErrorState(message: 'Boom', hasCachedData: true)));
    expect(find.text("Can't reach PandaPay"), findsOneWidget);
    expect(find.text("Showing what's saved on this phone."), findsOneWidget);
  });

  test('message mapping', () {
    expect(userFacingErrorMessage(http.ClientException('x')), offlineErrorMessage);
    expect(userFacingErrorMessage(Exception('boom')), 'Something went wrong. Try again.');
    KnownConnectivity.online = false;
    expect(userFacingErrorMessage(Exception('boom')), offlineErrorMessage);
    expect(userFacingErrorMessage(StateError('Own words')), 'Own words');
  });
}

void _noop() {}
