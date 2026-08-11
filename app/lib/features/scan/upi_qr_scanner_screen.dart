import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';

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
    // Design 03 "Tap to Sniff": no AppBar — a close control, the title, and
    // the torch sit on one row over the camera feed, with a corner-bracket
    // reticle instead of a full outlined square, and the instruction copy
    // below it.
    return Scaffold(
      backgroundColor: BambooInk.slate,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _PermissionExplainer(error: error),
          ),
          // The feed is a live photograph; the chrome below needs a floor of
          // contrast against whatever happens to be in frame.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xB32B313A), Color(0x332B313A), Color(0xCC2B313A)],
                stops: [0.0, 0.42, 1.0],
              ),
            ),
            child: SizedBox.expand(),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  Row(
                    children: [
                      _ScanChromeButton(
                        icon: Icons.close_rounded,
                        tooltip: 'Close',
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      Expanded(
                        child: Text(
                          'Tap to Sniff',
                          textAlign: TextAlign.center,
                          style: BambooFonts.heading(16, color: BambooInk.onSlate),
                        ),
                      ),
                      _ScanChromeButton(
                        icon: _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                        tooltip: 'Toggle torch',
                        active: _torchOn,
                        onTap: _toggleTorch,
                      ),
                    ],
                  ),
                  const Spacer(),
                  const _Reticle(),
                  const SizedBox(height: 26),
                  Text(
                    'Point at the QR or bill',
                    textAlign: TextAlign.center,
                    style: BambooFonts.heading(22, color: BambooInk.onSlate),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'PandaPay reads the merchant and picks your card before you reach for '
                    'your wallet.',
                    textAlign: TextAlign.center,
                    style: BambooFonts.ui(14, color: BambooInk.onSlateMuted, height: 1.5),
                  ),
                  const Spacer(),
                  if (_hint != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: BambooInk.slateLow.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        _hint!,
                        textAlign: TextAlign.center,
                        style: BambooFonts.ui(13.5, color: BambooInk.onSlate),
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                  ],
                  // Design 03's primary button reads "Scan now"; here the
                  // camera is already scanning continuously, so the honest
                  // equivalent is the manual escape hatch the deck's 21
                  // "couldn't read that code" state also offers.
                  FilledButton.icon(
                    onPressed: _pickFromGallery,
                    style: FilledButton.styleFrom(
                      backgroundColor: BambooInk.lime,
                      foregroundColor: BambooInk.slate,
                      minimumSize: const Size.fromHeight(56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      textStyle: BambooFonts.heading(17, color: BambooInk.slate),
                    ),
                    icon: const Icon(Icons.photo_library_rounded, size: 20),
                    label: const Text('Pick a QR from photos'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Works offline · No sign-in needed',
                    textAlign: TextAlign.center,
                    style: BambooFonts.ui(13.5, color: BambooInk.onSlateMuted),
                  ),
                  const SizedBox(height: 34),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The 38pt slate-raised round-rect buttons flanking design 03's title.
class _ScanChromeButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const _ScanChromeButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: BambooInk.slateRaised,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: onTap,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 19, color: active ? BambooInk.lime : BambooInk.onSlateSubtle),
          ),
        ),
      ),
    );
  }
}

/// Design 03's framing reticle: four 44pt lime corner brackets inset 16pt
/// into a 250pt rounded square, with the panda mark centred. Replaces a
/// fully outlined box — the brackets read as "aim here" without drawing a
/// border across whatever you're pointing at.
class _Reticle extends StatelessWidget {
  const _Reticle();

  static const _size = 250.0;
  static const _inset = 16.0;
  static const _arm = 44.0;
  static const _stroke = 3.0;
  static const _radius = 18.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF161B21).withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(44),
              ),
            ),
          ),
          const Center(child: PandaMark(size: 104)),
          _corner(top: _inset, left: _inset, topSide: true, leftSide: true),
          _corner(top: _inset, right: _inset, topSide: true, leftSide: false),
          _corner(bottom: _inset, left: _inset, topSide: false, leftSide: true),
          _corner(bottom: _inset, right: _inset, topSide: false, leftSide: false),
        ],
      ),
    );
  }

  Widget _corner({
    double? top,
    double? bottom,
    double? left,
    double? right,
    required bool topSide,
    required bool leftSide,
  }) {
    const side = BorderSide(color: BambooInk.lime, width: _stroke);
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: Container(
        width: _arm,
        height: _arm,
        decoration: BoxDecoration(
          border: Border(
            top: topSide ? side : BorderSide.none,
            bottom: topSide ? BorderSide.none : side,
            left: leftSide ? side : BorderSide.none,
            right: leftSide ? BorderSide.none : side,
          ),
          borderRadius: BorderRadius.only(
            topLeft: topSide && leftSide ? const Radius.circular(_radius) : Radius.zero,
            topRight: topSide && !leftSide ? const Radius.circular(_radius) : Radius.zero,
            bottomLeft: !topSide && leftSide ? const Radius.circular(_radius) : Radius.zero,
            bottomRight: !topSide && !leftSide ? const Radius.circular(_radius) : Radius.zero,
          ),
        ),
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
            const Icon(Icons.no_photography_rounded, color: BambooInk.onSlateMuted, size: 48),
            const SizedBox(height: 16),
            Text(
              'Camera access is needed to scan a QR code.',
              style: BambooFonts.ui(14.5, color: BambooInk.onSlate),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: openAppSettings,
              style: OutlinedButton.styleFrom(
                foregroundColor: BambooInk.onSlate,
                side: const BorderSide(color: BambooInk.onSlateMuted),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}
