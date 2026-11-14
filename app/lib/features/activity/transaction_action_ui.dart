import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../data/user_cards_repository.dart';
import '../sms_v2/ui/owner_identity_actions.dart';
import 'scope_candidate_tile.dart';
import 'spend_exclusion.dart';
import 'transaction_action_flow.dart';
import 'transaction_badge.dart';

/// What the sheet hands back besides a [TxnAction].
const kActionDelete = 'delete';
const kActionUnmarkTransfer = 'unmark_transfer';
const kActionCountAgain = 'count_again';

/// "Choose an action": the one place a payment is marked as a transfer, a card
/// bill, left out of spending, refunded, reversed, reported or deleted.
///
/// It only offers what would change something: a payment already seen as a
/// family transfer is not offered "Transfer to family" again, a card bill is
/// not offered "Credit card bill payment", and so on. Returns a [TxnAction]
/// name or one of the `kAction…` strings, null when dismissed.
Future<String?> showTransactionActionSheet(
  BuildContext context, {
  required TransactionEntry entry,
  bool offerSelf = true,
  bool offerFamily = true,
}) {
  final kind = txnBadgeKind(entry);
  final sms = entry.pipelineVersion == 2;
  final isSelf = kind == TxnBadgeKind.selfTransfer;
  final isFamily = kind == TxnBadgeKind.familyTransfer;

  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: BambooInk.paper,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (sheet) {
      void pick(String v) => Navigator.of(sheet).pop(v);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            0,
            AppSpace.lg,
            AppSpace.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose an action',
                style: BambooFonts.heading(20, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.md),
              if (sms) ...[
                if (!isSelf && offerSelf)
                  _ActionCard(
                    key: const Key('mark-own-transfer'),
                    icon: Icons.swap_horiz_rounded,
                    tint: BambooInk.jade,
                    title: TxnAction.selfTransfer.label,
                    subtitle:
                        'Move money between your own accounts. Not counted as '
                        'spending.',
                    onTap: () => pick(TxnAction.selfTransfer.name),
                  ),
                if (!isFamily && offerFamily)
                  _ActionCard(
                    key: const Key('mark-family-transfer'),
                    icon: Icons.groups_rounded,
                    tint: BambooInk.lime,
                    title: TxnAction.familyTransfer.label,
                    subtitle:
                        'Send money to a family member (e.g. spouse, parent, '
                        'child).',
                    onTap: () => pick(TxnAction.familyTransfer.name),
                  ),
                if (isSelf || isFamily)
                  _ActionCard(
                    key: const Key('unmark-transfer'),
                    icon: Icons.link_off_rounded,
                    tint: BambooInk.ink500,
                    title: 'Not a transfer',
                    subtitle: isFamily
                        ? 'Count it as normal spending or money in again.'
                        : 'This payee is not one of my accounts.',
                    onTap: () => pick(kActionUnmarkTransfer),
                  ),
                if (kind != TxnBadgeKind.cardBill)
                  _ActionCard(
                    key: const Key('mark-card-bill'),
                    icon: Icons.credit_card_rounded,
                    tint: BambooInk.slate,
                    title: TxnAction.cardBill.label,
                    subtitle:
                        'Paying off a card. Not counted again as spending.',
                    onTap: () => pick(TxnAction.cardBill.name),
                  ),
              ],
              if (canExcludeFromSpend(entry))
                _ActionCard(
                  key: const Key('toggle-spend-exclusion'),
                  icon: Icons.visibility_off_outlined,
                  tint: BambooInk.ink500,
                  title: TxnAction.excludeSpend.label,
                  subtitle:
                      'Stays in your history and Money out, and keeps its '
                      'rewards. Left out of spending totals and trends on this '
                      'phone.',
                  onTap: () => pick(TxnAction.excludeSpend.name),
                )
              else if (entry.excludeFromSpend && entry.status == 'active')
                _ActionCard(
                  key: const Key('toggle-spend-exclusion'),
                  icon: Icons.add_circle_outline_rounded,
                  tint: BambooInk.jade,
                  title: 'Count in spending again',
                  subtitle: 'Add it back to your spending totals.',
                  onTap: () => pick(kActionCountAgain),
                ),
              Row(
                children: [
                  if (kind != TxnBadgeKind.refund)
                    Expanded(
                      child: _ActionCard(
                        key: const Key('mark-refund'),
                        icon: Icons.replay_rounded,
                        tint: BambooInk.amber,
                        title: TxnAction.refund.label,
                        compact: true,
                        onTap: () => pick(TxnAction.refund.name),
                      ),
                    ),
                  if (kind != TxnBadgeKind.refund &&
                      kind != TxnBadgeKind.reversal)
                    const SizedBox(width: AppSpace.sm),
                  if (kind != TxnBadgeKind.reversal)
                    Expanded(
                      child: _ActionCard(
                        key: const Key('mark-reversal'),
                        icon: Icons.sync_alt_rounded,
                        tint: BambooInk.slate,
                        title: TxnAction.reversal.label,
                        compact: true,
                        onTap: () => pick(TxnAction.reversal.name),
                      ),
                    ),
                ],
              ),
              _ActionCard(
                key: const Key('mark-wrong'),
                icon: Icons.flag_outlined,
                tint: BambooInk.clay,
                danger: true,
                title: TxnAction.wrongTransaction.label,
                subtitle:
                    'This is not a transaction I recognise. It is excluded '
                    'from spend and reviewed with your consent.',
                onTap: () => pick(TxnAction.wrongTransaction.name),
              ),
              _ActionCard(
                key: const Key('mark-delete'),
                icon: Icons.delete_outline_rounded,
                tint: BambooInk.clay,
                danger: true,
                title: 'Delete transaction',
                onTap: () => pick(kActionDelete),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.icon,
    required this.tint,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.danger = false,
    this.compact = false,
  });
  final IconData icon;
  final Color tint;
  final String title;
  final String? subtitle;
  final bool danger;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(AppSpace.md),
          decoration: BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: BambooInk.hairlineOnPaper),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: danger ? BambooInk.clayInk : tint),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: BambooFonts.ui(
                        15,
                        weight: FontWeight.w700,
                        color: danger ? BambooInk.clayInk : BambooInk.ink900,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: BambooFonts.ui(12.5, color: BambooInk.ink700),
                      ),
                    ],
                  ],
                ),
              ),
              if (!compact)
                const Icon(
                  Icons.chevron_right_rounded,
                  color: BambooInk.ink500,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The page after an action is chosen: how far it should reach. Nothing changes
/// until the person confirms; everything done here can be undone from History.
Future<ActionScope?> showActionScopePage(
  BuildContext context, {
  required TransactionEntry entry,
  required TxnAction action,
  required List<TransactionEntry> candidates,
  MarkPlan? plan,
}) {
  return Navigator.of(context).push<ActionScope>(
    MaterialPageRoute(
      builder: (_) => ActionScopePage(
        entry: entry,
        action: action,
        candidates: candidates,
        plan: plan,
      ),
    ),
  );
}

class ActionScopePage extends StatefulWidget {
  const ActionScopePage({
    super.key,
    required this.entry,
    required this.action,
    required this.candidates,
    this.plan,
  });
  final TransactionEntry entry;
  final TxnAction action;
  final List<TransactionEntry> candidates;

  /// Set for the two transfer actions: what "always" and "only this one" can do.
  final MarkPlan? plan;

  @override
  State<ActionScopePage> createState() => _ActionScopePageState();
}

class _ActionScopePageState extends State<ActionScopePage> {
  late bool _always = _canAlways && !_canOnce;
  final _ticked = <String>{};

  MarkPlan? get _plan => widget.plan;
  bool get _canOnce => _plan?.canMarkOnce ?? true;
  bool get _canAlways => _plan != null && _plan!.canRemember;

  String _payee() {
    final p = (_plan?.payee ?? widget.entry.merchantName ?? '').trim();
    return p.isEmpty ? 'this payee' : p;
  }

  bool get _ready =>
      widget.action.isTransfer ? (_always ? _canAlways : _canOnce) : true;

  void _confirm() {
    Navigator.of(context).pop(
      ActionScope(
        always: widget.action.isTransfer && _always,
        others: [
          for (final e in widget.candidates)
            if (_ticked.contains(e.id)) e,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.action;
    final plan = _plan;
    final earlier = plan?.earlier ?? 0;
    final futureWords = earlier == 0
        ? 'every payment from now on'
        : earlier == 1
        ? '1 earlier payment and every payment from now on'
        : '$earlier earlier payments and every payment from now on';
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          a.label,
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.lg,
                      AppSpace.lg,
                      AppSpace.lg,
                      AppSpace.sm,
                    ),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        Text(
                          _payee(),
                          style: BambooFonts.heading(
                            18,
                            color: BambooInk.ink900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.entry.amount.format(),
                          style: BambooFonts.money(20, color: BambooInk.ink900),
                        ),
                        const SizedBox(height: AppSpace.lg),
                        Text(
                          'How far should this go?',
                          style: BambooFonts.ui(
                            14.5,
                            weight: FontWeight.w700,
                            color: BambooInk.ink900,
                          ),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        if (a.isTransfer) ...[
                          _Choice(
                            key: const Key('scope-once'),
                            selected: !_always,
                            enabled: _canOnce,
                            title: 'Only this payment',
                            subtitle:
                                'Other payments to ${_payee()} stay as they are.',
                            onTap: () => setState(() => _always = false),
                          ),
                          _Choice(
                            key: const Key('scope-always'),
                            selected: _always,
                            enabled: _canAlways,
                            title: 'This payee, past and future',
                            subtitle: plan != null && !plan.canRemember
                                ? 'Not offered: the message shows no name, UPI ID or account to recognise.'
                                : '${_payee()}: $futureWords.',
                            onTap: () => setState(() => _always = true),
                          ),
                        ] else if (widget.candidates.isEmpty)
                          _Choice(
                            selected: true,
                            enabled: true,
                            title: 'Only this payment',
                            subtitle:
                                'There are no other open payments to ${_payee()}.',
                            onTap: () {},
                          )
                        else ...[
                          _Choice(
                            selected: true,
                            enabled: true,
                            title: 'This payment',
                            subtitle: 'Always included.',
                            onTap: () {},
                          ),
                          const SizedBox(height: AppSpace.sm),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Also apply to other payments to ${_payee()}',
                                  style: BambooFonts.ui(
                                    13,
                                    color: BambooInk.ink700,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: () => setState(() {
                                  _ticked.length == widget.candidates.length
                                      ? _ticked.clear()
                                      : _ticked.addAll(
                                          widget.candidates.map((e) => e.id),
                                        );
                                }),
                                child: Text(
                                  _ticked.length == widget.candidates.length
                                      ? 'Clear'
                                      : 'Select all',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ]),
                    ),
                  ),
                  if (!a.isTransfer && widget.candidates.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.lg,
                      ),
                      sliver: SliverList.separated(
                        itemCount: widget.candidates.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: AppSpace.sm),
                        itemBuilder: (_, i) {
                          final e = widget.candidates[i];
                          return ScopeCandidateTile(
                            entry: e,
                            selected: _ticked.contains(e.id),
                            onTap: () => setState(
                              () => _ticked.contains(e.id)
                                  ? _ticked.remove(e.id)
                                  : _ticked.add(e.id),
                            ),
                          );
                        },
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        'Nothing is final: you can undo this from History.',
                        style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.sm,
                AppSpace.lg,
                AppSpace.lg,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: FilledButton(
                      key: const Key('scope-confirm'),
                      onPressed: _ready ? _confirm : null,
                      child: Text(
                        !a.isTransfer && _ticked.isNotEmpty
                            ? 'Apply to ${_ticked.length + 1}'
                            : 'Confirm',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.selected,
    required this.enabled,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final bool selected;
  final bool enabled;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: BambooInk.glassFillOnPaper,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? BambooInk.ink900 : BambooInk.hairlineOnPaper,
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: BambooInk.ink900,
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: BambooFonts.ui(
                          14.5,
                          weight: FontWeight.w700,
                          color: BambooInk.ink900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: BambooFonts.ui(12.5, color: BambooInk.ink700),
                      ),
                    ],
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
