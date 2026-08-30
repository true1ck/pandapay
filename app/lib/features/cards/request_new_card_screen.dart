import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

/// C8 Request New Card (ui-spec Group C — "as A8, available any time").
/// Built once and reused from two entry points: C3's "my card isn't
/// listed" and any time from My Cards, per spec wording. A7/A8's
/// onboarding equivalent doesn't exist yet as of this pass — when it's
/// built, it should adopt this same screen rather than growing a second
/// copy (same reasoning as CardPickerScreen's own doc-comment).
class RequestNewCardScreen extends ConsumerStatefulWidget {
  const RequestNewCardScreen({super.key});

  @override
  ConsumerState<RequestNewCardScreen> createState() => _RequestNewCardScreenState();
}

class _RequestNewCardScreenState extends ConsumerState<RequestNewCardScreen> {
  final _issuerController = TextEditingController();
  final _productController = TextEditingController();
  CardNetwork? _networkGuess;
  bool _submitting = false;
  bool _submitted = false;
  String? _error;

  @override
  void dispose() {
    _issuerController.dispose();
    _productController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_issuerController.text.trim().isEmpty || _productController.text.trim().isEmpty) {
      setState(() => _error = 'Issuer and card name are both required.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref
          .read(cardFeedbackRepositoryProvider)!
          .requestNewCard(
            issuerName: _issuerController.text.trim(),
            productName: _productController.text.trim(),
            networkGuess: _networkGuess?.name,
          );
      if (mounted) setState(() => _submitted = true);
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
        title: Text('Request a card', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: _submitted ? _buildConfirmation(context) : _buildForm(context),
        ),
      ),
    );
  }

  Widget _buildConfirmation(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 48, color: BambooInk.jade),
          const SizedBox(height: AppSpace.lg),
          Text('Request sent', style: BambooFonts.heading(17, color: BambooInk.ink900)),
          const SizedBox(height: AppSpace.sm),
          Text(
            "We add cards based on real demand — you'll see it in a future update if it's added.",
            style: BambooFonts.ui(13.5, color: BambooInk.ink500),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpace.xl),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.slate,
              foregroundColor: BambooInk.lime,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
            ),
            onPressed: () => context.pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    InputDecoration inputDecoration(String label) => InputDecoration(
      labelText: label,
      labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
      filled: true,
      fillColor: BambooInk.glassFillOnPaper,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
      ),
    );

    return ListView(
      children: [
        Text(
          "Add every card you own — the advice is only as good as what it knows about.",
          style: BambooFonts.ui(13.5, color: BambooInk.ink500),
        ),
        const SizedBox(height: AppSpace.xl),
        TextField(
          controller: _issuerController,
          style: BambooFonts.ui(14.5, color: BambooInk.ink900),
          decoration: inputDecoration('Issuer (e.g. HDFC Bank)'),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _productController,
          style: BambooFonts.ui(14.5, color: BambooInk.ink900),
          decoration: inputDecoration('Card name'),
        ),
        const SizedBox(height: AppSpace.lg),
        DropdownButtonFormField<CardNetwork>(
          initialValue: _networkGuess,
          style: BambooFonts.ui(14.5, color: BambooInk.ink900),
          decoration: inputDecoration('Network (if known)'),
          items: [
            // CardNetwork.unknown is a catalogue-draft marker, not something
            // to offer a user: leaving this optional field unset already says
            // "not known", and two ways to say the same thing is worse than
            // one. Only real networks are selectable.
            for (final n in CardNetwork.values.where((n) => n != CardNetwork.unknown))
              DropdownMenuItem(value: n, child: Text(_networkLabel(n))),
          ],
          onChanged: (v) => setState(() => _networkGuess = v),
        ),
        const SizedBox(height: AppSpace.md),
        Text(
          'A photo of the card FACE ONLY can help us identify it — never photograph the card number. '
          'Photo upload is coming in a later update; for now the description above is enough to submit.',
          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpace.md),
          Text(_error!, style: BambooFonts.ui(12.5, color: BambooInk.clay)),
        ],
        const SizedBox(height: AppSpace.xl),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: BambooInk.slate,
            foregroundColor: BambooInk.lime,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
          ),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.lime),
                )
              : const Text('Submit request'),
        ),
      ],
    );
  }

  static String _networkLabel(CardNetwork n) => switch (n) {
    CardNetwork.rupay => 'RuPay',
    CardNetwork.visa => 'Visa',
    CardNetwork.mastercard => 'Mastercard',
    CardNetwork.amex => 'American Express',
    CardNetwork.diners => 'Diners Club',
    CardNetwork.unknown => 'Not sure',
  };
}
