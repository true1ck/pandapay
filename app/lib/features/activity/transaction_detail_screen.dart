import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../account/account_screen.dart' show AccountTile;
import 'report_transaction_screen.dart';

/// D2 Transaction Detail (ui-spec Group D). Deep-linkable at /activity/:id.
/// Full record incl. source and reconciliation status. Actions: edit (D3),
/// mark ignored (refund/reversal/transfer), plus design 18's own two rows:
/// **Add a note** and **Split this expense**.
///
/// Both of those were previously flagged here as real gaps rather than
/// faked. Notes had no write path (the full transaction PATCH exists, but
/// routing a note through it would recompute reward state for a comment
/// edit), and `transaction_splits` had a table and an RLS policy since
/// migration 0004 with no route ever reading or writing it. Both routes
/// exist now — `PATCH /transactions/:id/note` and
/// `GET`/`PUT /transactions/:id/splits`.
///
/// Still NOT built: the "a better card existed" panel, which needs the
/// shared historical-recompute calculator. Note that D6 Missed
/// Opportunities and design 04's Insights both answer that question in
/// aggregate via `compareToOwnedCards`; what's missing is the per-row
/// version with its cap/milestone state as of the transaction date, which
/// this schema does not retain (see historical_comparison.dart).
class TransactionDetailScreen extends ConsumerWidget {
  final String transactionId;
  const TransactionDetailScreen({super.key, required this.transactionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txn = ref.watch(_transactionProvider(transactionId));
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Transaction', style: BambooFonts.heading(18, color: BambooInk.ink900)),
        actions: [
          if (txn.valueOrNull?.status == 'active')
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/activity/$transactionId/edit'),
            ),
        ],
      ),
      body: AppBackground(
        child: txn.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(_transactionProvider(transactionId)),
          ),
          data: (entry) => _DetailBody(entry: entry),
        ),
      ),
    );
  }
}

final _transactionProvider = FutureProvider.family<TransactionEntry, String>((ref, id) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) throw ApiException('Not signed in');
  return repo.fetchTransaction(id);
});

class _DetailBody extends ConsumerStatefulWidget {
  final TransactionEntry entry;
  const _DetailBody({required this.entry});

  @override
  ConsumerState<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends ConsumerState<_DetailBody> {
  bool _ignoring = false;

  /// Held locally so the note and split rows update the moment they're
  /// saved, rather than waiting on a re-fetch of the parent transaction.
  /// Seeded from the entry; splits are loaded once on init.
  late String? _note = widget.entry.note;
  List<TransactionSplit> _splits = const [];

  @override
  void initState() {
    super.initState();
    _loadSplits();
  }

  Future<void> _loadSplits() async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) return;
    try {
      final splits = await repo.fetchSplits(widget.entry.id);
      if (mounted) setState(() => _splits = splits);
    } catch (_) {
      // A failed split fetch must not take down the detail screen — the
      // row simply reads "Split this expense" as if there were none, and
      // opening it will surface the error properly.
    }
  }

  Future<void> _showNoteSheet() async {
    final controller = TextEditingController(text: _note ?? '');
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (context) => Padding(
        // Lifts the sheet above the keyboard, which otherwise covers the
        // field it exists to expose.
        padding: EdgeInsets.only(
          left: AppSpace.lg,
          right: AppSpace.lg,
          top: AppSpace.lg,
          bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Note', style: BambooFonts.heading(18, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              maxLength: 2000,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: const InputDecoration(hintText: 'What was this for?'),
            ),
            const SizedBox(height: AppSpace.sm),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.onSlate,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    await _saveNote(saved.trim());
  }

  Future<void> _saveNote(String note) async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) return;
    final previous = _note;
    setState(() => _note = note.isEmpty ? null : note);
    try {
      await repo.updateTransactionNote(widget.entry.id, note.isEmpty ? null : note);
      ref.invalidate(_transactionProvider(widget.entry.id));
    } catch (e) {
      if (mounted) setState(() => _note = previous);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Couldn't save the note. ${userFacingErrorMessage(e)}")));
      }
    }
  }

  Future<void> _showSplitSheet() async {
    final result = await showModalBottomSheet<List<TransactionSplit>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (context) => _SplitSheet(total: widget.entry.amount, initial: _splits),
    );
    if (result == null) return;

    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) return;
    try {
      final saved = await repo.saveSplits(widget.entry.id, result);
      if (mounted) setState(() => _splits = saved);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Couldn't save the split. ${userFacingErrorMessage(e)}")));
      }
    }
  }

  Future<void> _markIgnored(String reason) async {
    setState(() => _ignoring = true);
    try {
      await ref.read(userCardsRepositoryProvider)!.ignoreTransaction(widget.entry.id, reason: reason);
      ref.invalidate(_transactionProvider(widget.entry.id));
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Marked as ignored.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _ignoring = false);
    }
  }

  Future<void> _showIgnoreSheet() async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Text(
                'Why is this being ignored?',
                style: BambooFonts.heading(16, color: BambooInk.ink900),
              ),
            ),
            for (final r in const ['refund', 'reversal', 'transfer'])
              ListTile(
                title: Text(_reasonLabel(r), style: BambooFonts.ui(14.5, color: BambooInk.ink900)),
                onTap: () => Navigator.of(context).pop(r),
              ),
          ],
        ),
      ),
    );
    if (reason != null) await _markIgnored(reason);
  }

  static String _reasonLabel(String r) => switch (r) {
    'refund' => 'Refund',
    'reversal' => 'Reversal',
    'transfer' => 'Transfer (not really a spend)',
    _ => r,
  };

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final isActive = entry.status == 'active';

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        if (!isActive)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpace.lg),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.visibility_off_outlined, size: 16, color: BambooInk.ink500),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: Text(
                    'This transaction is ${entry.status} — excluded from caps and rankings.',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ),
              ],
            ),
          ),
        Center(
          child: Column(
            children: [
              MoneyText(
                entry.amount,
                confidence: Confidence.estimated,
                style: BambooFonts.money(26, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.xs),
              Text(entry.merchantName ?? 'Spend', style: BambooFonts.ui(13.5, color: BambooInk.ink500)),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        _DetailRow(label: 'Card', value: entry.cardDisplayName ?? '—'),
        _DetailRow(label: 'Category', value: entry.categoryName ?? '—'),
        _DetailRow(label: 'Date', value: entry.occurredAt.toLocal().toString().split('.').first),
        _DetailRow(label: 'Rail', value: _railLabel(entry.rail)),
        _DetailRow(label: 'Source', value: _sourceLabel(entry.source)),
        _DetailRow(label: 'Status', value: entry.status[0].toUpperCase() + entry.status.substring(1)),
        if (_note != null && _note!.isNotEmpty) _DetailRow(label: 'Note', value: _note!),
        const SizedBox(height: AppSpace.xl),
        // Design 18's two action rows, both now backed by real routes:
        // PATCH /transactions/:id/note and PUT /transactions/:id/splits.
        AccountTile(
          icon: Icons.edit_note_rounded,
          label: (_note == null || _note!.isEmpty) ? 'Add a note' : 'Edit note',
          onTap: _showNoteSheet,
        ),
        const SizedBox(height: AppSpace.sm),
        AccountTile(
          icon: Icons.call_split_rounded,
          label: _splits.isEmpty
              ? 'Split this expense'
              : 'Split across ${_splits.length} ${_splits.length == 1 ? 'share' : 'shares'}',
          onTap: _showSplitSheet,
        ),
        const SizedBox(height: AppSpace.sm),
        // Design 18's third row, landing on design 26 with this payment
        // already attached — not the catalogue-correction screen (C7) and
        // not the general feedback inbox (H9).
        AccountTile(
          icon: Icons.flag_outlined,
          label: 'Report an issue',
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => ReportTransactionScreen(entry: widget.entry))),
        ),
        const SizedBox(height: AppSpace.xl),
        if (isActive)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: BambooInk.ink900,
              side: const BorderSide(color: BambooInk.hairlineOnPaper),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
            ),
            onPressed: _ignoring ? null : _showIgnoreSheet,
            icon: _ignoring
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.visibility_off_outlined),
            label: const Text('Mark as ignored (refund / reversal / transfer)'),
          ),
      ],
    );
  }

  static String _railLabel(TxnRail rail) => switch (rail) {
    TxnRail.upiQr => 'UPI QR',
    TxnRail.swipe => 'Swipe',
    TxnRail.online => 'Online',
    TxnRail.contactless => 'Contactless',
    TxnRail.atm => 'ATM',
    TxnRail.emi => 'EMI',
    TxnRail.unknown => 'Unknown',
  };

  static String _sourceLabel(String source) => switch (source) {
    'manual' => 'Entered manually',
    'sms' => 'SMS',
    'email' => 'Email',
    'statement' => 'Statement import',
    'sms_bulk' => 'SMS backup import',
    'imported' => 'Imported',
    _ => source,
  };
}

/// Design 18 "Split this expense" — who owed what out of one payment.
///
/// Deliberately does **not** re-run any reward arithmetic. The parent
/// transaction's caps, milestones and points were computed once, on the
/// card it was actually paid with; a split records a claim between people,
/// not a second payment. The sheet says so, because "split" in a payments
/// app could reasonably be read as "charge this to two cards".
///
/// Shares are allowed to total less than the payment — partially splitting
/// a bill is a real thing ("₹400 of this ₹1,000 was Priya's") and the
/// remainder is simply yours. Totalling *more* is always a mistake and is
/// blocked here as well as server-side.
class _SplitSheet extends StatefulWidget {
  final Money total;
  final List<TransactionSplit> initial;
  const _SplitSheet({required this.total, required this.initial});

  @override
  State<_SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends State<_SplitSheet> {
  late final List<TextEditingController> _amounts;
  late final List<TextEditingController> _notes;

  @override
  void initState() {
    super.initState();
    final seed = widget.initial.isEmpty ? [const TransactionSplit(amount: Money.zero())] : widget.initial;
    _amounts = [
      for (final s in seed)
        TextEditingController(text: s.amount.isZero ? '' : s.amount.rupees.toStringAsFixed(2)),
    ];
    _notes = [for (final s in seed) TextEditingController(text: s.note ?? '')];
  }

  @override
  void dispose() {
    for (final c in _amounts) {
      c.dispose();
    }
    for (final c in _notes) {
      c.dispose();
    }
    super.dispose();
  }

  double get _enteredTotal => _amounts.fold(0.0, (sum, c) => sum + (double.tryParse(c.text.trim()) ?? 0));

  bool get _overAllocated => (_enteredTotal - widget.total.rupees) > 0.005;

  void _addShare() {
    setState(() {
      _amounts.add(TextEditingController());
      _notes.add(TextEditingController());
    });
  }

  void _removeShare(int index) {
    setState(() {
      _amounts.removeAt(index).dispose();
      _notes.removeAt(index).dispose();
    });
  }

  void _save() {
    final splits = <TransactionSplit>[];
    for (var i = 0; i < _amounts.length; i++) {
      final amount = double.tryParse(_amounts[i].text.trim()) ?? 0;
      if (amount <= 0) continue; // a blank row is not an error, just skipped
      final note = _notes[i].text.trim();
      splits.add(TransactionSplit(amount: Money.fromRupees(amount), note: note.isEmpty ? null : note));
    }
    Navigator.of(context).pop(splits);
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.total.rupees - _enteredTotal;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.lg,
        right: AppSpace.lg,
        top: AppSpace.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Split this expense', style: BambooFonts.heading(18, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Who owed what out of ${widget.total.format()}. This does not change which '
              'card was charged, or what it earned.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
            for (var i = 0; i < _amounts.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _amounts[i],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => setState(() {}),
                        style: BambooFonts.money(15, color: BambooInk.ink900),
                        decoration: const InputDecoration(prefixText: '₹ ', hintText: '0'),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: TextField(
                        controller: _notes[i],
                        style: BambooFonts.ui(14, color: BambooInk.ink900),
                        decoration: const InputDecoration(hintText: 'Who / what for'),
                      ),
                    ),
                    if (_amounts.length > 1)
                      IconButton(
                        tooltip: 'Remove this share',
                        icon: const Icon(Icons.close_rounded, size: 18, color: BambooInk.ink500),
                        onPressed: () => _removeShare(i),
                      ),
                  ],
                ),
              ),
            TextButton.icon(
              onPressed: _amounts.length >= 20 ? null : _addShare,
              style: TextButton.styleFrom(foregroundColor: BambooInk.ink900, minimumSize: const Size(44, 44)),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add a share'),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              _overAllocated
                  ? 'That is ${Money.fromRupees(-remaining).format()} more than the payment.'
                  : 'Unallocated: ${Money.fromRupees(remaining).format()} — still yours.',
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w600,
                color: _overAllocated ? BambooInk.clayInk : BambooInk.ink500,
              ),
            ),
            const SizedBox(height: AppSpace.md),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.onSlate,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: _overAllocated ? null : _save,
              child: const Text('Save split'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
          ),
          Expanded(
            child: Text(value, style: BambooFonts.ui(13.5, color: BambooInk.ink900)),
          ),
        ],
      ),
    );
  }
}
