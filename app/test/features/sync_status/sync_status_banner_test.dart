import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_attention.dart';
import 'package:pandapay/features/sync_status/queue_totals.dart';
import 'package:pandapay/features/sync_status/reachability_monitor.dart';
import 'package:pandapay/features/sync_status/sync_retry.dart';
import 'package:pandapay/features/sync_status/sync_status_banner.dart';
import 'package:pandapay/features/sync_status/sync_status_copy.dart';
import 'package:pandapay/features/sync_status/sync_status_providers.dart';

const _stripKey = Key('sync-status-strip');
const _probeKey = Key('probe');

const _offline = SyncStatusSummary(mode: SyncStatusMode.offline);
const _hidden = SyncStatusSummary(mode: SyncStatusMode.hidden);

final _mode = StateProvider<SyncStatusSummary>((_) => _hidden);

class _Page extends StatelessWidget {
  const _Page();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Home page')),
    body: const SizedBox.expand(key: _probeKey, child: Text('page body')),
  );
}

/// A MaterialApp.router with the strip mounted exactly like main.dart does:
/// in `builder`, above the Navigator.
Widget _app({
  List<Override> overrides = const [],
  bool wrapped = true,
  Widget page = const _Page(),
  ThemeMode themeMode = ThemeMode.light,
}) {
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => page)],
  );
  return ProviderScope(
    overrides: [
      syncStatusSummaryProvider.overrideWith((ref) => ref.watch(_mode)),
      syncQueueBreakdownProvider.overrideWith((_) async => const []),
      syncRetryActionsProvider.overrideWithValue(const {}),
      lastSyncedAtProvider.overrideWith((_) async => null),
      needsAttentionCountProvider.overrideWithValue(0),
      ...overrides,
    ],
    child: MaterialApp.router(
      routerConfig: router,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      builder: wrapped
          ? (context, child) => SyncStatusBanner(
              navigatorKey: router.routerDelegate.navigatorKey,
              child: child,
            )
          : null,
    ),
  );
}

Future<void> _show(
  WidgetTester tester,
  SyncStatusSummary summary, {
  List<Override> overrides = const [],
  ThemeMode themeMode = ThemeMode.light,
  Widget page = const _Page(),
}) async {
  await tester.pumpWidget(
    _app(overrides: overrides, themeMode: themeMode, page: page),
  );
  ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  ).read(_mode.notifier).state = summary;
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => BambooFonts.useSystemFontsForTests = true);
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  group('copy', () {
    test('offline', () {
      expect(syncStatusLabel(_offline), 'Offline mode · changes saved on this phone');
      expect(
        syncStatusLabel(
          const SyncStatusSummary(
            mode: SyncStatusMode.offline,
            pendingCount: 3,
          ),
        ),
        'Offline mode · changes saved on this phone',
      );
    });

    test('unreachable', () {
      expect(
        syncStatusLabel(const SyncStatusSummary(mode: SyncStatusMode.unreachable)),
        "Can't reach PandaPay · changes saved on this phone",
      );
      expect(
        syncStatusLabel(
          const SyncStatusSummary(
            mode: SyncStatusMode.unreachable,
            pendingCount: 1,
          ),
        ),
        "Can't reach PandaPay · changes saved on this phone",
      );
    });

    test('syncing and needs attention use singular and plural', () {
      expect(
        syncStatusLabel(
          const SyncStatusSummary(mode: SyncStatusMode.syncing, pendingCount: 1),
        ),
        'Syncing…',
      );
      expect(
        syncStatusLabel(
          const SyncStatusSummary(mode: SyncStatusMode.syncing, pendingCount: 4),
        ),
        'Syncing…',
      );
      expect(
        syncStatusLabel(
          const SyncStatusSummary(
            mode: SyncStatusMode.needsAttention,
            attentionCount: 1,
          ),
        ),
        'Some changes are saved on this phone',
      );
      expect(
        syncStatusLabel(
          const SyncStatusSummary(
            mode: SyncStatusMode.needsAttention,
            attentionCount: 2,
          ),
        ),
        'Some changes are saved on this phone',
      );
    });

    test('never uses the legacy Home banner phrase', () {
      for (final mode in SyncStatusMode.values) {
        expect(
          syncStatusLabel(
            SyncStatusSummary(
              mode: mode,
              pendingCount: 2,
              attentionCount: 2,
            ),
          ),
          isNot(contains("You're offline")),
        );
      }
    });

    test('semantics label spells out the state and the tap', () {
      expect(
        syncStatusSemanticsLabel(
          const SyncStatusSummary(
            mode: SyncStatusMode.offline,
            pendingCount: 3,
          ),
        ),
        'Offline, 3 changes waiting. Tap for details',
      );
      expect(
        syncStatusSemanticsLabel(_offline),
        'Offline, showing saved data. Tap for details',
      );
      expect(
        syncStatusSemanticsLabel(
          const SyncStatusSummary(
            mode: SyncStatusMode.needsAttention,
            attentionCount: 2,
          ),
        ),
        'Some changes are saved on this phone. Tap for details',
      );
    });
  });

  group('states', () {
    testWidgets('offline', (tester) async {
      await _show(tester, _offline);
      expect(find.text('Offline mode · changes saved on this phone'), findsOneWidget);
      expect(find.byKey(_stripKey), findsOneWidget);
    });

    testWidgets('offline with waiting changes', (tester) async {
      await _show(
        tester,
        const SyncStatusSummary(mode: SyncStatusMode.offline, pendingCount: 3),
      );
      expect(
        find.text('Offline mode · changes saved on this phone'),
        findsOneWidget,
      );
    });

    testWidgets('unreachable', (tester) async {
      await _show(
        tester,
        const SyncStatusSummary(mode: SyncStatusMode.unreachable),
      );
      expect(
        find.text("Can't reach PandaPay · changes saved on this phone"),
        findsOneWidget,
      );
    });

    testWidgets('syncing', (tester) async {
      await _show(
        tester,
        const SyncStatusSummary(mode: SyncStatusMode.syncing, pendingCount: 2),
      );
      expect(find.text('Syncing…'), findsOneWidget);
    });

    testWidgets('needs attention', (tester) async {
      await _show(
        tester,
        const SyncStatusSummary(
          mode: SyncStatusMode.needsAttention,
          attentionCount: 3,
        ),
      );
      expect(find.text('Some changes are saved on this phone'), findsOneWidget);
    });

    testWidgets('hidden renders no strip at all', (tester) async {
      await _show(tester, _hidden);
      expect(find.byKey(_stripKey), findsNothing);
      expect(find.byType(SyncStatusStrip), findsNothing);
      expect(find.text('page body'), findsOneWidget);
    });

    testWidgets('the strip appears and disappears with the state', (
      tester,
    ) async {
      await _show(tester, _hidden);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      container.read(_mode.notifier).state = _offline;
      await tester.pumpAndSettle();
      expect(find.byKey(_stripKey), findsOneWidget);
      container.read(_mode.notifier).state = _hidden;
      await tester.pumpAndSettle();
      expect(find.byKey(_stripKey), findsNothing);
    });

    testWidgets('exposes one tappable semantics node with the full sentence', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _show(
        tester,
        const SyncStatusSummary(mode: SyncStatusMode.offline, pendingCount: 3),
      );
      expect(
        find.bySemanticsLabel('Offline, 3 changes waiting. Tap for details'),
        findsOneWidget,
      );
      final data = tester
          .getSemantics(
            find.bySemanticsLabel('Offline, 3 changes waiting. Tap for details'),
          )
          .getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });
  });

  group('layout', () {
    testWidgets('hidden: identical size and position to no wrapper at all', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.padding = const FakeViewPadding(top: 40, bottom: 20);
      tester.view.viewPadding = const FakeViewPadding(top: 40, bottom: 20);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(wrapped: false));
      await tester.pumpAndSettle();
      final bare = {
        'probe': tester.getRect(find.byKey(_probeKey)),
        'appBar': tester.getRect(find.byType(AppBar)),
        'scaffold': tester.getRect(find.byType(Scaffold)),
        'navigator': tester.getRect(find.byType(Navigator).first),
      };

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(wrapped: true));
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
          .read(_mode.notifier)
          .state = _hidden;
      await tester.pumpAndSettle();
      final wrapped = {
        'probe': tester.getRect(find.byKey(_probeKey)),
        'appBar': tester.getRect(find.byType(AppBar)),
        'scaffold': tester.getRect(find.byType(Scaffold)),
        'navigator': tester.getRect(find.byType(Navigator).first),
      };
      expect(wrapped, bare);
      expect(wrapped['appBar']!.height, kToolbarHeight + 40);
    });

    testWidgets('hidden: the child sees the same MediaQuery', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.padding = const FakeViewPadding(top: 40, bottom: 20);
      tester.view.viewPadding = const FakeViewPadding(top: 40, bottom: 20);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);

      Future<MediaQueryData> capture({required bool wrapped}) async {
        late MediaQueryData seen;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          _app(
            wrapped: wrapped,
            page: Builder(
              builder: (context) {
                seen = MediaQuery.of(context);
                return const SizedBox();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        return seen;
      }

      final bare = await capture(wrapped: false);
      final wrapped = await capture(wrapped: true);
      expect(wrapped.padding, bare.padding);
      expect(wrapped.viewPadding, bare.viewPadding);
      expect(wrapped.viewInsets, bare.viewInsets);
      expect(wrapped.size, bare.size);
      expect(wrapped.textScaler, bare.textScaler);
      expect(wrapped.padding.top, 40);
      expect(wrapped.viewInsets.bottom, 300);
    });

    testWidgets(
      'visible: the strip takes the status bar inset, content loses it',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 800);
        tester.view.padding = const FakeViewPadding(top: 40, bottom: 20);
        tester.view.viewPadding = const FakeViewPadding(top: 40, bottom: 20);
        addTearDown(tester.view.reset);
        late MediaQueryData seen;
        await tester.pumpWidget(
          _app(
            page: Scaffold(
              appBar: AppBar(title: const Text('Home page')),
              body: Builder(
                builder: (context) {
                  seen = MediaQuery.of(context);
                  return const SizedBox.expand(key: _probeKey);
                },
              ),
            ),
          ),
        );
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
            .read(_mode.notifier)
            .state = _offline;
        await tester.pumpAndSettle();

        final strip = tester.getRect(find.byKey(_stripKey));
        final appBar = tester.getRect(find.byType(AppBar));
        expect(strip.top, 0);
        expect(strip.width, 400);
        // 40 dp status bar plus a slim 22-26 dp line.
        expect(strip.height - 40, inInclusiveRange(16, 20));
        // The app bar starts where the strip ends and is NOT 40 dp taller.
        expect(appBar.top, strip.bottom);
        expect(appBar.height, kToolbarHeight);
        expect(seen.padding.top, 0);
        // Only the top inset moved to the strip; the bottom is untouched.
        expect(seen.padding.bottom, 20);
        expect(tester.getRect(find.byKey(_probeKey)).bottom, 800);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('visible with no status bar inset is still slim', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.reset);
      await _show(tester, _offline);
      final strip = tester.getRect(find.byKey(_stripKey));
      expect(strip.height, inInclusiveRange(16, 20));
    });

    testWidgets('toggling does not recreate the screen below', (tester) async {
      var created = 0;
      await tester.pumpWidget(_app(page: _Counter(() => created += 1)));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      await tester.pumpAndSettle();
      container.read(_mode.notifier).state = _offline;
      await tester.pumpAndSettle();
      container.read(_mode.notifier).state = _hidden;
      await tester.pumpAndSettle();
      container.read(_mode.notifier).state = _offline;
      await tester.pumpAndSettle();
      expect(created, 1, reason: 'state of the Navigator and screens is kept');
    });

    testWidgets('a large text size never overflows or grows past 2 lines', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      addTearDown(tester.view.reset);
      await _show(
        tester,
        const SyncStatusSummary(mode: SyncStatusMode.offline, pendingCount: 12),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byKey(_stripKey)).height, lessThan(48));
    });

    testWidgets('renders in dark mode', (tester) async {
      await _show(tester, _offline, themeMode: ThemeMode.dark);
      expect(find.text('Offline mode · changes saved on this phone'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('tap', () {
    testWidgets('opens the Sync status sheet', (tester) async {
      await _show(tester, _offline);
      await tester.tap(find.byKey(_stripKey));
      await tester.pumpAndSettle();
      expect(find.text('Sync status'), findsOneWidget);
    });

    testWidgets('does nothing while a dialog is on top (WP-H2)', (tester) async {
      await _show(
        tester,
        _offline,
        page: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => const AlertDialog(title: Text('Signing out')),
              ),
              child: const Text('open dialog'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open dialog'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_stripKey), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Sync status'), findsNothing);
      expect(find.text('Signing out'), findsOneWidget);
    });

    testWidgets('the sheet opens above the app, not inside the strip', (
      tester,
    ) async {
      await _show(
        tester,
        const SyncStatusSummary(
          mode: SyncStatusMode.needsAttention,
          attentionCount: 2,
        ),
      );
      await tester.tap(find.byKey(_stripKey));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('wiring', () {
    testWidgets(
      'real summary: offline strip shows without any account queues',
      (tester) async {
        final router = GoRouter(
          routes: [GoRoute(path: '/', builder: (_, _) => const _Page())],
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isOnlineProvider.overrideWith((_) => Stream.value(false)),
              cacheNamespaceProvider.overrideWithValue('signed-out'),
              reachabilityMonitorProvider.overrideWith(_NullMonitor.new),
              syncQueueTotalsProvider.overrideWith(
                (_) => Stream.value(
                  const SyncQueueTotals(pending: 5, attention: 1),
                ),
              ),
              needsAttentionCountProvider.overrideWithValue(2),
              lastSyncedAtProvider.overrideWith((_) async => null),
              syncQueueBreakdownProvider.overrideWith((_) async => const []),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              builder: (context, child) => SyncStatusBanner(
                navigatorKey: router.routerDelegate.navigatorKey,
                child: child,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Offline mode · changes saved on this phone'), findsOneWidget);
        expect(find.textContaining('waiting to sync'), findsNothing);
      },
    );
  });
}

class _NullMonitor extends ReachabilityMonitor {
  @override
  bool? build() => null;
}

class _Counter extends StatefulWidget {
  const _Counter(this.onCreate);
  final VoidCallback onCreate;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('counter'));
}
