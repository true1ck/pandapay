import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/scan/upi_qr_scanner_screen.dart';

void main() {
  testWidgets('renders the framing guide, torch and gallery actions', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UpiQrScannerScreen()));
    await tester.pump();

    expect(find.text('Scan to pay'), findsOneWidget);
    expect(find.byIcon(Icons.flash_off_rounded), findsOneWidget);
    expect(find.byIcon(Icons.photo_library_rounded), findsOneWidget);
  });
}
