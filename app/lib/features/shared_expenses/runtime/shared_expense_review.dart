import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pandapay_domain/shared_expenses.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import '../../../app/design/app_theme.dart';
import '../storage/shared_store.dart';
import '../ui/shared_components.dart';
import '../ui/shared_presentation.dart' show sharedSavedOfflineCopy;
import 'shared_expense_summary.dart';
import 'shared_runtime.dart';

/// Reuses the group route. Accepted money and proposed revisions are separate;
/// immutable revisions, not inferred payment evidence, are the consent boundary.
class SharedExpenseReviewSheet extends StatefulWidget {
  final SharedExpensesRuntime runtime;
  final String contextId, expenseId;
  const SharedExpenseReviewSheet({
    super.key,
    required this.runtime,
    required this.contextId,
    required this.expenseId,
  });
  @override
  State<SharedExpenseReviewSheet> createState() =>
      _SharedExpenseReviewSheetState();
}

class _SharedExpenseReviewSheetState extends State<SharedExpenseReviewSheet> {
  late Future<Map<String, Object?>> _page;
  final _history = <String?>[null];
  String? _notice;
  bool _saving = false;
  late int _seenVersion = widget.runtime.dataVersion;
  @override
  void initState() {
    super.initState();
    _page = _load();
    widget.runtime.addListener(_changed);
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_changed);
    super.dispose();
  }

  Future<Map<String, Object?>> _load() => widget.runtime.expenseReviewPage(
    widget.contextId,
    widget.expenseId,
    after: _history.last,
  );
  void _changed() {
    if (!mounted || widget.runtime.busy) return;
    // Reload only when the data really changed. Every sync tick notifies, and
    // reloading on each one flashed a spinner over the Approve button while the
    // person was reaching for it.
    if (widget.runtime.dataVersion != _seenVersion) {
      _seenVersion = widget.runtime.dataVersion;
      setState(() {
        _page = _load();
      });
    } else {
      setState(() {}); // flags (offline, busy bar) may have changed
    }
  }

  Future<void> _respond(Map row, String decision) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      final op = await widget.runtime.respondToExpense(
        widget.contextId,
        widget.expenseId,
        row['revisionId'] as String,
        decision,
      );
      if (!mounted) return;
      final queued = widget.runtime.store.operation(op);
      final receipt = widget.runtime.store.receipt(op);
      final result = receipt?.result;
      setState(() {
        _notice =
            queued?.state == SharedCommandState.rejected ||
                queued?.state == SharedCommandState.conflict
            ? 'Response needs review. Refresh the expense before taking another action.'
            : result is Map && result['status'] == 'accepted'
            ? 'All approvals received. Expense accepted.'
            : receipt != null
            ? 'Response saved. Balances change only after acceptance.'
            : widget.runtime.offline
            ? sharedSavedOfflineCopy
            : 'Response saved on this device · waiting to sync';
        _page = _load();
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _notice =
              'Could not confirm your response. Your saved response is kept; refresh to check its status.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Anyone in the expense can take an accepted expense back out (the
  /// Splitwise way), after one confirmation. The earlier revision stays in the
  /// history, so nothing is lost.
  Future<void> _remove(Map row) async {
    if (_saving) return;
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Remove this expense?'),
            content: const Text(
              'It stops counting in balances for everyone. The history is kept.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep it'),
              ),
              TextButton(
                key: const Key('confirm-remove-expense'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      final op = await widget.runtime.removeExpense(
        contextId: widget.contextId,
        expenseId: widget.expenseId,
        headRevisionId: row['revisionId'] as String,
        title: row['title'] as String,
        occurredOn: row['occurredOn'] as String? ?? '',
      );
      if (!mounted) return;
      final result = widget.runtime.store.receipt(op)?.result;
      setState(() {
        _notice = result is Map && result['status'] == 'accepted'
            ? 'Expense removed. The history is kept.'
            : 'Removal saved. It takes effect once everyone has approved it.';
        _page = _load();
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _notice =
              'Could not remove the expense yet. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _money(String label, Money amount) =>
      SharedMoneyLine(label, amount, confidence: Confidence.confirmed);

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// `2026-11-11` as `11 Nov 2026`.
  static String _prettyDate(String? iso) {
    final d = DateTime.tryParse(iso ?? '');
    return d == null
        ? (iso ?? '')
        : '${d.day} ${_months[d.month - 1]} ${d.year}';
  }

  /// One person: who they are, what they put in, and what that leaves them
  /// owing or owed.
  Widget _person(SharedPersonLine p) {
    final net = p.netMinor;
    final parts = [
      if (p.paidMinor > 0) 'paid ${Money.fromPaise(p.paidMinor).format()}',
      'share ${Money.fromPaise(p.shareMinor).format()}',
    ];
    final amount = Money.fromPaise(net.abs()).format();
    final result = net == 0
        ? 'settled'
        : net > 0
        ? (p.isYou ? 'you get back $amount' : 'gets back $amount')
        : (p.isYou ? 'you owe $amount' : 'owes $amount');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          ExcludeSemantics(
            child: CircleAvatar(
              radius: 16,
              backgroundColor: p.isYou
                  ? BambooInk.lime.withValues(alpha: .35)
                  : BambooInk.rankBadgeBg,
              child: Text(
                p.name.isEmpty ? '?' : p.name.characters.first.toUpperCase(),
                style: BambooFonts.ui(13, weight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  style: BambooFonts.ui(15, weight: FontWeight.w600),
                ),
                Text(
                  parts.join(' · '),
                  style: BambooFonts.ui(12, color: BambooInk.ink700),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Flexible(
            child: Text(
              result,
              textAlign: TextAlign.end,
              style: BambooFonts.ui(
                13,
                weight: FontWeight.w600,
                color: net == 0
                    ? BambooInk.ink500
                    : net > 0
                    ? BambooInk.jade
                    : BambooInk.clayInk,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _revision(Map row, Map names) {
    final runtime = widget.runtime;
    final status = row['reviewState'] as String? ?? 'unknown';
    final operation = runtime.store.operation(
      runtime.expenseResponseId(
        widget.contextId,
        widget.expenseId,
        row['revisionId'] as String,
      ),
    );
    final bill = row['bill'] as Map?;
    final snapshot = row['snapshot'] as Map?;
    final paid = sharedMoneyFromMinor(row['yourPaidMinor'] ?? '0');
    final share = sharedMoneyFromMinor(row['yourShareMinor'] ?? '0');
    final mine = (bill?['contributions'] as List? ?? const [])
        .cast<Map>()
        .where((p) => p['memberId'] == row['ownMemberId'])
        .firstOrNull;
    final fullPaid = bill == null
        ? paid
        : sharedMoneyFromMinor(mine?['amountMinor'] ?? '0');
    final residual = fullPaid.paise - paid.paise;
    final canRespond =
        row['canRespond'] == true &&
        runtime.canQueueProposals &&
        operation == null &&
        !_saving;
    final isVoid = row['void'] == true;
    final accepted = status == 'accepted';
    final summary = isVoid
        ? null
        : SharedExpenseSummary.from(
            snapshot,
            names,
            row['ownMemberId'] as String?,
          );
    final billTotal = bill != null
        ? sharedMoneyFromMinor(bill['totalMinor'])
        : sharedMoneyFromMinor(row['totalMinor']);
    final sharedTotal = sharedMoneyFromMinor(row['totalMinor']);
    // Only what needs attention gets a label: a normal, accepted expense is
    // just an expense.
    final statusLabel = switch (status) {
      'accepted' => null,
      'voided' => 'Expense removed · history kept',
      'rejected' => 'Proposal rejected',
      'superseded' => 'Previous revision · no longer current',
      'awaiting_approval' => 'Awaiting approval',
      'awaiting_acceptance' => 'Approved · awaiting acceptance',
      _ => 'Refresh to check review status',
    };
    final decision = row['yourDecision'];
    return SharedPanel(
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(row['title'] as String, style: BambooFonts.heading(18)),
            if (row['occurredOn'] != null)
              Text(
                _prettyDate(row['occurredOn'] as String?),
                style: BambooFonts.ui(12, color: BambooInk.ink700),
              ),
            if (statusLabel != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                statusLabel,
                style: BambooFonts.ui(
                  13,
                  weight: FontWeight.w600,
                  color: BambooInk.amber,
                ),
              ),
            ],
            if (!accepted && status != 'voided')
              const SharedNotice(
                'Not counted in balances until everyone has approved it.',
              ),
            if (!isVoid) ...[
              const SizedBox(height: AppSpace.md),
              // What is split, in big figures; a bigger bill says so beneath.
              Text(
                sharedTotal.format(),
                style: BambooFonts.money(28, color: BambooInk.ink900),
              ),
              if (bill != null && billTotal.paise != sharedTotal.paise)
                Text(
                  'Part of a ${billTotal.format()} bill',
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                ),
              if (summary != null)
                Text(
                  '${summary.paidSentence}, ${summary.splitWords}',
                  style: BambooFonts.ui(13, color: BambooInk.ink700),
                ),
              if (summary != null) ...[
                const SizedBox(height: AppSpace.sm),
                const Divider(height: 1),
                for (final person in summary.people) _person(person),
                const Divider(height: 1),
                const SizedBox(height: AppSpace.sm),
                Container(
                  key: const Key('expense-your-position'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: switch (summary.position) {
                      SharedYourPosition.owes => BambooInk.clay.withValues(
                        alpha: .12,
                      ),
                      SharedYourPosition.owed => BambooInk.jade.withValues(
                        alpha: .12,
                      ),
                      _ => BambooInk.paperCool,
                    },
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    summary.yourSentence,
                    style: BambooFonts.ui(
                      15,
                      weight: FontWeight.w700,
                      color: switch (summary.position) {
                        SharedYourPosition.owes => BambooInk.clayInk,
                        SharedYourPosition.owed => BambooInk.jade,
                        _ => BambooInk.ink900,
                      },
                    ),
                  ),
                ),
              ],
              // The accounting behind the sentence, for anyone who wants it.
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(
                  'More details',
                  style: BambooFonts.ui(13, color: BambooInk.ink700),
                ),
                children: [
                  if (bill != null) _money('Bill total', billTotal),
                  if (bill == null || sharedTotal.paise != billTotal.paise)
                    _money('Shared total', sharedTotal),
                  _money(
                    bill == null ? 'Your shared contribution' : 'You paid',
                    fullPaid,
                  ),
                  if (fullPaid.paise != paid.paise)
                    _money('Your shared portion paid', paid),
                  _money('Your share', share),
                  if (bill != null && residual >= 0) ...[
                    if (residual > 0)
                      _money(
                        'Your unshared spending',
                        sharedMoneyFromMinor('$residual'),
                      ),
                    _money(
                      'Your personal spending',
                      sharedMoneyFromMinor('${share.paise + residual}'),
                    ),
                  ],
                  if (bill == null)
                    const SharedNotice(
                      'Full bill was not recorded for this older expense.',
                    ),
                  if (decision != null && !accepted)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'You ${decision == 'approve' ? 'approved' : 'rejected'} this revision.',
                        style: BambooFonts.ui(13),
                      ),
                    ),
                ],
              ),
            ],
            if (operation != null && decision == null)
              const SharedNotice(
                'A response is already saved on this device. Sync to check its status.',
              ),
            if (accepted &&
                !isVoid &&
                runtime.proposalsEnabled &&
                !runtime.offline &&
                !_saving)
              SharedTextAction(
                label: 'Remove this expense',
                icon: Icons.delete_outline_rounded,
                onTap: () => unawaited(_remove(row)),
              ),
            if (canRespond) ...[
              const SharedNotice(
                'Review the whole bill, who paid, and your share before approving.',
              ),
              SharedAction(
                label: 'Approve this revision',
                primary: true,
                onTap: () => unawaited(_respond(row, 'approve')),
              ),
              SharedTextAction(
                label: 'Reject this revision',
                onTap: () => unawaited(_respond(row, 'reject')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    if (!runtime.isCurrent() ||
        runtime.store.isContextRevoked(widget.contextId)) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('This shared expense is no longer available.'),
        ),
      );
    }
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Expense details',
                      style: BambooFonts.heading(18),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh expense',
                    onPressed: _saving
                        ? null
                        : () => unawaited(runtime.flushEditor()),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SharedNotice(_notice!),
              ),
            if (_saving || runtime.busy)
              const LinearProgressIndicator(color: BambooInk.slate),
            Expanded(
              child: FutureBuilder<Map<String, Object?>>(
                future: _page,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                      child: TextButton(
                        onPressed: () => setState(() {
                          _page = _load();
                        }),
                        child: const Text('Try again'),
                      ),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final page = snapshot.data!;
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (runtime.offline)
                        const SharedNotice(
                          "Offline · saved revisions shown. Your response is saved on this phone and sent when you're online.",
                        ),
                      if ((page['items'] as List).isEmpty)
                        const SharedNotice(
                          'No revisions available. Refresh this expense.',
                        ),
                      for (final row in page['items'] as List)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _revision(
                            row as Map,
                            page['memberNames'] as Map,
                          ),
                        ),
                      if (_history.length > 1)
                        TextButton(
                          onPressed: () => setState(() {
                            _history.removeLast();
                            _page = _load();
                          }),
                          child: const Text('Newer revisions'),
                        ),
                      if (page['hasMore'] == true)
                        TextButton(
                          onPressed: () => setState(() {
                            _history.add(page['nextCursor'] as String);
                            _page = _load();
                          }),
                          child: const Text('Older revisions'),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
