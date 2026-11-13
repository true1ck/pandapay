import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pandapay_domain/shared_expenses.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import '../../../app/design/app_theme.dart';
import '../storage/shared_store.dart';
import '../ui/shared_components.dart';
import '../ui/shared_presentation.dart' show sharedSavedOfflineCopy;
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
    if (mounted && !widget.runtime.busy) {
      setState(() {
        _page = _load();
      });
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

  Widget _money(String label, Money amount) =>
      SharedMoneyLine(label, amount, confidence: Confidence.confirmed);
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
    return SharedPanel(
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(row['title'] as String, style: BambooFonts.heading(18)),
            const SizedBox(height: AppSpace.sm),
            Text(switch (status) {
              'accepted' => 'Accepted expense',
              'voided' => 'Expense removed · history kept',
              'rejected' => 'Proposal rejected',
              'superseded' => 'Previous revision · no longer current',
              'awaiting_approval' => 'Awaiting approval',
              'awaiting_acceptance' => 'Approved · awaiting acceptance',
              _ => 'Refresh to check review status',
            }, style: BambooFonts.ui(13, weight: FontWeight.w600)),
            if (row['occurredOn'] != null)
              Text(
                row['occurredOn'] as String,
                style: BambooFonts.ui(12, color: BambooInk.ink700),
              ),
            if (status != 'accepted' && status != 'voided')
              const SharedNotice(
                'Proposed amounts below are not included in confirmed balances or spending.',
              ),
            if (row['void'] != true) ...[
              if (bill != null)
                _money('Bill total', sharedMoneyFromMinor(bill['totalMinor'])),
              _money('Shared total', sharedMoneyFromMinor(row['totalMinor'])),
              _money(
                bill == null ? 'Your shared contribution' : 'You paid',
                fullPaid,
              ),
              if (fullPaid.paise != paid.paise)
                _money('Your shared portion paid', paid),
              _money('Your share', share),
              if (bill != null && residual >= 0) ...[
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
              if (snapshot != null)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'Split breakdown · ${(snapshot['shares'] as List).length} people',
                    style: BambooFonts.ui(14),
                  ),
                  children: [
                    Text(
                      'Paid by',
                      style: BambooFonts.ui(13, weight: FontWeight.w600),
                    ),
                    for (final raw
                        in (bill?['contributions'] ?? snapshot['contributions'])
                            as List)
                      _money(
                        names[(raw as Map)['memberId']] as String? ??
                            'Former member',
                        sharedMoneyFromMinor(raw['amountMinor']),
                      ),
                    Text(
                      'Shares of the shared total',
                      style: BambooFonts.ui(13, weight: FontWeight.w600),
                    ),
                    for (final raw in snapshot['shares'] as List)
                      _money(
                        names[(raw as Map)['memberId']] as String? ??
                            'Former member',
                        sharedMoneyFromMinor(raw['amountMinor']),
                      ),
                  ],
                ),
            ],
            if (row['yourDecision'] != null)
              Text(
                'You ${row['yourDecision'] == 'approve' ? 'approved' : 'rejected'} this revision.',
                style: BambooFonts.ui(13),
              ),
            if (operation != null && row['yourDecision'] == null)
              const SharedNotice(
                'A response is already saved on this device. Sync to check its status.',
              ),
            if (canRespond) ...[
              const SharedNotice(
                'Review the whole bill, payer contributions, and your share before approving.',
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
                  if (!snapshot.hasData ||
                      snapshot.connectionState == ConnectionState.waiting) {
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
