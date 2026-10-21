import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../tool/referral_showcase.dart' as showcase;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows referral lifecycle and reward states on emulator', (
    tester,
  ) async {
    showcase.main();
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();

    expect(
      find.text(
        'PREVIEW ONLY · Synthetic referrals; no real credits are issued',
      ),
      findsOneWidget,
    );
    expect(find.text('DEMO26'), findsOneWidget);
    expect(find.text('Spin your reward'), findsOneWidget);
    expect(find.text('under review'), findsOneWidget);
    await binding.takeScreenshot('referral-showcase-rewards');

    await tester.scrollUntilVisible(
      find.text('Example friend 01 · joined'),
      450,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Bamboo 0/3 days'), findsOneWidget);
    expect(find.text('Joined'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Example friend 06 · credited'),
      450,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Example friend 06 · credited'), findsOneWidget);
    expect(find.text('Bamboo 1/3 days'), findsOneWidget);
    expect(find.text('Bamboo 2/3 days'), findsOneWidget);
    expect(find.text('Bamboo 3/3 days'), findsNWidgets(3));
    expect(find.text('Milestone complete'), findsOneWidget);
    expect(find.text('Under review'), findsOneWidget);
    expect(find.text('Credits added'), findsOneWidget);
    await binding.takeScreenshot('referral-showcase-friends');

    final spinButton = find.text('Spin your reward');
    await tester.ensureVisible(spinButton);
    await tester.pumpAndSettle();
    await tester.tap(spinButton);
    await tester.pumpAndSettle();
    expect(find.text('Your reward is ready'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('chance'), findsNothing);
    await binding.takeScreenshot('referral-spin-game');
    final gameAction = find.byKey(const Key('referral-spin-action'));
    await tester.ensureVisible(gameAction);
    await tester.pumpAndSettle();
    await tester.tap(gameAction);
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('SPINNING'), findsOneWidget);
    await binding.takeScreenshot('referral-spin-animation');
    await tester.pumpAndSettle();
    expect(find.text('Spin complete'), findsOneWidget);
    expect(find.text('₹25'), findsOneWidget);
    await binding.takeScreenshot('referral-spin-result');
    final done = find.text('Done');
    await tester.ensureVisible(done);
    await tester.pumpAndSettle();
    await tester.tap(done);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Saved reward: ₹25'),
      450,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Saved reward: ₹25'), findsOneWidget);
    await binding.takeScreenshot('referral-showcase-spin-confirmed');

    await tester.scrollUntilVisible(
      find.text('Example friend 04 · credited'),
      450,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Example friend 04 · credited'), findsOneWidget);
  });
}
