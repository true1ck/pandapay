import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

const _lastUsedCardKey = 'pandapay_app.quick_add_last_used_card_v1';
const _recentMerchantsKey = 'pandapay_app.quick_add_recent_merchants_v1';
const _maxRecentMerchants = 8;
const _merchantSearchDebounce = Duration(milliseconds: 300);

/// ui-spec B6 — "under 3 taps." No true undo: there is no
/// DELETE /transactions/:id route in this codebase (verified against
/// api/src/index.js — see Task 15's header note), so this posts the
/// transaction immediately on Save and the "Undo" snackbar action is
/// dismiss-only (it removes the snackbar and shows a follow-up notice that
/// the entry was already saved) rather than faking a revert that doesn't
/// actually happen server-side. A real undo is future work once a delete
/// route exists.
///
/// Merchant field: typeahead against merchantSearchRepositoryProvider (the
/// same GET /merchants/search Task 13/14 already wired up), plus a locally
/// persisted "recent merchants" list — mirrors Task 14's
/// pandapay_app.merchant_recent_searches_v1 pattern exactly, just under its
/// own key so quick-add's recents don't collide with merchant-search's.
/// Picking a *search-matched* suggestion (one with a real categoryId from
/// the backend) auto-fills the category dropdown, which the user can still
/// override afterward; typing a merchant name freehand (no suggestion
/// picked) leaves category as a manual choice, same as before.
class QuickAddScreen extends ConsumerStatefulWidget {
  const QuickAddScreen({super.key});

  @override
  ConsumerState<QuickAddScreen> createState() => _QuickAddScreenState();
}

class _QuickAddScreenState extends ConsumerState<QuickAddScreen> {
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  final _noteController = TextEditingController();
  final _merchantFocusNode = FocusNode();
  String? _selectedUserCardId;
  String? _selectedCategoryId;
  DateTime? _date;
  bool _saving = false;
  String? _amountError;

  List<String> _recentMerchants = const [];
  List<NearbyMerchantCandidate> _merchantResults = const [];
  bool _merchantSearching = false;
  bool _showMerchantSuggestions = false;
  Timer? _merchantDebounce;

  @override
  void initState() {
    super.initState();
    _loadLastUsedCard();
    _loadRecentMerchants();
    _merchantFocusNode.addListener(_onMerchantFocusChanged);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    _noteController.dispose();
    _merchantFocusNode.removeListener(_onMerchantFocusChanged);
    _merchantFocusNode.dispose();
    _merchantDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadLastUsedCard() async {
    final prefs = await SharedPreferences.getInstance();
    final lastUsed = prefs.getString(_lastUsedCardKey);
    if (lastUsed == null) return;
    // This prefs key isn't cleared on sign-out (only TokenStore's tokens
    // are), so a sign-out -> sign-in-as-different-user -> open Quick Add
    // sequence can restore a card id that isn't in the CURRENT user's
    // wallet. Feeding a value absent from the dropdown's `items` crashes
    // a debug assertion, so verify membership against the live wallet
    // before restoring it.
    final cards = await ref.read(userCardsProvider.future);
    if (mounted && cards.any((c) => c.id == lastUsed)) {
      setState(() => _selectedUserCardId = lastUsed);
    }
  }

  Future<void> _rememberLastUsedCard(String userCardId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastUsedCardKey, userCardId);
  }

  Future<void> _loadRecentMerchants() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _recentMerchants = prefs.getStringList(_recentMerchantsKey) ?? const []);
  }

  Future<void> _rememberMerchant(String name) async {
    if (name.trim().isEmpty) return;
    final trimmed = name.trim();
    final prefs = await SharedPreferences.getInstance();
    final updated = [trimmed, ..._recentMerchants.where((m) => m != trimmed)].take(_maxRecentMerchants).toList();
    await prefs.setStringList(_recentMerchantsKey, updated);
    if (mounted) setState(() => _recentMerchants = updated);
  }

  void _onMerchantFocusChanged() {
    if (_merchantFocusNode.hasFocus) {
      setState(() => _showMerchantSuggestions = true);
    } else {
      // Small delay so a tap on a suggestion tile (which also blurs the
      // field) still registers before the list disappears.
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted && !_merchantFocusNode.hasFocus) setState(() => _showMerchantSuggestions = false);
      });
    }
  }

  void _onMerchantTextChanged(String value) {
    _merchantDebounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _merchantResults = const [];
        _merchantSearching = false;
      });
      return;
    }
    _merchantDebounce = Timer(_merchantSearchDebounce, () => _searchMerchants(value.trim()));
  }

  Future<void> _searchMerchants(String query) async {
    setState(() => _merchantSearching = true);
    try {
      final repo = ref.read(merchantSearchRepositoryProvider);
      final results = await repo.search(query);
      if (mounted) setState(() => _merchantResults = results);
    } catch (_) {
      // Typeahead is a convenience, not a required step — a failed search
      // just means no suggestions this keystroke; the merchant field still
      // works as free text either way.
      if (mounted) setState(() => _merchantResults = const []);
    } finally {
      if (mounted) setState(() => _merchantSearching = false);
    }
  }

  void _pickMerchant({required String name, String? categoryId}) {
    _merchantController.text = name;
    setState(() {
      if (categoryId != null) _selectedCategoryId = categoryId;
      _showMerchantSuggestions = false;
      _merchantResults = const [];
    });
    _merchantFocusNode.unfocus();
    _rememberMerchant(name);
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
    final merchantName = _merchantController.text.trim().isEmpty ? null : _merchantController.text.trim();
    final note = _noteController.text.trim().isEmpty ? null : _noteController.text.trim();
    try {
      await repo.logTransaction(
        userCardId: _selectedUserCardId!,
        amount: Money.fromRupees(amount),
        categoryId: _selectedCategoryId,
        merchantName: merchantName,
        occurredAt: occurredAt,
        note: note,
      );
      await _rememberLastUsedCard(_selectedUserCardId!);
      // Remembers whatever merchant name was actually used this save, even
      // if typed freehand rather than picked from a suggestion — "remembers"
      // per ui-spec B6 means next time's quick-add, not just this session's
      // typeahead picks.
      if (merchantName != null) await _rememberMerchant(merchantName);
      // These providers already do the cap/milestone/points/fee-waiver
      // recompute server-side inside logTransaction above — invalidating
      // them here just pulls that already-updated state back down so Home
      // and Activity reflect it without a manual pull-to-refresh.
      ref.invalidate(userCardsProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) {
        // Captured BEFORE pop() — by the time a user actually taps "Undo"
        // (the snackbar lives ~4s, the pop animation completes in ~300ms),
        // this screen's own `context` is deactivated and
        // ScaffoldMessenger.of(context) inside the closure below would
        // throw. `messenger` stays valid because it's the ScaffoldMessenger
        // instance itself, not a context lookup.
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Transaction logged'),
            action: SnackBarAction(
              label: 'Undo',
              // Deliberately NOT a real undo — see the class doc comment.
              // Tapping this cannot silently do nothing: it tells the user
              // plainly that the save already happened and can't be
              // reversed from here, instead of pretending an undo occurred.
              onPressed: () {
                messenger.showSnackBar(
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
      // UA-0.3 offline queue (GAP_ANALYSIS.md §2): only route into the
      // outbox when the device actually reads as offline right now — a
      // real server error (validation, 500) while genuinely online must
      // still surface as an error, not silently queue a save that will
      // just fail identically on retry.
      final isOnline = ref.read(isOnlineProvider).valueOrNull ?? true;
      if (!isOnline) {
        await ref.read(outboxRepositoryProvider.future).then(
              (outbox) => outbox.enqueue(
                userCardId: _selectedUserCardId!,
                amount: Money.fromRupees(amount),
                categoryId: _selectedCategoryId,
                merchantName: merchantName,
                occurredAt: occurredAt,
                note: note,
              ),
            );
        ref.invalidate(pendingOutboxCountProvider);
        if (mounted) {
          // Same "capture before pop" reasoning as the success path above —
          // ScaffoldMessenger.of(context) after pop() would attach to a
          // deactivated context and silently fail to show anything.
          final messenger = ScaffoldMessenger.of(context);
          Navigator.of(context).pop();
          messenger.showSnackBar(
            const SnackBar(
              content: Text("Saved offline — this'll sync automatically once you're back online."),
            ),
          );
        }
        return;
      }
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
            TextField(
              controller: _merchantController,
              focusNode: _merchantFocusNode,
              decoration: InputDecoration(
                labelText: 'Merchant (optional)',
                suffixIcon: _merchantSearching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : null,
              ),
              onChanged: _onMerchantTextChanged,
            ),
            if (_showMerchantSuggestions)
              _MerchantSuggestions(
                query: _merchantController.text,
                recent: _recentMerchants,
                results: _merchantResults,
                onPick: _pickMerchant,
              ),
            const SizedBox(height: AppSpace.md),
            userCards.when(
              loading: () => const LinearProgressIndicator(),
              error: (err, _) => Text(userFacingErrorMessage(err)),
              data: (cards) => DropdownButtonFormField<String>(
                initialValue: _selectedUserCardId,
                decoration: const InputDecoration(labelText: 'Card'),
                items: cards
                    .map(
                      (c) => DropdownMenuItem(
                        value: c.id,
                        child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName),
                      ),
                    )
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
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
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

/// The merchant field's suggestion drop-down: recent picks when the field
/// is empty, live search results (from merchantSearchRepositoryProvider)
/// once the user starts typing. A search-result tap carries a real
/// categoryId through to [onPick] for the category auto-fill; a recent-pick
/// tap doesn't (recents only remember names — see
/// _QuickAddScreenState._rememberMerchant), so it leaves category untouched,
/// same as free-text entry.
class _MerchantSuggestions extends StatelessWidget {
  final String query;
  final List<String> recent;
  final List<NearbyMerchantCandidate> results;
  final void Function({required String name, String? categoryId}) onPick;

  const _MerchantSuggestions({required this.query, required this.recent, required this.results, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final showRecent = query.trim().isEmpty;
    final items = showRecent ? recent : null;
    if (showRecent && recent.isEmpty) return const SizedBox.shrink();
    if (!showRecent && results.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(top: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showRecent)
            for (final name in items!)
              ListTile(
                dense: true,
                leading: const Icon(Icons.history_rounded, size: 18),
                title: Text(name),
                onTap: () => onPick(name: name),
              )
          else
            for (final candidate in results)
              ListTile(
                dense: true,
                leading: const Icon(Icons.storefront_rounded, size: 18),
                title: Text(candidate.displayName ?? 'Unnamed merchant'),
                onTap: () => onPick(name: candidate.displayName ?? '', categoryId: candidate.categoryId),
              ),
        ],
      ),
    );
  }
}
