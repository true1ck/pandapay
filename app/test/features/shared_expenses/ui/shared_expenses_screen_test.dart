import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/design/widgets.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_expenses_screen.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_group_screen.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_components.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_presentation.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

const zero = Money.zero();
const balances = SharedBalanceSummary(
  owedToYou: Money.fromPaise(1408181),
  youOwe: Money.fromPaise(1408181),
  netBalance: zero,
);
const rahul = SharedContextRow(id: 'rahul', title: 'Rahul', balance: balances);
const settled = SharedContextRow(
  id: 'old',
  title: 'Old trip',
  state: SharedContextState.settled,
  balance: SharedBalanceSummary(
    owedToYou: zero,
    youOwe: zero,
    netBalance: zero,
  ),
);
SharedHubPresentation hub({
  bool offline = false,
  bool hideAmounts = false,
  SharedPage<SharedContextRow>? friends,
}) => SharedHubPresentation(
  summary: balances,
  friends: friends ?? SharedPage(items: [rahul, settled]),
  groups: SharedPage(
    items: const [
      SharedContextRow(id: 'home', title: 'Home', balance: balances),
    ],
  ),
  activity: SharedPage(items: const []),
  offline: offline,
  hideAmounts: hideAmounts,
);

Future<void> pump(
  WidgetTester tester,
  Widget child, {
  double width = 430,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    BambooFonts.useSystemFontsForTests = true;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  testWidgets(
    'shared-only financial amounts are not labeled as the full bill or full payment',
    (tester) async {
      final data = SharedGroupPresentation(
        id: 'partial',
        title: 'Flatmates',
        expenses: SharedPage(
          items: const [
            SharedExpenseRow(
              id: 'expense',
              title: 'Dinner',
              paidBy: 'You',
              payerLabel: 'Shared amount paid by',
              totalLabel: 'Shared total',
              paidLabel: 'Your shared contribution',
              billTotal: Money.fromPaise(120000),
              yourPaid: Money.fromPaise(120000),
              yourShare: Money.fromPaise(40000),
            ),
          ],
        ),
        balances: SharedPage(),
        totals: const SharedExpenseTotals(
          totalLabel: 'Shared expense total',
          paidLabel: 'Your shared contributions',
          billTotal: Money.fromPaise(120000),
          yourPaid: Money.fromPaise(120000),
          yourShare: Money.fromPaise(40000),
        ),
      );
      await pump(tester, SharedGroupScreen(data: data));
      // A shared amount whose full bill is unknown is never called the bill.
      expect(find.text('You paid ₹1,200.00 (shared amount)'), findsOneWidget);
      expect(find.text('Bill total'), findsNothing);
      expect(find.text('You paid'), findsNothing);
      await tester.tap(find.text('Totals'));
      await tester.pumpAndSettle();
      expect(find.text('Your shared contributions'), findsOneWidget);
      expect(find.text('You paid'), findsNothing);
    },
  );

  testWidgets(
    'hub has one familiar top tab level and no replacement bottom bar',
    (tester) async {
      await pump(tester, SharedExpensesScreen(data: hub()));
      expect(find.byType(TabBar), findsOneWidget);
      for (final label in ['Friends', 'Groups', 'Activity']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.byType(BottomNavigationBar), findsNothing);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.text('Rahul'), findsOneWidget);
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Expenses'), findsNothing);
    },
  );

  testWidgets('gross directions survive net zero and never imply all settled', (
    tester,
  ) async {
    await pump(tester, SharedExpensesScreen(data: hub()));
    expect(find.text('You are owed'), findsWidgets);
    expect(find.text('You owe'), findsWidgets);
    expect(find.text('Overall, even'), findsOneWidget);
    expect(find.text('All settled'), findsNothing);
    expect(find.text('Old trip'), findsNothing);
  });

  testWidgets(
    'mixed obligations show the informational net and both gross directions',
    (tester) async {
      await pump(
        tester,
        SharedExpensesScreen(
          data: hub(
            friends: SharedPage(
              items: const [
                SharedContextRow(
                  id: 'mixed',
                  title: 'Mixed balances',
                  balance: SharedBalanceSummary(
                    owedToYou: Money.fromPaise(1000),
                    youOwe: Money.fromPaise(300),
                    netBalance: Money.fromPaise(700),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Net owed to you'), findsOneWidget);
      expect(find.text(const Money.fromPaise(700).format()), findsOneWidget);
      expect(find.text(const Money.fromPaise(1000).format()), findsOneWidget);
      expect(find.text(const Money.fromPaise(300).format()), findsOneWidget);
    },
  );

  testWidgets(
    'settled visibility is reversible and a new active obligation reappears',
    (tester) async {
      await pump(tester, SharedExpensesScreen(data: hub()));
      expect(
        tester.getTopLeft(find.text('Show settled friends')).dy,
        greaterThan(tester.getBottomLeft(find.text('Rahul')).dy),
      );
      await tester.tap(find.text('Show settled friends'));
      await tester.pumpAndSettle();
      expect(find.text('Old trip'), findsOneWidget);
      await tester.tap(find.text('Hide settled friends'));
      await tester.pumpAndSettle();
      expect(find.text('Old trip'), findsNothing);
      await pump(
        tester,
        SharedExpensesScreen(
          data: hub(
            friends: SharedPage(
              items: const [
                rahul,
                SharedContextRow(
                  id: 'old',
                  title: 'Old trip',
                  balance: balances,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Old trip'), findsOneWidget);
    },
  );

  testWidgets(
    'row navigation and one primary add action use caller callbacks',
    (tester) async {
      String? opened;
      var added = 0;
      await pump(
        tester,
        SharedExpensesScreen(
          data: hub(),
          onOpenFriend: (id) => opened = id,
          onAddExpense: () => added++,
        ),
      );
      await tester.tap(find.text('Rahul'));
      await tester.pumpAndSettle();
      expect(opened, 'rahul');
      final add = find.byTooltip('Add expense');
      expect(
        find.descendant(of: find.byType(AppBar), matching: add),
        findsNothing,
      );
      expect(tester.getCenter(add).dx, greaterThan(300));
      expect(tester.getCenter(add).dy, greaterThan(900));
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(added, 1);
      expect(add, findsOneWidget);
      expect(find.text('Add expense'), findsNothing);
      for (final label in ['Groups', 'Activity']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(add);
        await tester.pumpAndSettle();
      }
      expect(added, 3);
    },
  );

  testWidgets(
    'group plus is reachable on every tab and creates no duplicate footer',
    (tester) async {
      var added = 0;
      await pump(
        tester,
        SharedGroupScreen(
          data: SharedGroupPresentation(
            id: 'g',
            title: 'Flatmates',
            expenses: SharedPage(),
            balances: SharedPage(),
          ),
          onAddExpense: () => added++,
        ),
      );
      // No tabs any more: Balances and Totals open in place, and the plus
      // stays reachable whatever is open.
      expect(find.byType(TabBar), findsNothing);
      for (final section in [null, 'Balances', 'Totals']) {
        if (section != null) {
          await tester.tap(find.text(section));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('Add expense'));
        await tester.pumpAndSettle();
      }
      expect(added, 3);
      expect(find.byTooltip('Add expense'), findsOneWidget);
      expect(find.text('Add expense'), findsNothing);
    },
  );

  testWidgets('search and selected tab state remain when switching tabs', (
    tester,
  ) async {
    final searches = <String>[];
    await pump(
      tester,
      SharedExpensesScreen(
        data: hub(),
        onSearchChanged: (tab, query) => searches.add('${tab.name}:$query'),
      ),
    );
    expect(find.byType(TextField), findsNothing);
    final summaryTop = tester.getTopLeft(find.text('Overall, even')).dy;
    await tester.tap(find.byTooltip('Search splits'));
    await tester.pumpAndSettle();
    expect(find.text('Splits'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(TextField),
      ),
      findsOneWidget,
    );
    expect(tester.getTopLeft(find.text('Overall, even')).dy, summaryTop);
    expect(
      (tester.widget<TextField>(find.byType(TextField))).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), 'Rah');
    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Friends'));
    await tester.pumpAndSettle();
    expect(
      (tester.widget<TextField>(find.byType(TextField))).controller!.text,
      'Rah',
    );
    expect(searches, ['friends:Rah']);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(searches, ['friends:Rah', 'friends:']);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('Search splits'), findsOneWidget);
    await tester.tap(find.byTooltip('Search splits'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Again');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Splits'), findsOneWidget);
    expect(searches.last, 'friends:');
    await tester.tap(find.byTooltip('Search splits'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Splits'), findsOneWidget);
    for (final tab in ['Groups', 'Activity']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search splits'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'query');
      await tester.pump();
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        (tester.widget<TextField>(find.byType(TextField))).controller!.text,
        isEmpty,
      );
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Search splits'), findsOneWidget);
    }
  });

  testWidgets('filter applies to the selected tab without hiding active debt', (
    tester,
  ) async {
    await pump(tester, SharedExpensesScreen(data: hub()));
    await tester.tap(find.byTooltip('Filter splits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Include settled friends'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Old trip'), findsOneWidget);
    expect(find.text('Rahul'), findsOneWidget);
    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();
    expect(find.text('Show settled groups'), findsOneWidget);
  });

  testWidgets('hub balance and compact rows fit narrow screens at large text', (
    tester,
  ) async {
    await pump(tester, SharedExpensesScreen(data: hub()), width: 320, scale: 2);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Rahul'),
      160,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('friends')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('You owe'), findsWidgets);
    await tester.tap(find.byTooltip('Search splits'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.byType(TextField)).dx,
      greaterThan(tester.getTopRight(find.text('Splits')).dx),
    );
  });

  testWidgets(
    'offline and incomplete coverage are explicit and retain cached content',
    (tester) async {
      await pump(
        tester,
        SharedExpensesScreen(
          data: hub(
            offline: true,
            friends: SharedPage(items: const [rahul], incomplete: true),
          ),
        ),
      );
      // The global "Offline mode" banner already says this; no duplicate here.
      expect(find.text('Offline · showing saved splits'), findsNothing);
      expect(find.text(sharedCatchingUpCopy), findsOneWidget);
      expect(find.text('Rahul'), findsOneWidget);
      expect(find.text('Settled!'), findsNothing);
    },
  );

  testWidgets('initial loading does not fabricate zero balances', (
    tester,
  ) async {
    await pump(
      tester,
      SharedExpensesScreen(
        data: SharedHubPresentation(
          friends: SharedPage(state: SharedLoadState.loading),
          groups: SharedPage(state: SharedLoadState.loading),
          activity: SharedPage(state: SharedLoadState.loading),
        ),
      ),
    );
    expect(find.byType(SkeletonList), findsOneWidget);
    expect(find.text('Overall, even'), findsNothing);
    expect(find.text('All settled'), findsNothing);
  });

  testWidgets('error retries and load-more stay explicit, bounded actions', (
    tester,
  ) async {
    var retried = 0, loaded = 0;
    await pump(
      tester,
      SharedExpensesScreen(
        data: hub(friends: SharedPage(state: SharedLoadState.error)),
        onRetry: (_) => retried++,
      ),
    );
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(retried, 1);
    await pump(
      tester,
      SharedExpensesScreen(
        data: hub(friends: SharedPage(items: const [rahul], hasMore: true)),
        onLoadMore: (_) => loaded++,
      ),
    );
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(loaded, 1);
  });

  testWidgets('revoked access never renders cached private rows or summary', (
    tester,
  ) async {
    await pump(
      tester,
      SharedExpensesScreen(
        data: hub(
          friends: SharedPage(
            items: const [rahul],
            state: SharedLoadState.accessRevoked,
          ),
        ),
      ),
    );
    expect(find.text('Rahul'), findsNothing);
    expect(find.text('You no longer have access'), findsOneWidget);
    expect(find.text('Overall, even'), findsNothing);
  });

  testWidgets('hidden amount preference hides every numeric money semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pump(tester, SharedExpensesScreen(data: hub(hideAmounts: true)));
      expect(find.textContaining('₹'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('₹')), findsNothing);
      expect(find.text('You owe'), findsWidgets);
      expect(find.text('••••'), findsWidgets);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'group page is one scroll; rows say who paid and what it means for you',
    (tester) async {
      final data = SharedGroupPresentation(
        id: 'g',
        title: 'Flatmates',
        summary: balances,
        expenses: SharedPage(
          items: const [
            SharedExpenseRow(
              id: 'e',
              title: 'Dinner',
              paidBy: 'Rahul',
              billTotal: Money.fromPaise(120000),
              yourPaid: zero,
              yourShare: Money.fromPaise(40000),
            ),
          ],
        ),
        balances: SharedPage(items: const [rahul]),
        totals: const SharedExpenseTotals(
          billTotal: Money.fromPaise(120000),
          yourPaid: zero,
          yourShare: Money.fromPaise(40000),
        ),
      );
      await pump(tester, SharedGroupScreen(data: data));
      // One scroll: no tab bar; Balances and Totals are actions under the
      // balance and open in place.
      expect(find.byType(TabBar), findsNothing);
      for (final label in ['Balances', 'Totals']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Friends'), findsNothing);
      // One plain line per expense: who paid, and what it means for you.
      expect(find.text('Rahul paid ₹1,200.00'), findsOneWidget);
      expect(find.text('you owe'), findsOneWidget);
      expect(find.text(const Money.fromPaise(40000).format()), findsOneWidget);
      for (final label in ['Bill total', 'You paid', 'Your share']) {
        expect(find.text(label), findsNothing, reason: 'the numbers live in the expense');
      }
      await tester.tap(find.text('Totals'));
      await tester.pumpAndSettle();
      expect(find.text('Total bills'), findsOneWidget);
    },
  );

  testWidgets(
    'payer-only and uninvolved rows have different honest copy at large text',
    (tester) async {
      await pump(
        tester,
        SharedGroupScreen(
          data: SharedGroupPresentation(
            id: 'g',
            title: 'A very long flatmates group name with many people',
            expenses: SharedPage(
              items: const [
                SharedExpenseRow(
                  id: 'e',
                  title: 'You bought groceries for the entire shared apartment',
                  paidBy: 'You',
                  billTotal: Money.fromPaise(120000),
                  yourPaid: Money.fromPaise(120000),
                  yourShare: zero,
                  participation: SharedParticipation.paidForOthers,
                ),
                SharedExpenseRow(
                  id: 'f',
                  title: 'Another members internet subscription',
                  paidBy: 'Rahul',
                  billTotal: Money.fromPaise(10000),
                  yourPaid: zero,
                  yourShare: zero,
                  participation: SharedParticipation.notIncluded,
                ),
              ],
            ),
            balances: SharedPage(),
          ),
        ),
        width: 320,
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('you lent'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('not involved'),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('g:expenses')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('not involved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stale settled metadata cannot hide an outstanding gross balance',
    (tester) async {
      await pump(
        tester,
        SharedExpensesScreen(
          data: hub(
            friends: SharedPage(
              items: const [
                SharedContextRow(
                  id: 'stale',
                  title: 'New balance',
                  state: SharedContextState.settled,
                  balance: balances,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('New balance'), findsOneWidget);
      expect(find.text('Balance changed · needs review'), findsOneWidget);
      expect(find.text('Settled'), findsNothing);
      expect(find.text('You owe'), findsWidgets);
    },
  );

  testWidgets(
    'maximum exact money stays bounded with complete accessible value',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        const maximum = Money.fromPaise(9007199254740991);
        await pump(
          tester,
          SharedGroupScreen(
            data: SharedGroupPresentation(
              id: 'g',
              title: 'Totals',
              expenses: SharedPage(),
              balances: SharedPage(),
              totals: const SharedExpenseTotals(
                billTotal: maximum,
                yourPaid: maximum,
                yourShare: maximum,
              ),
            ),
            initialIndex: 2,
          ),
          width: 320,
          scale: 2,
        );
        expect(tester.takeException(), isNull);
        expect(find.text(maximum.format()), findsNWidgets(3));
        // Label and value may merge into one accessible row. Check the full
        // value survives rather than requiring a particular node topology.
        for (var index = 0; index < 3; index++) {
          expect(
            tester.getSemantics(find.text(maximum.format()).at(index)).label,
            contains(maximum.format()),
          );
        }
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'activity routes an existing update without creating a payment action',
    (tester) async {
      String? opened;
      await pump(
        tester,
        SharedExpensesScreen(
          initialIndex: 2,
          onOpenActivity: (id) => opened = id,
          data: SharedHubPresentation(
            friends: SharedPage(),
            groups: SharedPage(),
            activity: SharedPage(
              items: const [
                SharedActivityRow(
                  id: 'event',
                  description: 'Rahul updated Dinner',
                  occurredAtLabel: 'Today at 12:03',
                  contextLabel: 'Flatmates',
                  impactLabel: 'Awaiting your review',
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Awaiting your review'), findsOneWidget);
      expect(find.text('Settled'), findsNothing);
      expect(find.text('Recent changes'), findsOneWidget);
      expect(find.text('View update'), findsNothing);
      await tester.tap(find.text('Rahul updated Dinner'));
      await tester.pumpAndSettle();
      expect(opened, 'event');
    },
  );

  testWidgets('activity groups actual timestamps and keeps pending copy', (
    tester,
  ) async {
    final now = DateTime.now();
    await pump(
      tester,
      SharedExpensesScreen(
        initialIndex: 2,
        data: SharedHubPresentation(
          summary: balances,
          friends: SharedPage(),
          groups: SharedPage(),
          activity: SharedPage(
            items: [
              SharedActivityRow(
                id: 'a',
                description: 'Payment reported',
                occurredAtLabel: now.toUtc().toIso8601String(),
                impactLabel: 'Awaiting your confirmation',
              ),
              SharedActivityRow(
                id: 'b',
                description: 'Group created',
                occurredAtLabel: now
                    .subtract(const Duration(days: 1))
                    .toUtc()
                    .toIso8601String(),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Awaiting your confirmation'), findsOneWidget);
    expect(find.text(now.toUtc().toIso8601String()), findsNothing);
    expect(find.text('You are owed'), findsNothing);
  });

  test('oversized page DTOs are rejected rather than silently truncating', () {
    expect(
      () => SharedPage(items: List.filled(101, rahul)),
      throwsArgumentError,
    );
  });

  testWidgets('expenses are grouped under their month', (tester) async {
    await pump(
      tester,
      SharedGroupScreen(
        data: SharedGroupPresentation(
          id: 'g',
          title: 'Flatmates',
          expenses: SharedPage(
            items: const [
              SharedExpenseRow(
                id: 'a',
                title: 'Dinner',
                paidBy: 'You',
                billTotal: Money.fromPaise(120000),
                yourPaid: Money.fromPaise(120000),
                yourShare: Money.fromPaise(60000),
                occurredAtLabel: '2026-11-11',
              ),
              SharedExpenseRow(
                id: 'b',
                title: 'Taxi',
                paidBy: 'You',
                billTotal: Money.fromPaise(30000),
                yourPaid: Money.fromPaise(30000),
                yourShare: Money.fromPaise(15000),
                occurredAtLabel: '2026-11-02',
              ),
              SharedExpenseRow(
                id: 'c',
                title: 'Rent',
                paidBy: 'Other members',
                billTotal: Money.fromPaise(500000),
                yourPaid: zero,
                yourShare: Money.fromPaise(250000),
                occurredAtLabel: '2026-10-28',
              ),
            ],
          ),
          balances: SharedPage(),
        ),
      ),
    );
    expect(find.text('November 2026'), findsOneWidget, reason: 'once, not per row');
    expect(find.text('October 2026'), findsOneWidget);
    expect(find.text('you lent'), findsNWidgets(2));
    expect(find.text('you owe'), findsOneWidget);
  });

  testWidgets('the overall card shows the gross lines only when both are real', (
    tester,
  ) async {
    Future<void> show(SharedBalanceSummary summary) => pump(
      tester,
      SharedGroupScreen(
        data: SharedGroupPresentation(
          id: 'g',
          title: 'Flatmates',
          summary: summary,
          expenses: SharedPage(),
          balances: SharedPage(),
        ),
      ),
    );
    Finder inCard(String text) => find.descendant(
      of: find.byType(SharedSummaryCard),
      matching: find.text(text),
    );
    await show(
      SharedBalanceSummary(
        owedToYou: Money.zero(),
        youOwe: const Money.fromPaise(50000),
        netBalance: const Money.fromPaise(-50000),
      ),
    );
    expect(inCard('Overall, you owe'), findsOneWidget);
    expect(inCard('You are owed'), findsNothing, reason: 'it would only repeat the headline');
    await show(
      SharedBalanceSummary(
        owedToYou: Money.fromPaise(100000),
        youOwe: Money.fromPaise(30000),
        netBalance: Money.fromPaise(70000),
      ),
    );
    expect(inCard('Overall, you are owed'), findsOneWidget);
    expect(inCard('You are owed'), findsOneWidget);
    expect(inCard('You owe'), findsOneWidget);
    await show(
      SharedBalanceSummary(
        owedToYou: Money.zero(),
        youOwe: Money.zero(),
        netBalance: Money.zero(),
      ),
    );
    expect(inCard('All settled up'), findsOneWidget);
  });

  testWidgets('Settle up sits under the balance, and only when there is one', (
    tester,
  ) async {
    var tapped = 0;
    Future<void> show(SharedBalanceSummary summary) => pump(
      tester,
      SharedGroupScreen(
        onSettleUp: () => tapped++,
        data: SharedGroupPresentation(
          id: 'g',
          title: 'Ravi',
          direct: true,
          summary: summary,
          expenses: SharedPage(),
          balances: SharedPage(),
        ),
      ),
    );
    await show(
      SharedBalanceSummary(
        owedToYou: Money.zero(),
        youOwe: const Money.fromPaise(50000),
        netBalance: const Money.fromPaise(-50000),
      ),
    );
    await tester.tap(find.byKey(const Key('expenses-settle-up')));
    expect(tapped, 1);
    await show(
      SharedBalanceSummary(
        owedToYou: Money.zero(),
        youOwe: Money.zero(),
        netBalance: Money.zero(),
      ),
    );
    expect(find.byKey(const Key('expenses-settle-up')), findsNothing);
  });

  testWidgets('a friend page reads like Splitwise: who owes whom, no tabs', (
    tester,
  ) async {
    var history = 0;
    await pump(
      tester,
      SharedGroupScreen(
        onSettleUp: () {},
        onViewSettlements: () => history++,
        data: SharedGroupPresentation(
          id: 'f',
          title: 'Sujay',
          direct: true,
          summary: SharedBalanceSummary(
            owedToYou: Money.zero(),
            youOwe: const Money.fromPaise(50000),
            netBalance: const Money.fromPaise(-50000),
          ),
          expenses: SharedPage(
            items: const [
              SharedExpenseRow(
                id: 'e',
                title: 'test payment',
                paidBy: 'Other members',
                billTotal: Money.fromPaise(100000),
                yourPaid: zero,
                yourShare: Money.fromPaise(50000),
                occurredAtLabel: '2026-11-14',
              ),
            ],
          ),
          balances: SharedPage(),
          totals: const SharedExpenseTotals(
            billTotal: Money.fromPaise(100000),
            yourPaid: zero,
            yourShare: Money.fromPaise(50000),
          ),
        ),
      ),
    );
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('You owe Sujay'), findsOneWidget);
    expect(find.text('Sujay paid ₹1,000.00'), findsOneWidget);
    expect(find.text('Balances'), findsNothing, reason: 'the line above says it');
    expect(find.text('Settle up'), findsOneWidget);
    // Totals open in place, and close again.
    expect(find.text('Total bills'), findsNothing);
    await tester.tap(find.text('Totals'));
    await tester.pumpAndSettle();
    expect(find.text('Total bills'), findsOneWidget);
    await tester.tap(find.text('Totals').first);
    await tester.pumpAndSettle();
    expect(find.text('Total bills'), findsNothing);
    await tester.tap(find.text('Payment history'));
    expect(history, 1);
  });

  testWidgets('a group keeps its balances: open in place, tap one to settle', (
    tester,
  ) async {
    String? opened;
    await pump(
      tester,
      SharedGroupScreen(
        onOpenBalance: (id) => opened = id,
        data: SharedGroupPresentation(
          id: 'g',
          title: 'Flatmates',
          summary: balances,
          expenses: SharedPage(),
          balances: SharedPage(items: const [rahul]),
        ),
      ),
    );
    expect(find.text('Rahul'), findsNothing);
    await tester.tap(find.text('Balances'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rahul'));
    expect(opened, 'rahul');
  });

  testWidgets('opening on Balances or Totals still works for old links', (
    tester,
  ) async {
    await pump(
      tester,
      SharedGroupScreen(
        initialIndex: 1,
        data: SharedGroupPresentation(
          id: 'g',
          title: 'Flatmates',
          expenses: SharedPage(),
          balances: SharedPage(items: const [rahul]),
        ),
      ),
    );
    expect(find.text('Rahul'), findsOneWidget);
  });
}
