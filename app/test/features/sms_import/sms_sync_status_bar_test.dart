import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_controller.dart';
import 'package:pandapay/features/sms_import/ios_sms_intake_providers.dart';
import 'package:pandapay/features/sms_import/sms_sync_status_bar.dart';

import 'ios_sms_intake_controller_test.dart' show MemoryBridge;

class _StatusController extends IosSmsIntakeController {
  _StatusController(MemoryBridge service)
    : super(
        service: service,
        namespace: () => 'user:test',
        capture: (_, _, _) async => [],
        requestUpload: () {},
      );
  IosSmsIntakeState value = _status();
  @override
  IosSmsIntakeState get state => value;
  void emit(IosSmsIntakeState next) {
    value = next;
    notifyListeners();
  }
}

IosSmsIntakeState _status({
  bool busy = false,
  bool job = false,
  bool enabled = true,
  int received = 0,
}) => IosSmsIntakeState(
  processing: busy,
  snapshot: {
    'enabled': enabled,
    'jobs': [
      if (job) {'id': 'history', 'kind': 'history', 'state': 'active'},
    ],
    'windows': [
      if (job)
        {
          'id': 'w',
          'job_id': 'history',
          'state': 'waiting',
          'start': '2026-09-01T00:00:00Z',
          'end': '2026-10-01T00:00:00Z',
          'enumerated': received,
        },
    ],
  },
);

class _Page extends StatefulWidget {
  final VoidCallback onMount, onBuild;
  const _Page({required this.onMount, required this.onBuild});
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  final text = TextEditingController(), scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    text.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return Column(
      children: [
        const Text('Your activity', key: ValueKey('page-anchor')),
        TextField(controller: text),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            itemCount: 100,
            itemBuilder: (_, i) => SizedBox(height: 50, child: Text('Item $i')),
          ),
        ),
      ],
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _StatusController controller,
  MemoryBridge service,
  Widget page, {
  bool reducedMotion = false,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        iosSmsIntakeServiceProvider.overrideWithValue(service),
        iosSmsIntakeControllerProvider.overrideWith((_) => controller),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(320, 640),
            padding: const EdgeInsets.only(top: 44),
            disableAnimations: reducedMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(body: SmsSyncStatusLayout(child: page)),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => BambooFonts.useSystemFontsForTests = true);
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  testWidgets('burst updates never remount the page or bounce its content', (
    tester,
  ) async {
    final service = MemoryBridge(),
        controller = _StatusController(MemoryBridge());
    var mounts = 0, builds = 0;
    final page = _Page(onMount: () => mounts++, onBuild: () => builds++);
    await _pump(tester, controller, service, page);
    final original = tester.state<_PageState>(find.byType(_Page));
    final idleTop = tester
        .getTopLeft(find.byKey(const ValueKey('page-anchor')))
        .dy;
    await tester.enterText(find.byType(TextField), 'Keep this edit');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    original.scroll.jumpTo(200);
    await tester.pump();

    controller.emit(_status(busy: true));
    await tester.pump(const Duration(milliseconds: 199));
    expect(find.byType(SmsSyncStatusBar), findsNothing);
    await tester.pump(const Duration(milliseconds: 2));
    expect(find.byType(SmsSyncStatusBar), findsOneWidget);
    final activeTop = tester
        .getTopLeft(find.byKey(const ValueKey('page-anchor')))
        .dy;
    expect(activeTop, greaterThan(idleTop));
    for (var i = 0; i < 5; i++) {
      controller.emit(_status());
      await tester.pump(const Duration(milliseconds: 300));
      controller.emit(_status(busy: true));
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('page-anchor'))).dy,
        activeTop,
      );
    }
    controller.emit(_status(job: true));
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('page-anchor'))).dy,
      activeTop,
    );
    controller.emit(_status(job: true, busy: true));
    await tester.pump();
    final beforeCounts = builds;
    for (var i = 1; i <= 20; i++) {
      controller.emit(_status(job: true, busy: true, received: i));
      await tester.pump();
    }
    expect(
      builds,
      beforeCounts,
      reason: 'Receipt updates cannot rebuild the page',
    );
    expect(
      find.text('Importing history · 0 of 1 months checked'),
      findsOneWidget,
    );
    controller.emit(_status());
    await tester.pump(const Duration(milliseconds: 901));
    expect(find.byType(SmsSyncStatusBar), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('page-anchor'))).dy,
      idleTop,
    );
    expect(tester.state<_PageState>(find.byType(_Page)), same(original));
    expect(original.text.text, 'Keep this edit');
    expect(original.scroll.offset, 200);
    expect(mounts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'short work never flashes the strip and revocation hides it immediately',
    (tester) async {
      final service = MemoryBridge(),
          controller = _StatusController(MemoryBridge());
      await _pump(tester, controller, service, const Text('Page'));
      controller.emit(_status(busy: true));
      await tester.pump(const Duration(milliseconds: 100));
      controller.emit(_status());
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SmsSyncStatusBar), findsNothing);
      controller.emit(_status(busy: true));
      await tester.pump(const Duration(milliseconds: 201));
      expect(find.byType(SmsSyncStatusBar), findsOneWidget);
      controller.emit(_status(enabled: false));
      await tester.pump();
      expect(find.byType(SmsSyncStatusBar), findsNothing);
      controller.emit(_status(busy: true));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large text, stable progress height and reduced motion are supported',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = MemoryBridge(),
          controller = _StatusController(MemoryBridge());
      controller.value = _status(busy: true, job: true);
      await _pump(
        tester,
        controller,
        service,
        const Text('Page', key: ValueKey('page')),
        reducedMotion: true,
        textScale: 2.5,
      );
      final top = tester.getTopLeft(find.byKey(const ValueKey('page'))).dy;
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        1,
      );
      controller.emit(_status(job: true));
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(const ValueKey('page'))).dy, top);
      expect(find.text('Details'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
