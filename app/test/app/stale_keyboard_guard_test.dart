import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/stale_keyboard_guard.dart';

void main() {
  var hides = 0;

  void listen(WidgetTester tester) {
    hides = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        if (call.method == 'TextInput.hide') hides++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        null,
      ),
    );
  }

  Widget app({required Widget field}) => StaleKeyboardGuard(
    child: MaterialApp(
      navigatorObservers: [StaleKeyboardObserver()],
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => field)),
          child: const Text('go'),
        ),
      ),
    ),
  );

  testWidgets('hides a keyboard that has nothing to type into', (tester) async {
    listen(tester);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Splits'))),
    );
    hideKeyboardIfNothingToTypeInto();
    await tester.idle();
    expect(hides, 1);
  });

  testWidgets('leaves the keyboard alone while a field is focused', (
    tester,
  ) async {
    listen(tester);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TextField(autofocus: true))),
    );
    await tester.pump();
    expect(textFieldHasFocus(), isTrue);
    hideKeyboardIfNothingToTypeInto();
    await tester.idle();
    expect(hides, 0);
  });

  testWidgets('a screen change hides it once things settle, not before', (
    tester,
  ) async {
    listen(tester);
    await tester.pumpWidget(app(field: const Text('next')));
    await tester.tap(find.text('go'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.idle();
    expect(hides, 0, reason: 'a new screen may be about to focus a field');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.idle();
    expect(hides, 1);
  });

  testWidgets('a screen that focuses its own field keeps its keyboard', (
    tester,
  ) async {
    listen(tester);
    await tester.pumpWidget(
      app(field: const Scaffold(body: TextField(autofocus: true))),
    );
    await tester.tap(find.text('go'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.idle();
    expect(hides, 0);
  });
}
