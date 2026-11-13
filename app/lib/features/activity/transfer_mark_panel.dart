import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/user_cards_repository.dart';
import '../sms_v2/ui/owner_identity_actions.dart';
import 'transaction_badge.dart';

/// On a transaction's detail screen: says when a payment is a transfer (between
/// the person's own accounts, or to a family member) and lets them say so, or
/// take it back.
///
/// Marking asks one question, once: does this apply to every payment to the same
/// payee (the earlier ones and the ones that come later), or only to this one?
/// The answer is remembered like a setting and listed under Settings, "Your
/// names & accounts", where it can be removed.
class TransferMarkPanel extends ConsumerStatefulWidget {
  const TransferMarkPanel({super.key, required this.entry, this.onChanged});
  final TransactionEntry entry;

  /// Called after a mark changed the rows, so the screen that shows this one
  /// can read it again.
  final VoidCallback? onChanged;

  @override
  ConsumerState<TransferMarkPanel> createState() => _TransferMarkPanelState();
}

class _TransferMarkPanelState extends ConsumerState<TransferMarkPanel> {
  bool _busy = false;

  OwnerIdentityActions get _actions => OwnerIdentityActions(ref);

  void _say(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  /// The list, the totals and this screen all read the same rows.
  void _refresh() {
    widget.onChanged?.call();
    ref.invalidate(transactionsProvider);
    ref.invalidate(utilizationTransactionsProvider);
    ref.invalidate(homeSummaryProvider);
    ref.invalidate(spendReportProvider);
    ref.invalidate(categorySpendProvider);
  }

  String _others(int changed) =>
      changed <= 1 ? '' : ' $changed payments were updated.';

  Future<void> _mark(TransferMark mark) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final plan = await _actions.plan(widget.entry);
      if (!mounted) return;
      final MarkScope? scope;
      if (plan.canRemember && plan.canMarkOnce) {
        scope = await showTransferScopeSheet(
          context: context,
          mark: mark,
          plan: plan,
        );
      } else if (plan.canMarkOnce) {
        scope = MarkScope.once;
      } else if (plan.canRemember) {
        scope = MarkScope.always;
      } else {
        scope = null;
        _say(
          'This message does not show a name, UPI ID or account, so it cannot '
          'be marked. Use Edit and change the type to Transfer for this one.',
        );
      }
      if (scope == null || !mounted) return;
      final r = await _actions.mark(widget.entry, mark, scope);
      _refresh();
      if (r.outcome == MarkOutcome.nothingToRecognise) {
        _say('This message does not show a name, UPI ID or account.');
        return;
      }
      final chosen = scope;
      _say(
        'Marked as a ${mark == TransferMark.family ? 'family' : 'self'} '
        'transfer.${_others(r.changed)}',
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await _actions.undoMark(widget.entry, mark, chosen);
            _refresh();
          },
        ),
      );
    } catch (_) {
      _say('That did not work. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unmark() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final n = await _actions.unmark(widget.entry);
      _refresh();
      _say('Not a transfer any more.${_others(n)}');
    } catch (_) {
      _say('That did not work. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    if (entry.pipelineVersion != 2 || entry.eventId == null) {
      return const SizedBox.shrink();
    }
    final kind = txnBadgeKind(entry);
    final isSelf = kind == TxnBadgeKind.selfTransfer;
    final isFamily = kind == TxnBadgeKind.familyTransfer;
    final canMark =
        entry.entryKind == TxnEntryKind.spend ||
        entry.entryKind == TxnEntryKind.income;
    if (!isSelf && !isFamily && !canMark) return const SizedBox.shrink();
    final hasPayee =
        ((entry.merchantName ?? '').trim().isNotEmpty &&
            entry.merchantName!.trim().toUpperCase() != 'UNKNOWN') ||
        (entry.merchantVpa ?? '').isNotEmpty;
    if (!isSelf && !isFamily && !hasPayee) return const SizedBox.shrink();

    final method = transferCheckMethod(entry);
    final title = isSelf
        ? 'Self transfer'
        : isFamily
        ? 'Family transfer'
        : method != null
        ? 'Paid by $method. Is this a transfer?'
        : 'Is this a transfer?';
    final body = isSelf
        ? 'Counted as a move between your own accounts, not as spending or '
              'money in.'
        : isFamily
        ? 'Counted as money moved to or from a family member, not as spending '
              'or money in.'
        : 'If this payment went to, or came from, one of your own accounts or a '
              'family member, mark it so it is not counted as spending or money '
              'in.';

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.md),
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
              Icon(
                isFamily ? Icons.family_restroom_rounded : Icons.swap_horiz_rounded,
                size: 20,
                color: isSelf || isFamily ? BambooInk.ink900 : BambooInk.ink500,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  title,
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900, weight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(body, style: BambooFonts.ui(12.5, color: BambooInk.ink700)),
          const SizedBox(height: AppSpace.sm),
          if (_busy)
            const LinearProgressIndicator()
          else
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                if (isSelf || isFamily)
                  TextButton(
                    onPressed: _unmark,
                    child: Text(isFamily ? 'Not a family transfer' : 'Not a self transfer'),
                  ),
                if (!isSelf)
                  OutlinedButton(
                    onPressed: () => _mark(TransferMark.self),
                    child: const Text('Mark as self transfer'),
                  ),
                if (!isFamily)
                  OutlinedButton(
                    onPressed: () => _mark(TransferMark.family),
                    child: const Text('Mark as family transfer'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The one question a mark asks: this payment only, or the payee for good.
/// Returns null when the person cancels.
Future<MarkScope?> showTransferScopeSheet({
  required BuildContext context,
  required TransferMark mark,
  required MarkPlan plan,
}) {
  final family = mark == TransferMark.family;
  final payee = (plan.payee ?? '').trim().isEmpty ? 'this payee' : plan.payee!.trim();
  final earlier = plan.earlier == 0
      ? 'every payment from now on'
      : plan.earlier == 1
      ? '1 earlier payment and every payment from now on'
      : '${plan.earlier} earlier payments and every payment from now on';
  return showModalBottomSheet<MarkScope>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: BambooInk.paper,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              family ? 'Mark as a family transfer?' : 'Mark as a self transfer?',
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
            const SizedBox(height: 4),
            Text(
              'It is left out of spending and money in. You can take it back '
              'from Settings, Your names & accounts.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink700),
            ),
            const SizedBox(height: AppSpace.md),
            _ScopeTile(
              key: const Key('scope-always'),
              title: 'Always',
              subtitle: '$payee: $earlier.',
              onTap: () => Navigator.of(sheet).pop(MarkScope.always),
            ),
            const SizedBox(height: AppSpace.sm),
            _ScopeTile(
              key: const Key('scope-once'),
              title: 'Only this payment',
              subtitle: 'Other payments to $payee stay as they are.',
              onTap: () => Navigator.of(sheet).pop(MarkScope.once),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ScopeTile extends StatelessWidget {
  const _ScopeTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: BambooFonts.ui(14.5, color: BambooInk.ink900, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: BambooFonts.ui(12.5, color: BambooInk.ink700)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: BambooInk.ink500),
          ],
        ),
      ),
    );
  }
}
