import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

/// Design 17 "Payment sent". The design's own mockup is static and can
/// afford to just declare the payment succeeded; this app has no way to
/// actually know that — handing off to an external UPI app via a deep
/// link (see ScanResultScreen._payWith) gives no success callback on
/// return, only proof that some UPI app WAS opened. Claiming a guaranteed
/// success here would be exactly the kind of number/state this codebase
/// elsewhere refuses to fabricate (see MonthlySavingsScreen, Home's
/// doc-comment). So this screen shows the reward *that will be earned if
/// the payment completes*, and only logs the real transaction (making the
/// reward and cap/milestone tracking real) once the user confirms they
/// actually finished paying in the other app — same honesty rule, applied
/// to a payment-status claim instead of a money figure.
class PaymentSentScreen extends ConsumerStatefulWidget {
  final String merchantName;
  final Money amount;
  final String cardName;
  final String? userCardId;
  final String? categoryId;
  final Money expectedValue;
  final Confidence confidence;

  const PaymentSentScreen({
    super.key,
    required this.merchantName,
    required this.amount,
    required this.cardName,
    required this.userCardId,
    required this.categoryId,
    required this.expectedValue,
    required this.confidence,
  });

  @override
  ConsumerState<PaymentSentScreen> createState() => _PaymentSentScreenState();
}

class _PaymentSentScreenState extends ConsumerState<PaymentSentScreen> {
  bool _logging = false;
  bool _logged = false;
  String? _error;

  Future<void> _confirmAndLog() async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null || widget.userCardId == null) {
      setState(() => _logged = true); // Guest/no owned card — nothing to log against.
      return;
    }
    setState(() {
      _logging = true;
      _error = null;
    });
    try {
      await repo.logTransaction(
        userCardId: widget.userCardId!,
        amount: widget.amount,
        categoryId: widget.categoryId,
        merchantName: widget.merchantName,
      );
      ref.invalidate(userCardsProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) setState(() => _logged = true);
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _logging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.slate,
      body: DecoratedBox(
        decoration: const BoxDecoration(color: BambooInk.slate),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(color: BambooInk.lime, shape: BoxShape.circle),
                  child: Icon(
                    _logged ? Icons.check_rounded : Icons.arrow_outward_rounded,
                    color: BambooInk.slate,
                    size: 32,
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                Text(
                  _logged ? 'Logged.' : 'Continue in your UPI app',
                  style: BambooFonts.heading(26, color: BambooInk.onSlate),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  _logged
                      ? 'This spend now counts toward ${widget.cardName}\'s caps, milestones and points.'
                      : 'Finish paying ${widget.merchantName.isEmpty ? '' : widget.merchantName} there, then come back and confirm below.',
                  style: BambooFonts.ui(14, color: BambooInk.onSlateSubtle),
                ),
                const SizedBox(height: AppSpace.xxl),
                Container(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  decoration: BoxDecoration(
                    color: BambooInk.slateRaised,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: BambooInk.slateHairline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'REWARD IF THIS COMPLETES',
                        style: BambooFonts.ui(
                          11,
                          weight: FontWeight.w600,
                          color: BambooInk.onSlateMuted,
                        ).copyWith(letterSpacing: 1.1),
                      ),
                      const SizedBox(height: 6),
                      MoneyText(
                        widget.expectedValue,
                        confidence: widget.confidence,
                        style: BambooFonts.money(36, color: BambooInk.lime),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'with ${widget.cardName}',
                        style: BambooFonts.ui(13.5, color: BambooInk.onSlateSubtle),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpace.md),
                  Text(_error!, style: BambooFonts.ui(13, color: BambooInk.clay)),
                ],
                const Spacer(),
                if (!_logged)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: BambooInk.lime,
                        foregroundColor: BambooInk.slate,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: _logging ? null : _confirmAndLog,
                      child: _logging
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.slate),
                            )
                          : const Text("I've paid — log this spend"),
                    ),
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: BambooInk.lime,
                        foregroundColor: BambooInk.slate,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                      child: const Text('Take me Home'),
                    ),
                  ),
                const SizedBox(height: AppSpace.sm),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                    style: TextButton.styleFrom(foregroundColor: BambooInk.onSlateSubtle),
                    child: Text(_logged ? 'Done' : "I'll log it later"),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
