import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';

/// D3 Edit Transaction (ui-spec Group D). All fields editable, explicit
/// save/cancel; recomputes caps/milestones on save — that recompute is
/// entirely server-side (Task C-0c's PATCH /transactions/:id, verified
/// live against a real database during that task), so this screen's only
/// job is collecting the new values correctly.
class EditTransactionScreen extends ConsumerStatefulWidget {
  final String transactionId;
  const EditTransactionScreen({super.key, required this.transactionId});

  @override
  ConsumerState<EditTransactionScreen> createState() => _EditTransactionScreenState();
}

class _EditTransactionScreenState extends ConsumerState<EditTransactionScreen> {
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  String? _userCardId;
  String? _categoryId;
  DateTime? _occurredAt;
  bool _initialized = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    super.dispose();
  }

  void _initFrom(TransactionEntry entry) {
    if (_initialized) return;
    _initialized = true;
    _amountController.text = entry.amount.rupees.toStringAsFixed(2);
    _merchantController.text = entry.merchantName ?? '';
    _userCardId = entry.userCardId;
    _categoryId = entry.categoryId;
    _occurredAt = entry.occurredAt;
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid amount greater than zero.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(userCardsRepositoryProvider)!
          .editTransaction(
            widget.transactionId,
            amountInr: amount,
            occurredAt: _occurredAt,
            categoryId: _categoryId,
            merchantName: _merchantController.text.trim().isEmpty ? null : _merchantController.text.trim(),
            userCardId: _userCardId,
          );
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      if (mounted) context.pop();
    } catch (e) {
      // Plan Phase 4. Before this, an edit made offline simply failed and the
      // user's typing was gone the moment they left the screen — only B6
      // quick-add had an offline path, and this is an edit to a row that
      // already exists, which that queue can't represent.
      //
      // Queued only when the device is actually offline. A 4xx means the
      // server rejected the content and queueing it would just retry the same
      // rejection five times before dropping it, while telling the user it
      // was saved.
      final offline = ref.read(isOnlineProvider).valueOrNull == false;
      if (offline) {
        final queue = await ref.read(syncQueueProvider.future);
        queue.enqueueUpdate(
          entity: 'transactions',
          entityId: widget.transactionId,
          fields: {
            'amount_inr': amount,
            'occurred_at': _occurredAt?.toIso8601String(),
            'category_id': _categoryId,
            'merchant_name':
                _merchantController.text.trim().isEmpty ? null : _merchantController.text.trim(),
            'user_card_id': _userCardId,
          },
        );
        ref.invalidate(pendingSyncCountProvider);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved offline — will sync when you reconnect.')),
          );
          context.pop();
        }
        return;
      }
      setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final txn = ref.watch(_editTransactionProvider(widget.transactionId));
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];

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

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Edit transaction', style: BambooFonts.heading(17, color: BambooInk.ink900)),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: BambooInk.ink900),
            onPressed: () => context.pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
      body: AppBackground(
        child: txn.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
          data: (entry) {
            _initFrom(entry);
            return ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                TextField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  decoration: inputDecoration('Amount (₹)'),
                ),
                const SizedBox(height: AppSpace.lg),
                TextField(
                  controller: _merchantController,
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  decoration: inputDecoration('Merchant'),
                ),
                const SizedBox(height: AppSpace.lg),
                DropdownButtonFormField<String>(
                  initialValue: _userCardId,
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  decoration: inputDecoration('Card'),
                  items: [
                    for (final c in cards)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName),
                      ),
                  ],
                  onChanged: (v) => setState(() => _userCardId = v),
                ),
                const SizedBox(height: AppSpace.lg),
                DropdownButtonFormField<String>(
                  initialValue: _categoryId,
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  decoration: inputDecoration('Category'),
                  items: [for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.name))],
                  onChanged: (v) => setState(() => _categoryId = v),
                ),
                const SizedBox(height: AppSpace.lg),
                Material(
                  color: BambooInk.glassFillOnPaper,
                  borderRadius: BorderRadius.circular(16),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: const BorderSide(color: BambooInk.hairlineOnPaper),
                    ),
                    title: Text('Date', style: BambooFonts.ui(13.5, color: BambooInk.ink500)),
                    subtitle: Text(
                      _occurredAt?.toLocal().toString().split(' ').first ?? '—',
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                    ),
                    trailing: const Icon(Icons.calendar_today_outlined, size: 18, color: BambooInk.ink500),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _occurredAt ?? DateTime.now(),
                        firstDate: DateTime.now().subtract(const Duration(days: 365 * 3)),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) setState(() => _occurredAt = picked);
                    },
                  ),
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
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.lime),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

final _editTransactionProvider = FutureProvider.family<TransactionEntry, String>((ref, id) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) throw ApiException('Not signed in');
  return repo.fetchTransaction(id);
});
