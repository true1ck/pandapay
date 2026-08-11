import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import 'card_scanner.dart';
import 'card_text_matcher.dart';

/// UA-4 (Chunk 30): camera-based "scan to add a card" flow, launched from
/// `cards_screen.dart`'s `_AddCardForm` as an alternative to the manual
/// catalogue dropdown (which remains the fallback — this screen always
/// returns to it rather than replacing it, per the task's scope).
///
/// Scope reduction stated up front (this codebase's convention): full
/// physical-card OCR recognition (network logo / embossed digits / issuer
/// wordmark as printed) is out of scope. This screen scans a QR/barcode
/// (e.g. printed on some card mailers/statements) via `mobile_scanner`,
/// running whatever text payload it decodes through the same pure
/// `matchCardText` fuzzy-matcher used for camera-OCR-recognized text. A
/// still-photo "OCR a card" capture path (via `MlKitCardTextRecognizer`) is
/// also wired for the same matcher, but — like the QR path — could not be
/// exercised against real camera hardware in this sandbox; see PROGRESS.md.
///
/// If nothing clears a confidence floor, no candidate is auto-selected: the
/// raw extracted text is shown and the user must confirm manually from the
/// catalogue, never a fabricated guess (same rule as AD-4.3).
class ScanCardScreen extends StatefulWidget {
  final List<CardProduct> catalogue;

  const ScanCardScreen({super.key, required this.catalogue});

  @override
  State<ScanCardScreen> createState() => _ScanCardScreenState();
}

class _ScanCardScreenState extends State<ScanCardScreen> {
  final MobileScannerController _controller = MobileScannerController();
  ExtractedCardText? _lastExtracted;
  List<CardMatch> _matches = const [];
  bool _handling = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handling || capture.barcodes.isEmpty) return;
    final extracted = extractedTextFromBarcode(capture.barcodes.first);
    if (extracted.rawText.isEmpty) return;
    setState(() {
      _handling = true;
      _lastExtracted = extracted;
      _matches = matchCardText(extracted, widget.catalogue);
    });
  }

  void _rescan() {
    setState(() {
      _handling = false;
      _lastExtracted = null;
      _matches = const [];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Scan a card (QR/barcode)', style: BambooFonts.heading(16, color: BambooInk.ink900)),
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: _handling
                ? const Center(child: Icon(Icons.qr_code_scanner, size: 64, color: BambooInk.ink500))
                : MobileScanner(controller: _controller, onDetect: _onDetect),
          ),
          Expanded(
            flex: 2,
            child: _lastExtracted == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Point the camera at a QR code or barcode on a card mailer or '
                        'statement. Full physical-card OCR is not supported yet — use the '
                        'manual picker below the wallet for cards without a scannable code.',
                        textAlign: TextAlign.center,
                        style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                      ),
                    ),
                  )
                : _ResultPanel(
                    extracted: _lastExtracted!,
                    matches: _matches,
                    onConfirm: (product) => Navigator.of(context).pop(product),
                    onRescan: _rescan,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ResultPanel extends StatelessWidget {
  final ExtractedCardText extracted;
  final List<CardMatch> matches;
  final void Function(CardProduct) onConfirm;
  final VoidCallback onRescan;

  const _ResultPanel({
    required this.extracted,
    required this.matches,
    required this.onConfirm,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) {
    final confident = matches.where((m) => m.confidence != MatchConfidence.low).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Scanned text',
            style: BambooFonts.ui(12, weight: FontWeight.w700, color: BambooInk.ink500),
          ),
          Text(
            extracted.rawText,
            style: const TextStyle(fontFamily: 'monospace', color: BambooInk.ink900),
          ),
          const SizedBox(height: 12),
          if (confident.isEmpty)
            Text(
              'No confident match in the catalogue — pick the card manually below.',
              style: BambooFonts.ui(13, color: BambooInk.amber),
            )
          else
            Text(
              'Possible matches',
              style: BambooFonts.ui(12, weight: FontWeight.w700, color: BambooInk.ink500),
            ),
          for (final match in matches.take(5))
            ListTile(
              title: Text(match.product.name, style: BambooFonts.ui(14.5, color: BambooInk.ink900)),
              subtitle: Text(
                '${match.confidence.name} confidence · ${match.reason}',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
              trailing: match.confidence == MatchConfidence.low
                  ? null
                  : FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: BambooInk.slate,
                        foregroundColor: BambooInk.lime,
                      ),
                      onPressed: () => onConfirm(match.product),
                      child: const Text('Use this'),
                    ),
            ),
          const SizedBox(height: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: BambooInk.ink900,
              side: const BorderSide(color: BambooInk.hairlineOnPaper),
            ),
            onPressed: onRescan,
            child: const Text('Scan again'),
          ),
        ],
      ),
    );
  }
}
