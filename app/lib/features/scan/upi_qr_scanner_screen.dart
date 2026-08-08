import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:permission_handler/permission_handler.dart';

/// ui-spec B2. Full-screen camera scan of a merchant's UPI *payment* QR —
/// distinct from `scan_card_screen.dart`, which scans a QR/barcode off a
/// physical card to identify a card *product* for the wallet. Works fully
/// offline (feature 4) — every step here is local camera/image decode via
/// mobile_scanner, no network calls at all, unlike most of this app's other
/// screens which need a live API.
class UpiQrScannerScreen extends StatefulWidget {
  const UpiQrScannerScreen({super.key});

  @override
  State<UpiQrScannerScreen> createState() => _UpiQrScannerScreenState();
}

class _UpiQrScannerScreenState extends State<UpiQrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handling = false;
  String? _hint;
  bool _torchOn = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handling || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    _handleRaw(raw);
  }

  Future<void> _handleRaw(String? raw) async {
    if (raw == null || raw.isEmpty) {
      setState(() => _hint = "Couldn't read that — steady the camera or clean the lens.");
      return;
    }
    final parsed = parseUpiQrString(raw);
    if (parsed == null) {
      setState(() {
        _hint = "That's not a UPI code.";
        _handling = false;
      });
      return;
    }
    setState(() => _handling = true);
    // ui-spec B2.3: haptic on a successful decode.
    await HapticFeedback.mediumImpact();
    if (!mounted) return;
    Navigator.of(context).pop<ParsedUpiQr>(parsed);
  }

  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final capture = await _controller.analyzeImage(picked.path);
    final raw = capture?.barcodes.isNotEmpty == true ? capture!.barcodes.first.rawValue : null;
    await _handleRaw(raw);
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    setState(() => _torchOn = !_torchOn);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Scan to pay', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Toggle torch',
            icon: Icon(_torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded, color: Colors.white),
            onPressed: _toggleTorch,
          ),
          IconButton(
            tooltip: 'Import from gallery',
            icon: const Icon(Icons.photo_library_rounded, color: Colors.white),
            onPressed: _pickFromGallery,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _PermissionExplainer(error: error),
          ),
          // Framing guide (ui-spec B2.1) — a plain square outline, no extra
          // asset/plugin needed.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(border: Border.all(color: Colors.white70, width: 2), borderRadius: BorderRadius.circular(16)),
            ),
          ),
          if (_hint != null)
            Positioned(
              bottom: 48,
              left: 24,
              right: 24,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                child: Text(_hint!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
              ),
            ),
        ],
      ),
    );
  }
}

/// ui-spec B2 edge case: permission denied -> explainer + settings deep
/// link. mobile_scanner surfaces a MobileScannerException through
/// errorBuilder when the camera permission was refused; permission_handler
/// (already a dependency — see pubspec.yaml's SMS-import section) drives
/// the actual settings deep link, the same package this app already uses
/// for its other runtime-permission flows.
class _PermissionExplainer extends StatelessWidget {
  final MobileScannerException error;
  const _PermissionExplainer({required this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_rounded, color: Colors.white70, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Camera access is needed to scan a QR code.',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: openAppSettings,
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white70)),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}
