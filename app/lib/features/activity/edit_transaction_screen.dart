import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/category_picker.dart';
import '../../app/transaction_tag_picker.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/catalogue_repository.dart'
    show categoryIdForServer, userCategoryIdForServer;
import '../../data/local/sync_queue.dart';
import '../../data/local/sms_feedback_outbox.dart';
import '../../data/local/auto_resolved_history_repository.dart';
import '../../data/merchant_category_rules_repository.dart';
import '../../data/user_cards_repository.dart';
import 'category_bulk_review_sheet.dart';
import 'merchant_future_rule_sheet.dart';
import 'sms_learning_capture.dart';

/// D3 Edit Transaction (ui-spec Group D). All fields editable, explicit
/// save/cancel; recomputes caps/milestones on save — that recompute is
/// entirely server-side (Task C-0c's PATCH /transactions/:id, verified
/// live against a real database during that task), so this screen's only
/// job is collecting the new values correctly.
class EditTransactionScreen extends ConsumerStatefulWidget {
  final String transactionId;
  final TransactionEntry? initialEntry;

  const EditTransactionScreen({
    super.key,
    required this.transactionId,
    this.initialEntry,
  });

  @override
  ConsumerState<EditTransactionScreen> createState() =>
      _EditTransactionScreenState();
}

class _EditTransactionScreenState extends ConsumerState<EditTransactionScreen> {
  final _amountController = TextEditingController();
  final _merchantController = TextEditingController();
  String? _userCardId;
  String? _categoryId;
  Set<String> _tagIds = {};
  bool _tagsEdited = false;
  TransactionEntry? _originalEntry;
  DateTime? _occurredAt;
  TxnInstrument? _instrument;
  TxnEntryKind _entryKind = TxnEntryKind.spend;
  TxnRail _rail = TxnRail.unknown;
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
    _originalEntry = entry;
    _tagIds =
        (ref
                    .read(transactionTagsProvider)
                    ?.tagsForTransaction(entry.id, fallback: entry.tags) ??
                entry.tags)
            .map((t) => t.id)
            .toSet();
    _amountController.text = entry.amount.rupees.toStringAsFixed(2);
    _merchantController.text = entry.merchantName ?? '';
    _userCardId = entry.userCardId;
    _categoryId = entry.categoryId;
    _occurredAt = entry.occurredAt;
    _entryKind = entry.entryKind;
    _instrument = entry.instrumentKnown ? entry.instrument : null;
    _rail = entry.rail;
    // The bottom action is built before the body's AsyncValue builder runs.
    // Request one safe rebuild after the first frame so Save is enabled for
    // the loaded row instead of remaining disabled until another provider
    // happens to change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || !amount.isFinite || amount <= 0) {
      setState(() => _error = 'Enter a valid amount greater than zero.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final original = _originalEntry;
    final financialChanged =
        original == null ||
        original.amount != Money.fromRupees(amount) ||
        original.categoryId != _categoryId ||
        original.userCardId != _userCardId ||
        original.occurredAt != _occurredAt ||
        (original.merchantName ?? '') != _merchantController.text.trim() ||
        (original.instrumentKnown
            ? original.instrument != _instrument
            : _instrument != null) ||
        original.entryKind != _entryKind ||
        original.rail != _rail;
    try {
      final categoryChanged =
          original != null && original.categoryId != _categoryId;
      if (_tagsEdited) {
        final tags = ref.read(transactionTagsProvider);
        if (tags == null)
          throw StateError('Tags are still loading. Please retry.');
        await tags.replace(
          widget.transactionId,
          _tagIds,
          fallback: original?.tags ?? [],
        );
      }
      if (financialChanged) {
        await _submitEdit(amount);
        await _recordSmsEditFeedbackSafely(amount);
      }
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      ref.invalidate(transactionsProvider);
      ref.invalidate(utilizationTransactionsProvider);
      ref.invalidate(homeSummaryProvider);

      // The original row is saved before this optional bulk flow starts. A
      // preview is only useful for a real online category change; tags and
      // other edits retain the existing one-row behaviour. The repository
      // adapter is intentionally invoked through the dynamic boundary here so
      // old app builds and lightweight repository fakes can keep compiling
      // while the typed data-layer methods roll out.
      if (categoryChanged && ref.read(isOnlineProvider).valueOrNull != false) {
        final result = await _offerCategoryBulkReview(
          targetCategoryId: _categoryId,
        );
        if (result != null && mounted && result.changedCount > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Applied ${result.changedCount} more transaction${result.changedCount == 1 ? '' : 's'} to ${_categoryLabel(_categoryId)}.',
              ),
            ),
          );
        }
        await _offerFutureCategoryRule(targetCategoryId: _categoryId);
      }
      if (mounted) context.pop(true);
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
        final clientSeq = queue.enqueueUpdate(
          entity: 'transactions',
          entityId: widget.transactionId,
          fields: {
            'amount_inr': amount,
            'occurred_at': _occurredAt?.toIso8601String(),
            'category_id': categoryIdForServer(_categoryId),
            'user_category_id': userCategoryIdForServer(_categoryId),
            'merchant_name': _merchantController.text.trim().isEmpty
                ? null
                : _merchantController.text.trim(),
            'user_card_id': _userCardId,
            if (_instrument != null) 'instrument': _instrument!.wireValue,
            'entry_kind': _entryKind.wireValue,
            'rail': _railWireValue(_rail),
          },
        );
        if (financialChanged) {
          try {
            await _queueSmsEditFeedbackAfterSync(queue, clientSeq, amount);
          } catch (_) {
            // Learning capture cannot undo a durable offline financial edit.
          }
        }
        ref.invalidate(pendingSyncCountProvider);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Saved offline — will sync when you reconnect.'),
            ),
          );
          context.pop(true);
        }
        return;
      }
      if (isAuthenticationFailure(e)) {
        try {
          final refreshed = await ref
              .read(sessionRefreshCoordinatorProvider)
              .refresh();
          if (refreshed != null && refreshed.isNotEmpty) {
            await _submitEdit(amount);
            if (financialChanged) {
              await _recordSmsEditFeedbackSafely(amount);
            }
            ref.invalidate(userCardsProvider);
            ref.invalidate(myCardsProvider);
            ref.invalidate(transactionsProvider);
            ref.invalidate(utilizationTransactionsProvider);
            ref.invalidate(homeSummaryProvider);
            if (mounted) context.pop(true);
            return;
          }
        } catch (_) {
          // Fall through to the explicit session-recovery message below.
        }
        if (mounted) {
          setState(
            () => _error =
                'Your session has expired. Reconnect and sign in again, then try saving this edit.',
          );
        }
        return;
      }
      setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _submitEdit(double amount) async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) {
      throw const AuthenticationUnavailableException();
    }
    await repo.editTransaction(
      widget.transactionId,
      amountInr: amount,
      occurredAt: _occurredAt,
      categoryId: _categoryId,
      clearCategory: _originalEntry?.categoryId != null && _categoryId == null,
      merchantName: _merchantController.text.trim().isEmpty
          ? null
          : _merchantController.text.trim(),
      userCardId: _userCardId,
      instrument: _instrument,
      entryKind: _entryKind,
      rail: _rail,
    );
  }

  /// Queues one typed correction when an SMS-backed transaction is edited from
  /// Activity. Runs after the PATCH has committed, so a failed or offline save
  /// never produces evidence, and never blocks or fails the user's edit.
  Future<void> _recordSmsEditFeedback(double amount) async {
    final original = _originalEntry;
    if (original == null) return;
    final categories = ref.read(categoriesProvider).valueOrNull ?? const [];
    String? slugFor(String? id) {
      for (final category in categories) {
        if (category.id == id) return category.slug;
      }
      return null;
    }

    final merchant = _merchantController.text.trim();
    await queueSmsTransactionCorrection(
      ref: ref,
      original: original,
      action: 'edited',
      correctedFields: {
        'amountInr': amount,
        if (_occurredAt != null)
          'occurredAt': _occurredAt!.toUtc().toIso8601String(),
        if (merchant.isNotEmpty) 'merchant': merchant,
        // A private custom category stays local: it is sent only when it maps
        // to a canonical spend slug, so it can never enter shared learning.
        if (slugFor(_categoryId) != null) 'categorySlug': slugFor(_categoryId),
        if (_instrument != null) 'instrument': _instrument!.wireValue,
        'entryKind': _entryKind.wireValue,
      },
      correctionKind: _smsEditCorrectionKind(original, amount),
    );
  }

  Future<void> _recordSmsEditFeedbackSafely(double amount) async {
    try {
      await _recordSmsEditFeedback(amount);
    } catch (_) {
      // The financial edit has committed; learning capture is best effort.
    }
  }

  Future<void> _queueSmsEditFeedbackAfterSync(
    SyncQueue queue,
    int clientSeq,
    double amount,
  ) async {
    final original = _originalEntry;
    if (original == null ||
        (original.source != 'sms' && original.source != 'sms_bulk')) {
      return;
    }
    final sourceKey = original.sourceKey ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceKey)) return;
    final cache = await ref.read(responseCacheProvider.future);
    final feedbackOutbox = SmsFeedbackOutbox(
      cache.financialStore.database,
      namespace: ref.read(cacheNamespaceProvider),
    );
    var factIndex = 0;
    if (original.id.startsWith('local-ai:')) {
      final history = AutoResolvedHistoryRepository(
        cache.financialStore.database,
        namespace: ref.read(cacheNamespaceProvider),
      ).findById('ai:$sourceKey');
      if (history?.factIndex == null) return;
      factIndex = history!.factIndex!;
    } else if (feedbackOutbox.hasMultiplePersistedFacts(sourceKey)) {
      return;
    }
    // Persist this metadata before the edit screen closes or sync can run.
    // Sync checks the current grant and its timestamp before upload.
    final categories = ref.read(categoriesProvider).valueOrNull ?? const [];
    String? slugFor(String? id) {
      for (final category in categories) {
        if (category.id == id) return category.slug;
      }
      return null;
    }

    final merchant = _merchantController.text.trim();
    final originalFields = <String, dynamic>{
      'amountInr': original.amount.rupees,
      'occurredAt': original.occurredAt.toUtc().toIso8601String(),
      if ((original.merchantName ?? '').trim().isNotEmpty)
        'merchant': original.merchantName!.trim(),
      if (slugFor(original.categoryId) != null)
        'categorySlug': slugFor(original.categoryId),
      if (original.instrumentKnown) 'instrument': original.instrument.wireValue,
      'entryKind': original.entryKind.wireValue,
    };
    final correctedFields = <String, dynamic>{
      'amountInr': amount,
      if (_occurredAt != null)
        'occurredAt': _occurredAt!.toUtc().toIso8601String(),
      if (merchant.isNotEmpty) 'merchant': merchant,
      if (slugFor(_categoryId) != null) 'categorySlug': slugFor(_categoryId),
      if (_instrument != null) 'instrument': _instrument!.wireValue,
      'entryKind': _entryKind.wireValue,
    };
    final origin = original.id.startsWith('local-ai:') ? 'ai' : 'parser';
    final feedback = <String, dynamic>{
      'sourceKey': sourceKey,
      'action': 'edited',
      'resolvedKind': 'transaction',
      'occurredAt': original.occurredAt.toUtc().toIso8601String(),
      'originalDecision': {
        'kind': 'posted_movement',
        'origin': origin,
        'fields': originalFields,
      },
      'correctedFields': correctedFields,
      'correctionKind': _smsEditCorrectionKind(original, amount),
      'decisionOrigin': origin,
      'factIndex': factIndex,
    };
    feedback['capturedAt'] = DateTime.now().toUtc().toIso8601String();
    queue.enqueueSmsLearningAfterSync(clientSeq: clientSeq, payload: feedback);
  }

  String _smsEditCorrectionKind(TransactionEntry original, double amount) {
    if (original.categoryId != _categoryId) return 'misclassified_category';
    if (original.entryKind != _entryKind) return 'misclassified_kind';
    if (original.amount != Money.fromRupees(amount)) return 'wrong_amount';
    if ((original.merchantName ?? '') != _merchantController.text.trim()) {
      return 'wrong_merchant';
    }
    if (original.occurredAt != _occurredAt) return 'wrong_date';
    if (original.instrumentKnown &&
        _instrument != null &&
        original.instrument != _instrument) {
      return 'wrong_instrument';
    }
    if (original.userCardId != _userCardId || original.rail != _rail) {
      return 'wrong_account';
    }
    return 'cosmetic';
  }

  String _categoryLabel(String? id) {
    if (id == null) return 'this category';
    final categories = ref.read(categoriesProvider).valueOrNull ?? const [];
    for (final category in categories) {
      if (category.id == id) return category.name;
    }
    return 'this category';
  }

  /// Invokes the category-bulk data contract after the original row is saved.
  /// Preview and apply both use server-owned IDs and selection tiers; the UI
  /// never reconstructs merchant matches locally.
  Future<CategoryBulkApplyResult?> _offerCategoryBulkReview({
    required String? targetCategoryId,
  }) async {
    if (targetCategoryId == null || targetCategoryId.isEmpty) return null;
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) return null;
    final isCustomCategory = targetCategoryId.startsWith('custom:');
    final serverCategoryId = isCustomCategory ? null : targetCategoryId;
    final serverUserCategoryId = isCustomCategory
        ? targetCategoryId.substring('custom:'.length)
        : null;

    Future<RelatedCategoryPreview> fetchPreview() =>
        repo.fetchCategoryRelatedPreview(
          widget.transactionId,
          targetCategoryId: serverCategoryId,
          targetUserCategoryId: serverUserCategoryId,
        );

    RelatedCategoryPreview preview;
    try {
      preview = await fetchPreview();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Saved this transaction. Related transactions could not be loaded.',
            ),
          ),
        );
      }
      return null;
    }
    if (!mounted || preview.candidates.isEmpty) return null;

    Future<CategoryBulkApplyResult> apply(Set<String> ids) =>
        repo.applyCategoryBulk(
          previewId: preview.previewId,
          selectedTransactionIds: ids,
          targetCategoryId: serverCategoryId,
          targetUserCategoryId: serverUserCategoryId,
        );

    final result = await showCategoryBulkReviewSheet(
      context: context,
      preview: preview,
      onRetry: fetchPreview,
      onApply: apply,
    );
    if (result != null) {
      ref.invalidate(transactionsProvider);
      ref.invalidate(utilizationTransactionsProvider);
      ref.invalidate(homeSummaryProvider);
    }
    return result;
  }

  /// Offers the separate, opt-in future rule after the one-time bulk review.
  /// The server derives merchant identity from the owned source transaction;
  /// the client never sends a merchant name, VPA, narration, or phone number.
  Future<MerchantCategoryRule?> _offerFutureCategoryRule({
    required String? targetCategoryId,
  }) async {
    if (targetCategoryId == null || targetCategoryId.isEmpty) return null;
    final repo = ref.read(merchantCategoryRulesRepositoryProvider);
    if (repo == null) return null;
    final isCustomCategory = targetCategoryId.startsWith('custom:');
    final categoryId = isCustomCategory ? null : targetCategoryId;
    final userCategoryId = isCustomCategory
        ? targetCategoryId.substring('custom:'.length)
        : null;
    MerchantCategoryRulePreview preview;
    try {
      preview = await repo.preview(
        sourceTransactionId: widget.transactionId,
        categoryId: categoryId,
        userCategoryId: userCategoryId,
      );
    } catch (_) {
      // The saved one-time category edit remains complete if the optional
      // future-rule service is unavailable. Do not turn this into an edit
      // failure or imply that a rule was created.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Saved this transaction. Future rule options could not be loaded.',
            ),
          ),
        );
      }
      return null;
    }
    if (!mounted || !preview.hasUsableIdentity) return null;

    Future<MerchantCategoryRule> create() => repo.create(
      sourceTransactionId: widget.transactionId,
      categoryId: categoryId,
      userCategoryId: userCategoryId,
    );
    Future<MerchantCategoryRule> update(MerchantCategoryRule rule) =>
        repo.update(
          rule.id,
          categoryId: categoryId,
          userCategoryId: userCategoryId,
          isActive: true,
          expectedVersion: rule.version,
        );

    return showMerchantFutureRuleSheet(
      context: context,
      preview: preview,
      onCreate: create,
      onUpdate: update,
      offline: ref.read(isOnlineProvider).valueOrNull == false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tagRepository = ref.watch(transactionTagsProvider);
    if (!_tagsEdited && _originalEntry != null && tagRepository != null) {
      _tagIds = tagRepository
          .tagsForTransaction(
            widget.transactionId,
            fallback: _originalEntry!.tags,
          )
          .map((tag) => tag.id)
          .toSet();
    }
    final txn = ref.watch(
      _editTransactionProvider((
        id: widget.transactionId,
        initialEntry: widget.initialEntry,
      )),
    );
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];

    InputDecoration inputDecoration(String label) => InputDecoration(
      labelText: label,
      labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
      filled: true,
      fillColor: BambooInk.glassFillOnPaper,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
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
        title: Text(
          'Edit transaction',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: BambooInk.ink900),
            onPressed: () => context.pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.sm,
            AppSpace.lg,
            AppSpace.lg,
          ),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.slate,
              foregroundColor: BambooInk.lime,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
            ),
            // Never offer Save while the transaction itself failed to load;
            // the screenshot's blank form was allowing exactly that state.
            onPressed: _saving || !_initialized ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: BambooInk.lime,
                    ),
                  )
                : const Text('Save'),
          ),
        ),
      ),
      body: AppBackground(
        child: txn.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
          data: (entry) {
            _initFrom(entry);
            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  children: [
                    TextField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      decoration: inputDecoration(
                        _entryKind == TxnEntryKind.income
                            ? 'Amount credited (₹)'
                            : 'Amount (₹)',
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    TextField(
                      controller: _merchantController,
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      decoration: inputDecoration(
                        _entryKind == TxnEntryKind.income
                            ? 'Received from'
                            : 'Merchant',
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    DropdownButtonFormField<TxnEntryKind>(
                      initialValue: _entryKind,
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      decoration: inputDecoration('Kind'),
                      items: [
                        for (final kind in TxnEntryKind.values)
                          DropdownMenuItem(
                            value: kind,
                            child: Text(kind.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _entryKind = value;
                          if (_entryKind != TxnEntryKind.spend &&
                              _instrument == TxnInstrument.creditCard) {
                            _instrument = TxnInstrument.upiBank;
                            _userCardId = null;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: AppSpace.lg),
                    DropdownButtonFormField<TxnInstrument?>(
                      initialValue: _instrument,
                      hint: const Text('Unknown — choose a method'),
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      decoration: inputDecoration('Paid with'),
                      items: [
                        for (final instrument in TxnInstrument.values)
                          if (instrument != TxnInstrument.creditCard ||
                              _entryKind == TxnEntryKind.spend)
                            DropdownMenuItem(
                              value: instrument,
                              child: Text(instrument.label),
                            ),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _instrument = value;
                          if (_instrument != TxnInstrument.creditCard)
                            _userCardId = null;
                        });
                      },
                    ),
                    const SizedBox(height: AppSpace.lg),
                    DropdownButtonFormField<TxnRail>(
                      initialValue: _rail,
                      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                      decoration: inputDecoration('Payment route'),
                      items: [
                        for (final rail in TxnRail.values)
                          DropdownMenuItem(
                            value: rail,
                            child: Text(_railLabel(rail)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _rail = value);
                      },
                    ),
                    if (_instrument == TxnInstrument.creditCard) ...[
                      const SizedBox(height: AppSpace.lg),
                      DropdownButtonFormField<String>(
                        initialValue: _userCardId,
                        style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                        decoration: inputDecoration('Card'),
                        items: [
                          for (final c in cards)
                            DropdownMenuItem(
                              value: c.id,
                              child: Text(
                                c.nickname?.isNotEmpty == true
                                    ? c.nickname!
                                    : c.cardName,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _userCardId = v),
                      ),
                    ],
                    const SizedBox(height: AppSpace.lg),
                    CategoryPickerField(
                      categories: categories,
                      selectedId: _categoryId,
                      label: 'Category',
                      onSelected: (v) => setState(() => _categoryId = v),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    Material(
                      color: BambooInk.glassFillOnPaper,
                      borderRadius: BorderRadius.circular(16),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(
                            color: BambooInk.hairlineOnPaper,
                          ),
                        ),
                        title: Text(
                          'Date',
                          style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                        ),
                        subtitle: Text(
                          _occurredAt?.toLocal().toString().split(' ').first ??
                              '—',
                          style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                        ),
                        trailing: const Icon(
                          Icons.calendar_today_outlined,
                          size: 18,
                          color: BambooInk.ink500,
                        ),
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _occurredAt ?? DateTime.now(),
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null)
                            setState(() => _occurredAt = picked);
                        },
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    TransactionTagField(
                      selectedIds: _tagIds,
                      enabled: !_saving,
                      onChanged: (ids) => setState(() {
                        _tagIds = ids;
                        _tagsEdited = true;
                      }),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpace.md),
                      Text(
                        _error!,
                        style: BambooFonts.ui(12.5, color: BambooInk.clay),
                      ),
                    ],
                    const SizedBox(height: AppSpace.xl),
                  ],
                ),
              ),
            );
          },
        ),
      ),
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

  static String _railWireValue(TxnRail rail) => switch (rail) {
    TxnRail.upiQr => 'upi_qr',
    TxnRail.swipe => 'swipe',
    TxnRail.online => 'online',
    TxnRail.contactless => 'contactless',
    TxnRail.atm => 'atm',
    TxnRail.emi => 'emi',
    TxnRail.unknown => 'unknown',
  };
}

final _editTransactionProvider =
    FutureProvider.family<
      TransactionEntry,
      ({String id, TransactionEntry? initialEntry})
    >((ref, request) async {
      final id = request.id;
      final repo = ref.watch(userCardsRepositoryProvider);
      // Activity already has the row the user tapped. Prefer that row, then
      // the in-memory list/cache, so an expired token cannot turn a usable
      // edit screen into a blank form.
      final loaded = ref.read(transactionsProvider).valueOrNull;
      TransactionEntry? fromLoaded;
      if (loaded != null) {
        for (final entry in loaded) {
          if (entry.id == id) {
            fromLoaded = entry;
            break;
          }
        }
      }
      final cached =
          request.initialEntry ??
          fromLoaded ??
          await cachedTransactionById(ref, id);
      if (repo == null) {
        if (cached != null) return cached;
        throw ApiException('Not signed in');
      }
      try {
        return await repo.fetchTransaction(id);
      } catch (_) {
        if (cached != null) return cached;
        rethrow;
      }
    });
