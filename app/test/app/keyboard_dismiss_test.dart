import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirrors the app-wide wrapper in main.dart's MaterialApp.builder.
Widget _app() => MaterialApp(
  builder: (context, child) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
    child: child!,
  ),
  home: const Scaffold(
    body: Column(
      children: [
        TextField(key: Key('field')),
        Expanded(child: Center(child: Text('outside'))),
      ],
    ),
  ),
);

void main() {
  testWidgets('tapping outside a text field unfocuses it', (tester) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.byKey(const Key('field')));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('outside'));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('tapping the field keeps focus', (tester) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.byKey(const Key('field')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('field')));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
  });
}
