import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/acceptance_reports_repository.dart';
import '../../data/analytics.dart';
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

  /// Plan Phase 2.1 — the payee VPA and the network of the card that was
  /// actually used, both needed to file an acceptance report.
  ///
  /// This screen is the only place in the app where the acceptance question
  /// can honestly be asked. It is the one moment where the user has just told
  /// us they completed a payment with a specific card at a specific payee, so
  /// "did it go through?" is a question they know the answer to and have a
  /// reason to care about. Asking anywhere else would be asking them to
  /// remember.
  final String vpa;
  final CardNetwork cardNetwork;

  /// RuPay-on-UPI plan, Phase 2. When the targeted-app handoff returned a
  /// definite success status (Android only), the spend is logged
  /// immediately on open — the UPI app already told us it went through, so
  /// re-asking "did you pay?" would be asking the user to confirm a fact we
  /// have. Everywhere else this stays false and the screen keeps its
  /// honest manual-confirm button (see this class's doc comment).
  final bool autoLog;

  const PaymentSentScreen({
    super.key,
    required this.merchantName,
    required this.amount,
    required this.cardName,
    required this.userCardId,
    required this.categoryId,
    required this.expectedValue,
    required this.confidence,
    required this.vpa,
    required this.cardNetwork,
    this.autoLog = false,
  });

  @override
  ConsumerState<PaymentSentScreen> createState() => _PaymentSentScreenState();
}

class _PaymentSentScreenState extends ConsumerState<PaymentSentScreen> {
  bool _logging = false;
  bool _logged = false;
  String? _error;
  bool _acceptanceAnswered = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoLog) {
      // The UPI app reported success — record the spend without making the
      // user tap "I've paid" first. The acceptance prompt still appears
      // afterwards (it's the one honest moment to ask).
      WidgetsBinding.instance.addPostFrameCallback((_) => _confirmAndLog());
    }
  }

  /// Files an acceptance report (plan Phase 2.1). Every refusal path is
  /// handled as information rather than an error, because none of them is a
  /// failure of anything the user did: not opted in means they never agreed
  /// to contribute, and a spent quota means they have already contributed
  /// plenty today. The prompt closes either way — re-asking a question the
  /// user has answered because the server declined to record it would be
  /// worse than losing the datapoint.
  Future<void> _reportAcceptance(AcceptanceResult result) async {
    setState(() => _acceptanceAnswered = true);
    final repo = ref.read(acceptanceReportsRepositoryProvider);
    if (repo == null) return;
    try {
      await repo.submit(
        vpa: widget.vpa,
        displayName: widget.merchantName.isEmpty ? null : widget.merchantName,
        network: widget.cardNetwork.name,
        rail: 'upi_qr',
        result: result,
      );
      ref.read(analyticsProvider).track(
        AnalyticsEvent.acceptanceReportSubmitted,
        props: {'result': result.wire},
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Thanks — that helps other cardholders.')));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }

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
      ref.read(analyticsProvider).track(
        AnalyticsEvent.transactionLogged,
        props: const {'source': 'scan'},
      );
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
                // Scrolls rather than overflowing when the acceptance prompt
                // is also on screen (auto-log path) on a short device.
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                if (_logged && !_acceptanceAnswered) ...[
                  const SizedBox(height: AppSpace.lg),
                  _AcceptancePrompt(
                    cardName: widget.cardName,
                    onAnswer: _reportAcceptance,
                    onDismiss: () => setState(() => _acceptanceAnswered = true),
                  ),
                ],
                      ],
                    ),
                  ),
                ),
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

/// Plan Phase 2.1 — the acceptance question, asked once, at the only moment
/// the user knows the answer.
///
/// Three options rather than two. "Didn't work" and "Card not accepted here"
/// are genuinely different facts about a merchant — a declined transaction is
/// about this attempt, whereas a terminal that doesn't take the network at
/// all is a permanent property of the payee — and collapsing them would make
/// the resulting dataset less useful than not collecting it. Dismiss is
/// always available and costs nothing: a contribution prompt that can't be
/// ignored trains people to answer it carelessly, which poisons the data.
class _AcceptancePrompt extends StatelessWidget {
  final String cardName;
  final void Function(AcceptanceResult) onAnswer;
  final VoidCallback onDismiss;

  const _AcceptancePrompt({
    required this.cardName,
    required this.onAnswer,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Did $cardName work here?',
                  style: BambooFonts.ui(14.5, weight: FontWeight.w600, color: BambooInk.ink900),
                ),
              ),
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded, size: 18),
                color: BambooInk.ink500,
                tooltip: 'Dismiss',
              ),
            ],
          ),
          Text(
            'Shared anonymously so other cardholders know before they queue up.',
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              OutlinedButton(
                onPressed: () => onAnswer(AcceptanceResult.accepted),
                child: const Text('Worked'),
              ),
              OutlinedButton(
                onPressed: () => onAnswer(AcceptanceResult.declined),
                child: const Text('Declined'),
              ),
              OutlinedButton(
                onPressed: () => onAnswer(AcceptanceResult.notSupported),
                child: const Text('Not accepted here'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
