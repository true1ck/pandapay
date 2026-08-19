import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

const _lastUsedCardKey = 'pandapay_app.quick_add_last_used_card_v1';
const _recentMerchantsKey = 'pandapay_app.quick_add_recent_merchants_v1';
const _maxRecentMerchants = 8;
const _merchantSearchDebounce = Duration(milliseconds: 300);

/// ui-spec B6 — "under 3 taps." Save posts the transaction immediately;
/// the "Undo" snackbar action is a real undo despite there being no
/// DELETE /transactions/:id route — it calls
/// POST /transactions/:id/ignore with reason 'reversal', which already
/// existed server-side (used by the duplicate/needs-review flows) and
/// reverses the exact cap/milestone/points/fee-waiver state update Save
/// just made, then marks the row 'ignored' so it stops counting anywhere.
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
  /// Prefill from Home's hero-card "Pay with this card" action (design 01):
  /// Home already knows the amount/category/winning card from the ranked
  /// list, so landing here with the form blank would just make the user
  /// retype what they already told Home. Null when opened from the plain
  /// "+" entry point, which has none of this context.
  final Money? initialAmount;
  final String? initialCategoryId;
  final String? initialUserCardId;

  const QuickAddScreen({super.key, this.initialAmount, this.initialCategoryId, this.initialUserCardId});

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
    if (widget.initialAmount != null && !widget.initialAmount!.isZero) {
      _amountController.text = widget.initialAmount!.rupees.toStringAsFixed(0);
    }
    _selectedCategoryId = widget.initialCategoryId;
    _selectedUserCardId = widget.initialUserCardId;
    // Only fall back to the remembered card when Home didn't already hand
    // us a winning one — _loadLastUsedCard's own membership check still
    // protects against a stale cross-user id either way.
    if (widget.initialUserCardId == null) _loadLastUsedCard();
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
    final updated = [
      trimmed,
      ..._recentMerchants.where((m) => m != trimmed),
    ].take(_maxRecentMerchants).toList();
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
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save anyway'),
            ),
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
      final transactionId = await repo.logTransaction(
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
        // this screen's own `context`/`State` is deactivated/disposed.
        // `messenger` stays valid because it's the ScaffoldMessenger
        // instance itself, not a context lookup. `container` (the
        // ProviderContainer, not this State's `ref`) is the same fix for
        // Riverpod: `ref.invalidate(...)` after this State disposes throws
        // "used after dispose" — caught by the try/catch below, so it never
        // crashed, but silently always fell to "Could not undo." instead of
        // ever running the real undo. Found by actually exercising this
        // path in a test, not assumed correct from reading the code.
        final messenger = ScaffoldMessenger.of(context);
        final container = ProviderScope.containerOf(context, listen: false);
        Navigator.of(context).pop();
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Transaction logged'),
            action: SnackBarAction(
              label: 'Undo',
              // Real undo: POST /transactions/:id/ignore with reason
              // 'reversal' already exists server-side and does exactly
              // what this needs — reverseTransactionState() reverses the
              // cap/milestone/points/fee-waiver update logTransaction just
              // made, and the row is marked 'ignored' so it no longer
              // counts anywhere. No DELETE route needed.
              onPressed: () async {
                try {
                  await repo.ignoreTransaction(transactionId, reason: 'reversal');
                  container.invalidate(userCardsProvider);
                  container.invalidate(transactionsProvider);
                  messenger.showSnackBar(const SnackBar(content: Text('Undone.')));
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('Could not undo. ${userFacingErrorMessage(e)}')),
                  );
                }
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
        // A second try/catch, deliberately nested here rather than left to
        // propagate: this branch is ALREADY inside the outer catch, so an
        // exception from the outbox write itself (a full local queue, a
        // disk error) had nowhere left to go — it used to vanish silently
        // (an unhandled Future rejection from an unawaited async callback),
        // and would otherwise now surface only in the global CrashLog with
        // nothing shown on screen. Either way the user just sees a button
        // that appeared to do nothing. This makes that failure a normal,
        // visible error instead.
        try {
          final outbox = await ref.read(outboxRepositoryProvider.future);
          await outbox.enqueue(
            userCardId: _selectedUserCardId!,
            amount: Money.fromRupees(amount),
            categoryId: _selectedCategoryId,
            merchantName: merchantName,
            occurredAt: occurredAt,
            note: note,
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
        } catch (outboxErr) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(outboxErr))));
          }
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
    InputDecoration inputDecoration(String label, {String? prefix, String? error, Widget? suffixIcon}) =>
        InputDecoration(
          labelText: label,
          prefixText: prefix,
          errorText: error,
          suffixIcon: suffixIcon,
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
        title: Text('Quick add', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: ListView(
            children: [
              TextField(
                controller: _amountController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
                style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                decoration: inputDecoration('Amount', prefix: '₹ ', error: _amountError),
                onChanged: (_) => setState(() => _amountError = null),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: _merchantController,
                focusNode: _merchantFocusNode,
                style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                decoration: inputDecoration(
                  'Merchant (optional)',
                  suffixIcon: _merchantSearching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
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
                error: (err, _) =>
                    Text(userFacingErrorMessage(err), style: BambooFonts.ui(13.5, color: BambooInk.clay)),
                data: (cards) => DropdownButtonFormField<String>(
                  initialValue: _selectedUserCardId,
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  decoration: inputDecoration('Card'),
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
                error: (err, _) =>
                    Text(userFacingErrorMessage(err), style: BambooFonts.ui(13.5, color: BambooInk.clay)),
                data: (list) => DropdownButtonFormField<String>(
                  initialValue: _selectedCategoryId,
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  decoration: inputDecoration('Category (optional)'),
                  items: list.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                  onChanged: (v) => setState(() => _selectedCategoryId = v),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              Material(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(16),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: const BorderSide(color: BambooInk.hairlineOnPaper),
                  ),
                  title: Text(
                    _date == null
                        ? 'Today'
                        : '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}',
                    style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  ),
                  trailing: const Icon(Icons.calendar_today_rounded, color: BambooInk.ink500),
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
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: _noteController,
                style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                decoration: inputDecoration('Note (optional)'),
              ),
              const SizedBox(height: AppSpace.lg),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                ),
                onPressed: _canSave && !_saving ? _save : null,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.lime),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
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

  const _MerchantSuggestions({
    required this.query,
    required this.recent,
    required this.results,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final showRecent = query.trim().isEmpty;
    final items = showRecent ? recent : null;
    if (showRecent && recent.isEmpty) return const SizedBox.shrink();
    if (!showRecent && results.isEmpty) return const SizedBox.shrink();

    // A Material, not a plain Container: ListTile paints its background and
    // ink splashes onto the nearest Material ancestor, so a coloured
    // DecoratedBox/Container wrapper hides them (Flutter asserts on exactly
    // this). Same visual result, correct ancestry.
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: BambooInk.glassFillOnPaper,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: BambooInk.hairlineOnPaper),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showRecent)
              for (final name in items!)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history_rounded, size: 18, color: BambooInk.ink500),
                  title: Text(name, style: BambooFonts.ui(13.5, color: BambooInk.ink900)),
                  onTap: () => onPick(name: name),
                )
            else
              for (final candidate in results)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.storefront_rounded, size: 18, color: BambooInk.ink500),
                  title: Text(
                    candidate.displayName ?? 'Unnamed merchant',
                    style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                  ),
                  onTap: () => onPick(name: candidate.displayName ?? '', categoryId: candidate.categoryId),
                ),
          ],
        ),
      ),
    );
  }
}
