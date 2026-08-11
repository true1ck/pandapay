import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

/// ui-spec.md A8 Request Unsupported Card — also reachable from C8, per
/// implementation-plan-group-c-d.md's note that A8 and C8 are the SAME
/// screen, not a fork. Reached by push (see router.dart's own comment on
/// why this is a plain `Navigator.push`, not a registered go_router route):
/// this is a "go look at one thing and come back" flow, not a linear
/// onboarding step of its own.
///
/// Photo upload: `image_picker` returns a local file path; there is no
/// upload endpoint yet (POST /card-requests' `imagePath` field expects an
/// already-uploaded storage path, per its own doc-comment), so a picked
/// photo is shown as a preview/confirmation of what was captured but is
/// deliberately NOT sent as `imagePath` this pass — flagged, not silently
/// faked as uploaded.
class RequestUnsupportedCardScreen extends ConsumerStatefulWidget {
  const RequestUnsupportedCardScreen({super.key});

  @override
  ConsumerState<RequestUnsupportedCardScreen> createState() => _RequestUnsupportedCardScreenState();
}

class _RequestUnsupportedCardScreenState extends ConsumerState<RequestUnsupportedCardScreen> {
  final _issuerController = TextEditingController();
  final _productController = TextEditingController();
  CardNetwork? _networkGuess;
  XFile? _photo;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _issuerController.dispose();
    _productController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600);
      if (picked != null && mounted) setState(() => _photo = picked);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open camera: $e')));
      }
    }
  }

  bool get _canSubmit =>
      _issuerController.text.trim().isNotEmpty && _productController.text.trim().isNotEmpty;

  Future<void> _submit() async {
    final api = ref.read(cardRequestsApiProvider);
    if (api == null) {
      setState(() => _error = 'Sign in to request a card.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await api.submit(
        issuerName: _issuerController.text.trim(),
        productName: _productController.text.trim(),
        networkGuess: _networkGuess?.name,
      );
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thanks — we\'ve logged this.'),
            content: const Text("We'll let you know when it's added."),
            actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
          ),
        );
        if (mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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
        title: Text("My card isn't listed", style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              "Tell us which card you own and we'll add it to the catalogue. We'll let you know once it's available.",
              style: BambooFonts.ui(13.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.xl),
            TextField(
              controller: _issuerController,
              decoration: const InputDecoration(labelText: 'Issuer (e.g. HDFC Bank)'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _productController,
              decoration: const InputDecoration(labelText: 'Card name (e.g. Millennia)'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpace.lg),
            DropdownButtonFormField<CardNetwork>(
              initialValue: _networkGuess,
              decoration: const InputDecoration(labelText: 'Network (optional)'),
              items: [
                for (final n in CardNetwork.values) DropdownMenuItem(value: n, child: Text(_networkLabel(n))),
              ],
              onChanged: (v) => setState(() => _networkGuess = v),
            ),
            const SizedBox(height: AppSpace.xxl),
            Text('Photo (optional)', style: BambooFonts.heading(14, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.sm),
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: BambooInk.clay.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: BambooInk.clay.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, color: BambooInk.clay, size: 20),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      'Photograph the card face only — never the number, CVV, or expiry.',
                      style: BambooFonts.ui(12.5, color: BambooInk.clay),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.md),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: BambooInk.ink900,
                minimumSize: const Size.fromHeight(48),
                side: const BorderSide(color: BambooInk.hairlineOnPaper),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: _pickPhoto,
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text(_photo == null ? 'Take a photo' : 'Retake photo'),
            ),
            if (_photo != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text('Photo captured: ${_photo!.name}', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpace.lg),
              Text(_error!, style: BambooFonts.ui(12.5, color: BambooInk.clay)),
            ],
            const SizedBox(height: AppSpace.xxl),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
              ),
              onPressed: !_canSubmit || _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.lime),
                    )
                  : const Text('Submit request'),
            ),
          ],
        ),
      ),
    );
  }

  static String _networkLabel(CardNetwork n) => switch (n) {
    CardNetwork.rupay => 'RuPay',
    CardNetwork.visa => 'Visa',
    CardNetwork.mastercard => 'Mastercard',
    CardNetwork.amex => 'Amex',
    CardNetwork.diners => 'Diners',
  };
}
