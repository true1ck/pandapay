import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
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
      await ref.read(cardFeedbackRepositoryProvider)!.requestNewCard(
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
      appBar: AppBar(title: const Text('Request a card')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: _submitted ? _buildConfirmation(context) : _buildForm(context),
      ),
    );
  }

  Widget _buildConfirmation(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 48, color: AppColors.success),
          const SizedBox(height: AppSpace.lg),
          Text('Request sent', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpace.sm),
          const Text(
            "We add cards based on real demand — you'll see it in a future update if it's added.",
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpace.xl),
          FilledButton(onPressed: () => context.pop(), child: const Text('Done')),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    return ListView(
      children: [
        Text(
          "Add every card you own — the advice is only as good as what it knows about.",
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpace.xl),
        TextField(
          controller: _issuerController,
          decoration: const InputDecoration(labelText: 'Issuer (e.g. HDFC Bank)'),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _productController,
          decoration: const InputDecoration(labelText: 'Card name'),
        ),
        const SizedBox(height: AppSpace.lg),
        DropdownButtonFormField<CardNetwork>(
          initialValue: _networkGuess,
          decoration: const InputDecoration(labelText: 'Network (if known)'),
          items: [
            for (final n in CardNetwork.values) DropdownMenuItem(value: n, child: Text(_networkLabel(n))),
          ],
          onChanged: (v) => setState(() => _networkGuess = v),
        ),
        const SizedBox(height: AppSpace.md),
        Text(
          'A photo of the card FACE ONLY can help us identify it — never photograph the card number. '
          'Photo upload is coming in a later update; for now the description above is enough to submit.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpace.md),
          Text(_error!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.error)),
        ],
        const SizedBox(height: AppSpace.xl),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
      };
}
