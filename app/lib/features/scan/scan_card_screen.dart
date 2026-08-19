import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import 'card_guide_painter.dart';
import 'card_scanner.dart';
import 'card_text_matcher.dart';

/// UA-4 (Chunk 30, extended): "scan to add a card," launched from
/// `cards_screen.dart`'s `_AddCardForm` as an alternative to the manual
/// catalogue dropdown (which remains the fallback — this screen always
/// returns to it rather than replacing it).
///
/// ## What this reads, and why that's enough
///
/// Two modes, front-of-card OCR primary and QR/barcode secondary. Neither
/// asks the user to show the back of their card, and this is a deliberate
/// design choice, not a scope cut: this screen (like the rest of the app —
/// see `db/supabase/migrations/0004_user_domain.sql`'s "stores no PAN, not
/// even last-4") never verifies card OWNERSHIP. It identifies which
/// CATALOGUE PRODUCT a card is — issuer + name — so the matching row can be
/// added to the wallet. Everything needed for that (issuer wordmark,
/// product name, network logo) is on the front. The back carries the CVV
/// and magnetic stripe, neither of which this app has any use for; asking
/// for it would only invite the "why does this need my CVV" review
/// question this codebase's whole design stance is built to avoid.
///
/// ## What happens to the photo
///
/// A card's front usually prints a full or partial card number. The
/// captured frame is processed entirely on-device (camera → MLKit OCR →
/// the pure matcher in `card_text_matcher.dart`, no network call in this
/// flow) and the file is deleted the moment recognition finishes — success
/// or failure — so a photo of the card face never lingers in app storage.
/// Anything shown on screen (the "why this matched" text) runs through
/// [redactDigitRuns] first, same reasoning as the SMS-import pipeline's
/// server-side redaction: a UI is also a place raw card data can leak, via
/// a screenshot, a screen recording, or someone glancing at the phone.
class ScanCardScreen extends StatefulWidget {
  final List<CardProduct> catalogue;

  const ScanCardScreen({super.key, required this.catalogue});

  @override
  State<ScanCardScreen> createState() => _ScanCardScreenState();
}

enum _ScanMode { ocr, qr }

class _ScanCardScreenState extends State<ScanCardScreen> with WidgetsBindingObserver {
  _ScanMode _mode = _ScanMode.ocr;

  // ---- OCR (primary) state ----
  CameraController? _cameraController;
  Future<void>? _cameraInitFuture;
  MlKitCardTextRecognizer? _recognizer;
  bool _capturing = false;
  String? _cameraError;

  // ---- QR (secondary) state ----
  final MobileScannerController _qrController = MobileScannerController();

  // ---- Shared result state ----
  ExtractedCardText? _lastExtracted;
  List<CardMatch> _matches = const [];
  bool _resultIsFromOcr = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      // enableAudio: false is load-bearing, not a default left alone — see
      // AndroidManifest.xml's note on why RECORD_AUDIO is stripped for this
      // app. This screen only ever calls takePicture(); requesting an audio
      // track this flow never uses is what would otherwise put a
      // microphone permission on a card-scanning screen.
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );
      _cameraInitFuture = controller.initialize();
      await _cameraInitFuture;
      _recognizer = MlKitCardTextRecognizer();
      if (mounted) setState(() => _cameraController = controller);
    } catch (e) {
      if (mounted) setState(() => _cameraError = _friendlyCameraError(e));
    }
  }

  String _friendlyCameraError(Object e) {
    if (e is CameraException && (e.code == 'CameraAccessDenied' || e.code == 'CameraAccessDeniedWithoutPrompt')) {
      return 'Camera access is off for PandaPay. Enable it in your phone\'s settings to scan a card.';
    }
    return "Couldn't start the camera. You can still add a card from the list below.";
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A live camera session must not keep running (or keep the sensor
    // reserved) while the app is backgrounded — the QR path already got
    // this for free from MobileScanner; the OCR path owns its own
    // CameraController now, so it has to handle the lifecycle itself.
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      controller.dispose();
      _cameraController = null;
    } else if (state == AppLifecycleState.resumed && _mode == _ScanMode.ocr) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _recognizer?.dispose();
    _qrController.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final controller = _cameraController;
    final recognizer = _recognizer;
    if (controller == null || recognizer == null || _capturing) return;
    setState(() => _capturing = true);

    XFile? file;
    try {
      file = await controller.takePicture();
      final extracted = await recognizer.recognizeText(file.path);
      if (!mounted) return;
      setState(() {
        _lastExtracted = extracted;
        _resultIsFromOcr = true;
        _matches = matchCardText(extracted, widget.catalogue);
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Couldn't read that — try again with more light.")));
      }
    } finally {
      // Deleted unconditionally, success or failure: a captured card-face
      // photo has no reason to exist past this function returning. See
      // this file's doc-comment.
      if (file != null) {
        unawaited(File(file.path).delete().catchError((_) => File(file!.path)));
      }
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _onQrDetect(BarcodeCapture capture) {
    if (capture.barcodes.isEmpty || _lastExtracted != null) return;
    final extracted = extractedTextFromBarcode(capture.barcodes.first);
    if (extracted.rawText.isEmpty) return;
    setState(() {
      _lastExtracted = extracted;
      _resultIsFromOcr = false;
      _matches = matchCardText(extracted, widget.catalogue);
    });
  }

  void _rescan() {
    setState(() {
      _lastExtracted = null;
      _matches = const [];
    });
  }

  Future<void> _switchMode(_ScanMode mode) async {
    if (_mode == mode) return;
    // Most real devices only let one process hold the camera sensor at a
    // time. Without this, switching to QR mode left the OCR path's
    // CameraController alive in the background while MobileScannerController
    // opened a second session — invisible on this emulator's virtual
    // camera, which tolerates concurrent opens, but a real device would
    // either fail the second open or silently starve one of the two feeds.
    if (mode == _ScanMode.qr && _cameraController != null) {
      final controller = _cameraController;
      setState(() {
        _cameraController = null;
        _cameraInitFuture = null;
      });
      await controller?.dispose();
    }
    setState(() {
      _mode = mode;
      _rescan();
    });
    if (mode == _ScanMode.ocr && _cameraController == null && _cameraError == null) {
      await _initCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Scan a card'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ModeToggle(mode: _mode, onChanged: _switchMode),
            Expanded(
              flex: 3,
              child: _lastExtracted != null
                  ? const _CapturedPreview()
                  : _mode == _ScanMode.ocr
                  ? _OcrView(
                      controller: _cameraController,
                      initFuture: _cameraInitFuture,
                      error: _cameraError,
                      capturing: _capturing,
                      onCapture: _capture,
                    )
                  : _QrView(controller: _qrController, onDetect: _onQrDetect),
            ),
            Expanded(
              flex: 2,
              child: Container(
                color: BambooInk.paper,
                child: _lastExtracted == null
                    ? _IdleHint(mode: _mode)
                    : _ResultPanel(
                        extracted: _lastExtracted!,
                        matches: _matches,
                        showRawText: !_resultIsFromOcr,
                        onConfirm: (product) => Navigator.of(context).pop(product),
                        onRescan: _rescan,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final _ScanMode mode;
  final ValueChanged<_ScanMode> onChanged;
  const _ModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Expanded(child: _segment('Front of card', _ScanMode.ocr)),
          const SizedBox(width: 8),
          Expanded(child: _segment('QR / barcode', _ScanMode.qr)),
        ],
      ),
    );
  }

  Widget _segment(String label, _ScanMode value) {
    final selected = mode == value;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? BambooInk.lime : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          label,
          style: BambooFonts.ui(
            13,
            weight: FontWeight.w700,
            color: selected ? BambooInk.slate : Colors.white70,
          ),
        ),
      ),
    );
  }
}

/// The live OCR view: camera preview + [CardGuidePainter] + capture button.
class _OcrView extends StatefulWidget {
  final CameraController? controller;
  final Future<void>? initFuture;
  final String? error;
  final bool capturing;
  final VoidCallback onCapture;

  const _OcrView({
    required this.controller,
    required this.initFuture,
    required this.error,
    required this.capturing,
    required this.onCapture,
  });

  @override
  State<_OcrView> createState() => _OcrViewState();
}

class _OcrViewState extends State<_OcrView> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.error!,
            textAlign: TextAlign.center,
            style: BambooFonts.ui(14, color: Colors.white70),
          ),
        ),
      );
    }
    final controller = widget.controller;
    if (controller == null || widget.initFuture == null) {
      return const Center(child: CircularProgressIndicator(color: BambooInk.lime));
    }

    return FutureBuilder<void>(
      future: widget.initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(color: BambooInk.lime));
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(controller),
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, _) =>
                  CustomPaint(painter: CardGuidePainter(pulse: _pulseController.value), size: Size.infinite),
            ),
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: widget.capturing ? null : widget.onCapture,
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(color: BambooInk.lime, width: 3),
                    ),
                    child: widget.capturing
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: CircularProgressIndicator(strokeWidth: 3, color: BambooInk.slate),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _QrView extends StatelessWidget {
  final MobileScannerController controller;
  final void Function(BarcodeCapture) onDetect;
  const _QrView({required this.controller, required this.onDetect});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(controller: controller, onDetect: onDetect),
        CustomPaint(painter: _CornerBracketPainter(), size: Size.infinite),
      ],
    );
  }
}

/// The corner-bracket viewfinder for QR/barcode mode — a square target,
/// deliberately not the card silhouette, since a barcode isn't card-shaped
/// and drawing the card outline here would guide the user to frame the
/// wrong thing.
class _CornerBracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width * 0.6;
    final rect = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    final overlayPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)));
    canvas.drawPath(overlayPath, Paint()..color = Colors.black.withValues(alpha: 0.55));

    final cornerLen = side * 0.18;
    final paint = Paint()
      ..color = BambooInk.lime
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    void corner(Offset o, Offset dx, Offset dy) {
      canvas.drawLine(o, o + dx, paint);
      canvas.drawLine(o, o + dy, paint);
    }

    corner(rect.topLeft, Offset(cornerLen, 0), Offset(0, cornerLen));
    corner(rect.topRight, Offset(-cornerLen, 0), Offset(0, cornerLen));
    corner(rect.bottomLeft, Offset(cornerLen, 0), Offset(0, -cornerLen));
    corner(rect.bottomRight, Offset(-cornerLen, 0), Offset(0, -cornerLen));
  }

  @override
  bool shouldRepaint(covariant _CornerBracketPainter oldDelegate) => false;
}

/// Shown for the brief moment between capture and the recognizer returning
/// — the camera preview itself has already been torn down (dispose isn't
/// called, but the picture-taking freezes the feed), so this fills that gap
/// rather than showing a dead frame.
class _CapturedPreview extends StatelessWidget {
  const _CapturedPreview();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(child: Icon(Icons.check_circle_outline_rounded, size: 56, color: BambooInk.lime)),
    );
  }
}

class _IdleHint extends StatelessWidget {
  final _ScanMode mode;
  const _IdleHint({required this.mode});

  @override
  Widget build(BuildContext context) {
    final (title, body) = switch (mode) {
      _ScanMode.ocr => (
        'Frame the front of your card',
        'PandaPay reads the issuer and card name printed on the front — '
            'never the back, and never a full card number. That\'s enough to '
            'find the right card in our catalogue; nothing about the card is '
            'stored.',
      ),
      _ScanMode.qr => (
        'Point at a QR code or barcode',
        'Some card mailers and statements carry a scannable code. Full '
            'physical-card recognition isn\'t needed here — switch to '
            '"Front of card" for that.',
      ),
    };
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: BambooFonts.heading(15, color: BambooInk.ink900), textAlign: TextAlign.center),
          const SizedBox(height: AppSpace.sm),
          Text(body, style: BambooFonts.ui(12.5, color: BambooInk.ink500), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _ResultPanel extends StatelessWidget {
  final ExtractedCardText extracted;
  final List<CardMatch> matches;

  /// QR payloads are safe to show verbatim (a URL/code). OCR of a physical
  /// card face is not — see this file's doc-comment — so the raw text
  /// block is only ever rendered for the QR path, and even then nothing
  /// about that changes: this flag exists so a future third input mode
  /// can't accidentally inherit "show raw text" without a deliberate
  /// decision to allow it.
  final bool showRawText;
  final void Function(CardProduct) onConfirm;
  final VoidCallback onRescan;

  const _ResultPanel({
    required this.extracted,
    required this.matches,
    required this.showRawText,
    required this.onConfirm,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) {
    final confident = matches.where((m) => m.confidence != MatchConfidence.low).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showRawText) ...[
            Text('Scanned text', style: BambooFonts.ui(12, weight: FontWeight.w700, color: BambooInk.ink500)),
            Text(
              redactDigitRuns(extracted.rawText),
              style: const TextStyle(fontFamily: 'monospace', color: BambooInk.ink900),
            ),
            const SizedBox(height: 12),
          ],
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
                '${match.confidence.name} confidence · ${redactDigitRuns(match.reason)}',
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
