import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/scan/upi_qr_scanner_screen.dart';

void main() {
  testWidgets('renders design 03: Tap to Sniff header, reticle copy, torch and gallery', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: UpiQrScannerScreen()));
    await tester.pump();

    expect(find.text('Tap to Sniff'), findsOneWidget);
    expect(find.text('Point at the QR or bill'), findsOneWidget);
    expect(find.text('Works offline · No sign-in needed'), findsOneWidget);
    expect(find.byIcon(Icons.flash_off_rounded), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    // Gallery import is the primary button now, not an app-bar icon — the
    // camera is already scanning continuously, so "Scan now" would be a
    // button for something that's always happening.
    expect(find.text('Pick a QR from photos'), findsOneWidget);
  });
}
