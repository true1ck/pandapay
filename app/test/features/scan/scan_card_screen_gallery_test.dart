import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/features/scan/card_scanner.dart';
import 'package:pandapay/features/scan/card_text_matcher.dart';
import 'package:pandapay/features/scan/scan_card_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Covers the "Upload a photo instead" path added to [ScanCardScreen]:
/// picking an image from the gallery and running it through the same
/// on-device OCR / QR pipeline as the live camera, without regressing the
/// live paths or the "a captured frame is deleted" privacy contract.

class _FakeRecognizer implements CardTextRecognizer {
  _FakeRecognizer(this.text);

  final String text;
  int recognizeCalls = 0;
  String? lastPath;
  bool disposed = false;

  @override
  Future<ExtractedCardText> recognizeText(String imagePath) async {
    recognizeCalls++;
    lastPath = imagePath;
    return ExtractedCardText(text);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

final _catalogue = [
  const CardProduct(id: 'c1', name: 'HDFC Millennia', network: CardNetwork.visa),
  const CardProduct(id: 'c2', name: 'SBI Cashback', network: CardNetwork.rupay),
];

Widget _host(Widget home) => MaterialApp(theme: AppTheme.light(), home: home);

/// The screen never settles (camera-preview pulse animation + progress
/// spinners), so we step time explicitly instead of pumpAndSettle.
Future<void> _tick(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('OCR mode: picking a photo runs OCR and shows catalogue matches', (tester) async {
    final recognizer = _FakeRecognizer('HDFC BANK MILLENNIA VISA');
    await tester.pumpWidget(
      _host(
        ScanCardScreen(
          catalogue: _catalogue,
          recognizerFactory: () => recognizer,
          pickImagePath: () async => '/tmp/fake-card.jpg',
        ),
      ),
    );
    await _tick(tester);

    expect(find.text('Upload a photo instead'), findsOneWidget);
    await tester.tap(find.text('Upload a photo instead'));
    await _tick(tester);

    expect(recognizer.recognizeCalls, 1);
    expect(recognizer.lastPath, '/tmp/fake-card.jpg');
    expect(find.text('Possible matches'), findsOneWidget);
    expect(find.text('HDFC Millennia'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Use this'), findsWidgets);
    // OCR of a physical card face is never echoed back verbatim.
    expect(find.text('Scanned text'), findsNothing);
  });

  testWidgets('OCR mode: "Use this" returns the chosen product to the caller', (tester) async {
    CardProduct? popped;

    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<CardProduct>(
                    MaterialPageRoute(
                      builder: (_) => ScanCardScreen(
                        catalogue: _catalogue,
                        recognizerFactory: () => _FakeRecognizer('HDFC MILLENNIA VISA'),
                        pickImagePath: () async => '/tmp/fake-card.jpg',
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _tick(tester);

    await tester.tap(find.text('Upload a photo instead'));
    await _tick(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Use this').first);
    await _tick(tester);

    expect(popped, isNotNull);
    expect(popped!.id, 'c1');
  });

  testWidgets('OCR mode: backing out of the picker leaves the idle hint untouched', (tester) async {
    await tester.pumpWidget(
      _host(
        ScanCardScreen(
          catalogue: _catalogue,
          recognizerFactory: () => _FakeRecognizer('unused'),
          pickImagePath: () async => null,
        ),
      ),
    );
    await _tick(tester);

    await tester.tap(find.text('Upload a photo instead'));
    await _tick(tester);

    expect(find.text('Frame the front of your card'), findsOneWidget);
    expect(find.text('Possible matches'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OCR mode: an unreadable photo shows a hint and stays on the picker', (tester) async {
    await tester.pumpWidget(
      _host(
        ScanCardScreen(
          catalogue: _catalogue,
          recognizerFactory: () => _FakeRecognizer('   '),
          pickImagePath: () async => '/tmp/blurry.jpg',
        ),
      ),
    );
    await _tick(tester);

    await tester.tap(find.text('Upload a photo instead'));
    await _tick(tester);

    expect(
      find.textContaining("Couldn't read a card in that photo"),
      findsOneWidget,
    );
    expect(find.text('Frame the front of your card'), findsOneWidget);
  });

  testWidgets('QR mode: picking an image decodes the barcode and shows the payload', (tester) async {
    await tester.pumpWidget(
      _host(
        ScanCardScreen(
          catalogue: _catalogue,
          pickImagePath: () async => '/tmp/statement.png',
          decodeBarcodeFromImage: (path) async => 'SBI CASHBACK RUPAY CARD',
        ),
      ),
    );
    await _tick(tester);

    await tester.tap(find.text('QR / barcode'));
    await _tick(tester);
    expect(find.text('Pick an image instead'), findsOneWidget);

    await tester.tap(find.text('Pick an image instead'));
    await _tick(tester);

    // QR payloads are shown verbatim (unlike OCR).
    expect(find.text('Scanned text'), findsOneWidget);
    expect(find.text('SBI Cashback'), findsOneWidget);
  });

  testWidgets('QR mode: an image with no code shows a hint', (tester) async {
    await tester.pumpWidget(
      _host(
        ScanCardScreen(
          catalogue: _catalogue,
          pickImagePath: () async => '/tmp/cat.png',
          decodeBarcodeFromImage: (path) async => null,
        ),
      ),
    );
    await _tick(tester);

    await tester.tap(find.text('QR / barcode'));
    await _tick(tester);
    await tester.tap(find.text('Pick an image instead'));
    await _tick(tester);

    expect(find.textContaining('No QR code or barcode found'), findsOneWidget);
  });

  testWidgets('privacy: a gallery-picked file is never deleted', (tester) async {
    final dir = await Directory.systemTemp.createTemp('scan_card_gallery_test');
    addTearDown(() => dir.delete(recursive: true));
    final photo = File('${dir.path}/my-card.jpg')..writeAsBytesSync([1, 2, 3, 4]);

    await tester.pumpWidget(
      _host(
        ScanCardScreen(
          catalogue: _catalogue,
          recognizerFactory: () => _FakeRecognizer('HDFC MILLENNIA VISA'),
          pickImagePath: () async => photo.path,
        ),
      ),
    );
    await _tick(tester);

    await tester.tap(find.text('Upload a photo instead'));
    await _tick(tester);
    await tester.pump(const Duration(seconds: 1));

    expect(photo.existsSync(), isTrue, reason: 'the user\'s own photo must be left alone');
  });

  testWidgets('the recognizer is disposed with the screen', (tester) async {
    final recognizer = _FakeRecognizer('HDFC MILLENNIA VISA');
    await tester.pumpWidget(
      _host(
        ScanCardScreen(
          catalogue: _catalogue,
          recognizerFactory: () => recognizer,
          pickImagePath: () async => '/tmp/fake-card.jpg',
        ),
      ),
    );
    await _tick(tester);
    await tester.tap(find.text('Upload a photo instead'));
    await _tick(tester);

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await _tick(tester);

    expect(recognizer.disposed, isTrue);
  });
}
