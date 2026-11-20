import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/design/bamboo_date_range_dialog.dart';

DateTimeRange? _result;
bool _closed = false;

Future<void> _open(WidgetTester tester, {DateTimeRange? initial}) async {
  _result = null;
  _closed = false;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              _result = await showBambooDateRangeDialog(
                context: context,
                firstDate: DateTime(2020),
                lastDate: DateTime(2026, 11, 20),
                initialRange: initial,
                helpText: 'Pick range',
              );
              _closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _day(WidgetTester tester, String day) async {
  await tester.tap(
    find.descendant(of: find.byType(Dialog), matching: find.text(day)),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

String _headline(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('range-calendar-headline'))).data!;

VoidCallback? _applyOnPressed(WidgetTester tester) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, 'Apply'))
    .onPressed;

void main() {
  testWidgets('tap start then end in one calendar, then Apply', (tester) async {
    await _open(tester);
    expect(find.text('November 2026'), findsOneWidget);
    expect(_applyOnPressed(tester), isNull, reason: 'nothing picked yet');

    await _day(tester, '10');
    expect(_headline(tester), contains('End date'));
    await _day(tester, '15');
    expect(_headline(tester), isNot(contains('End date')));

    // The days from first to last are filled: a visible band, not a collapsed box.
    final bands = find.byWidgetPredicate(
      (w) => w is ColoredBox && w.color == BambooInk.wash,
    );
    expect(bands, findsWidgets);
    for (final band in bands.evaluate()) {
      expect(band.size!.height, greaterThan(20));
      expect(band.size!.width, greaterThan(10));
    }

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(
      _result,
      DateTimeRange(start: DateTime(2026, 11, 10), end: DateTime(2026, 11, 15)),
    );
  });

  testWidgets('a day before the start becomes the new start', (tester) async {
    await _open(tester);
    await _day(tester, '15');
    await _day(tester, '10');
    expect(_headline(tester), contains('End date'));

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    // Only a start was picked, so it applies as a one-day range.
    expect(
      _result,
      DateTimeRange(start: DateTime(2026, 11, 10), end: DateTime(2026, 11, 10)),
    );
  });

  testWidgets('tapping after a finished range starts a new one', (
    tester,
  ) async {
    await _open(tester);
    await _day(tester, '3');
    await _day(tester, '5');
    await _day(tester, '12');
    expect(_headline(tester), contains('End date'));
    await _day(tester, '14');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(_result!.start, DateTime(2026, 11, 12));
    expect(_result!.end, DateTime(2026, 11, 14));
  });

  testWidgets(
    'future days are not selectable and the month stops at the last',
    (tester) async {
      await _open(tester);
      await _day(tester, '25'); // after lastDate (20 Nov)
      expect(_headline(tester), 'Start date – End date');
      expect(_applyOnPressed(tester), isNull);

      final next = find.widgetWithIcon(IconButton, Icons.chevron_right);
      expect(tester.widget<IconButton>(next).onPressed, isNull);
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      expect(find.text('October 2026'), findsOneWidget);
    },
  );

  testWidgets('reopens on the earlier range and Cancel returns nothing', (
    tester,
  ) async {
    await _open(
      tester,
      initial: DateTimeRange(
        start: DateTime(2026, 9, 2),
        end: DateTime(2026, 9, 9),
      ),
    );
    expect(find.text('September 2026'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_closed, isTrue);
    expect(_result, isNull);
  });
}
