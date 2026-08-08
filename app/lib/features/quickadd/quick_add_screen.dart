import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

const _lastUsedCardKey = 'pandapay_app.quick_add_last_used_card_v1';

/// ui-spec B6 — "under 3 taps." No true undo: there is no
/// DELETE /transactions/:id route in this codebase (verified against
/// api/src/index.js — see Task 15's header note), so this posts the
/// transaction immediately on Save and the "Undo" snackbar action is
/// dismiss-only (it removes the snackbar and shows a follow-up notice that
/// the entry was already saved) rather than faking a revert that doesn't
/// actually happen server-side. A real undo is future work once a delete
/// route exists.
///
/// Scope note (matches the Task 16 brief as written, not the fuller B6
/// ui-spec prose): merchant is a plain optional text field, not an
/// autocomplete-with-history — the brief's own "Consumes" list only calls
/// for shared_preferences persistence of the *last-used card*, not a
/// merchant-name history store, so no such store was invented here.
/// Category is an independent optional dropdown rather than auto-filled
/// from merchant, for the same reason: nothing in this codebase maps a
/// free-text merchant name to a category client-side today (the closest
/// server-side equivalent is SMS-parser merchant matching in
/// transactions/from-sms, which isn't reachable from a manual-entry form).
class QuickAddScreen extends ConsumerStatefulWidget {
  const QuickAddScreen({super.key});

  @override
  ConsumerState<QuickAddScreen> createState() => _QuickAddScreenState();
}

class _QuickAddScreenState extends ConsumerState<QuickAddScreen> {
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  final _noteController = TextEditingController();
  String? _selectedUserCardId;
  String? _selectedCategoryId;
  DateTime? _date;
  bool _saving = false;
  String? _amountError;

  @override
  void initState() {
    super.initState();
    _loadLastUsedCard();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadLastUsedCard() async {
    final prefs = await SharedPreferences.getInstance();
    final lastUsed = prefs.getString(_lastUsedCardKey);
    if (lastUsed != null && mounted) setState(() => _selectedUserCardId = lastUsed);
  }

  Future<void> _rememberLastUsedCard(String userCardId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastUsedCardKey, userCardId);
  }

  bool get _canSave {
    final amount = double.tryParse(_amountController.text);
    return _selectedUserCardId != null && amount != null && amount > 0;
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) {
      setState(() => _amountError = 'Enter an amount greater than ₹0');
      return;
    }
    // ui-spec B6 validation: future dates warn, not block.
    final now = ref.read(clockProvider).now();
    final occurredAt = _date ?? now;
    if (occurredAt.isAfter(now)) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('This date is in the future'),
          content: const Text('Save it anyway?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Save anyway')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null || _selectedUserCardId == null) return;
    setState(() => _saving = true);
    try {
      await repo.logTransaction(
        userCardId: _selectedUserCardId!,
        amount: Money.fromRupees(amount),
        categoryId: _selectedCategoryId,
        merchantName: _merchantController.text.trim().isEmpty ? null : _merchantController.text.trim(),
        occurredAt: occurredAt,
        note: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
      );
      await _rememberLastUsedCard(_selectedUserCardId!);
      // These providers already do the cap/milestone/points/fee-waiver
      // recompute server-side inside logTransaction above — invalidating
      // them here just pulls that already-updated state back down so Home
      // and Activity reflect it without a manual pull-to-refresh.
      ref.invalidate(userCardsProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Transaction logged'),
            action: SnackBarAction(
              label: 'Undo',
              // Deliberately NOT a real undo — see the class doc comment.
              // Tapping this cannot silently do nothing: it tells the user
              // plainly that the save already happened and can't be
              // reversed from here, instead of pretending an undo occurred.
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      "This app can't undo a saved transaction yet — there's no delete option either; edit it from Activity instead.",
                    ),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userCards = ref.watch(userCardsProvider);
    final categories = ref.watch(categoriesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Quick add')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: ListView(
          children: [
            TextField(
              controller: _amountController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
              decoration: InputDecoration(labelText: 'Amount', prefixText: '₹ ', errorText: _amountError),
              onChanged: (_) => setState(() => _amountError = null),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(controller: _merchantController, decoration: const InputDecoration(labelText: 'Merchant (optional)')),
            const SizedBox(height: AppSpace.md),
            userCards.when(
              loading: () => const LinearProgressIndicator(),
              error: (err, _) => Text(userFacingErrorMessage(err)),
              data: (cards) => DropdownButtonFormField<String>(
                initialValue: _selectedUserCardId,
                decoration: const InputDecoration(labelText: 'Card'),
                items: cards
                    .map((c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _selectedUserCardId = v),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            categories.when(
              loading: () => const LinearProgressIndicator(),
              error: (err, _) => Text(userFacingErrorMessage(err)),
              data: (list) => DropdownButtonFormField<String>(
                initialValue: _selectedCategoryId,
                decoration: const InputDecoration(labelText: 'Category (optional)'),
                items: list.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                onChanged: (v) => setState(() => _selectedCategoryId = v),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                _date == null
                    ? 'Today'
                    : '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}',
              ),
              trailing: const Icon(Icons.calendar_today_rounded),
              onTap: () async {
                final now = ref.read(clockProvider).now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date ?? now,
                  firstDate: DateTime(now.year - 2),
                  lastDate: DateTime(now.year + 1),
                );
                if (picked != null) setState(() => _date = picked);
              },
            ),
            const SizedBox(height: AppSpace.md),
            TextField(controller: _noteController, decoration: const InputDecoration(labelText: 'Note (optional)')),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              onPressed: _canSave && !_saving ? _save : null,
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
