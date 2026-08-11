import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/support_api.dart';
import '../../data/user_cards_repository.dart';
import '../settings/feedback_support_screen.dart' show supportApiBaseUrl;
import '../../main.dart' show MoneyText;

/// Design 26 "Report an issue" — the transaction-scoped one, reached from
/// design 18 Transaction detail.
///
/// Distinct from the two report surfaces that already existed and neither
/// of which is this: C7 Report Wrong Data corrects the **catalogue** (this
/// card's stated rate is wrong for everyone), and H9 Feedback & Support is
/// the general inbox. Design 26 is narrower and more useful than either —
/// something is wrong with *this payment* — and the deck's own note is that
/// it "attaches the transaction context automatically", so the user never
/// has to describe which payment they mean.
///
/// The attached context is shown on screen before it is sent. That is the
/// same rule feedback_support_screen.dart follows and the reason
/// [SupportApi.submitTicket]'s doc-comment gives: diagnostics must be
/// exactly what the user was shown, never a superset.
class ReportTransactionScreen extends ConsumerStatefulWidget {
  final TransactionEntry entry;
  const ReportTransactionScreen({super.key, required this.entry});

  @override
  ConsumerState<ReportTransactionScreen> createState() => _ReportTransactionScreenState();
}

/// The deck's four options. `other` exists because a fixed list that
/// doesn't include the user's actual problem is worse than a free-text box.
enum _IssueKind {
  wrongReward('Wrong reward', 'wrong_card_data'),
  duplicateCharge('Duplicate charge', 'bug'),
  cardNotRecognized('Card not recognized', 'bug'),
  other('Other', 'general');

  /// Label shown on the chip.
  final String label;

  /// Which of the backend's four `SUPPORT_TICKET_KINDS` this maps to. The
  /// user-facing taxonomy is design 26's; the storage taxonomy is the
  /// existing one, and inventing a fifth kind to match the UI would mean a
  /// migration and a console change for no operational gain.
  final String ticketKind;

  const _IssueKind(this.label, this.ticketKind);
}

class _ReportTransactionScreenState extends ConsumerState<ReportTransactionScreen> {
  _IssueKind? _kind;
  final _details = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  /// Exactly what the context card above renders — see the class
  /// doc-comment on why these must not diverge.
  Map<String, dynamic> get _diagnostics => {
    'transactionId': widget.entry.id,
    'merchant': widget.entry.merchantName,
    'amountInr': widget.entry.amount.rupees,
    'occurredAt': widget.entry.occurredAt.toIso8601String(),
    'card': widget.entry.cardDisplayName,
    'category': widget.entry.categoryName,
  };

  Future<void> _submit() async {
    final kind = _kind;
    final token = ref.read(accessTokenProvider);
    if (kind == null || token == null || _submitting) return;

    setState(() => _submitting = true);
    try {
      await SupportApi(apiBaseUrl: supportApiBaseUrl, accessToken: token).submitTicket(
        kind: kind.ticketKind,
        // The chip label leads the message so a human triaging the queue
        // sees design 26's taxonomy even though it is stored under the
        // coarser backend kind.
        message: [kind.label, if (_details.text.trim().isNotEmpty) _details.text.trim()].join('\n\n'),
        diagnostics: _diagnostics,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Report sent. We usually respond within a day.')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Couldn't send that. ${userFacingErrorMessage(e)}")));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Report an issue', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            _TransactionContextCard(entry: entry),
            const SizedBox(height: AppSpace.xl),
            Text('What went wrong', style: BambooFonts.heading(15, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                for (final kind in _IssueKind.values)
                  Pressable(
                    enforceMinTarget: false,
                    onTap: () => setState(() => _kind = kind),
                    semanticLabel: kind.label,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: 11),
                      decoration: BoxDecoration(
                        color: _kind == kind ? BambooInk.slate : BambooInk.glassFillOnPaper,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        border: Border.all(
                          color: _kind == kind ? BambooInk.slate : BambooInk.hairlineOnPaper,
                        ),
                      ),
                      child: Text(
                        kind.label,
                        style: BambooFonts.ui(
                          13.5,
                          weight: FontWeight.w600,
                          color: _kind == kind ? BambooInk.onSlate : BambooInk.ink900,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.xl),
            Text('Tell us more (optional)', style: BambooFonts.heading(15, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.sm),
            TextField(
              controller: _details,
              maxLines: 4,
              maxLength: 2000,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: const InputDecoration(hintText: 'What did you expect to happen?'),
            ),
            const SizedBox(height: AppSpace.sm),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.onSlate,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                disabledBackgroundColor: BambooInk.paperMuted,
                disabledForegroundColor: BambooInk.ink300,
              ),
              // Disabled until a category is picked: an uncategorised report
              // lands in the queue as "general" with no signal, which is how
              // support inboxes rot.
              onPressed: _kind == null || _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.ink500),
                    )
                  : const Text('Submit report'),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'We usually respond within a day. The payment details above are sent with your report.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
        ),
      ),
    );
  }
}

/// The auto-attached context — design 26's merchant tile, amount and
/// timestamp. Rendered from the same values that go into the ticket.
class _TransactionContextCard extends StatelessWidget {
  final TransactionEntry entry;
  const _TransactionContextCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final merchant = entry.merchantName ?? entry.categoryName ?? 'Payment';
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: BambooInk.slate, borderRadius: BorderRadius.circular(14)),
            child: Text(
              merchant.characters.first.toUpperCase(),
              style: BambooFonts.heading(18, color: BambooInk.lime),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        merchant,
                        style: BambooFonts.heading(15, color: BambooInk.ink900),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(' · ', style: BambooFonts.ui(14, color: BambooInk.ink500)),
                    MoneyText(
                      entry.amount,
                      confidence: Confidence.confirmed,
                      style: BambooFonts.money(15, color: BambooInk.ink900),
                      hidePaise: true,
                      showConfidenceIcon: false,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  DateFormat("d MMM, h:mm a").format(entry.occurredAt.toLocal()),
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
