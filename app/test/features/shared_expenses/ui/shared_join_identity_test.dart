import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/shared_expenses/data/shared_directory.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/data/shared_invitations.dart';
import 'package:pandapay/features/shared_expenses/data/shared_phone_display.dart';
import 'package:pandapay/features/shared_expenses/data/shared_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_join_route.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_add_friend_sheet.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_claimant_phone.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_phone_consent.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_rename_member_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

const account = '11111111-1111-4111-8111-111111111111',
    ctxId = '22222222-2222-4222-8222-222222222222',
    inv1 = '66666666-6666-4666-8666-666666666661',
    inv2 = '66666666-6666-4666-8666-666666666662';
final token = 'a' * 43;
const full = '+917234512345';
const dot = '•••';

String _jwt() {
  String b(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b({'alg': 'none'})}.${b({'sub': account})}.sig';
}

Map<String, Object?> phoneJson({
  String consent = 'shared',
  bool available = true,
  bool lookalike = false,
  String? status,
  String? last4 = '4821',
  String mask = '+91 72••• ••4821',
}) => {
  'v': 1,
  'source': consent == 'none' ? 'none' : 'verified',
  'consent': consent,
  'countryCode': '+91',
  'last4': last4,
  'mask': mask,
  'available': available,
  'unavailableReason': null,
  'lookalike': lookalike,
  'duplicateOf': <String>[],
  'numberStatus': status ?? 'confirmed',
  'capturedAt': '2026-11-07T10:00:00Z',
};

SharedJoinRequest request(
  String id, {
  Map<String, Object?>? phone,
  String name = 'Rahul',
  String? fullNumber,
  Map<String, Object?> extra = const {},
}) => SharedJoinRequest.fromJson({
  'invitationId': id,
  'contextId': ctxId,
  'contextName': 'Goa',
  'memberName': name,
  'claimantProfileName': 'Rahul Kumar',
  'claimantPhone': ?phone,
  'fullNumber': ?fullNumber,
  ...extra,
});

class Runtime extends SharedExpensesRuntime {
  Runtime({required super.store, required super.remote, required super.cache})
    : super(isCurrent: () => true);
  Object? revealError;
  int reveals = 0;
  SharedInvitePreview? preview;
  final claims = <bool?>[];
  final claimOps = <String>[];
  final claimFailures = <Object>[];
  Object? renameError;
  @override
  Future<SharedRevealedPhone> revealClaimantPhone(String invitationId) async {
    reveals++;
    if (revealError != null) throw revealError!;
    return const SharedRevealedPhone(full);
  }

  @override
  Future<SharedInvitePreview> previewInvite(String token) async => preview!;
  @override
  Future<String> claimInvite(
    String token,
    String operationId, {
    bool? sharePhone,
  }) async {
    claims.add(sharePhone);
    claimOps.add(operationId);
    if (claimFailures.isNotEmpty) throw claimFailures.removeAt(0);
    return 'awaiting_owner';
  }

  @override
  Future<String> renameMember({
    required String contextId,
    required String memberId,
    required String name,
    bool directCounterpart = false,
  }) async {
    if (renameError != null) throw renameError!;
    return 'op';
  }
}

void main() {
  late AppDatabase db;
  late Runtime runtime;
  late AuthenticatedHttpClient client;
  late List<MethodCall> clipboard;
  String? clipboardText;
  late List<bool> secure;

  setUp(() {
    BambooFonts.useSystemFontsForTests = true;
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) async => http.Response('{}', 200)),
    );
    runtime = Runtime(
      store: SharedExpensesStore(db, namespace: 'user:$account'),
      remote: SharedExpensesHttpTransport(
        apiBaseUrl: 'http://127.0.0.1:4001',
        namespace: 'user:$account',
        client: client,
        accessToken: () => null,
        isCurrent: () => true,
      ),
      cache: ResponseCache(db),
    )..capabilities = {'reads': true, 'proposals': true, 'settlements': true};
    clipboard = [];
    clipboardText = null;
    secure = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('pandapay/secure_screen'),
          (call) async {
            secure.add((call.arguments as Map)['enable'] as bool);
            return null;
          },
        );
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          clipboard.add(call);
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
          }
          if (call.method == 'Clipboard.getData') {
            return {'text': clipboardText};
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    runtime.dispose();
    client.close();
    db.close();
    BambooFonts.useSystemFontsForTests = false;
  });

  group('parsing and formatting', () {
    test('absent or malformed claimantPhone means the old view', () {
      expect(SharedClaimantPhone.tryParse(null), isNull);
      expect(SharedClaimantPhone.tryParse('x'), isNull);
      expect(SharedClaimantPhone.tryParse({'consent': 'maybe'}), isNull);
      expect(request(inv1).claimantPhone, isNull);
      expect(request(inv1).signedInAs, isNotNull);
    });

    test('full number is kept only for look-alike items', () {
      final normal = SharedClaimantPhone.tryParse(
        phoneJson(),
        fullNumber: full,
      )!;
      expect(normal.fullNumber, isNull);
      final look = SharedClaimantPhone.tryParse(
        phoneJson(lookalike: true),
        fullNumber: full,
      )!;
      expect(look.fullNumber, full);
      final bad = SharedClaimantPhone.tryParse(
        phoneJson(lookalike: true),
        fullNumber: '12; DROP',
      )!;
      expect(bad.fullNumber, isNull);
    });

    test('toString never contains the number', () {
      final look = SharedClaimantPhone.tryParse(
        phoneJson(lookalike: true),
        fullNumber: full,
      )!;
      final req = request(
        inv1,
        phone: phoneJson(lookalike: true),
        fullNumber: full,
      );
      for (final text in [
        look.toString(),
        const SharedRevealedPhone(full).toString(),
        '$req',
        req.claimantPhone.toString(),
      ]) {
        expect(text, isNot(contains('7234512345')));
        expect(text, isNot(contains('4821')));
      }
    });

    test('formatting, speech and differing digits', () {
      expect(sharedFormatE164(full, countryCode: '+91'), '+91 72345 12345');
      expect(sharedSpokenDigits('+91 72'), 'plus 9 1 7 2');
      final other = '+917234512346';
      expect(sharedDifferingDigits(full, [other]), {11});
      expect(sharedDifferingDigits(full, const []), isEmpty);
    });

    test('preview: phoneSharing absent means off', () {
      final old = SharedInvitePreview.fromJson({
        'contextName': 'Goa',
        'memberName': 'Rahul',
        'status': 'open',
        'phoneBound': false,
      });
      expect(old.phoneSharing, isFalse);
      expect(old.ownPhoneMask, isNull);
      final on = SharedInvitePreview.fromJson({
        'contextName': 'Goa',
        'memberName': 'Rahul',
        'status': 'open',
        'phoneBound': false,
        'phoneSharing': true,
        'ownerName': 'Meera',
        'ownPhoneMask': '+91 72••• ••4821',
      });
      expect(on.phoneSharing, isTrue);
      expect(on.ownerName, 'Meera');
    });

    test('stored name refusal round-trips', () {
      final e = SharedNameException.fromStored(
        'http_409:friend_name_taken:$ctxId',
      )!;
      expect(e.code, 'friend_name_taken');
      expect(e.existingContextId, ctxId);
      expect(SharedNameException.fromStored('http_409'), isNull);
      expect(SharedNameException.fromStored('http_400:other'), isNull);
    });
  });

  group('transport', () {
    SharedExpensesHttpTransport transport(
      Future<http.Response> Function(http.Request) handler,
    ) => SharedExpensesHttpTransport(
      apiBaseUrl: 'http://127.0.0.1:4001',
      namespace: 'user:$account',
      client: AuthenticatedHttpClient(
        refreshAccessToken: () async => null,
        inner: MockClient((r) => handler(r)),
      ),
      accessToken: _jwt,
      isCurrent: () => true,
    );
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

    test('claim sends sharePhone only when chosen', () async {
      final bodies = <Map>[];
      final t = transport((r) async {
        bodies.add(jsonDecode(r.body) as Map);
        return json({'status': 'awaiting_owner'});
      });
      await t.claimInvitation(
        token: token,
        operationId: inv1,
        sharePhone: true,
      );
      await t.claimInvitation(token: token, operationId: inv1);
      expect(bodies[0]['sharePhone'], isTrue);
      expect(bodies[1].containsKey('sharePhone'), isFalse);
    });

    test('reveal success and errors map to codes', () async {
      var mode = 0;
      final t = transport((r) async {
        expect(r.url.path, endsWith('/invitations/reveal-phone'));
        return switch (mode) {
          0 => json({
            'invitationId': inv1,
            'e164': full,
            'revealedAt': '2026-11-07T10:00:00Z',
          }),
          1 => json({'error': 'reveal_rate_limited'}, 429),
          2 => json({'error': 'phone_not_available'}, 409),
          _ => json({'error': 'context_not_authorized'}, 403),
        };
      });
      final ok = await t.revealClaimantPhone(
        invitationId: inv1,
        operationId: inv2,
      );
      expect(ok.e164, full);
      for (final (m, code, status) in [
        (1, 'reveal_rate_limited', 429),
        (2, 'phone_not_available', 409),
        (3, 'context_not_authorized', 403),
      ]) {
        mode = m;
        await expectLater(
          t.revealClaimantPhone(invitationId: inv1, operationId: inv2),
          throwsA(
            isA<SharedTransportException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.statusCode, 'status', status),
          ),
        );
      }
    });

    Map<String, Object?> item(
      String id, {
      bool lookalike = false,
      String? full,
    }) => {
      'invitationId': id,
      'contextId': ctxId,
      'contextName': 'Goa',
      'memberName': 'Rahul',
      'claimantPhone': phoneJson(lookalike: lookalike),
      'fullNumber': ?full,
    };

    test('plain list request first; full numbers only when flagged', () async {
      final queries = <Map<String, String>>[];
      final t = transport((r) async {
        queries.add(r.url.queryParameters);
        final withFull = r.url.queryParameters['withLookalikeFull'] == '1';
        return json({
          'items': [
            item(inv1),
            item(inv2, lookalike: true, full: withFull ? full : null),
          ],
        });
      });
      final list = await t.fetchJoinRequests();
      expect(queries, [
        <String, String>{},
        {'withLookalikeFull': '1'},
      ]);
      expect(list.last.claimantPhone!.fullNumber, full);
    });

    test('no look-alikes means a single plain request', () async {
      var calls = 0;
      final t = transport((r) async {
        calls++;
        expect(r.url.queryParameters, isEmpty);
        return json({
          'items': [item(inv1)],
        });
      });
      await t.fetchJoinRequests();
      expect(calls, 1);
    });

    test('an API that rejects the parameter keeps the plain answer', () async {
      final t = transport((r) async {
        if (r.url.queryParameters.containsKey('withLookalikeFull')) {
          return json({'error': 'invalid_input'}, 400);
        }
        return json({
          'items': [item(inv2, lookalike: true)],
        });
      });
      final list = await t.fetchJoinRequests();
      expect(list, hasLength(1));
      expect(list.single.claimantPhone!.fullNumber, isNull);
    });

    test(
      'invitation id in the reveal reply is compared ignoring case',
      () async {
        final t = transport(
          (r) async => json({'invitationId': inv1.toUpperCase(), 'e164': full}),
        );
        final ok = await t.revealClaimantPhone(
          invitationId: inv1,
          operationId: inv2,
        );
        expect(ok.e164, full);
      },
    );

    test('a friend_name_taken body carries the existing chat id', () async {
      final t = transport(
        (r) async => json({
          'error': 'friend_name_taken',
          'existingContextId': ctxId,
        }, 409),
      );
      await expectLater(
        t.revealClaimantPhone(invitationId: inv1, operationId: inv2),
        throwsA(
          isA<SharedTransportException>().having(
            (e) => e.existingContextId,
            'existing',
            ctxId,
          ),
        ),
      );
    });
  });

  Future<void> pumpApp(
    WidgetTester tester,
    Widget child, {
    double scale = 1,
    TextDirection dir = TextDirection.ltr,
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
          ...overrides,
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, c) => Directionality(
            textDirection: dir,
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: c!,
            ),
          ),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget card(
    SharedJoinRequest r, {
    List<SharedJoinRequest> siblings = const [],
    Duration autoHide = const Duration(seconds: 60),
  }) => SharedClaimantPhoneView(
    request: r,
    siblings: siblings,
    autoHide: autoHide,
    onReveal: () => runtime.revealClaimantPhone(r.invitationId),
  );

  group('consent', () {
    testWidgets('neither option is selected and choosing reports it', (
      tester,
    ) async {
      bool? chosen;
      await pumpApp(
        tester,
        StatefulBuilder(
          builder: (context, set) => SharedPhoneConsent(
            ownerName: 'Meera',
            ownMask: '+91 72••• ••4821',
            value: chosen,
            enabled: true,
            onChanged: (v) => set(() => chosen = v),
          ),
        ),
      );
      expect(find.byIcon(Icons.radio_button_checked_rounded), findsNothing);
      expect(
        find.textContaining('Meera will see your PandaPay name'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('consent-decline')));
      await tester.pump();
      expect(chosen, isFalse);
      expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
    });

    testWidgets('no verified phone: notice only', (tester) async {
      await pumpApp(
        tester,
        SharedPhoneConsent(
          ownerName: 'Meera',
          ownMask: null,
          value: null,
          enabled: true,
          onChanged: (_) {},
        ),
      );
      expect(
        find.text(
          'Your account has no verified phone number, so Meera will see your name only.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('consent-share')), findsNothing);
    });

    SharedInvitePreview preview({bool sharing = true, String? mask}) =>
        SharedInvitePreview(
          kind: 'group_link',
          contextName: 'Goa',
          memberName: 'Group',
          status: 'open',
          phoneBound: false,
          phoneSharing: sharing,
          ownerName: 'Meera',
          ownPhoneMask: mask,
        );

    Future<void> openJoin(WidgetTester tester) async {
      await pumpApp(tester, const SizedBox());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedExpensesRuntimeProvider.overrideWith((ref) async => runtime),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: SharedJoinRoute(token: token, onDone: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    FilledButton joinButton(WidgetTester tester) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Join'));

    testWidgets('join stays disabled until a choice, then sends it', (
      tester,
    ) async {
      runtime.preview = preview(mask: '+91 72••• ••4821');
      await openJoin(tester);
      expect(joinButton(tester).onPressed, isNull);
      expect(find.text('Choose one option above to continue.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('consent-share')));
      await tester.pump();
      expect(joinButton(tester).onPressed, isNotNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Join'));
      await tester.pumpAndSettle();
      expect(runtime.claims, [true]);
    });

    testWidgets('changing the answer after a failed claim uses a new id', (
      tester,
    ) async {
      runtime.preview = preview(
        mask: '+91 72\u2022\u2022\u2022 \u2022\u20224821',
      );
      runtime.claimFailures.add(
        const SharedTransportException(code: 'network_unavailable'),
      );
      await openJoin(tester);
      await tester.tap(find.byKey(const Key('consent-share')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Join'));
      await tester.pumpAndSettle();
      // Same answer retried: same id (safe replay).
      await tester.tap(find.widgetWithText(FilledButton, 'Join'));
      await tester.pumpAndSettle();
      expect(runtime.claimOps[1], runtime.claimOps[0]);
    });

    testWidgets('switching the answer after an attempt gets a fresh id', (
      tester,
    ) async {
      runtime.preview = preview(
        mask: '+91 72\u2022\u2022\u2022 \u2022\u20224821',
      );
      runtime.claimFailures.add(
        const SharedTransportException(code: 'network_unavailable'),
      );
      await openJoin(tester);
      await tester.tap(find.byKey(const Key('consent-share')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Join'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('consent-decline')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Join'));
      await tester.pumpAndSettle();
      expect(runtime.claims, [true, false]);
      expect(runtime.claimOps[1], isNot(runtime.claimOps[0]));
    });

    testWidgets('operation_conflict retries once with a fresh id', (
      tester,
    ) async {
      runtime.preview = preview(
        mask: '+91 72\u2022\u2022\u2022 \u2022\u20224821',
      );
      runtime.claimFailures.add(
        const SharedTransportException(
          statusCode: 409,
          code: 'operation_conflict',
        ),
      );
      await openJoin(tester);
      await tester.tap(find.byKey(const Key('consent-decline')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Join'));
      await tester.pumpAndSettle();
      expect(runtime.claims, [false, false]);
      expect(runtime.claimOps[1], isNot(runtime.claimOps[0]));
      expect(find.textContaining('Request sent'), findsOneWidget);
    });

    testWidgets('flag off: no consent screen and no sharePhone sent', (
      tester,
    ) async {
      runtime.preview = preview(sharing: false, mask: '+91 72••• ••4821');
      await openJoin(tester);
      expect(find.byKey(const Key('consent-share')), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Join'));
      await tester.pumpAndSettle();
      expect(runtime.claims, [null]);
    });

    testWidgets('email-only: notice, join enabled, nothing sent', (
      tester,
    ) async {
      runtime.preview = preview(mask: null);
      await openJoin(tester);
      expect(find.byKey(const Key('phone-consent-notice')), findsOneWidget);
      expect(joinButton(tester).onPressed, isNotNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Join'));
      await tester.pumpAndSettle();
      expect(runtime.claims, [null]);
    });
  });

  group('owner card', () {
    testWidgets('shows mask and chip, no number, no reveal if declined', (
      tester,
    ) async {
      await pumpApp(
        tester,
        card(request(inv1, phone: phoneJson(consent: 'declined'))),
      );
      expect(find.text('Did not share a number'), findsOneWidget);
      expect(find.byKey(const Key('reveal-phone')), findsNothing);
    });

    testWidgets('older request and unverified chips', (tester) async {
      await pumpApp(
        tester,
        card(
          request(
            inv1,
            phone: phoneJson(consent: 'not_asked', available: false),
          ),
        ),
      );
      expect(
        find.text('Details not available for this older request'),
        findsOneWidget,
      );
      await pumpApp(
        tester,
        card(
          request(inv1, phone: phoneJson(consent: 'none', available: false)),
        ),
      );
      expect(find.text('Number not verified'), findsOneWidget);
    });

    testWidgets('shared: masked number, moved warning, reveal then hide', (
      tester,
    ) async {
      await pumpApp(
        tester,
        card(request(inv1, phone: phoneJson(status: 'moved'))),
      );
      expect(find.textContaining('72•••'), findsOneWidget);
      expect(
        find.text('This number now belongs to a different account.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('reveal-phone')));
      await tester.pumpAndSettle();
      expect(find.text('+91 72345 12345'), findsOneWidget);
      expect(runtime.reveals, 1);
      await tester.tap(find.byKey(const Key('hide-phone')));
      await tester.pump();
      expect(find.text('+91 72345 12345'), findsNothing);
      expect(find.byKey(const Key('reveal-phone')), findsOneWidget);
    });

    testWidgets('revealed number auto-hides after 60 seconds', (tester) async {
      await pumpApp(tester, card(request(inv1, phone: phoneJson())));
      await tester.tap(find.byKey(const Key('reveal-phone')));
      await tester.pumpAndSettle();
      expect(find.text('+91 72345 12345'), findsOneWidget);
      await tester.pump(const Duration(seconds: 59));
      expect(find.text('+91 72345 12345'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('+91 72345 12345'), findsNothing);
    });

    testWidgets('leaving the card drops the number', (tester) async {
      await pumpApp(tester, card(request(inv1, phone: phoneJson())));
      await tester.tap(find.byKey(const Key('reveal-phone')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      // Disposed without a pending timer or a retained value.
      await tester.pump(const Duration(seconds: 61));
      expect(tester.takeException(), isNull);
    });

    testWidgets('copy puts digits+cc on the clipboard, cleared after 60 s', (
      tester,
    ) async {
      await pumpApp(tester, card(request(inv1, phone: phoneJson())));
      await tester.tap(find.byKey(const Key('reveal-phone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('copy-phone')));
      await tester.pump();
      expect(clipboardText, full);
      await tester.pump(const Duration(seconds: 61));
      expect(clipboardText, '');
    });

    testWidgets('clipboard is wiped blindly, also on Hide', (tester) async {
      await pumpApp(tester, card(request(inv1, phone: phoneJson())));
      await tester.tap(find.byKey(const Key('reveal-phone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('copy-phone')));
      await tester.pump();
      expect(clipboardText, full);
      await tester.tap(find.byKey(const Key('hide-phone')));
      await tester.pump();
      expect(clipboardText, '');
      // Never reads the clipboard back.
      expect(clipboard.where((c) => c.method == 'Clipboard.getData'), isEmpty);
    });

    testWidgets('revealed number holds the secure screen until hidden', (
      tester,
    ) async {
      await pumpApp(tester, card(request(inv1, phone: phoneJson())));
      await tester.tap(find.byKey(const Key('reveal-phone')));
      await tester.pumpAndSettle();
      expect(secure, [true]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(secure, [true, false]);
      expect(find.byKey(const Key('reveal-phone')), findsOneWidget);
    });

    testWidgets('look-alike without a full number offers Tap to show', (
      tester,
    ) async {
      await pumpApp(
        tester,
        card(request(inv1, phone: phoneJson(lookalike: true))),
      );
      expect(find.byKey(const Key('lookalike-tap-to-show')), findsOneWidget);
      expect(find.byKey(const Key('reveal-phone')), findsOneWidget);
    });

    testWidgets('declined claimant with null last4 does not crash', (
      tester,
    ) async {
      await pumpApp(
        tester,
        card(
          request(
            inv1,
            phone: phoneJson(
              consent: 'declined',
              last4: null,
              status: 'unknown',
            ),
          ),
        ),
      );
      expect(find.text('Did not share a number'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final shared = SharedClaimantPhone.tryParse(phoneJson(last4: null))!;
      expect(shared.last4, isNull);
    });

    testWidgets('owner without a verified phone gets its own message', (
      tester,
    ) async {
      runtime.revealError = const SharedTransportException(
        statusCode: 409,
        code: 'owner_phone_required',
      );
      await pumpApp(tester, card(request(inv1, phone: phoneJson())));
      await tester.tap(find.byKey(const Key('reveal-phone')));
      await tester.pumpAndSettle();
      expect(
        find.text('Add and verify your own phone number to view numbers.'),
        findsOneWidget,
      );
    });

    for (final (error, text) in [
      (
        const SharedTransportException(
          statusCode: 429,
          code: 'reveal_rate_limited',
        ),
        'several numbers recently',
      ),
      (
        const SharedTransportException(
          statusCode: 409,
          code: 'phone_not_available',
        ),
        'no longer available',
      ),
      (
        const SharedTransportException(
          statusCode: 403,
          code: 'context_not_authorized',
        ),
        'Only the owner',
      ),
      (
        const SharedTransportException(code: 'network_unavailable'),
        'No connection',
      ),
    ]) {
      testWidgets('reveal error: $text', (tester) async {
        runtime.revealError = error;
        await pumpApp(tester, card(request(inv1, phone: phoneJson())));
        await tester.tap(find.byKey(const Key('reveal-phone')));
        await tester.pumpAndSettle();
        expect(find.textContaining(text), findsOneWidget);
        expect(find.byKey(const Key('reveal-phone')), findsOneWidget);
      });
    }

    testWidgets('look-alikes show full numbers, underline the difference', (
      tester,
    ) async {
      final a = request(
        inv1,
        phone: phoneJson(lookalike: true),
        fullNumber: '+917234512345',
      );
      final b = request(
        inv2,
        phone: phoneJson(lookalike: true),
        fullNumber: '+917234512346',
      );
      await pumpApp(tester, card(a, siblings: [a, b]));
      expect(
        find.text('These two look alike. Check the full numbers.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('reveal-phone')), findsNothing);
      final rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .where((w) => w.text.toPlainText().contains('72345'));
      expect(rich, isNotEmpty);
      final underlined = <String>[];
      rich.first.text.visitChildren((span) {
        if (span is TextSpan &&
            span.style?.decoration == TextDecoration.underline) {
          underlined.add(span.text ?? '');
        }
        return true;
      });
      expect(underlined, ['5']);
    });

    testWidgets('2x font scale does not overflow', (tester) async {
      final long = 'Ramachandran ' * 9;
      await pumpApp(
        tester,
        card(
          request(
            inv1,
            name: long,
            phone: phoneJson(status: 'moved'),
          ),
        ),
        scale: 2,
      );
      await tester.tap(find.byKey(const Key('reveal-phone')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('RTL surroundings keep the number left-to-right', (
      tester,
    ) async {
      await pumpApp(
        tester,
        card(request(inv1, name: 'راهول', phone: phoneJson())),
        dir: TextDirection.rtl,
      );
      await tester.tap(find.byKey(const Key('reveal-phone')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final dirs = tester
          .widgetList<Directionality>(
            find.ancestor(
              of: find.byWidgetPredicate(
                (w) => w is RichText && w.text.toPlainText().contains('72345'),
              ),
              matching: find.byType(Directionality),
            ),
          )
          .first
          .textDirection;
      expect(dirs, TextDirection.ltr);
    });

    testWidgets('screen reader reads digits one by one', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, card(request(inv1, phone: phoneJson())));
      expect(
        find.bySemanticsLabel(
          RegExp(r'Phone number ending 4 8 2 1, partly hidden'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('reveal-phone')));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(
          RegExp(r'Phone number plus 9 1 7 2 3 4 5 1 2 3 4 5'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('unique names', () {
    testWidgets('rename dialog keeps open and shows the server refusal', (
      tester,
    ) async {
      runtime.renameError = const SharedNameException('member_name_taken');
      String? result = 'untouched';
      await pumpApp(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showSharedRenameMemberDialog(
              context,
              title: 'Edit name',
              initialName: 'Rahul',
              onSave: (name) async {
                try {
                  await runtime.renameMember(
                    contextId: ctxId,
                    memberId: inv1,
                    name: name,
                  );
                  return null;
                } on SharedNameException catch (e) {
                  return sharedInviteIssueMessage(
                    SharedTransportException(code: e.code),
                  );
                }
              },
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('rename-member-field')),
        'Asha',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('already has that name'), findsOneWidget);
      expect(result, 'untouched');
      runtime.renameError = null;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result, 'Asha');
    });

    testWidgets('friend name taken: open existing or edit, no add anyway', (
      tester,
    ) async {
      bool? answer = false;
      await pumpApp(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => answer =
                await showSharedFriendNameTakenDialog(context, 'Rahul'),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Add anyway'), findsNothing);
      expect(find.text('Open existing'), findsOneWidget);
      expect(find.text('Edit name'), findsOneWidget);
      await tester.tap(find.text('Open existing'));
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });

    test('server messages for each refusal', () {
      for (final code in [
        'member_name_taken',
        'friend_name_taken',
        'member_name_reserved',
      ]) {
        final text = sharedInviteIssueMessage(
          SharedTransportException(code: code),
        );
        expect(text, isNot(contains('_')));
        expect(text, isNot('Something went wrong. Please try again.'));
      }
    });
  });
}
