import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/auth/login_screen.dart';
import 'package:pandapay/features/auth/product_activation_screen.dart';
import 'package:pandapay/features/onboarding/add_first_card_screen.dart';
import 'package:pandapay/features/onboarding/all_set_screen.dart';
import 'package:pandapay/features/onboarding/permissions_screen.dart';
import 'package:pandapay/features/onboarding/tracking_setup_screen.dart';
import 'package:pandapay/features/onboarding/welcome_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

const _channel = MethodChannel('flutter.baseflow.com/permissions/methods');

class _Location extends GeolocatorPlatform {
  LocationPermission permission = LocationPermission.whileInUse;
  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<LocationPermission> requestPermission() async =>
      permission = LocationPermission.whileInUse;
}

const _cards = [
  UserCard(
    id: 'one',
    cardProductId: 'p1',
    cardName: 'First card',
    isDefault: true,
  ),
  UserCard(
    id: 'two',
    cardProductId: 'p2',
    cardName: 'Second card',
    isDefault: false,
  ),
];

class _CardRepository implements UserCardsRepository {
  int additions = 0;
  @override
  Future<String> addCard(
    String cardProductId, {
    String? nickname,
    String? last4,
  }) async {
    additions++;
    return 'one';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  String initial = AppRoute.permissions,
  Object? extra,
  bool activated = true,
  UserCardsRepository? cardRepository,
}) async {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      sessionInitProvider.overrideWith((ref) async {}),
      sessionKeepAliveProvider.overrideWith((ref) {}),
      accessTokenProvider.overrideWith((ref) => 'test-token'),
      activationVerifiedNamespaceProvider.overrideWith(
        (ref) => activated ? ref.watch(cacheNamespaceProvider) : null,
      ),
      appStatusProvider.overrideWith((ref) async => null),
      catalogueProvider.overrideWith(
        (ref) async => [
          const CardProduct(
            id: 'p1',
            name: 'First card',
            network: CardNetwork.visa,
          ),
        ],
      ),
      userCardsProvider.overrideWith((ref) async => _cards),
      ownedCardsWithProductProvider.overrideWithValue(
        const AsyncValue.data([]),
      ),
      userCardsRepositoryProvider.overrideWithValue(cardRepository),
    ],
  );
  final router = container.read(goRouterProvider);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    container.dispose();
  });
  container.read(onboardingCompleteProvider);
  await container.read(sessionInitProvider.future);
  await tester.pump();
  router.go(initial, extra: extra);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  late GeolocatorPlatform original;
  late Map<int, int> statuses;
  late List<int> requests;
  var settingsOpened = 0;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    original = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = _Location();
    statuses = {};
    requests = [];
    settingsOpened = 0;
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
          if (call.method == 'openAppSettings') {
            settingsOpened++;
            return true;
          }
          return false;
        });
  });
  tearDown(() {
    GeolocatorPlatform.instance = original;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      '$platform setup Back visits the previous step without signing out',
      (tester) async {
        final container = await _pump(tester);
        expect(find.text('1 of 2'), findsOneWidget);
        if (platform == TargetPlatform.iOS) {
          expect(find.text('Set up SMS Shortcuts'), findsOneWidget);
          expect(find.text('Allow SMS & find my spends'), findsNothing);
          await tester.tap(find.text('Set up SMS Shortcuts'));
          await tester.pumpAndSettle();
          expect(find.text('Your spending, up to date.'), findsOneWidget);
          await tester.tap(find.byTooltip('Back'));
          await tester.pumpAndSettle();
          expect(find.text('1 of 2'), findsOneWidget);
        }
        await tester.tap(
          find.text(
            platform == TargetPlatform.iOS
                ? 'Continue for now'
                : 'I’ll add spends myself',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('2 of 2'), findsOneWidget);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.text('1 of 2'), findsOneWidget);
        await tester.tap(
          find.text(
            platform == TargetPlatform.iOS
                ? 'Continue for now'
                : 'I’ll add spends myself',
          ),
        );
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('1 of 2'), findsOneWidget);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(WelcomeScreen), findsOneWidget);
        expect(find.text('Continue setup'), findsOneWidget);
        expect(find.byType(LoginScreen), findsNothing);
        expect(container.read(accessTokenProvider), 'test-token');
        await tester.tap(find.text('Continue setup'));
        await tester.pumpAndSettle();
        expect(find.byType(PermissionsScreen), findsOneWidget);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'iOS extras request native grants and blocked permissions open Settings',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Continue for now'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable').first);
      await tester.pumpAndSettle();
      expect(requests, [Permission.notification.value]);
      expect(find.text('Enabled'), findsNWidgets(2));
      statuses[Permission.camera.value] =
          PermissionStatus.permanentlyDenied.index;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Settings'));
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(settingsOpened, 1);
      expect(requests, isNot(contains(Permission.camera.value)));
      // Returning from Settings re-reads the OS instead of retaining an old label.
      statuses[Permission.camera.value] = PermissionStatus.granted.index;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);
      await tester.tap(find.text('Allow remaining permissions'));
      await tester.pumpAndSettle();
      expect(requests, [
        Permission.notification.value,
        Permission.microphone.value,
      ]);
      expect(find.text('Continue to my cards'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('cards and final screen keep their previous page and account', (
    tester,
  ) async {
    final container = await _pump(tester);
    await tester.tap(find.text('I’ll add spends myself'));
    await tester.pumpAndSettle();
    // The first Continue is the platform's permission step where available.
    if (find.byType(AddFirstCardScreen).evaluate().isEmpty) {
      await tester.tap(find.text('Continue for now'));
      await tester.pumpAndSettle();
    }
    expect(find.byType(AddFirstCardScreen), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    await tester.tap(find.text('Add a card'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Add a card'), findsOneWidget);
    await tester.tap(find.text('I’ll do this later'));
    await tester.pumpAndSettle();
    expect(find.byType(AllSetScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(AllSetScreen), findsNothing);
    expect(find.byType(AddFirstCardScreen), findsOneWidget);
    expect(container.read(onboardingCompleteProvider).valueOrNull, isFalse);
    expect(container.read(accessTokenProvider), 'test-token');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionsScreen), findsOneWidget);
  });

  testWidgets(
    'cold-start card details Back has a destination and traverses cards',
    (tester) async {
      await _pump(
        tester,
        initial: AppRoute.cardDetailsSetup,
        extra: ['one', 'two'],
      );
      await tester.ensureVisible(find.text('Next'));
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Card 2 of 2'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'Second card draft');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Card 1 of 2'), findsOneWidget);
      await tester.ensureVisible(find.text('Next'));
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Second card draft',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Card 1 of 2'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AddFirstCardScreen), findsOneWidget);
    },
  );

  testWidgets(
    'returning from details retains selection without submitting a card twice',
    (tester) async {
      final repository = _CardRepository();
      await _pump(
        tester,
        initial: AppRoute.addFirstCard,
        cardRepository: repository,
      );
      await tester.tap(find.text('Add a card'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('First card'));
      await tester.tap(find.text('First card'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add 1 card'));
      await tester.tap(find.text('Add 1 card'));
      await tester.pumpAndSettle();
      expect(find.text('Card 1 of 1'), findsOneWidget);
      expect(repository.additions, 1);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.ensureVisible(find.text('Add 1 card'));
      await tester.tap(find.text('Add 1 card'));
      await tester.pumpAndSettle();
      expect(find.text('Card 1 of 1'), findsOneWidget);
      expect(repository.additions, 1);
    },
  );

  testWidgets('returning from a tracking channel does not advance onboarding', (
    tester,
  ) async {
    await _pump(tester, initial: AppRoute.trackingSetup);
    await tester.tap(find.text('Manual / statement import'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(TrackingSetupScreen), findsOneWidget);
    expect(find.byType(AllSetScreen), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(AddFirstCardScreen), findsOneWidget);
  });

  testWidgets(
    'restoring details without card arguments recovers to the card page',
    (tester) async {
      final container = await _pump(tester, initial: AppRoute.cardDetailsSetup);
      expect(find.byType(AddFirstCardScreen), findsOneWidget);
      expect(container.read(accessTokenProvider), 'test-token');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tour Back traverses slides before leaving the page', (
    tester,
  ) async {
    await _pump(tester, initial: AppRoute.tour);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('The right card.\nAt the right moment.'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Meet your\nmoney buddy.'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Meet your\nmoney buddy.'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionsScreen), findsOneWidget);
  });

  testWidgets(
    'signed-in introduction resumes through activation rather than login',
    (tester) async {
      final container = await _pump(
        tester,
        initial: AppRoute.welcome,
        activated: false,
      );
      expect(find.text('Continue setup'), findsOneWidget);
      expect(find.text('Create account'), findsNothing);
      await tester.tap(find.text('Continue setup'));
      // Account access has a pending network indicator; it need not settle.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ProductActivationScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Continue setup'), findsOneWidget);
      expect(container.read(accessTokenProvider), 'test-token');
    },
  );
}
