import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widget_previews.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/user_cards_repository.dart'
    show TransactionEntry, TxnEntryKind, TxnInstrument, UserCard;
import '../cards/card_summary.dart';
import '../cards/card_visual.dart';
import '../import/import_hub_screen.dart';
import '../insights/spending_visuals.dart'
    show spendingCategoryVisual, spendingInstrumentVisual;

const _lastUsedCardKey = 'pandapay_app.quick_add_last_used_card_v1';
const _recentMerchantsKey = 'pandapay_app.quick_add_recent_merchants_v1';
const _maxRecentMerchants = 8;
const _merchantSearchDebounce = Duration(milliseconds: 300);

enum _ReceiptPickOption { camera, gallery, file }

enum AddFlowPage { quickAdd, scanBill, import }

@Preview(name: 'Add flow tabs', group: 'Quick add')
Widget addFlowTabsPreview() => const MaterialApp(
  home: Scaffold(
    body: Padding(
      padding: EdgeInsets.all(16),
      child: AddFlowTabs(selected: AddFlowPage.quickAdd),
    ),
  ),
);

class AddFlowTabs extends StatelessWidget {
  final AddFlowPage selected;
  final ValueChanged<AddFlowPage>? onSelected;

  const AddFlowTabs({super.key, required this.selected, this.onSelected});

  @override
  Widget build(BuildContext context) {
    const labels = {
      AddFlowPage.quickAdd: ('Quick Add', Icons.bolt_rounded),
      AddFlowPage.scanBill: ('Scan Bill', Icons.document_scanner_outlined),
      AddFlowPage.import: ('Import', Icons.table_rows_outlined),
    };
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: BambooInk.slate.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          for (final page in AddFlowPage.values)
            Expanded(
              child: Semantics(
                button: true,
                selected: selected == page,
                child: InkWell(
                  onTap: () => onSelected?.call(page),
                  borderRadius: BorderRadius.circular(8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 4,
                    ),
                    decoration: BoxDecoration(
                      color: selected == page
                          ? BambooInk.paper
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: selected == page
                          ? [
                              BoxShadow(
                                color: BambooInk.slate.withValues(alpha: 0.05),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          labels[page]!.$2,
                          size: 17,
                          color: selected == page
                              ? BambooInk.ink900
                              : BambooInk.ink500,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            labels[page]!.$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BambooFonts.ui(
                              12,
                              weight: selected == page
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: selected == page
                                  ? BambooInk.ink900
                                  : BambooInk.ink500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PendingReceipt {
  final String name;
  final String? path;
  final List<int>? bytes;
  final String? mimeType;

  const _PendingReceipt({
    required this.name,
    this.path,
    this.bytes,
    this.mimeType,
  });
}

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
  final String? initialMerchant;
  final String? initialCategoryName;
  final bool autofocus;
  final Key? amountFieldKey;

  const QuickAddScreen({
    super.key,
    this.initialAmount,
    this.initialCategoryId,
    this.initialUserCardId,
    this.initialMerchant,
    this.initialCategoryName,
    this.autofocus = true,
    this.amountFieldKey,
  });

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
  final ImagePicker _imagePicker = ImagePicker();
  _PendingReceipt? _receipt;
  bool _pickingReceipt = false;
  AddFlowPage _activePage = AddFlowPage.quickAdd;

  /// What paid for it, and whether it is spending at all.
  ///
  /// Both default to the overwhelmingly common case (a credit-card spend),
  /// so the form is unchanged for anyone who never touches them. They exist
  /// because the app previously could not record cash, a debit swipe, a
  /// salary credit or an SIP at all — every transaction had to belong to a
  /// credit card — which capped a spend tracker at "what my credit cards
  /// did".
  TxnInstrument _instrument = TxnInstrument.creditCard;
  TxnEntryKind _entryKind = TxnEntryKind.spend;
  bool _saving = false;
  String? _amountError;
  String? _pendingClientMutationId;
  String? _pendingPayloadFingerprint;
  DateTime? _pendingOccurredAt;

  List<String> _recentMerchants = const [];
  List<NearbyMerchantCandidate> _merchantResults = const [];
  bool _merchantSearching = false;
  bool _merchantSearchFailed = false;
  bool _showMerchantSuggestions = false;
  Timer? _merchantDebounce;
  int _merchantSearchRevision = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialAmount != null && !widget.initialAmount!.isZero) {
      _amountController.text = widget.initialAmount!.rupees.toStringAsFixed(0);
    }
    if (widget.initialMerchant != null) {
      _merchantController.text = widget.initialMerchant!;
    }
    _selectedCategoryId = widget.initialCategoryId;
    _selectedUserCardId = widget.initialUserCardId;
    // Only fall back to the remembered card when Home didn't already hand
    // us a winning one — _loadLastUsedCard's own membership check still
    // protects against a stale cross-user id either way.
    if (widget.initialUserCardId == null) _loadLastUsedCard();
    if (widget.initialCategoryId == null &&
        widget.initialCategoryName != null) {
      _resolveInitialCategory(widget.initialCategoryName!);
    }
    _loadRecentMerchants();
    _merchantFocusNode.addListener(_onMerchantFocusChanged);
  }

  Future<void> _resolveInitialCategory(String name) async {
    try {
      final categories = await ref.read(categoriesProvider.future);
      final query = name.trim().toLowerCase();
      final match = categories.where((category) {
        final label = category.name.trim().toLowerCase();
        final slug = category.slug.trim().toLowerCase();
        return label == query ||
            slug == query ||
            label.contains(query) ||
            query.contains(label);
      }).firstOrNull;
      if (mounted && match != null && _selectedCategoryId == null) {
        setState(() => _selectedCategoryId = match.id);
      }
    } catch (_) {
      // Assistant category text is only a convenience. The user can still
      // choose a category from the normal dropdown if catalogue loading fails.
    }
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
    if (mounted) {
      setState(
        () => _recentMerchants =
            prefs.getStringList(_recentMerchantsKey) ?? const [],
      );
    }
  }

  Future<void> _rememberMerchant(String name) async {
    if (name.trim().isEmpty) return;
    final trimmed = name.trim();
    final prefs = await SharedPreferences.getInstance();
    final updated = [
      trimmed,
      ..._recentMerchants.where(
        (m) => m.trim().toLowerCase() != trimmed.toLowerCase(),
      ),
    ].take(_maxRecentMerchants).toList();
    await prefs.setStringList(_recentMerchantsKey, updated);
    if (mounted) setState(() => _recentMerchants = updated);
  }

  Future<void> _pickReceipt([_ReceiptPickOption? preselected]) async {
    if (_pickingReceipt || _saving) return;
    final option =
        preselected ??
        await showModalBottomSheet<_ReceiptPickOption>(
          context: context,
          backgroundColor: BambooInk.paper,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.lg,
                    AppSpace.lg,
                    AppSpace.lg,
                    AppSpace.sm,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Add a receipt',
                      style: BambooFonts.heading(17, color: BambooInk.ink900),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take a photo'),
                  onTap: () =>
                      Navigator.of(context).pop(_ReceiptPickOption.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Choose a photo'),
                  onTap: () =>
                      Navigator.of(context).pop(_ReceiptPickOption.gallery),
                ),
                ListTile(
                  leading: const Icon(Icons.attach_file_rounded),
                  title: const Text('Choose a file'),
                  subtitle: const Text(
                    'Receipt, PDF, or other proof of payment',
                  ),
                  onTap: () =>
                      Navigator.of(context).pop(_ReceiptPickOption.file),
                ),
              ],
            ),
          ),
        );
    if (option == null || !mounted) return;
    setState(() => _pickingReceipt = true);
    try {
      if (option == _ReceiptPickOption.file) {
        final selection = await FilePicker.pickFiles(type: FileType.any);
        if (selection == null || selection.files.isEmpty) return;
        final file = selection.files.single;
        final bytes = file.path == null ? await file.readAsBytes() : null;
        setState(
          () => _receipt = _PendingReceipt(
            name: file.name,
            path: file.path,
            bytes: bytes,
            mimeType: file.extension == null ? null : _mimeFor(file.extension!),
          ),
        );
      } else {
        final image = await _imagePicker.pickImage(
          source: option == _ReceiptPickOption.camera
              ? ImageSource.camera
              : ImageSource.gallery,
          imageQuality: 95,
        );
        if (image == null) return;
        setState(
          () => _receipt = _PendingReceipt(
            name: image.name,
            path: image.path,
            mimeType: image.mimeType ?? 'image/jpeg',
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add that receipt: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _pickingReceipt = false);
    }
  }

  Future<void> _saveReceipt(String transactionId) async {
    final receipt = _receipt;
    if (receipt == null) return;
    final repository = await ref.read(
      transactionAttachmentsRepositoryProvider.future,
    );
    if (receipt.path != null) {
      await repository.addFromPath(
        transactionId: transactionId,
        sourcePath: receipt.path!,
        fileName: receipt.name,
        mimeType: receipt.mimeType,
      );
    } else if (receipt.bytes != null) {
      await repository.addFromBytes(
        transactionId: transactionId,
        bytes: receipt.bytes!,
        fileName: receipt.name,
        mimeType: receipt.mimeType,
      );
    }
  }

  static String _mimeFor(String extension) => switch (extension.toLowerCase()) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'pdf' => 'application/pdf',
    _ => 'application/octet-stream',
  };

  void _onMerchantFocusChanged() {
    if (_merchantFocusNode.hasFocus) {
      setState(() => _showMerchantSuggestions = true);
    } else {
      // Small delay so a tap on a suggestion tile (which also blurs the
      // field) still registers before the list disappears.
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted && !_merchantFocusNode.hasFocus) {
          setState(() => _showMerchantSuggestions = false);
        }
      });
    }
  }

  void _onMerchantTextChanged(String value) {
    _merchantDebounce?.cancel();
    final revision = ++_merchantSearchRevision;
    final query = value.trim();
    setState(() {
      _merchantResults = const [];
      _merchantSearching = query.isNotEmpty;
      _merchantSearchFailed = false;
      _showMerchantSuggestions = true;
    });
    if (query.isEmpty) return;
    _merchantDebounce = Timer(
      _merchantSearchDebounce,
      () => _searchMerchants(query, revision),
    );
  }

  Future<void> _searchMerchants(String query, int revision) async {
    try {
      final repo = ref.read(merchantSearchRepositoryProvider);
      final results = await repo
          .search(query)
          .timeout(const Duration(seconds: 8));
      if (mounted && revision == _merchantSearchRevision) {
        setState(() => _merchantResults = results);
      }
    } catch (_) {
      // Typeahead is a convenience, not a required step — a failed search
      // just means no suggestions this keystroke; the merchant field still
      // works as free text either way.
      if (mounted && revision == _merchantSearchRevision) {
        setState(() {
          _merchantResults = const [];
          _merchantSearchFailed = true;
        });
      }
    } finally {
      if (mounted && revision == _merchantSearchRevision) {
        setState(() => _merchantSearching = false);
      }
    }
  }

  void _pickMerchant({required String name, String? categoryId}) {
    _merchantDebounce?.cancel();
    _merchantSearchRevision++;
    _merchantController.text = name;
    setState(() {
      if (categoryId != null) _selectedCategoryId = categoryId;
      _showMerchantSuggestions = false;
      _merchantResults = const [];
      _merchantSearching = false;
      _merchantSearchFailed = false;
    });
    _merchantFocusNode.unfocus();
    _rememberMerchant(name);
  }

  bool get _canSave {
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) return false;
    // A card is required only for a credit-card entry. Cash, a debit swipe,
    // a salary credit and an SIP have no card by definition, and requiring
    // one here would leave Save permanently disabled for every one of them.
    if (_instrument == TxnInstrument.creditCard) {
      return _selectedUserCardId != null;
    }
    return true;
  }

  Future<void> _chooseCard(List<UserCard> cards) async {
    final targetType = _instrument == TxnInstrument.debitCard
        ? 'debit'
        : 'credit';
    final compatible = cards.where((card) {
      final type = card.cardType?.toLowerCase();
      return type == null || type == targetType;
    }).toList();
    if (compatible.isEmpty) return;
    final selection = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BambooInk.paper,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Text(
                'Choose a $targetType card',
                style: BambooFonts.heading(18, color: BambooInk.ink900),
              ),
            ),
            for (final card in compatible)
              ListTile(
                leading: const Icon(
                  Icons.credit_card_rounded,
                  color: BambooInk.ink700,
                ),
                title: Text(
                  card.nickname?.isNotEmpty == true
                      ? card.nickname!
                      : card.cardName,
                ),
                subtitle: card.last4 == null
                    ? null
                    : Text('•••• ${card.last4}'),
                trailing: _selectedUserCardId == card.id
                    ? const Icon(Icons.check_circle, color: BambooInk.slate)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(card.id),
              ),
          ],
        ),
      ),
    );
    if (selection != null && mounted) {
      setState(() => _selectedUserCardId = selection);
    }
  }

  Future<void> _chooseCategory(List<SpendCategory> categories) async {
    final selection = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BambooInk.paper,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Text(
                'Choose a category',
                style: BambooFonts.heading(18, color: BambooInk.ink900),
              ),
            ),
            for (final category in categories)
              ListTile(
                leading: _CategoryIcon(
                  label: category.name,
                  size: 40,
                  selected: _selectedCategoryId == category.id,
                ),
                title: Text(category.name),
                trailing: _selectedCategoryId == category.id
                    ? const Icon(Icons.check_circle, color: BambooInk.slate)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(category.id),
              ),
          ],
        ),
      ),
    );
    if (selection != null && mounted) {
      setState(() => _selectedCategoryId = selection);
    }
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
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
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
    // A card is required only for a credit-card entry; cash, income and
    // investments have none by definition.
    if (repo == null) return;
    if (_instrument == TxnInstrument.creditCard &&
        _selectedUserCardId == null) {
      return;
    }
    setState(() => _saving = true);
    final merchantName = _merchantController.text.trim().isEmpty
        ? null
        : _merchantController.text.trim();
    final note = _noteController.text.trim().isEmpty
        ? null
        : _noteController.text.trim();
    // Reuse the identity when the same submit is retried after a lost HTTP
    // response. If the user changes the form, it is a genuinely new mutation.
    final payloadFingerprint = [
      _selectedUserCardId,
      amount,
      _selectedCategoryId,
      merchantName,
      // A blank date means "at first submission", not a new timestamp on
      // every retry. The actual timestamp is retained below with the ID.
      _date?.toUtc().toIso8601String(),
      note,
      _instrument.wireValue,
      _entryKind.wireValue,
    ].join('|');
    if (_pendingPayloadFingerprint != payloadFingerprint) {
      _pendingPayloadFingerprint = payloadFingerprint;
      _pendingClientMutationId = const Uuid().v4();
      _pendingOccurredAt = occurredAt;
    }
    final clientMutationId = _pendingClientMutationId!;
    final effectiveOccurredAt = _pendingOccurredAt!;
    try {
      final transactionId = await repo.logTransaction(
        userCardId:
            _instrument == TxnInstrument.creditCard ||
                _instrument == TxnInstrument.debitCard
            ? _selectedUserCardId
            : null,
        amount: Money.fromRupees(amount),
        categoryId: _selectedCategoryId,
        merchantName: merchantName,
        occurredAt: effectiveOccurredAt,
        note: note,
        instrument: _instrument,
        entryKind: _entryKind,
        clientMutationId: clientMutationId,
      );
      String? receiptError;
      if (_receipt != null) {
        try {
          await _saveReceipt(transactionId);
        } catch (error) {
          receiptError =
              'Transaction saved, but its receipt could not be attached: $error';
        }
      }
      _pendingClientMutationId = null;
      _pendingPayloadFingerprint = null;
      _pendingOccurredAt = null;
      if (_selectedUserCardId != null &&
          _instrument == TxnInstrument.creditCard) {
        await _rememberLastUsedCard(_selectedUserCardId!);
      }
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
      ref.invalidate(utilizationTransactionsProvider);
      ref.invalidate(homeSummaryProvider);
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
            content: Text(
              receiptError ??
                  'Logged ${Money.fromRupees(amount).format()} ${_entryKind == TxnEntryKind.income ? 'income' : 'spend'}',
            ),
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
                  await repo.ignoreTransaction(
                    transactionId,
                    reason: 'reversal',
                  );
                  container.invalidate(userCardsProvider);
                  container.invalidate(transactionsProvider);
                  container.invalidate(utilizationTransactionsProvider);
                  container.invalidate(homeSummaryProvider);
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Undone.')),
                  );
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        'Could not undo. ${userFacingErrorMessage(e)}',
                      ),
                    ),
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
        if (_receipt != null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Connect to the internet to save this transaction with its receipt.',
                ),
              ),
            );
          }
          return;
        }
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
            userCardId:
                _instrument == TxnInstrument.creditCard ||
                    _instrument == TxnInstrument.debitCard
                ? _selectedUserCardId
                : null,
            amount: Money.fromRupees(amount),
            categoryId: _selectedCategoryId,
            merchantName: merchantName,
            occurredAt: effectiveOccurredAt,
            note: note,
            instrument: _instrument,
            entryKind: _entryKind,
            clientMutationId: clientMutationId,
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
                content: Text(
                  "Saved offline — this'll sync automatically once you're back online.",
                ),
              ),
            );
          }
        } catch (outboxErr) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(userFacingErrorMessage(outboxErr))),
            );
          }
        }
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userCards = ref.watch(userCardsProvider);
    final categories = ref.watch(categoriesProvider);
    final history = ref.watch(transactionsProvider).valueOrNull ?? const [];
    final merchants = _rankedMerchants(history);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Add transaction', style: BambooFonts.heading(18)),
      ),
      body: AppBackground(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: AddFlowTabs(
                    selected: _activePage,
                    onSelected: (page) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      setState(() => _activePage = page);
                    },
                  ),
                ),
                Expanded(
                  child: switch (_activePage) {
                    AddFlowPage.quickAdd => SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildAmountHeader(),
                          CardSummaryPanel(
                            elevated: false,
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildMerchantField(merchants),
                                const _FormDivider(),
                                _buildCategories(categories),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          CardSummaryPanel(
                            elevated: false,
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildPaymentMethods(userCards),
                                const _FormDivider(),
                                _buildDateField(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildExtras(),
                        ],
                      ),
                    ),
                    AddFlowPage.scanBill => _buildScanPlaceholder(),
                    AddFlowPage.import => const ImportHubScreen(embedded: true),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _activePage == AddFlowPage.quickAdd
          ? _saveBar()
          : null,
    );
  }

  List<String> _rankedMerchants(List<TransactionEntry> history) {
    final rows =
        history
            .where(
              (row) =>
                  row.status == 'active' &&
                  row.entryKind == _entryKind &&
                  row.merchantName?.trim().isNotEmpty == true,
            )
            .toList()
          ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final names = <String, String>{};
    final counts = <String, int>{};
    final latest = <String, DateTime>{};
    for (final row in rows) {
      final name = row.merchantName!.trim();
      final key = name.toLowerCase();
      names.putIfAbsent(key, () => name);
      counts.update(key, (count) => count + 1, ifAbsent: () => 1);
      latest.putIfAbsent(key, () => row.occurredAt);
    }
    final frequent = names.keys.toList()
      ..sort((a, b) {
        final frequency = counts[b]!.compareTo(counts[a]!);
        return frequency != 0 ? frequency : latest[b]!.compareTo(latest[a]!);
      });
    final picked = <String, String>{};
    void add(String name) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) {
        picked.putIfAbsent(trimmed.toLowerCase(), () => trimmed);
      }
    }

    // Keep the latest choice first, then the most-used names in recent activity.
    if (_recentMerchants.isNotEmpty) {
      add(_recentMerchants.first);
    } else if (rows.isNotEmpty) {
      add(rows.first.merchantName!);
    }
    for (final key in frequent) {
      add(names[key]!);
    }
    for (final name in _recentMerchants) {
      add(name);
    }
    return picked.values.toList();
  }

  Widget _buildAmountHeader() => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 16),
    child: Column(
      children: [
        Text('Amount', style: BambooFonts.ui(12, color: BambooInk.ink700)),
        const SizedBox(height: 2),
        LayoutBuilder(
          builder: (context, constraints) {
            final style = BambooFonts.money(
              constraints.maxWidth < 340 ? 42 : 48,
              weight: FontWeight.w600,
              letterSpacing: -1.5,
            );
            final painter = TextPainter(
              text: TextSpan(
                text: _amountController.text.isEmpty
                    ? '0.00'
                    : _amountController.text,
                style: style,
              ),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final width = (painter.width + 12)
                .clamp(110.0, constraints.maxWidth - 62)
                .toDouble();
            painter.dispose();
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '₹',
                  style: BambooFonts.money(
                    28,
                    weight: FontWeight.w500,
                    color: BambooInk.ink700,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: width,
                  child: TextField(
                    key:
                        widget.amountFieldKey ??
                        const ValueKey('quick-add-amount-field'),
                    controller: _amountController,
                    autofocus: widget.autofocus,
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*\.?\d{0,2}'),
                      ),
                    ],
                    style: style,
                    textAlign: TextAlign.left,
                    decoration: InputDecoration(
                      hintText: '0.00',
                      hintStyle: style.copyWith(color: BambooInk.ink900),
                      isDense: true,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      // The label is spoken without shifting the display amount.
                      semanticCounterText: 'Amount in rupees',
                    ),
                    onChanged: (_) => setState(() => _amountError = null),
                  ),
                ),
              ],
            );
          },
        ),
        if (_amountError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _amountError!,
              style: BambooFonts.ui(12, color: BambooInk.clayInk),
            ),
          ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 330 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.3;
            final columns = compact ? 2 : 4;
            final width =
                (constraints.maxWidth - 8 - (columns - 1) * 4) / columns;
            return Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: BambooInk.slate.withValues(alpha: 0.045),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final kind in const [
                    TxnEntryKind.spend,
                    TxnEntryKind.income,
                    TxnEntryKind.transfer,
                    TxnEntryKind.investment,
                  ])
                    SizedBox(
                      width: width,
                      child: _KindOption(
                        label: kind == TxnEntryKind.income
                            ? 'Income'
                            : kind.label,
                        selected: _entryKind == kind,
                        onTap: () => setState(() {
                          _entryKind = kind;
                          if (kind != TxnEntryKind.spend &&
                              _instrument == TxnInstrument.creditCard) {
                            _instrument = TxnInstrument.upiBank;
                            _selectedUserCardId = null;
                          }
                        }),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    ),
  );

  Widget _buildMerchantField(List<String> merchants) {
    final shortcuts = merchants.take(4).toList();
    return _FieldGroup(
      title: _entryKind == TxnEntryKind.income
          ? 'Source or payee'
          : 'Merchant or payee',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('quick-add-merchant-field'),
            controller: _merchantController,
            focusNode: _merchantFocusNode,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            style: BambooFonts.ui(15, weight: FontWeight.w500),
            decoration:
                _fieldDecoration(
                  _entryKind == TxnEntryKind.income
                      ? 'Search or enter a source'
                      : 'Search or enter a merchant',
                  icon: Icons.storefront_outlined,
                ).copyWith(
                  suffixIcon: _merchantSearching
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: BambooInk.ink700,
                            ),
                          ),
                        )
                      : IconButton(
                          tooltip: 'Choose a merchant',
                          onPressed: () {
                            _merchantFocusNode.requestFocus();
                            setState(() => _showMerchantSuggestions = true);
                          },
                          icon: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 20,
                          ),
                          color: BambooInk.ink700,
                        ),
                ),
            onChanged: _onMerchantTextChanged,
          ),
          if (shortcuts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Recent & frequent',
              style: BambooFonts.ui(10.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              key: const ValueKey('quick-add-merchant-shortcuts'),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final name in shortcuts)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _MerchantShortcut(
                        name: name,
                        selected:
                            _merchantController.text.trim().toLowerCase() ==
                            name.toLowerCase(),
                        onTap: () => _pickMerchant(name: name),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (_showMerchantSuggestions)
            _MerchantSuggestions(
              query: _merchantController.text,
              recent: merchants,
              results: _merchantResults,
              isSearching: _merchantSearching,
              searchFailed: _merchantSearchFailed,
              onPick: _pickMerchant,
            ),
        ],
      ),
    );
  }

  Widget _buildCategories(AsyncValue<List<SpendCategory>> categories) =>
      _FieldGroup(
        title: 'Category',
        trailing: TextButton(
          style: TextButton.styleFrom(
            foregroundColor: BambooInk.ink900,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(44, 32),
            textStyle: BambooFonts.ui(11.5, weight: FontWeight.w600),
          ),
          onPressed: () => categories.whenData(_chooseCategory),
          child: const Text('View all'),
        ),
        child: categories.when(
          loading: () => const LinearProgressIndicator(color: BambooInk.slate),
          error: (err, _) => Text(
            userFacingErrorMessage(err),
            style: BambooFonts.ui(12, color: BambooInk.clayInk),
          ),
          data: (list) {
            if (list.isEmpty) {
              return Text(
                'Categories are unavailable right now.',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              );
            }
            final visible = list.take(4).toList();
            final selected = list
                .where((item) => item.id == _selectedCategoryId)
                .firstOrNull;
            if (selected != null &&
                !visible.any((item) => item.id == selected.id)) {
              visible[visible.length - 1] = selected;
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final category in visible)
                  Expanded(
                    child: _CategoryChoice(
                      category: category,
                      selected: _selectedCategoryId == category.id,
                      onTap: () =>
                          setState(() => _selectedCategoryId = category.id),
                    ),
                  ),
              ],
            );
          },
        ),
      );

  Widget _buildPaymentMethods(
    AsyncValue<List<UserCard>> userCards,
  ) => _FieldGroup(
    title: _entryKind == TxnEntryKind.income ? 'Received in' : 'Paid with',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          key: const ValueKey('quick-add-payment-methods'),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final instrument in TxnInstrument.values)
                if (instrument != TxnInstrument.creditCard ||
                    _entryKind == TxnEntryKind.spend)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _SelectChip(
                      label: switch (instrument) {
                        TxnInstrument.creditCard => 'Credit card',
                        TxnInstrument.debitCard => 'Debit',
                        TxnInstrument.upiBank => 'UPI / bank',
                        TxnInstrument.cash => 'Cash',
                        TxnInstrument.wallet => 'Wallet',
                        TxnInstrument.other => 'Other',
                      },
                      icon: spendingInstrumentVisual(instrument.wireValue).icon,
                      selected: _instrument == instrument,
                      onTap: () => setState(() {
                        if (_instrument != instrument) {
                          _selectedUserCardId = null;
                        }
                        _instrument = instrument;
                      }),
                    ),
                  ),
            ],
          ),
        ),
        if (_instrument == TxnInstrument.creditCard ||
            _instrument == TxnInstrument.debitCard) ...[
          const SizedBox(height: 12),
          userCards.when(
            loading: () =>
                const LinearProgressIndicator(color: BambooInk.slate),
            error: (err, _) => Text(
              userFacingErrorMessage(err),
              style: BambooFonts.ui(12, color: BambooInk.clayInk),
            ),
            data: _buildCardSelector,
          ),
        ] else ...[
          const SizedBox(height: 10),
          Text(
            _entryKind == TxnEntryKind.spend
                ? 'Included in spending and budgets. Only credit-card entries affect card rewards and limits.'
                : 'Recorded separately from expense totals.',
            style: BambooFonts.ui(11, color: BambooInk.ink700, height: 1.4),
          ),
        ],
      ],
    ),
  );

  Widget _buildCardSelector(List<UserCard> cards) {
    final cardKind = _instrument == TxnInstrument.debitCard
        ? 'debit'
        : 'credit';
    final compatible = cards
        .where(
          (card) =>
              card.cardType == null || card.cardType!.toLowerCase() == cardKind,
        )
        .toList();
    final selected = compatible
        .where((card) => card.id == _selectedUserCardId)
        .firstOrNull;
    final catalogue = selected == null
        ? null
        : ref.watch(catalogueProvider).valueOrNull;
    final product = catalogue
        ?.where((product) => product.id == selected?.cardProductId)
        .firstOrNull;
    return Material(
      color: BambooInk.paperCool.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: const ValueKey('quick-add-card-selector'),
        onTap: compatible.isEmpty ? null : () => _chooseCard(cards),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (product != null)
                CardVisual(
                  product: product,
                  width: 48,
                  height: 32,
                  showProductName: false,
                )
              else
                Container(
                  width: 44,
                  height: 32,
                  decoration: BoxDecoration(
                    color: BambooInk.slate.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.credit_card_outlined,
                    size: 21,
                    color: BambooInk.ink700,
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected == null
                          ? (compatible.isEmpty
                                ? 'No matching card added'
                                : 'Choose your $cardKind card')
                          : selected.nickname?.isNotEmpty == true
                          ? selected.nickname!
                          : selected.cardName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(13, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      selected?.last4 != null
                          ? '•••• ${selected!.last4}'
                          : compatible.isEmpty
                          ? 'Add a card in Wallet or choose another payment method.'
                          : 'Select from your wallet',
                      style: BambooFonts.ui(11, color: BambooInk.ink700),
                    ),
                  ],
                ),
              ),
              if (compatible.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  selected == null ? 'Select' : 'Change',
                  style: BambooFonts.ui(11.5, weight: FontWeight.w600),
                ),
                const SizedBox(width: 2),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: BambooInk.ink700,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDateField() {
    final now = ref.read(clockProvider).now();
    final today = _date == null || DateUtils.isSameDay(_date, now);
    final yesterday = DateUtils.isSameDay(
      _date,
      now.subtract(const Duration(days: 1)),
    );
    return _FieldGroup(
      title: 'Transaction date',
      trailing: Text(
        MaterialLocalizations.of(context).formatMediumDate(_date ?? now),
        style: BambooFonts.ui(11, color: BambooInk.ink700),
      ),
      child: Row(
        children: [
          for (final choice in ['Today', 'Yesterday', 'Custom'])
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: choice == 'Custom' ? 0 : 6),
                child: _SelectChip(
                  label: choice,
                  icon: choice == 'Custom'
                      ? Icons.calendar_today_outlined
                      : Icons.event_available_outlined,
                  selected: choice == 'Today'
                      ? today
                      : choice == 'Yesterday'
                      ? yesterday
                      : !today && !yesterday,
                  onTap: () async {
                    if (choice == 'Today') {
                      setState(() => _date = null);
                    } else if (choice == 'Yesterday') {
                      setState(
                        () =>
                            _date = DateTime(now.year, now.month, now.day - 1),
                      );
                    } else {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _date ?? now,
                        firstDate: DateTime(now.year - 5),
                        lastDate: DateTime(now.year + 1),
                      );
                      if (picked != null && mounted) {
                        setState(() => _date = picked);
                      }
                    }
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildExtras() => CardSummaryPanel(
    elevated: false,
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldGroup(
          title: 'Note',
          trailing: Text(
            'Optional',
            style: BambooFonts.ui(10.5, color: BambooInk.ink500),
          ),
          child: TextField(
            controller: _noteController,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            style: BambooFonts.ui(14),
            decoration: _fieldDecoration(
              'What was it for?',
              icon: Icons.notes_rounded,
            ),
          ),
        ),
        const _FormDivider(),
        _FieldGroup(
          title: 'Receipt',
          trailing: Text(
            'Optional',
            style: BambooFonts.ui(10.5, color: BambooInk.ink500),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _ReceiptAction(
                      icon: Icons.photo_camera_outlined,
                      label: 'Take photo',
                      onTap: () => _pickReceipt(_ReceiptPickOption.camera),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ReceiptAction(
                      icon: Icons.upload_file_outlined,
                      label: 'Choose file',
                      onTap: () => _pickReceipt(_ReceiptPickOption.file),
                    ),
                  ),
                ],
              ),
              if (_receipt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.description_outlined,
                        size: 18,
                        color: BambooInk.ink700,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _receipt!.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: BambooFonts.ui(12),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove attachment',
                        onPressed: _saving
                            ? null
                            : () => setState(() => _receipt = null),
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  InputDecoration _fieldDecoration(String hint, {required IconData icon}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: BambooFonts.ui(14, color: BambooInk.ink500),
        filled: true,
        fillColor: BambooInk.slate.withValues(alpha: 0.035),
        prefixIcon: Icon(icon, size: 19, color: BambooInk.ink700),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BambooInk.slate),
        ),
      );

  Widget _saveBar() => DecoratedBox(
    decoration: const BoxDecoration(
      color: BambooInk.paper,
      border: Border(top: BorderSide(color: BambooInk.hairlineOnPaper)),
    ),
    child: SafeArea(
      top: false,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  disabledBackgroundColor: BambooInk.slate.withValues(
                    alpha: 0.07,
                  ),
                  disabledForegroundColor: BambooInk.ink500,
                  minimumSize: const Size.fromHeight(52),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  textStyle: BambooFonts.ui(14, weight: FontWeight.w600),
                ),
                onPressed: _canSave && !_saving ? _save : null,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: BambooInk.lime,
                        ),
                      )
                    : const Icon(Icons.save_outlined, size: 20),
                label: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _saving
                            ? 'Saving…'
                            : switch (_entryKind) {
                                TxnEntryKind.spend => 'Save expense',
                                TxnEntryKind.income => 'Save income',
                                TxnEntryKind.transfer => 'Save transfer',
                                TxnEntryKind.investment => 'Save investment',
                              },
                      ),
                    ),
                    if (!_saving)
                      Flexible(
                        child: Text(
                          '₹${_amountController.text.isEmpty ? '0.00' : _amountController.text}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: BambooFonts.money(
                            15,
                            weight: FontWeight.w600,
                            color: _canSave ? BambooInk.lime : BambooInk.ink500,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildScanPlaceholder() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: BambooInk.slate.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(
              Icons.document_scanner_outlined,
              size: 34,
              color: BambooInk.ink900,
            ),
          ),
          const SizedBox(height: 20),
          Text('Scan Bill', style: BambooFonts.heading(21)),
          const SizedBox(height: 8),
          Text(
            'Receipt scanning is being prepared. The scanner and bill review flow will appear here.',
            textAlign: TextAlign.center,
            style: BambooFonts.ui(14, color: BambooInk.ink700, height: 1.5),
          ),
        ],
      ),
    ),
  );
}

class _FieldGroup extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const _FieldGroup({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: BambooFonts.ui(
                12,
                weight: FontWeight.w600,
                color: BambooInk.ink700,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
      const SizedBox(height: 10),
      child,
    ],
  );
}

class _FormDivider extends StatelessWidget {
  const _FormDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 14),
    child: Divider(height: 1, color: BambooInk.hairlineOnPaper),
  );
}

class _KindOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _KindOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: selected ? BambooInk.lime : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: BambooFonts.ui(
              11.5,
              weight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? BambooInk.ink900 : BambooInk.ink700,
            ),
          ),
        ),
      ),
    ),
  );
}

class _SelectChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _SelectChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected
          ? BambooInk.lime.withValues(alpha: 0.28)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? BambooInk.lime : BambooInk.hairlineOnPaper,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? BambooInk.ink900 : BambooInk.ink700,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(
                    11.5,
                    weight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: BambooInk.ink900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MerchantShortcut extends StatelessWidget {
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _MerchantShortcut({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: selected
          ? BambooInk.lime.withValues(alpha: 0.28)
          : BambooInk.paperCool.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.history_rounded,
                size: 13,
                color: selected ? BambooInk.ink900 : BambooInk.ink700,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 115),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(11.5, color: BambooInk.ink900),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _CategoryIcon extends StatelessWidget {
  final String label;
  final double size;
  final bool selected;

  const _CategoryIcon({
    required this.label,
    this.size = 42,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: selected ? BambooInk.slate : BambooInk.paperCool,
      shape: BoxShape.circle,
    ),
    child: Icon(
      label == 'card'
          ? Icons.credit_card_rounded
          : spendingCategoryVisual(label).icon,
      size: size * 0.45,
      color: selected ? BambooInk.lime : BambooInk.ink700,
    ),
  );
}

class _CategoryChoice extends StatelessWidget {
  final SpendCategory category;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChoice({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
          child: Column(
            children: [
              _CategoryIcon(label: category.name, size: 42, selected: selected),
              const SizedBox(height: 8),
              SizedBox(
                height: 30 * MediaQuery.textScalerOf(context).scale(1),
                child: Text(
                  category.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: BambooFonts.ui(
                    10.5,
                    weight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? BambooInk.ink900 : BambooInk.ink700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ReceiptAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ReceiptAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon, size: 17),
    label: Text(label),
    style: OutlinedButton.styleFrom(
      foregroundColor: BambooInk.ink900,
      side: const BorderSide(color: BambooInk.hairlineOnPaper),
      minimumSize: const Size(0, 42),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: BambooFonts.ui(12, weight: FontWeight.w500),
    ),
  );
}

/// The merchant field's suggestion drop-down displays live search results
/// (from merchantSearchRepositoryProvider) once the user starts typing. A search-result tap carries a real
/// categoryId through to [onPick] for the category auto-fill; a recent-pick
/// tap doesn't (recents only remember names — see
/// _QuickAddScreenState._rememberMerchant), so it leaves category untouched,
/// same as free-text entry.
class _MerchantSuggestions extends StatelessWidget {
  final String query;
  final List<String> recent;
  final List<NearbyMerchantCandidate> results;
  final bool isSearching;
  final bool searchFailed;
  final void Function({required String name, String? categoryId}) onPick;

  const _MerchantSuggestions({
    required this.query,
    required this.recent,
    required this.results,
    required this.isSearching,
    required this.searchFailed,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final showRecent = query.trim().isEmpty;
    final serverNames = results
        .map((item) => item.displayName?.trim().toLowerCase())
        .toSet();
    final items = showRecent
        ? recent
        : recent
              .where(
                (name) =>
                    name.toLowerCase().contains(query.trim().toLowerCase()) &&
                    !serverNames.contains(name.toLowerCase()),
              )
              .toList();
    if (showRecent && recent.isEmpty) return const SizedBox.shrink();

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
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!showRecent && results.isEmpty && items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      isSearching
                          ? 'Searching merchants…'
                          : searchFailed
                          ? 'Search unavailable. You can still enter a name.'
                          : 'No match. You can use the name you entered.',
                      style: BambooFonts.ui(12, color: BambooInk.ink700),
                    ),
                  ),
                for (final name in items)
                  ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.history_rounded,
                      size: 18,
                      color: BambooInk.ink500,
                    ),
                    title: Text(
                      name,
                      style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                    ),
                    onTap: () => onPick(name: name),
                  ),
                if (!showRecent)
                  for (final candidate in results)
                    ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.storefront_rounded,
                        size: 18,
                        color: BambooInk.ink500,
                      ),
                      title: Text(
                        candidate.displayName ?? 'Unnamed merchant',
                        style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                      ),
                      onTap: () => onPick(
                        name: candidate.displayName ?? '',
                        categoryId: candidate.categoryId,
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
