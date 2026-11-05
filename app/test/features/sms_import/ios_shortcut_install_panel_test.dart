import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_import/ios_shortcut_links.dart';
import 'package:pandapay/features/sms_import/ios_sms_import_screen.dart';
import 'package:pandapay/features/sms_import/live_alert_status.dart';

const historyLink = 'https://www.icloud.com/shortcuts/0123456789abcdef';
const liveLink = 'https://www.icloud.com/shortcuts/fedcba9876543210';

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  test('only genuine iCloud shortcut links are accepted', () {
    expect(IosShortcutLinks.parse(historyLink), isNotNull);
    for (final bad in [
      '',
      'http://www.icloud.com/shortcuts/abc',
      'https://www.icloud.com/shortcuts/',
      'https://icloud.com.evil.example/shortcuts/abc',
      'https://drive.google.com/file/abc',
    ]) {
      expect(IosShortcutLinks.parse(bad), isNull, reason: bad);
    }
  });

  testWidgets('hidden until a link is set', (tester) async {
    await tester.pumpWidget(
      host(const IosShortcutInstallPanel(historyLink: '', liveLink: '')),
    );
    expect(find.text('PandaPay shortcuts'), findsNothing);
  });

  testWidgets('buttons open the matching shortcut link', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      host(
        IosShortcutInstallPanel(
          historyLink: historyLink,
          liveLink: liveLink,
          open: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('add-history-shortcut')));
    await tester.tap(find.byKey(const ValueKey('add-live-shortcut')));
    await tester.pump();
    expect(opened.map((u) => u.toString()), [historyLink, liveLink]);
    expect(find.textContaining('Automation'), findsOneWidget);
  });

  testWidgets('a failed open tells the person', (tester) async {
    await tester.pumpWidget(
      host(
        IosShortcutInstallPanel(
          historyLink: historyLink,
          liveLink: '',
          open: (_) async => false,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('add-history-shortcut')));
    await tester.pump();
    expect(find.text('Couldn’t open Shortcuts. Try again.'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-live-shortcut')), findsNothing);
  });

  testWidgets('working live alerts hide the live button', (tester) async {
    await tester.pumpWidget(
      host(
        const IosShortcutInstallPanel(
          historyLink: historyLink,
          liveLink: liveLink,
          liveHealth: LiveAlertHealth.working,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('add-history-shortcut')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-live-shortcut')), findsNothing);
  });

  testWidgets('quiet live alerts offer to turn them back on', (tester) async {
    await tester.pumpWidget(
      host(
        const IosShortcutInstallPanel(
          historyLink: historyLink,
          liveLink: liveLink,
          liveHealth: LiveAlertHealth.quiet,
        ),
      ),
    );
    expect(find.text('Turn live alerts back on'), findsOneWidget);
  });
}
