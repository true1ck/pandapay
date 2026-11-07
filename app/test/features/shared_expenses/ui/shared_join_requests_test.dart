import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/shared_expenses/data/shared_directory.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/data/shared_phone_display.dart';
import 'package:pandapay/features/shared_expenses/data/shared_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_join_requests_page.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_join_requests_summary.dart';
import 'package:sqlite3/sqlite3.dart';

const account = '11111111-1111-4111-8111-111111111111',
    goa = '22222222-2222-4222-8222-222222222222',
    flat = '33333333-3333-4333-8333-333333333333',
    office = '44444444-4444-4444-8444-444444444444';
final clock = DateTime.utc(2026, 11, 7, 12);
const dot = '••';

String idOf(int n) =>
    '66666666-6666-4666-8666-6666666666${n.toString().padLeft(2, '0')}';

Map<String, Object?> phone({
  String consent = 'shared',
  bool available = true,
  bool lookalike = false,
  String status = 'confirmed',
  String mask = '+91 72••• ••4821',
}) => {
  'v': 1,
  'source': consent == 'none' ? 'none' : 'verified',
  'consent': consent,
  'countryCode': '+91',
  'last4': consent == 'shared' ? '4821' : null,
  'mask': mask,
  'available': available,
  'unavailableReason': null,
  'lookalike': lookalike,
  'duplicateOf': <String>[],
  'numberStatus': status,
  'capturedAt': '2026-11-07T10:00:00Z',
};

SharedJoinRequest req(
  int n, {
  String ctx = goa,
  String ctxName = 'Goa',
  String? name,
  Map<String, Object?>? ph,
  String? full,
  Duration age = const Duration(hours: 2),
  Duration? left = const Duration(days: 5),
  String kind = 'group',
}) => SharedJoinRequest.fromJson({
  'invitationId': idOf(n),
  'contextId': ctx,
  'contextName': ctxName,
  'contextKind': kind,
  'memberName': name ?? 'Person $n',
  'claimantProfileName': 'Profile $n',
  'claimantPhone': ph ?? phone(),
  'fullNumber': ?full,
  'createdAt': clock.subtract(age).toIso8601String(),
  if (left != null) 'expiresAt': clock.add(left).toIso8601String(),
});

class Runtime extends SharedExpensesRuntime {
  Runtime({required super.store, required super.remote, required super.cache})
    : super(isCurrent: () => true);
  List<SharedJoinRequest> list = [];
  Completer<void>? hold;
  Object? loadError;
  final calls = <({String id, bool approve, String op})>[];
  final failures = <String, List<Object>>{};
  int refreshes = 0;

  @override
  Future<List<SharedJoinRequest>> joinRequests() async {
    if (hold != null) await hold!.future;
    if (loadError != null) throw loadError!;
    cachedJoinRequests = List.of(list);
    return List.of(list);
  }

  @override
  Future<String> respondToJoinRequest(
    String invitationId, {
    required bool approve,
    String? operationId,
    bool refreshAfter = true,
  }) async {
    calls.add((id: invitationId, approve: approve, op: operationId ?? ''));
    final queue = failures[invitationId];
    if (queue != null && queue.isNotEmpty) {
      final error = queue.removeAt(0);
      // The server no longer lists a request that expired or is already done.
      if (error is SharedTransportException &&
          (error.code == 'invitation_unavailable' ||
              error.code == 'invitation_conflict')) {
        list.removeWhere((r) => r.invitationId == invitationId);
      }
      throw error;
    }
    list.removeWhere((r) => r.invitationId == invitationId);
    return approve ? 'joined' : 'declined';
  }

  @override
  Future<void> refresh({int maxPullPages = 2}) async => refreshes++;

  @override
  Future<SharedRevealedPhone> revealClaimantPhone(String invitationId) async =>
      const SharedRevealedPhone('+917234512345');
}

void main() {
  late AppDatabase db;
  late Runtime runtime;
  late AuthenticatedHttpClient client;
  setUp(() {
    BambooFonts.useSystemFontsForTests = true;
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
  });
  tearDown(() {
    runtime.dispose();
    client.close();
    db.close();
    BambooFonts.useSystemFontsForTests = false;
  });

  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    double scale = 1,
    TextDirection dir = TextDirection.ltr,
    bool dark = false,
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(430, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, c) => Directionality(
          textDirection: dir,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: c!,
          ),
        ),
        home: home,
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> page(
    WidgetTester tester, {
    double scale = 1,
    TextDirection dir = TextDirection.ltr,
    bool dark = false,
    bool settle = true,
    VoidCallback? onShare,
  }) => pump(
    tester,
    SharedJoinRequestsPage(
      runtime: runtime,
      now: () => clock,
      onShareGroupLink: onShare,
    ),
    scale: scale,
    dir: dir,
    dark: dark,
    settle: settle,
  );

  group('summary row', () {
    Widget row(List<SharedJoinRequest> r, {VoidCallback? onReview}) => Scaffold(
      body: SharedJoinRequestsSummary(requests: r, onReview: onReview ?? () {}),
    );

    testWidgets('no requests: nothing shown, no space taken', (tester) async {
      await pump(tester, row(const []));
      expect(find.byKey(const Key('join-requests-summary')), findsNothing);
      expect(tester.getSize(find.byType(SharedJoinRequestsSummary)), Size.zero);
    });

    testWidgets('one request names the person and the split', (tester) async {
      await pump(tester, row([req(1, name: 'Rahul')]));
      expect(find.text('Rahul wants to join Goa'), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
    });

    testWidgets('a friend split reads "your split"', (tester) async {
      await pump(
        tester,
        row([req(1, name: 'Rahul', ctxName: 'Rahul', kind: 'direct')]),
      );
      expect(find.text('Rahul wants to join your split'), findsOneWidget);
    });

    testWidgets('three requests across splits list the splits', (tester) async {
      await pump(
        tester,
        row([
          req(1, ctx: goa, ctxName: 'Goa trip'),
          req(2, ctx: flat, ctxName: 'Flat 4B'),
          req(3, ctx: office, ctxName: 'Office'),
        ]),
      );
      expect(find.text('3 people want to join'), findsOneWidget);
      expect(find.text('Goa trip, Flat 4B and 1 more'), findsOneWidget);
    });

    testWidgets('50 requests', (tester) async {
      await pump(tester, row([for (var n = 0; n < 50; n++) req(n)]));
      expect(find.text('50 people want to join'), findsOneWidget);
    });

    testWidgets('2x text with 120-char names does not overflow', (
      tester,
    ) async {
      final long = 'Ramachandran ' * 9 + 'Iyer';
      await pump(
        tester,
        row([
          req(1, name: long, ctxName: long),
          req(2, ctx: flat, ctxName: long),
        ]),
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      await pump(tester, row([req(1, name: long, ctxName: long)]), scale: 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('RTL and dark mode build cleanly', (tester) async {
      await pump(
        tester,
        row([req(1, name: 'راهول')]),
        dir: TextDirection.rtl,
        dark: true,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('screen reader gets one button with the whole sentence', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await pump(
        tester,
        row([
          req(1, ctxName: 'Goa trip'),
          req(2, ctx: flat, ctxName: 'Flat'),
        ], onReview: () => taps++),
      );
      expect(
        find.bySemanticsLabel(
          RegExp(r'2 people want to join\. Goa trip and Flat\. Review'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('join-requests-summary')));
      expect(taps, 1);
      handle.dispose();
    });
  });

  group('page', () {
    testWidgets('groups by split, oldest first, collapsible', (tester) async {
      runtime.list = [
        req(1, ctx: flat, ctxName: 'Flat 4B', age: const Duration(hours: 1)),
        req(2, ctx: goa, ctxName: 'Goa trip', age: const Duration(days: 2)),
        req(3, ctx: goa, ctxName: 'Goa trip', age: const Duration(days: 3)),
      ];
      await page(tester);
      expect(find.text('Goa trip · 2 waiting'), findsOneWidget);
      expect(find.text('Flat 4B · 1 waiting'), findsOneWidget);
      // Oldest split first, oldest request first within it.
      expect(
        tester.getTopLeft(find.text('Goa trip · 2 waiting')).dy <
            tester.getTopLeft(find.text('Flat 4B · 1 waiting')).dy,
        isTrue,
      );
      expect(
        tester.getTopLeft(find.byKey(Key('row-${idOf(3)}'))).dy <
            tester.getTopLeft(find.byKey(Key('row-${idOf(2)}'))).dy,
        isTrue,
      );
      // The warning appears once, not per row.
      expect(find.byKey(const Key('requests-warning')), findsOneWidget);
      expect(find.textContaining('Only approve people'), findsOneWidget);
      await tester.tap(find.byKey(Key('group-header-$goa')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('row-${idOf(2)}')), findsNothing);
      expect(find.byKey(Key('row-${idOf(1)}')), findsOneWidget);
    });

    testWidgets('rows show label, signed-in name, chip, mask and timing', (
      tester,
    ) async {
      runtime.list = [req(1, name: 'Rahul')];
      await page(tester);
      expect(find.text('Rahul'), findsOneWidget);
      expect(find.text('Signed in as Profile 1'), findsOneWidget);
      expect(find.text('Shared a number'), findsOneWidget);
      expect(find.textContaining('72•••'), findsOneWidget);
      expect(find.text('Asked 2 h ago · expires in 5 days'), findsOneWidget);
    });

    testWidgets('cached requests show at once; skeleton when none', (
      tester,
    ) async {
      runtime.hold = Completer<void>();
      await page(tester, settle: false);
      expect(find.byKey(const Key('skeleton-row')), findsNWidgets(3));
      runtime.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('skeleton-row')), findsNothing);

      runtime.list = [req(1)];
      runtime.cachedJoinRequests = [req(1)];
      runtime.hold = Completer<void>();
      await pump(
        tester,
        SharedJoinRequestsPage(
          key: UniqueKey(),
          runtime: runtime,
          now: () => clock,
        ),
        settle: false,
      );
      expect(find.byKey(Key('row-${idOf(1)}')), findsOneWidget);
      expect(find.byKey(const Key('skeleton-row')), findsNothing);
      runtime.hold!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets(
      'error shows Retry; offline shows a banner and pauses actions',
      (tester) async {
        runtime.loadError = const SharedTransportException(statusCode: 500);
        await page(tester);
        expect(find.text('Could not load the requests.'), findsOneWidget);
        runtime.loadError = null;
        runtime.list = [req(1)];
        await tester.tap(find.byKey(const Key('retry-load')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('row-${idOf(1)}')), findsOneWidget);

        runtime.loadError = const SharedTransportException(
          code: 'network_unavailable',
        );
        // Same as a pull to refresh.
        tester
            .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
            .show();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('offline-banner')), findsOneWidget);
        final approve = tester.widget<TextButton>(
          find.byKey(Key('approve-${idOf(1)}')),
        );
        expect(approve.onPressed, isNull);
      },
    );

    testWidgets('empty state offers Share group link', (tester) async {
      var shared = 0;
      await page(tester, onShare: () => shared++);
      expect(find.byKey(const Key('empty-state')), findsOneWidget);
      await tester.tap(find.byKey(const Key('share-group-link')));
      expect(shared, 1);
    });

    testWidgets('an expired request cannot be approved', (tester) async {
      runtime.list = [req(1, left: const Duration(minutes: -5))];
      await page(tester);
      expect(find.text('Expired'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(Key('approve-${idOf(1)}')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('approve says the request expired and removes the row', (
      tester,
    ) async {
      runtime.list = [req(1)];
      runtime.failures[idOf(1)] = [
        const SharedTransportException(
          statusCode: 410,
          code: 'invitation_unavailable',
        ),
      ];
      await page(tester);
      await tester.tap(find.byKey(Key('approve-${idOf(1)}')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('row-${idOf(1)}')), findsNothing);
      expect(
        find.text('That request expired or was withdrawn.'),
        findsOneWidget,
      );
    });

    testWidgets('declining shows a SnackBar with the name', (tester) async {
      runtime.list = [req(1, name: 'Rahul')];
      await page(tester);
      await tester.tap(find.byKey(Key('decline-${idOf(1)}')));
      await tester.pumpAndSettle();
      expect(find.text('Rahul declined'), findsOneWidget);
      expect(runtime.calls.single.approve, isFalse);
    });

    testWidgets('120-char names at 2x and dark mode do not overflow', (
      tester,
    ) async {
      final long = 'Ramachandran ' * 9 + 'Iyer';
      runtime.list = [
        req(1, name: long, ctxName: long),
        req(2, name: long, ctxName: long, ph: phone(lookalike: true)),
      ];
      await page(tester, scale: 2, dark: true);
      expect(tester.takeException(), isNull);
    });

    testWidgets('two look-alikes get a side-by-side Compare card', (
      tester,
    ) async {
      runtime.list = [
        req(1, ph: phone(lookalike: true), full: '+917234512345'),
        req(2, ph: phone(lookalike: true), full: '+917234512346'),
      ];
      await page(tester);
      expect(find.byKey(const Key('compare-card')), findsOneWidget);
    });
  });

  group('selection and bulk', () {
    List<SharedJoinRequest> mixed() => [
      req(1),
      req(2),
      req(3, ph: phone(lookalike: true)),
      req(4, ph: phone(consent: 'none', available: false)),
      req(5, ph: phone(consent: 'declined')),
      req(6, ph: phone(status: 'moved')),
    ];

    testWidgets('Select all skips look-alikes, unverified and moved', (
      tester,
    ) async {
      runtime.list = mixed();
      await page(tester);
      await tester.longPress(find.byKey(Key('row-${idOf(1)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-all')));
      await tester.pumpAndSettle();
      expect(find.text('Approve selected (2)'), findsOneWidget);
      // Look-alikes cannot be ticked at all.
      expect(
        tester.widget<Checkbox>(find.byKey(Key('check-${idOf(3)}'))).onChanged,
        isNull,
      );
      // Others can be ticked by hand.
      await tester.tap(find.byKey(Key('check-${idOf(5)}')));
      await tester.pumpAndSettle();
      expect(find.text('Approve selected (3)'), findsOneWidget);
    });

    testWidgets('batch is capped at 25', (tester) async {
      runtime.list = [for (var n = 0; n < 30; n++) req(n)];
      await page(tester);
      await tester.tap(find.byKey(Key('group-menu-$goa')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('select-$goa')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-all')));
      await tester.pumpAndSettle();
      expect(find.text('Approve selected (25)'), findsOneWidget);
    });

    testWidgets('switching split asks before clearing the selection', (
      tester,
    ) async {
      runtime.list = [
        req(1),
        req(2, ctx: flat, ctxName: 'Flat 4B', age: const Duration(hours: 1)),
      ];
      await page(tester);
      await tester.longPress(find.byKey(Key('row-${idOf(1)}')));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(Key('row-${idOf(2)}')));
      await tester.pumpAndSettle();
      expect(find.text('Switch split?'), findsOneWidget);
    });

    testWidgets('confirmation lists counts, names, masks and concerns', (
      tester,
    ) async {
      runtime.list = mixed();
      await page(tester);
      await tester.longPress(find.byKey(Key('row-${idOf(1)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('check-${idOf(2)}')));
      await tester.tap(find.byKey(Key('check-${idOf(5)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('approve-selected')));
      await tester.pumpAndSettle();
      expect(find.text('Approve 3 people to Goa?'), findsOneWidget);
      expect(find.textContaining('see the split'), findsWidgets);
      expect(find.byKey(const Key('bulk-concern')), findsOneWidget);
      expect(
        find.textContaining('Person 5: did not share a number'),
        findsOneWidget,
      );
      expect(find.textContaining('Person 1  +91'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Approve 3'), findsOneWidget);
      // Nothing was sent just by opening it.
      expect(runtime.calls, isEmpty);
    });

    testWidgets(
      'sequential approve: a failing item is kept, retry reuses its id',
      (tester) async {
        runtime.list = [req(1), req(2), req(3)];
        runtime.failures[idOf(2)] = [
          const SharedTransportException(statusCode: 500),
        ];
        await page(tester);
        await tester.longPress(find.byKey(Key('row-${idOf(1)}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('select-all')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('approve-selected')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-action')));
        await tester.pumpAndSettle();
        expect(runtime.calls.map((c) => c.id), [idOf(1), idOf(2), idOf(3)]);
        expect(
          find.text('2 approved. 1 could not be approved.'),
          findsOneWidget,
        );
        expect(find.byKey(Key('row-${idOf(2)}')), findsOneWidget);
        expect(find.byKey(Key('row-${idOf(1)}')), findsNothing);
        expect(find.byKey(Key('reason-${idOf(2)}')), findsOneWidget);
        expect(runtime.refreshes, 1);
        final firstOp = runtime.calls[1].op;

        await tester.tap(find.byKey(const Key('retry-batch')));
        await tester.pumpAndSettle();
        expect(runtime.calls.last.id, idOf(2));
        expect(runtime.calls.last.op, firstOp);
        expect(find.byKey(Key('row-${idOf(2)}')), findsNothing);
      },
    );

    testWidgets('already a member counts as success', (tester) async {
      runtime.list = [req(1)];
      runtime.failures[idOf(1)] = [
        const SharedTransportException(
          statusCode: 409,
          code: 'invitation_conflict',
        ),
      ];
      await page(tester);
      await tester.tap(find.byKey(Key('approve-${idOf(1)}')));
      await tester.pumpAndSettle();
      expect(find.text('Already in the group.'), findsOneWidget);
      expect(find.byKey(Key('row-${idOf(1)}')), findsNothing);
    });

    testWidgets('losing the connection stops the run', (tester) async {
      runtime.list = [req(1), req(2), req(3)];
      runtime.failures[idOf(2)] = [
        const SharedTransportException(code: 'network_unavailable'),
      ];
      await page(tester);
      await tester.longPress(find.byKey(Key('row-${idOf(1)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('approve-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(runtime.calls.map((c) => c.id), [idOf(1), idOf(2)]);
      expect(
        find.textContaining('Connection lost. 2 not sent.'),
        findsOneWidget,
      );
    });

    testWidgets('Decline all asks first, then declines everyone', (
      tester,
    ) async {
      runtime.list = [req(1), req(2)];
      await page(tester);
      await tester.tap(find.byKey(Key('group-menu-$goa')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('decline-all-$goa')));
      await tester.pumpAndSettle();
      expect(find.text('Decline all 2 requests to Goa?'), findsOneWidget);
      expect(runtime.calls, isEmpty);
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(runtime.calls.every((c) => !c.approve), isTrue);
      expect(runtime.calls, hasLength(2));
    });
  });
}
