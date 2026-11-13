import 'package:pandapay_domain/sms_v2.dart' show Totals;
import '../sms_v2/ledger/providers.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/category_picker.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/transaction_tag_picker.dart';
import '../../data/api_exception.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/merchant_identity.dart';
import '../../data/foreign_payment.dart';
import '../../data/spending_selection.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../auth/login_screen.dart';
import 'activity_projection.dart';
import 'spend_exclusion.dart';
import 'transaction_reward_label.dart';
import 'foreign_payments_screen.dart';
import 'deleted_transactions_screen.dart';
import 'local_category_learning.dart';
import '../../data/local/sms_intake_repository.dart';
import 'transaction_badge.dart';
import '../sms_v2/storage/outbox_store.dart';
import '../sms_v2/sync/learning_signals.dart';
import '../sms_v2/ui/review_controller.dart'
    show readSharingConsent, smsReviewController;
import '../sms_v2/ui/transaction_actions.dart';

/// D1 Transaction List (ui-spec Group D, implementation-plan-group-c-d.md)
/// — extends the original flat list (UA-3+/Chunk 18) with date grouping,
/// card/category/type filters, a money-in/money-out summary for whatever's currently
/// filtered in, tap-through to D2 Transaction Detail, and free-text search
/// over merchant and note (`GET /transactions?q=`, debounced — see
/// [_SearchField]). Search was previously flagged here as a real gap
/// because no server-side text match existed; it does now.
///
/// The "needs-review" filter still isn't here, and shouldn't be: it isn't a
/// transactions-table concept at all (D4's parser_failures queue is a
/// separate surface with its own screen). The optimality indicator (✓
/// best / ⚠ better existed) depends on the shared historical-recompute
/// calculator, built separately and not yet wired into this row.
class ActivityScreen extends ConsumerStatefulWidget {
  final Set<String> initialTagIds;
  final String? initialCategoryId;
  final String? initialCategoryLabel;
  final DateTime? initialFrom;
  final DateTime? initialTo;
  final bool initialSpendOnly;

  /// A merchant or note search to start with, e.g. from a voice answer.
  final String? initialQuery;

  const ActivityScreen({
    super.key,
    this.initialTagIds = const {},
    this.initialCategoryId,
    this.initialCategoryLabel,
    this.initialFrom,
    this.initialTo,
    this.initialSpendOnly = false,
    this.initialQuery,
  });

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  final _projectionCache = ActivityProjectionCache();

  Future<void> _openPeriodSheet(
    BuildContext context,
    ActivityFilter filter,
  ) async {
    final picked = await showModalBottomSheet<_ActivityDatePreset>(
      context: context,
      backgroundColor: BambooInk.paper,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.sm,
                  AppSpace.lg,
                  AppSpace.xs,
                ),
                child: Text(
                  'Activity period',
                  style: BambooFonts.heading(17, color: BambooInk.ink900),
                ),
              ),
              for (final preset in _ActivityDatePreset.values)
                ListTile(
                  leading: Icon(
                    _datePresetIcon(preset),
                    color: preset == filter.datePreset
                        ? BambooInk.jade
                        : BambooInk.ink500,
                  ),
                  title: Text(
                    preset.label,
                    style: BambooFonts.ui(
                      14,
                      weight: FontWeight.w600,
                      color: BambooInk.ink900,
                    ),
                  ),
                  selected: preset == filter.datePreset,
                  selectedTileColor: BambooInk.paperMuted,
                  onTap: () => Navigator.of(sheetContext).pop(preset),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;

    if (picked == _ActivityDatePreset.custom) {
      final now = DateTime.now();
      final firstDate = DateTime(now.year - 5, 1, 1);
      final lastDate = DateTime(now.year + 1, 12, 31);
      DateTimeRange? initialRange;
      if (filter.from != null && filter.to != null) {
        final start = filter.from!.isBefore(firstDate)
            ? firstDate
            : filter.from!;
        final end = filter.to!.isAfter(lastDate)
            ? lastDate
            : (filter.to!.isBefore(start) ? start : filter.to!);
        initialRange = DateTimeRange(start: start, end: end);
      }
      if (!context.mounted) return;
      final range = await showDateRangePicker(
        context: context,
        firstDate: firstDate,
        lastDate: lastDate,
        initialDateRange: initialRange,
      );
      if (range != null && mounted) {
        ref
            .read(_activityFilterProvider.notifier)
            .update(
              (current) => current.copyWith(
                from: () => range.start,
                to: () => range.end,
                datePreset: _ActivityDatePreset.custom,
              ),
            );
      }
      return;
    }

    final range = picked.range(DateTime.now());
    ref
        .read(_activityFilterProvider.notifier)
        .update(
          (current) => current.copyWith(
            from: () => range?.start,
            to: () => range?.end,
            datePreset: picked,
          ),
        );
  }

  Future<void> _openFilterSheet(
    BuildContext context,
    ActivityFilter filter,
    List<TransactionEntry> entries, {
    Set<String> foreignTransactionIds = const {},
  }) async {
    final cards = ref.read(userCardsProvider).valueOrNull ?? const [];
    final tagRepo = ref.read(transactionTagsProvider);
    final tags = tagRepo?.allTags ?? const [];
    var categories = ref.read(categoriesProvider).valueOrNull;
    if (categories == null) {
      try {
        categories = await ref.read(categoriesProvider.future);
      } catch (_) {}
    }
    final resolvedCategories = categories ?? const <SpendCategory>[];

    final updated = await showModalBottomSheet<ActivityFilter>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: BambooInk.paper,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => _ActivityFilterSheet(
        initial: filter,
        entries: entries,
        foreignTransactionIds: foreignTransactionIds,
        cards: cards,
        tags: tags,
        categories: resolvedCategories,
        totalForEntries: ref.read(smsV2ReportingEnabledProvider)
            ? ref
                  .read(smsV2LedgerReadModelProvider)
                  .valueOrNull
                  ?.totalsForTransactions
            : null,
      ),
    );

    if (updated != null && mounted) {
      ref.read(_activityFilterProvider.notifier).update((_) => updated);
    }
  }

  final Set<String> _selectedIds = {};
  bool _selecting = false;
  bool _isBulkOperating = false;
  String? _lastSavedView;
  late bool _initialFilterReady = !_hasInitialFilter;

  bool get _hasInitialFilter =>
      widget.initialTagIds.isNotEmpty ||
      widget.initialCategoryId != null ||
      widget.initialCategoryLabel != null ||
      widget.initialFrom != null ||
      widget.initialTo != null ||
      widget.initialSpendOnly ||
      widget.initialQuery != null;

  @override
  void initState() {
    super.initState();
    if (_hasInitialFilter) {
      _applyInitialFilterAfterBuild();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreSavedView());
    }
  }

  /// Brings back the view the person left: filters, merchants and sort order.
  /// Coming back to the page in the same session keeps what is on screen; a
  /// fresh start, or a visit after a drill-down from another screen, reads the
  /// saved view, and with none saved starts on this month.
  Future<void> _restoreSavedView() async {
    if (!mounted || ref.read(_activityViewRestoredProvider)) return;
    ref.read(_activityViewRestoredProvider.notifier).state = true;
    final saved = await _loadActivityView();
    if (!mounted) return;
    ref.read(_activityFilterProvider.notifier).state =
        saved?.filter ?? _activityMonthFilter();
    ref.read(_activitySortProvider.notifier).state =
        saved?.sort ?? ActivitySort.newest;
  }

  void _saveViewIfChanged() {
    final json = _activityViewToJson(
      ref.read(_activityFilterProvider),
      ref.read(_activitySortProvider),
    );
    if (json == _lastSavedView) return;
    _lastSavedView = json;
    unawaited(
      _saveActivityView(
        ref.read(_activityFilterProvider),
        ref.read(_activitySortProvider),
      ),
    );
  }

  @override
  void deactivate() {
    // Leaving the page (a transaction, another tab, back) must not leave the
    // keyboard open over whatever comes next.
    FocusManager.instance.primaryFocus?.unfocus();
    super.deactivate();
  }

  @override
  void didUpdateWidget(covariant ActivityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tagsChanged =
        oldWidget.initialTagIds.length != widget.initialTagIds.length ||
        !oldWidget.initialTagIds.containsAll(widget.initialTagIds);
    if (tagsChanged ||
        oldWidget.initialCategoryId != widget.initialCategoryId ||
        oldWidget.initialCategoryLabel != widget.initialCategoryLabel ||
        oldWidget.initialFrom != widget.initialFrom ||
        oldWidget.initialTo != widget.initialTo ||
        oldWidget.initialSpendOnly != widget.initialSpendOnly ||
        oldWidget.initialQuery != widget.initialQuery) {
      _initialFilterReady = !_hasInitialFilter;
      if (_hasInitialFilter) {
        _applyInitialFilterAfterBuild();
      } else {
        ref.read(_activityViewRestoredProvider.notifier).state = false;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _restoreSavedView(),
        );
      }
    }
  }

  void _applyInitialFilterAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // This filter belongs to the screen that sent the person here. The next
      // plain visit goes back to their own saved view.
      ref.read(_activityViewRestoredProvider.notifier).state = false;
      final hasInitialDate =
          widget.initialFrom != null || widget.initialTo != null;
      final defaultMonth = _activityMonthFilter();
      ref.read(_activityFilterProvider.notifier).state = ActivityFilter(
        tagIds: widget.initialTagIds,
        categoryId: widget.initialCategoryId,
        categoryLabel: widget.initialCategoryLabel,
        from: hasInitialDate ? widget.initialFrom : defaultMonth.from,
        to: hasInitialDate ? widget.initialTo : defaultMonth.to,
        datePreset: hasInitialDate
            ? _ActivityDatePreset.custom
            : _ActivityDatePreset.thisMonth,
        type: widget.initialSpendOnly
            ? _ActivityTypeFilter.spending
            : _ActivityTypeFilter.all,
        query: widget.initialQuery,
      );
      setState(() => _initialFilterReady = true);
    });
  }

  Future<void> _changeTags(
    List<TransactionEntry> visible, {
    required bool remove,
  }) async {
    final repository = ref.read(transactionTagsProvider);
    if (repository == null || _isBulkOperating) return;
    final ids = visible
        .where((entry) => _selectedIds.contains(entry.id))
        .map((entry) => entry.id)
        .toList();
    if (ids.isEmpty) return;
    final chosen = await showTransactionTagPicker(
      context,
      title: remove
          ? 'Remove tags from ${ids.length} transactions'
          : 'Add tags to ${ids.length} transactions',
    );
    if (chosen == null ||
        chosen.isEmpty ||
        !mounted ||
        ref.read(transactionTagsProvider) != repository)
      return;
    setState(() => _isBulkOperating = true);
    try {
      if (remove) {
        await repository.unassign(ids, chosen.toList());
      } else {
        await repository.assign(ids, chosen.toList());
      }
      if (mounted) {
        setState(() {
          _selectedIds.clear();
          _selecting = false;
        });
        ref.invalidate(activityTransactionsProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Tags ${remove ? 'removed from' : 'added to'} ${ids.length} transactions',
            ),
          ),
        );
      }
      // Local writes are durable; synchronization can retry while offline.
      unawaited(repository.sync().catchError((Object _) {}));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
    } finally {
      if (mounted) setState(() => _isBulkOperating = false);
    }
  }

  Future<void> _bulkCategorize(List<TransactionEntry> visible) async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null || _isBulkOperating) return;
    final ids = visible
        .where((entry) => _selectedIds.contains(entry.id))
        .map((entry) => entry.id)
        .toList();
    if (ids.isEmpty) return;

    var categories = ref.read(categoriesProvider).valueOrNull;
    if (categories == null) {
      try {
        categories = await ref.read(categoriesProvider.future);
      } catch (_) {}
    }
    categories ??= const [];
    if (!mounted) return;

    final chosen = await showCategoryBottomSheet(
      context,
      ref,
      categories,
      title: 'Set category for ${ids.length} transactions',
    );
    if (chosen == null || !mounted) return;

    setState(() => _isBulkOperating = true);
    try {
      // SMS transactions (`v2:` ids) live on this phone and sync from there;
      // the server has no such id and answers 400. Save them locally and send
      // only the rest to the API.
      final selected = visible.where((e) => _selectedIds.contains(e.id));
      final local = selected.where((e) => e.pipelineVersion == 2).toList();
      final localIds = {for (final e in local) e.id};
      if (local.isNotEmpty) {
        final slug = categories
            .where((c) => c.id == chosen)
            .map((c) => c.slug)
            .firstOrNull;
        if (slug == null) {
          throw ArgumentError(
            'Choose a supported category for SMS transactions',
          );
        }
        final controller = await smsReviewController(ref);
        SmsTransactionActions(controller: controller).setCategory(local, slug);
      }
      await Future.wait(
        ids
            .where((id) => !localIds.contains(id))
            .map((id) => repo.editTransaction(id, categoryId: chosen)),
      );
      unawaited(_teachLocalCategoryRules(visible, chosen));
      unawaited(_shareCategoryChoices(visible, chosen));
      if (mounted) {
        setState(() {
          _selectedIds.clear();
          _selecting = false;
        });
        ref.invalidate(activityTransactionsProvider);
        ref.invalidate(transactionsProvider);
        ref.invalidate(homeSummaryProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Category updated for ${ids.length} transaction${ids.length == 1 ? '' : 's'}',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _isBulkOperating = false);
    }
  }

  /// Teaches the on-device merchant rule for each SMS-backed transaction in a
  /// bulk reassign, after every local edit has committed. Entries already in
  /// the chosen category teach nothing. Local only: nothing is uploaded.
  Future<void> _teachLocalCategoryRules(
    List<TransactionEntry> visible,
    String chosenCategoryId,
  ) async {
    final selectedIds = _selectedIds.toSet();
    final categories = ref.read(categoriesProvider).valueOrNull ?? const [];
    String? slugFor(String? id) {
      for (final category in categories) {
        if (category.id == id) return category.slug;
      }
      return null;
    }

    final correctedSlug = slugFor(chosenCategoryId);
    if (correctedSlug == null) return;
    try {
      final cache = await ref.read(responseCacheProvider.future);
      final namespace = ref.read(cacheNamespaceProvider);
      for (final entry in visible) {
        if (!selectedIds.contains(entry.id)) continue;
        if (entry.categoryId == chosenCategoryId) continue;
        recordLocalCategoryCorrection(
          database: cache.financialStore.database,
          namespace: namespace,
          original: entry,
          categorySlug: correctedSlug,
        );
      }
    } catch (_) {
      // Local rules are a convenience; the category edit already committed.
    }
  }

  /// With the sharing opt-in, queues one anonymised `category_choice` per
  /// distinct shop among the selected SMS readings (never people or own
  /// accounts; see [learningSignalFor]). Without the opt-in nothing is queued.
  Future<void> _shareCategoryChoices(
    List<TransactionEntry> visible,
    String chosenCategoryId,
  ) async {
    final categories = ref.read(categoriesProvider).valueOrNull ?? const [];
    String? slug;
    for (final category in categories) {
      if (category.id == chosenCategoryId) slug = category.slug;
    }
    if (slug == null) return;
    try {
      if (!await readSharingConsent(ref)) return;
      final cache = await ref.read(responseCacheProvider.future);
      final namespace = ref.read(cacheNamespaceProvider);
      final database = cache.financialStore.database;
      final selected = _selectedIds.toSet();
      final queue = OutboxStore(database.db, namespace: namespace);
      for (final signal in categoryChoiceSignalsForEntries(
        db: database.db,
        intake: SmsIntakeRepository(database),
        namespace: namespace,
        entries: visible.where((entry) => selected.contains(entry.id)),
        categorySlug: slug,
        chosenCategoryId: chosenCategoryId,
      )) {
        enqueueLearningSignal(queue, signal);
      }
    } catch (_) {
      // Sharing is optional; the category edit already committed.
    }
  }

  Future<void> _bulkAssignCard(List<TransactionEntry> visible) async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null || _isBulkOperating) return;
    final ids = visible
        .where((entry) => _selectedIds.contains(entry.id))
        .map((entry) => entry.id)
        .toList();
    if (ids.isEmpty) return;

    var cards = ref.read(userCardsProvider).valueOrNull;
    if (cards == null) {
      try {
        cards = await ref.read(userCardsProvider.future);
      } catch (_) {}
    }
    cards ??= const [];
    if (!mounted) return;
    final activeCards = cards.where((c) => !c.isArchived).toList();
    if (activeCards.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active cards found to assign.')),
      );
      return;
    }

    final chosen = await showModalBottomSheet<UserCard>(
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
                'Assign to card (${ids.length} transactions)',
                style: BambooFonts.heading(18, color: BambooInk.ink900),
              ),
            ),
            for (final card in activeCards)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: BambooInk.slate.withValues(alpha: 0.08),
                  child: const Icon(
                    Icons.credit_card_outlined,
                    color: BambooInk.ink700,
                  ),
                ),
                title: Text(
                  card.nickname?.isNotEmpty == true
                      ? card.nickname!
                      : card.cardName,
                  style: BambooFonts.ui(15, color: BambooInk.ink900),
                ),
                subtitle: card.last4 != null
                    ? Text(
                        '•••• ${card.last4}',
                        style: BambooFonts.ui(13, color: BambooInk.ink500),
                      )
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(card),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    setState(() => _isBulkOperating = true);
    try {
      // An SMS transaction's account is confirmed in Needs review or its own
      // Edit screen; the server cannot take a `v2:` id, so skip those rather
      // than failing the whole batch.
      final skipped = visible
          .where((e) => _selectedIds.contains(e.id) && e.pipelineVersion == 2)
          .map((e) => e.id)
          .toSet();
      await Future.wait(
        ids
            .where((id) => !skipped.contains(id))
            .map((id) => repo.editTransaction(id, userCardId: chosen.id)),
      );
      if (mounted) {
        setState(() {
          _selectedIds.clear();
          _selecting = false;
        });
        ref.invalidate(activityTransactionsProvider);
        ref.invalidate(userCardsProvider);
        ref.invalidate(transactionsProvider);
        ref.invalidate(homeSummaryProvider);
        final cardTitle = chosen.nickname?.isNotEmpty == true
            ? chosen.nickname!
            : chosen.cardName;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              skipped.isEmpty
                  ? 'Assigned ${ids.length} transaction${ids.length == 1 ? '' : 's'} to $cardTitle'
                  : 'Assigned ${ids.length - skipped.length} to $cardTitle. ${skipped.length} SMS transaction${skipped.length == 1 ? '' : 's'} skipped: change those from their own Edit screen.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _isBulkOperating = false);
    }
  }

  Future<void> _bulkDelete(List<TransactionEntry> visible) async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null || _isBulkOperating) return;
    final ids = visible
        .where((entry) => _selectedIds.contains(entry.id))
        .map((entry) => entry.id)
        .toList();
    if (ids.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Delete ${ids.length} transaction${ids.length == 1 ? '' : 's'}?',
        ),
        content: const Text(
          'They will be excluded from spend and moved to Deleted Transactions. You can restore them anytime.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: BambooInk.clayInk),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isBulkOperating = true);
    try {
      await Future.wait(
        ids.map((id) => repo.ignoreTransaction(id, reason: 'manual')),
      );
      if (mounted) {
        setState(() {
          _selectedIds.clear();
          _selecting = false;
        });
        ref.invalidate(activityTransactionsProvider);
        ref.invalidate(userCardsProvider);
        ref.invalidate(transactionsProvider);
        ref.invalidate(homeSummaryProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${ids.length} transaction${ids.length == 1 ? '' : 's'} deleted',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _isBulkOperating = false);
    }
  }

  /// Leaves the selected spend transactions out of (or back in) the person's
  /// spending. Other kinds in the selection are skipped and counted.
  Future<void> _bulkSpendExclusion(
    List<TransactionEntry> visible, {
    required bool excluded,
  }) async {
    if (_isBulkOperating) return;
    final selected = visible
        .where((entry) => _selectedIds.contains(entry.id))
        .toList();
    if (selected.isEmpty) return;
    setState(() => _isBulkOperating = true);
    try {
      final changed = await setSpendExclusion(ref, selected, excluded: excluded);
      ref.invalidate(activityTransactionsProvider);
      if (!mounted) return;
      final skipped = selected.where((e) => !canExcludeFromSpend(e)).length;
      setState(() {
        _selectedIds.clear();
        _selecting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            changed == 0
                ? 'Nothing to change: only settled spending can be left out of spending.'
                : '${excluded ? 'Left' : 'Added'} $changed transaction${changed == 1 ? '' : 's'} '
                      '${excluded ? 'out of' : 'back to'} your spending'
                      '${skipped > 0 ? '. $skipped other${skipped == 1 ? '' : 's'} skipped.' : ''}',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _isBulkOperating = false);
    }
  }

  void _openBulkEditSheet(List<TransactionEntry> visible) {
    final tagsAvailable = ref.read(transactionTagsProvider) != null;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: BambooInk.paper,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => _BulkEditSheet(
        count: _selectedIds.length,
        tagsAvailable: tagsAvailable,
        onSetCategory: () {
          Navigator.of(sheetContext).pop();
          _bulkCategorize(visible);
        },
        onAddTags: tagsAvailable
            ? () {
                Navigator.of(sheetContext).pop();
                _changeTags(visible, remove: false);
              }
            : null,
        onRemoveTags: tagsAvailable
            ? () {
                Navigator.of(sheetContext).pop();
                _changeTags(visible, remove: true);
              }
            : null,
        onAssignCard: () {
          Navigator.of(sheetContext).pop();
          _bulkAssignCard(visible);
        },
        onLeaveOutOfSpending: () {
          Navigator.of(sheetContext).pop();
          _bulkSpendExclusion(visible, excluded: true);
        },
        onCountInSpending: () {
          Navigator.of(sheetContext).pop();
          _bulkSpendExclusion(visible, excluded: false);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessionInit = ref.watch(sessionInitProvider);
    if (sessionInit.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final token = ref.watch(accessTokenProvider);
    if (token == null) return const LoginScreen();
    if (!_initialFilterReady) {
      return const Center(child: CircularProgressIndicator());
    }

    final filter = ref.watch(_activityFilterProvider);
    final sort = ref.watch(_activitySortProvider);
    final searching = ref.watch(_activitySearchActiveProvider);
    if (!_hasInitialFilter) {
      // Keep the view for the next visit, but not a filter that another screen
      // sent the person here with.
      ref.listen<ActivityFilter>(
        _activityFilterProvider,
        (_, _) => _saveViewIfChanged(),
      );
      ref.listen<ActivitySort>(
        _activitySortProvider,
        (_, _) => _saveViewIfChanged(),
      );
    }
    final transactions = ref.watch(activityTransactionsProvider);
    final tagRepository = ref.watch(transactionTagsProvider);
    final foreign =
        foreignPaymentsForPeriod(
              ref.watch(foreignPaymentsProvider).valueOrNull ?? const [],
              from: filter.from,
              to: filter.to,
              query: filter.query,
              categoryId: filter.categoryId,
            )
            .where(
              (payment) =>
                  !payment.isIgnored &&
                  (filter.cardId == null ||
                      payment.userCardId == filter.cardId) &&
                  filter.tagIds.isEmpty &&
                  switch (filter.type) {
                    _ActivityTypeFilter.all => true,
                    _ActivityTypeFilter.spending ||
                    _ActivityTypeFilter.moneyOut =>
                      payment.direction != 'refund',
                    _ActivityTypeFilter.moneyIn =>
                      payment.direction == 'refund',
                    _ => false,
                  },
            )
            .toList();
    final foreignByTransaction = {
      for (final payment in foreign)
        if (payment.transactionId != null) payment.transactionId!: payment,
    };
    final pendingForeign = foreign
        .where((payment) => payment.isPending)
        .toList();
    // The banner says how many are waiting; the rows only show when the
    // Foreign currency filter is on.
    final previewForeign = filter.foreignOnly
        ? pendingForeign
        : const <ForeignPayment>[];

    return AppBackground(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.lg,
              AppSpace.lg,
              0,
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(child: _SearchField()),
                    if (!searching) ...[
                      const SizedBox(width: AppSpace.xs),
                      PopupMenuButton<String>(
                        key: const Key('activity-more-menu'),
                        tooltip: 'More',
                        icon: const Icon(Icons.more_horiz_rounded),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        onSelected: (value) {
                          if (value == 'select' &&
                              !_selecting &&
                              !_isBulkOperating) {
                            setState(() => _selecting = true);
                          } else if (value == 'deleted') {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    const DeletedTransactionsScreen(),
                              ),
                            );
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'select',
                            enabled: !_selecting && !_isBulkOperating,
                            child: const ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.checklist),
                              title: Text('Select transactions'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'deleted',
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.history),
                              title: Text('Deleted transactions'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                if (!searching) ...[
                  const SizedBox(height: AppSpace.sm),
                  _ActivityControlRow(
                    filter: filter,
                    sort: sort,
                    onOpenPeriod: () => _openPeriodSheet(context, filter),
                    onOpenFilters: () => _openFilterSheet(
                      context,
                      filter,
                      ref.read(transactionsProvider).valueOrNull ??
                          transactions.valueOrNull ??
                          const [],
                      foreignTransactionIds: foreignByTransaction.keys.toSet(),
                    ),
                    onOpenSort: () => _openSortSheet(context, sort),
                  ),
                  if (filter.hasClearableFilters && _hasChips(filter)) ...[
                    const SizedBox(height: AppSpace.xs),
                    _ActiveChipsRow(filter: filter),
                  ],
                ],
              ],
            ),
          ),
          Expanded(
            child: searching
                ? const _SearchSuggestions()
                : transactions.when(
                    // Explicit refreshes keep the list stable. Account/filter
                    // dependency changes still enter loading below.
                    skipLoadingOnRefresh: true,
                    skipLoadingOnReload: false,
                    // See my_cards_screen.dart for why a list-shaped skeleton
                    // rather than a centred spinner.
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppSpace.lg),
                      child: SkeletonList(count: 5),
                    ),
                    error: (err, _) => ErrorState(
                      message: userFacingErrorMessage(err),
                      onRetry: () =>
                          ref.invalidate(activityTransactionsProvider),
                    ),
                    data: (allEntries) {
                      final entries = filter.foreignOnly
                          ? allEntries
                                .where(
                                  (entry) => foreignByTransaction.containsKey(
                                    entry.id,
                                  ),
                                )
                                .toList()
                          : allEntries;
                      if (entries.isEmpty && previewForeign.isEmpty) {
                        return RefreshIndicator(
                          onRefresh: () async {
                            ref.invalidate(activityTransactionsProvider);
                            ref.invalidate(transactionsProvider);
                            try {
                              await ref.read(
                                activityTransactionsProvider.future,
                              );
                            } catch (_) {}
                          },
                          child: LayoutBuilder(
                            builder: (context, constraints) =>
                                SingleChildScrollView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      minHeight: constraints.maxHeight,
                                    ),
                                    child: EmptyState(
                                      icon: Icons.receipt_long_outlined,
                                      title: filter.foreignOnly
                                          ? 'No foreign payments in this period'
                                          : filter.hasClearableFilters
                                          ? 'No activity matches these filters'
                                          : 'No activity this month',
                                      message: filter.isActive
                                          ? null
                                          : 'Transactions you log from the Cards tab show up here.',
                                    ),
                                  ),
                                ),
                          ),
                        );
                      }
                      final v2Enabled = ref.watch(
                        smsV2ReportingEnabledProvider,
                      );
                      final ledgerState = v2Enabled
                          ? ref.watch(smsV2LedgerReadModelProvider)
                          : null;
                      final ledgerModel = ledgerState?.valueOrNull;
                      if (v2Enabled && ledgerModel == null) {
                        return Center(
                          child: ledgerState!.hasError
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'Couldn’t load activity totals.',
                                    ),
                                    TextButton(
                                      onPressed: () => ref.invalidate(
                                        smsV2LedgerReadModelProvider,
                                      ),
                                      child: const Text('Retry'),
                                    ),
                                  ],
                                )
                              : const CircularProgressIndicator(),
                        );
                      }
                      final projection = _projectionCache.resolve(
                        entries,
                        scope: (
                          ref.read(cacheNamespaceProvider),
                          token,
                          filter,
                          v2Enabled,
                          sort,
                        ),
                        ledgerTotals: ledgerModel?.totalsForTransactions(
                          entries,
                        ),
                        sort: sort,
                      );
                      final visibleSelected = projection.visibleSelectedCount(
                        _selectedIds,
                      );
                      final selectionOffset = _selecting ? 1 : 0;

                      return Column(
                        children: [
                          Expanded(
                            child: RefreshIndicator(
                              onRefresh: () async {
                                ref.invalidate(activityTransactionsProvider);
                                ref.invalidate(transactionsProvider);
                                try {
                                  await ref.read(
                                    activityTransactionsProvider.future,
                                  );
                                } catch (_) {}
                              },
                              child: ListView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                  AppSpace.lg,
                                  AppSpace.lg,
                                  AppSpace.lg,
                                  0,
                                ),
                                itemCount:
                                    projection.rows.length +
                                    selectionOffset +
                                    (pendingForeign.isEmpty
                                        ? 0
                                        : previewForeign.length + 1),
                                itemBuilder: (context, index) {
                                  final foreignOffset = pendingForeign.isEmpty
                                      ? 0
                                      : previewForeign.length + 1;
                                  if (foreignOffset > 0 && index == 0) {
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: AppSpace.sm,
                                      ),
                                      child: _ForeignBanner(
                                        payments: pendingForeign,
                                        onTap: () => Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) =>
                                                ForeignPaymentsScreen(
                                                  from: filter.from,
                                                  to: filter.to,
                                                ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  if (index < foreignOffset) {
                                    final payment = previewForeign[index - 1];
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: AppSpace.sm,
                                      ),
                                      child: ForeignPaymentTile(
                                        payment: payment,
                                        onTap: () => openForeignPayment(
                                          context,
                                          payment,
                                        ),
                                      ),
                                    );
                                  }
                                  index -= foreignOffset;
                                  final row = _selecting && index == 0
                                      ? const ActivityListRow.selection()
                                      : projection.rows[index -
                                            selectionOffset];
                                  switch (row.kind) {
                                    case ActivityRowKind.selection:
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: AppSpace.sm,
                                        ),
                                        child: Row(
                                          children: [
                                            _SelectionCountChip(
                                              count: visibleSelected,
                                              onCancel: _isBulkOperating
                                                  ? null
                                                  : () => setState(() {
                                                      _selecting = false;
                                                      _selectedIds.clear();
                                                    }),
                                            ),
                                            const Spacer(),
                                            TextButton(
                                              onPressed: _isBulkOperating
                                                  ? null
                                                  : () => setState(() {
                                                      if (visibleSelected ==
                                                          entries.length) {
                                                        _selectedIds.clear();
                                                      } else {
                                                        _selectedIds.addAll(
                                                          entries.map(
                                                            (e) => e.id,
                                                          ),
                                                        );
                                                      }
                                                    }),
                                              child: Text(
                                                visibleSelected ==
                                                        entries.length
                                                    ? 'Deselect all'
                                                    : 'Select all',
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    case ActivityRowKind.summary:
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: AppSpace.lg,
                                        ),
                                        child: _SummaryCard(
                                          totalIncoming: row.totalIncoming!,
                                          totalOutgoing: row.totalOutgoing!,
                                          count: row.activeCount!,
                                        ),
                                      );
                                    case ActivityRowKind.dayHeader:
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: AppSpace.sm,
                                        ),
                                        child: Text(
                                          _dayLabel(row.day!),
                                          style: BambooFonts.heading(
                                            13,
                                            color: BambooInk.ink500,
                                          ),
                                        ),
                                      );
                                    case ActivityRowKind.transaction:
                                      final entry = row.entry!;
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: AppSpace.sm,
                                        ),
                                        child: _TransactionTile(
                                          entry,
                                          showDate: !sort.groupsByDay,
                                          foreignPayment:
                                              foreignByTransaction[entry.id],
                                          selecting: _selecting,
                                          selected: _selectedIds.contains(
                                            entry.id,
                                          ),
                                          tagNames:
                                              (tagRepository
                                                          ?.tagsForTransaction(
                                                            entry.id,
                                                            fallback:
                                                                entry.tags,
                                                          ) ??
                                                      entry.tags)
                                                  .map((tag) => tag.name)
                                                  .toList(),
                                          onTap: () {
                                            if (_selecting) {
                                              if (!_isBulkOperating) {
                                                setState(() {
                                                  if (!_selectedIds.remove(
                                                    entry.id,
                                                  )) {
                                                    _selectedIds.add(entry.id);
                                                  }
                                                });
                                              }
                                            } else {
                                              FocusManager.instance.primaryFocus
                                                  ?.unfocus();
                                              context.push(
                                                '/activity/${entry.id}',
                                                extra: entry,
                                              );
                                            }
                                          },
                                          onLongPress:
                                              _selecting || _isBulkOperating
                                              ? null
                                              : () => setState(() {
                                                  _selecting = true;
                                                  _selectedIds.add(entry.id);
                                                }),
                                        ),
                                      );
                                    case ActivityRowKind.spacer:
                                      return const SizedBox(
                                        height: AppSpace.sm,
                                      );
                                  }
                                },
                              ),
                            ),
                          ),
                          if (_selecting)
                            _BulkActionBar(
                              selectedCount: visibleSelected,
                              isBusy: _isBulkOperating,
                              onEdit: () => _openBulkEditSheet(entries),
                              onDelete: () => _bulkDelete(entries),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSortSheet(
    BuildContext context,
    ActivitySort current,
  ) async {
    final picked = await showModalBottomSheet<ActivitySort>(
      context: context,
      backgroundColor: BambooInk.paper,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.sm,
                  AppSpace.lg,
                  AppSpace.xs,
                ),
                child: Text(
                  'Sort activity',
                  style: BambooFonts.heading(17, color: BambooInk.ink900),
                ),
              ),
              for (final option in ActivitySort.values)
                ListTile(
                  key: Key('activity-sort-${option.name}'),
                  leading: Icon(
                    _activitySortIcon(option),
                    color: option == current
                        ? BambooInk.jade
                        : BambooInk.ink500,
                  ),
                  title: Text(
                    option.label,
                    style: BambooFonts.ui(
                      14,
                      weight: FontWeight.w600,
                      color: BambooInk.ink900,
                    ),
                  ),
                  trailing: option == current
                      ? const Icon(Icons.check_rounded, color: BambooInk.jade)
                      : null,
                  selected: option == current,
                  selectedTileColor: BambooInk.paperMuted,
                  onTap: () => Navigator.of(sheetContext).pop(option),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    ref.read(_activitySortProvider.notifier).state = picked;
  }

  static String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = [
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
    return '${day.day} ${months[day.month - 1]} ${day.year}';
  }

  static String _timeLabel(BuildContext context, DateTime timestamp) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(timestamp.toLocal()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }
}

/// D1's filter state — card + category + date preset/range. A plain immutable
/// value class over a StateProvider, same shape as other multi-field
/// filter state in this app (none yet reused a common pattern, kept local).
class ActivityFilter {
  /// Cards or accounts to show. Empty means all.
  final Set<String> cardIds;

  /// Categories to show, by id (a sub-category counts under its parent) or, when
  /// a screen only knows the name, by label. Both empty means all.
  final Set<String> categoryIds;
  final Set<String> categoryLabels;

  /// Merchant names to show, matched without regard to case. Empty means all.
  final Set<String> merchants;
  final Set<String> tagIds;
  final bool untagged;
  final DateTime? from;
  final DateTime? to;

  /// Smallest and largest amount to show, in paise. Null means no limit.
  final int? amountMinPaise;
  final int? amountMaxPaise;

  /// Only payments made in another currency.
  final bool foreignOnly;

  /// Free-text search over merchant name and note, matched server-side
  /// (`GET /transactions?q=`). Client-side filtering would only ever have
  /// searched the rows already loaded, which is why this shipped as a
  /// documented gap rather than a box that quietly searched the last 50
  /// transactions.
  final String? query;
  final _ActivityTypeFilter type;
  final _ActivityDatePreset datePreset;

  ActivityFilter({
    String? cardId,
    Set<String> cardIds = const {},
    String? categoryId,
    String? categoryLabel,
    Set<String> categoryIds = const {},
    Set<String> categoryLabels = const {},
    this.merchants = const {},
    this.tagIds = const {},
    this.untagged = false,
    this.from,
    this.to,
    this.amountMinPaise,
    this.amountMaxPaise,
    this.foreignOnly = false,
    this.query,
    this.type = _ActivityTypeFilter.all,
    this.datePreset = _ActivityDatePreset.allTime,
  }) : cardIds = {?cardId, ...cardIds},
       categoryIds = {?categoryId, ...categoryIds},
       categoryLabels = {?categoryLabel, ...categoryLabels};

  /// The one card or category chosen, for the server request and for screens
  /// that only understand a single choice. Null when none or several.
  String? get cardId => cardIds.length == 1 ? cardIds.first : null;
  String? get categoryId => categoryIds.length == 1 && categoryLabels.isEmpty
      ? categoryIds.first
      : null;

  /// How many kinds of filter are on, for the badge on the Filters button.
  int get activeSectionCount =>
      (hasTypeFilter ? 1 : 0) +
      (merchants.isNotEmpty ? 1 : 0) +
      (categoryIds.isNotEmpty || categoryLabels.isNotEmpty ? 1 : 0) +
      (cardIds.isNotEmpty ? 1 : 0) +
      (tagIds.isNotEmpty || untagged ? 1 : 0) +
      (amountMinPaise != null || amountMaxPaise != null ? 1 : 0) +
      (foreignOnly ? 1 : 0);

  bool get isActive =>
      activeSectionCount > 0 ||
      from != null ||
      to != null ||
      (query != null && query!.isNotEmpty);

  /// The current month is the default scope, so it should not by itself show
  /// the Clear chip. Any other selected filter or date preset remains clearable.
  bool get hasClearableFilters =>
      activeSectionCount > 0 ||
      (query != null && query!.isNotEmpty) ||
      datePreset != _ActivityDatePreset.thisMonth;

  bool get hasTypeFilter => type != _ActivityTypeFilter.all;

  /// Whether [entry] passes the choices that are made on the phone (the rest,
  /// date and search, may also have been applied by the server).
  bool matchesLocally(TransactionEntry entry) {
    if (!type.matches(entry)) return false;
    if (cardIds.isNotEmpty && !cardIds.contains(entry.userCardId)) return false;
    if (categoryIds.isNotEmpty || categoryLabels.isNotEmpty) {
      final byId =
          categoryIds.contains(entry.categoryId) ||
          categoryIds.contains(entry.parentCategoryId);
      final byLabel = categoryLabels.any(
        (label) =>
            label.trim().toLowerCase() ==
            entry.categoryLabel.trim().toLowerCase(),
      );
      if (!byId && !byLabel) return false;
    }
    if (merchants.isNotEmpty) {
      final key = _merchantKey(entry.merchantName);
      if (key == null || !merchants.any((m) => _merchantKey(m) == key)) {
        return false;
      }
    }
    if (amountMinPaise != null && entry.amount.paise < amountMinPaise!) {
      return false;
    }
    if (amountMaxPaise != null && entry.amount.paise > amountMaxPaise!) {
      return false;
    }
    return true;
  }

  ActivityFilter copyWith({
    String? Function()? cardId,
    Set<String>? cardIds,
    String? Function()? categoryId,
    String? Function()? categoryLabel,
    Set<String>? categoryIds,
    Set<String>? categoryLabels,
    Set<String>? merchants,
    Set<String>? tagIds,
    bool? untagged,
    DateTime? Function()? from,
    DateTime? Function()? to,
    int? Function()? amountMinPaise,
    int? Function()? amountMaxPaise,
    bool? foreignOnly,
    String? Function()? query,
    _ActivityTypeFilter? type,
    _ActivityDatePreset? datePreset,
  }) {
    return ActivityFilter(
      cardIds: cardIds ?? (cardId != null ? {?cardId()} : this.cardIds),
      categoryIds:
          categoryIds ??
          (categoryId != null ? {?categoryId()} : this.categoryIds),
      categoryLabels:
          categoryLabels ??
          (categoryLabel != null ? {?categoryLabel()} : this.categoryLabels),
      merchants: merchants ?? this.merchants,
      tagIds: tagIds ?? this.tagIds,
      untagged: untagged ?? this.untagged,
      from: from != null ? from() : this.from,
      to: to != null ? to() : this.to,
      amountMinPaise: amountMinPaise != null
          ? amountMinPaise()
          : this.amountMinPaise,
      amountMaxPaise: amountMaxPaise != null
          ? amountMaxPaise()
          : this.amountMaxPaise,
      foreignOnly: foreignOnly ?? this.foreignOnly,
      query: query != null ? query() : this.query,
      type: type ?? this.type,
      datePreset: datePreset ?? this.datePreset,
    );
  }
}

/// The key two spellings of one merchant share: trimmed and lower-cased. Null
/// for a row with no merchant, which no merchant filter matches.
String? _merchantKey(String? name) {
  final key = name?.trim().toLowerCase();
  return key == null || key.isEmpty ? null : key;
}

ActivityFilter _activityMonthFilter([DateTime? now]) {
  final today = now ?? DateTime.now();
  return ActivityFilter(
    from: DateTime(today.year, today.month),
    to: DateTime(today.year, today.month, today.day),
    datePreset: _ActivityDatePreset.thisMonth,
  );
}

final _activityFilterProvider = StateProvider<ActivityFilter>(
  (ref) => _activityMonthFilter(),
);

/// How the Activity list is ordered. Starts as newest first; not part of the
/// filter, so Clear leaves it alone and it never reaches the server.
final _activitySortProvider = StateProvider<ActivitySort>(
  (ref) => ActivitySort.newest,
);

/// Whether this session already loaded the saved view. A drill-down from
/// another screen sets its own filter and clears this, so the next plain visit
/// goes back to the person's saved view instead of the drill-down.
final _activityViewRestoredProvider = StateProvider<bool>((ref) => false);

/// True while the search box has focus: the list gives way to suggestions.
final _activitySearchActiveProvider = StateProvider<bool>((ref) => false);

/// What is typed in the search box right now, before the short wait that sends
/// it to the server. Suggestions follow this.
final _activitySearchDraftProvider = StateProvider<String>((ref) => '');

const _activityViewKey = 'activity_view_v1';
const _activityRecentKey = 'activity_recent_searches_v1';

/// What is kept between visits: every filter and the sort order, but not the
/// search text. A relative period (this month) is saved as its name and worked
/// out again on load, so it never goes stale.
String _activityViewToJson(ActivityFilter f, ActivitySort sort) => jsonEncode({
  'type': f.type.name,
  'datePreset': f.datePreset.name,
  if (f.datePreset == _ActivityDatePreset.custom) ...{
    'from': f.from?.toIso8601String(),
    'to': f.to?.toIso8601String(),
  },
  'cardIds': f.cardIds.toList(),
  'categoryIds': f.categoryIds.toList(),
  'categoryLabels': f.categoryLabels.toList(),
  'merchants': f.merchants.toList(),
  'tagIds': f.tagIds.toList(),
  'untagged': f.untagged,
  'amountMin': f.amountMinPaise,
  'amountMax': f.amountMaxPaise,
  'foreignOnly': f.foreignOnly,
  'sort': sort.name,
});

({ActivityFilter filter, ActivitySort sort})? _activityViewFromJson(
  String raw,
  DateTime now,
) {
  try {
    final j = (jsonDecode(raw) as Map).cast<String, Object?>();
    Set<String> strings(String key) => {
      for (final v in (j[key] as List? ?? const [])) '$v',
    };
    final preset = _ActivityDatePreset.values.firstWhere(
      (v) => v.name == j['datePreset'],
      orElse: () => _ActivityDatePreset.thisMonth,
    );
    final range = preset.range(now);
    final custom = preset == _ActivityDatePreset.custom;
    return (
      filter: ActivityFilter(
        type: _ActivityTypeFilter.values.firstWhere(
          (v) => v.name == j['type'],
          orElse: () => _ActivityTypeFilter.all,
        ),
        datePreset: preset,
        from: custom ? DateTime.tryParse('${j['from']}') : range?.start,
        to: custom ? DateTime.tryParse('${j['to']}') : range?.end,
        cardIds: strings('cardIds'),
        categoryIds: strings('categoryIds'),
        categoryLabels: strings('categoryLabels'),
        merchants: strings('merchants'),
        tagIds: strings('tagIds'),
        untagged: j['untagged'] == true,
        amountMinPaise: (j['amountMin'] as num?)?.toInt(),
        amountMaxPaise: (j['amountMax'] as num?)?.toInt(),
        foreignOnly: j['foreignOnly'] == true,
      ),
      sort: ActivitySort.values.firstWhere(
        (v) => v.name == j['sort'],
        orElse: () => ActivitySort.newest,
      ),
    );
  } catch (_) {
    return null;
  }
}

Future<void> _saveActivityView(ActivityFilter f, ActivitySort sort) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activityViewKey, _activityViewToJson(f, sort));
  } catch (_) {
    // Saving the view is a convenience; the screen works without it.
  }
}

Future<({ActivityFilter filter, ActivitySort sort})?>
_loadActivityView() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_activityViewKey);
    return raw == null ? null : _activityViewFromJson(raw, DateTime.now());
  } catch (_) {
    return null;
  }
}

Future<List<String>> _loadRecentSearches() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_activityRecentKey) ?? const [];
  } catch (_) {
    return const [];
  }
}

Future<void> _rememberSearch(String text) async {
  final clean = text.trim();
  if (clean.length < 2) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    final recent = [
      clean,
      ...(prefs.getStringList(_activityRecentKey) ?? const []).where(
        (r) => r.toLowerCase() != clean.toLowerCase(),
      ),
    ].take(8).toList();
    await prefs.setStringList(_activityRecentKey, recent);
  } catch (_) {
    // Recent searches are a convenience.
  }
}

IconData _activitySortIcon(ActivitySort sort) => switch (sort) {
  ActivitySort.newest => Icons.arrow_downward_rounded,
  ActivitySort.oldest => Icons.arrow_upward_rounded,
  ActivitySort.highestAmount => Icons.trending_down_rounded,
  ActivitySort.lowestAmount => Icons.trending_up_rounded,
  ActivitySort.merchantAz => Icons.sort_by_alpha_rounded,
};

final activityTransactionsProvider = FutureProvider<List<TransactionEntry>>((
  ref,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  final filter = ref.watch(_activityFilterProvider);
  final tags = ref.watch(transactionTagsProvider);

  // Synchronously listen once to canonical provider invalidation
  ref.listen(transactionsProvider, (previous, next) {
    if (previous?.hasValue == true && next.hasValue) {
      ref.invalidateSelf();
    }
  });

  // Keep the unfiltered Activity surface on the same provider as every
  // other transaction consumer. SMS reconciliation, quick-add, imports and
  // resume refreshes invalidate [transactionsProvider]; using a second
  // independently cached request here used to leave Activity showing an old
  // empty result until the app was restarted or the user tapped Retry.
  // Type-only filters can still be applied locally without a second fetch.
  final hasServerFilter =
      filter.from != null ||
      filter.to != null ||
      filter.cardId != null ||
      filter.categoryId != null ||
      (filter.query != null && filter.query!.trim().isNotEmpty);
  final entries = hasServerFilter
      ? await loadTransactionsWithOfflineCache(
          ref,
          repo: repo,
          cacheKey: 'transactions:activity',
          from: filter.from,
          to: filter.to,
          cardId: filter.cardId,
          categoryId: filter.categoryId,
          query: filter.query,
        )
      : await ref.watch(transactionsProvider.future);
  final selection = SpendingSelection(
    tagIds: filter.tagIds,
    untagged: filter.untagged,
  );
  final unique = {for (final entry in entries) entry.id: entry};
  return unique.values
      .where(
        (entry) =>
            filter.matchesLocally(entry) &&
            selection.matches(
              entry,
              tags:
                  (tags?.tagsForTransaction(entry.id, fallback: entry.tags) ??
                          entry.tags)
                      .map((tag) => tag.id),
            ),
      )
      .toList();
});

enum _ActivityTypeFilter {
  all,
  spending,
  moneyIn,
  moneyOut,
  transfers,
  investments,
}

enum _ActivityDatePreset {
  allTime,
  today,
  thisWeek,
  thisMonth,
  lastMonth,
  last30Days,
  last90Days,
  thisYear,
  custom,
}

extension on _ActivityDatePreset {
  String get label => switch (this) {
    _ActivityDatePreset.allTime => 'All time',
    _ActivityDatePreset.today => 'Today',
    _ActivityDatePreset.thisWeek => 'This week',
    _ActivityDatePreset.thisMonth => 'This month',
    _ActivityDatePreset.lastMonth => 'Last month',
    _ActivityDatePreset.last30Days => 'Last 30 days',
    _ActivityDatePreset.last90Days => 'Last 90 days',
    _ActivityDatePreset.thisYear => 'This year',
    _ActivityDatePreset.custom => 'Custom range',
  };

  DateTimeRange? range(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return switch (this) {
      _ActivityDatePreset.allTime || _ActivityDatePreset.custom => null,
      _ActivityDatePreset.today => DateTimeRange(start: today, end: today),
      _ActivityDatePreset.thisWeek => DateTimeRange(
        start: today.subtract(Duration(days: today.weekday - 1)),
        end: today,
      ),
      _ActivityDatePreset.thisMonth => DateTimeRange(
        start: DateTime(today.year, today.month),
        end: today,
      ),
      _ActivityDatePreset.lastMonth => DateTimeRange(
        start: DateTime(today.year, today.month - 1),
        end: DateTime(today.year, today.month, 0),
      ),
      _ActivityDatePreset.last30Days => DateTimeRange(
        start: today.subtract(const Duration(days: 29)),
        end: today,
      ),
      _ActivityDatePreset.last90Days => DateTimeRange(
        start: today.subtract(const Duration(days: 89)),
        end: today,
      ),
      _ActivityDatePreset.thisYear => DateTimeRange(
        start: DateTime(today.year),
        end: today,
      ),
    };
  }
}

extension on _ActivityTypeFilter {
  String get label => switch (this) {
    _ActivityTypeFilter.all => 'All activities',
    _ActivityTypeFilter.spending => 'Spending',
    _ActivityTypeFilter.moneyIn => 'Money in',
    _ActivityTypeFilter.moneyOut => 'Money out',
    _ActivityTypeFilter.transfers => 'Transfers',
    _ActivityTypeFilter.investments => 'Investments',
  };

  bool matches(TransactionEntry entry) => switch (this) {
    _ActivityTypeFilter.all => true,
    _ActivityTypeFilter.spending => entry.countsAsSpend,
    _ActivityTypeFilter.moneyIn =>
      entry.entryKind == TxnEntryKind.income ||
          entry.entryKind == TxnEntryKind.investmentReturn,
    _ActivityTypeFilter.moneyOut =>
      entry.entryKind == TxnEntryKind.spend ||
          entry.entryKind == TxnEntryKind.investment,
    _ActivityTypeFilter.transfers => entry.entryKind == TxnEntryKind.transfer,
    _ActivityTypeFilter.investments =>
      entry.entryKind == TxnEntryKind.investment ||
          entry.entryKind == TxnEntryKind.investmentReturn ||
          entry.categoryId == 'investments' ||
          (entry.categoryName?.toLowerCase() == 'investments'),
  };
}

IconData _typeIcon(_ActivityTypeFilter type) => switch (type) {
  _ActivityTypeFilter.all => Icons.receipt_long_outlined,
  _ActivityTypeFilter.spending => Icons.shopping_bag_outlined,
  _ActivityTypeFilter.moneyIn => Icons.arrow_downward_rounded,
  _ActivityTypeFilter.moneyOut => Icons.arrow_upward_rounded,
  _ActivityTypeFilter.transfers => Icons.swap_horiz_rounded,
  _ActivityTypeFilter.investments => Icons.trending_up_rounded,
};

/// D1's search box. Debounced, because every keystroke would otherwise be
/// a round trip — and the ILIKE behind it scans, so a burst of them on a
/// long history is exactly the query you don't want to fire six times.
/// One tap group for the search box and the suggestions under it, so a tap on a
/// suggestion does not count as "outside" and close the keyboard first.
final Object _searchTapGroup = Object();

class _SearchField extends ConsumerStatefulWidget {
  const _SearchField();

  @override
  ConsumerState<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<_SearchField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(_activityFilterProvider).query ?? '';
    _focus.addListener(_onFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(_activitySearchDraftProvider.notifier).state = _controller.text;
      ref.read(_activitySearchActiveProvider.notifier).state = _focus.hasFocus;
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    ref.read(_activitySearchActiveProvider.notifier).state = _focus.hasFocus;
    if (!_focus.hasFocus) unawaited(_rememberSearch(_controller.text));
  }

  void _setQuery(String value) {
    final trimmed = value.trim();
    ref
        .read(_activityFilterProvider.notifier)
        .update(
          (f) => f.copyWith(query: () => trimmed.isEmpty ? null : trimmed),
        );
  }

  void _onChanged(String value) {
    ref.read(_activitySearchDraftProvider.notifier).state = value;
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _setQuery(value),
    );
    // Rebuild for the clear button's visibility, which shouldn't wait on
    // the debounce.
    setState(() {});
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    ref.read(_activitySearchDraftProvider.notifier).state = '';
    _setQuery('');
    setState(() {});
  }

  void _finish() {
    _debounce?.cancel();
    _setQuery(_controller.text);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    // The query can be set from elsewhere (a suggestion, Clear all, a voice
    // answer); keep the box in step with it.
    ref.listen<String?>(_activityFilterProvider.select((f) => f.query), (
      _,
      next,
    ) {
      final incoming = next ?? '';
      if (_controller.text.trim() != incoming) {
        _controller.text = incoming;
        ref.read(_activitySearchDraftProvider.notifier).state = incoming;
        setState(() {});
      }
    });
    ref.listen<String>(_activitySearchDraftProvider, (_, next) {
      if (_controller.text != next) {
        // Changed from outside (a suggestion was chosen): a search typed a
        // moment ago must not land afterwards and undo it.
        _debounce?.cancel();
        _controller.text = next;
        setState(() {});
      }
    });
    final active = ref.watch(_activitySearchActiveProvider);
    final hasMerchants = ref.watch(
      _activityFilterProvider.select((f) => f.merchants.isNotEmpty),
    );

    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('activity-search-field'),
            controller: _controller,
            focusNode: _focus,
            groupId: _searchTapGroup,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            // Tapping anywhere outside the field and its suggestions (or
            // pressing Search) closes the keyboard.
            onTapOutside: (_) => _focus.unfocus(),
            onSubmitted: (_) => _finish(),
            style: BambooFonts.ui(14.5, color: BambooInk.ink900),
            decoration: InputDecoration(
              hintText: 'Search merchants or notes',
              prefixIcon: const Icon(
                Icons.search_rounded,
                size: 20,
                color: BambooInk.ink500,
              ),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: BambooInk.ink500,
                      ),
                      onPressed: _clear,
                    ),
              isDense: true,
            ),
          ),
        ),
        if (active)
          TextButton(
            key: const Key('activity-search-done'),
            onPressed: _finish,
            style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
            child: Text(
              _controller.text.trim().isEmpty && !hasMerchants
                  ? 'Cancel'
                  : 'Done',
            ),
          ),
      ],
    );
  }
}

/// Every merchant on the phone with how many transactions it has, most used
/// first. One pass per list snapshot.
final _merchantStatsCache = Expando<List<({String name, int count})>>(
  'activityMerchantStats',
);

List<({String name, int count})> _merchantStats(List<TransactionEntry> all) {
  final cached = _merchantStatsCache[all];
  if (cached != null) return cached;
  final counts = <String, ({String name, int count})>{};
  for (final entry in all) {
    final key = _merchantKey(entry.merchantName);
    if (key == null) continue;
    final seen = counts[key];
    counts[key] = (
      name: seen?.name ?? entry.merchantName!.trim(),
      count: (seen?.count ?? 0) + 1,
    );
  }
  final result = counts.values.toList()
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0
          ? byCount
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  return _merchantStatsCache[all] = List.unmodifiable(result);
}

final _recentSearchesProvider = FutureProvider.autoDispose<List<String>>(
  (ref) => _loadRecentSearches(),
);

/// What shows while the search box has focus: merchants that match what is
/// typed (tap to add several), recent searches, and a way to search notes.
class _SearchSuggestions extends ConsumerWidget {
  const _SearchSuggestions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(_activitySearchDraftProvider).trim();
    final filter = ref.watch(_activityFilterProvider);
    final all = ref.watch(transactionsProvider).valueOrNull ?? const [];
    final recent = ref.watch(_recentSearchesProvider).valueOrNull ?? const [];
    final stats = _merchantStats(all);
    final needle = draft.toLowerCase();
    final selected = {for (final m in filter.merchants) _merchantKey(m)};
    final matches = needle.isEmpty
        ? stats.take(6).toList()
        : (stats.where((m) => m.name.toLowerCase().contains(needle)).toList()
                ..sort((a, b) {
                  final aStart = a.name.toLowerCase().startsWith(needle);
                  final bStart = b.name.toLowerCase().startsWith(needle);
                  if (aStart != bStart) return aStart ? -1 : 1;
                  return b.count.compareTo(a.count);
                }))
              .take(8)
              .toList();

    void toggle(String name) {
      final key = _merchantKey(name);
      ref.read(_activityFilterProvider.notifier).update((f) {
        final next = {...f.merchants};
        final had = next.any((m) => _merchantKey(m) == key);
        next.removeWhere((m) => _merchantKey(m) == key);
        if (!had) next.add(name);
        // The words typed found this merchant; the list now follows the
        // merchants chosen, not the typed text as well.
        return f.copyWith(merchants: next, query: () => null);
      });
      ref.read(_activitySearchDraftProvider.notifier).state = '';
    }

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        2,
      ),
      child: Text(
        text,
        style: BambooFonts.ui(
          12,
          weight: FontWeight.w700,
          color: BambooInk.ink500,
        ),
      ),
    );

    // Tapping a suggestion must not move focus off the search box: that would
    // close the list after the first merchant, and several are the point.
    return TapRegion(
      groupId: _searchTapGroup,
      child: ExcludeFocus(
        child: ListView(
          key: const Key('activity-search-suggestions'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
          children: [
            header(needle.isEmpty ? 'Your merchants' : 'Merchants'),
            if (matches.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.lg,
                  vertical: AppSpace.sm,
                ),
                child: Text(
                  'No merchant matches “$draft”.',
                  style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                ),
              ),
            for (final m in matches)
              ListTile(
                key: Key('activity-suggest-${m.name}'),
                dense: true,
                title: Text(
                  m.name,
                  style: BambooFonts.ui(
                    14,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                ),
                subtitle: Text(
                  '${m.count} ${m.count == 1 ? 'transaction' : 'transactions'}',
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                ),
                trailing: selected.contains(_merchantKey(m.name))
                    ? const Icon(
                        Icons.check_circle_rounded,
                        color: BambooInk.jade,
                      )
                    : const Icon(
                        Icons.add_circle_outline_rounded,
                        color: BambooInk.jade,
                      ),
                onTap: () => toggle(m.name),
              ),
            if (draft.isNotEmpty)
              ListTile(
                key: const Key('activity-suggest-notes'),
                dense: true,
                leading: const Icon(
                  Icons.search_rounded,
                  color: BambooInk.ink500,
                ),
                title: Text(
                  'Search notes for “$draft”',
                  style: BambooFonts.ui(14, color: BambooInk.ink900),
                ),
                onTap: () {
                  ref
                      .read(_activityFilterProvider.notifier)
                      .update((f) => f.copyWith(query: () => draft));
                  unawaited(_rememberSearch(draft));
                  FocusManager.instance.primaryFocus?.unfocus();
                },
              ),
            if (needle.isEmpty && recent.isNotEmpty) ...[
              header('Recent searches'),
              for (final r in recent)
                ListTile(
                  key: Key('activity-recent-$r'),
                  dense: true,
                  leading: const Icon(
                    Icons.history_rounded,
                    color: BambooInk.ink500,
                  ),
                  title: Text(
                    r,
                    style: BambooFonts.ui(14, color: BambooInk.ink900),
                  ),
                  onTap: () {
                    ref.read(_activitySearchDraftProvider.notifier).state = r;
                    ref
                        .read(_activityFilterProvider.notifier)
                        .update((f) => f.copyWith(query: () => r));
                    FocusManager.instance.primaryFocus?.unfocus();
                  },
                ),
            ],
            const SizedBox(height: AppSpace.xl),
          ],
        ),
      ),
    );
  }
}

bool _hasChips(ActivityFilter f) => f.activeSectionCount > 0;

String _sortShortLabel(ActivitySort sort) => switch (sort) {
  ActivitySort.newest => 'Newest',
  ActivitySort.oldest => 'Oldest',
  ActivitySort.highestAmount => 'Highest',
  ActivitySort.lowestAmount => 'Lowest',
  ActivitySort.merchantAz => 'A to Z',
};

/// The three controls under the search box: period, Filters and Sort. Equal
/// width, so the row looks the same whatever is chosen.
class _ActivityControlRow extends StatelessWidget {
  final ActivityFilter filter;
  final ActivitySort sort;
  final VoidCallback onOpenPeriod;
  final VoidCallback onOpenFilters;
  final VoidCallback onOpenSort;

  const _ActivityControlRow({
    required this.filter,
    required this.sort,
    required this.onOpenPeriod,
    required this.onOpenFilters,
    required this.onOpenSort,
  });

  @override
  Widget build(BuildContext context) {
    final count = filter.activeSectionCount;
    return Row(
      children: [
        Expanded(
          child: _ControlPill(
            key: const Key('activity-period-button'),
            icon: Icons.calendar_month_rounded,
            label: _dateFilterLabel(filter),
            trailing: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
            onTap: onOpenPeriod,
          ),
        ),
        const SizedBox(width: AppSpace.xs),
        Expanded(
          child: _ControlPill(
            key: const Key('activity-filters-button'),
            icon: Icons.tune_rounded,
            label: 'Filters',
            highlighted: count > 0,
            trailing: count == 0
                ? null
                : Container(
                    key: const Key('activity-filters-count'),
                    constraints: const BoxConstraints(minWidth: 18),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: BambooInk.jade,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      '$count',
                      textAlign: TextAlign.center,
                      style: BambooFonts.ui(
                        11,
                        weight: FontWeight.w700,
                        color: BambooInk.onSlate,
                      ),
                    ),
                  ),
            onTap: onOpenFilters,
          ),
        ),
        const SizedBox(width: AppSpace.xs),
        Expanded(
          child: _ControlPill(
            key: const Key('activity-sort-button'),
            icon: Icons.swap_vert_rounded,
            label: _sortShortLabel(sort),
            highlighted: sort != ActivitySort.newest,
            trailing: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
            onTap: onOpenSort,
          ),
        ),
      ],
    );
  }
}

class _ControlPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final bool highlighted;
  final VoidCallback onTap;

  const _ControlPill({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = highlighted ? BambooInk.jade : BambooInk.ink900;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: highlighted ? BambooInk.jade : BambooInk.hairlineOnPaper,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: BambooFonts.ui(
                  13,
                  weight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 3), trailing!],
          ],
        ),
      ),
    );
  }
}

/// One chip per choice made in Filters, each with its own ✕, and one Clear all.
class _ActiveChipsRow extends ConsumerWidget {
  final ActivityFilter filter;
  const _ActiveChipsRow({required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
    void update(ActivityFilter Function(ActivityFilter) change) =>
        ref.read(_activityFilterProvider.notifier).update(change);

    String cardName(String id) {
      final card = cards.cast<UserCard?>().firstWhere(
        (c) => c?.id == id,
        orElse: () => null,
      );
      if (card == null) return 'Card';
      return card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName;
    }

    String categoryName(String id) {
      final category = categories.cast<SpendCategory?>().firstWhere(
        (c) => c?.id == id,
        orElse: () => null,
      );
      return category?.name ?? 'Category';
    }

    final chips = <Widget>[
      if (filter.type != _ActivityTypeFilter.all)
        _FilterValueChip(
          label: filter.type.label,
          onRemove: () =>
              update((f) => f.copyWith(type: _ActivityTypeFilter.all)),
        ),
      for (final merchant in filter.merchants)
        _FilterValueChip(
          label: merchant,
          onRemove: () => update(
            (f) => f.copyWith(
              merchants: {...f.merchants}
                ..removeWhere((m) => _merchantKey(m) == _merchantKey(merchant)),
            ),
          ),
        ),
      for (final id in filter.categoryIds)
        _FilterValueChip(
          label: categoryName(id),
          onRemove: () => update(
            (f) => f.copyWith(categoryIds: {...f.categoryIds}..remove(id)),
          ),
        ),
      for (final label in filter.categoryLabels)
        _FilterValueChip(
          label: label,
          onRemove: () => update(
            (f) => f.copyWith(
              categoryLabels: {...f.categoryLabels}..remove(label),
            ),
          ),
        ),
      for (final id in filter.cardIds)
        _FilterValueChip(
          label: cardName(id),
          onRemove: () =>
              update((f) => f.copyWith(cardIds: {...f.cardIds}..remove(id))),
        ),
      if (filter.tagIds.isNotEmpty || filter.untagged)
        _FilterValueChip(
          label: filter.untagged
              ? 'Untagged'
              : '${filter.tagIds.length} ${filter.tagIds.length == 1 ? 'tag' : 'tags'}',
          onRemove: () =>
              update((f) => f.copyWith(tagIds: const {}, untagged: false)),
        ),
      if (filter.amountMinPaise != null || filter.amountMaxPaise != null)
        _FilterValueChip(
          label: _amountRangeLabel(
            filter.amountMinPaise,
            filter.amountMaxPaise,
          ),
          onRemove: () => update(
            (f) => f.copyWith(
              amountMinPaise: () => null,
              amountMaxPaise: () => null,
            ),
          ),
        ),
      if (filter.foreignOnly)
        _FilterValueChip(
          label: 'Foreign currency',
          onRemove: () => update((f) => f.copyWith(foreignOnly: false)),
        ),
    ];

    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final chip in chips)
            Padding(padding: const EdgeInsets.only(right: 6), child: chip),
          TextButton(
            key: const Key('activity-clear-all'),
            onPressed: () {
              ref.read(_activityFilterProvider.notifier).state =
                  _activityMonthFilter();
            },
            style: TextButton.styleFrom(
              foregroundColor: BambooInk.jade,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: BambooFonts.ui(13, weight: FontWeight.w700),
            ),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }
}

String _amountRangeLabel(int? minPaise, int? maxPaise) {
  String rupees(int paise) => Money.fromPaise(paise).format(hidePaise: true);
  if (minPaise != null && maxPaise != null) {
    return '${rupees(minPaise)} to ${rupees(maxPaise)}';
  }
  return minPaise != null
      ? 'From ${rupees(minPaise)}'
      : 'Up to ${rupees(maxPaise!)}';
}

class _FilterValueChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  const _FilterValueChip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BambooInk.wash,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onRemove,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(
                    12.5,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Semantics(
                label: 'Remove $label',
                child: const Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: BambooInk.ink700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line that says foreign payments are waiting for their INR amount, where
/// the old card and three rows pushed the list off the screen.
class _ForeignBanner extends StatelessWidget {
  final List<ForeignPayment> payments;
  final VoidCallback onTap;
  const _ForeignBanner({required this.payments, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final estimated = payments
        .where((p) => p.direction != 'refund')
        .fold<int>(0, (sum, p) => sum + (p.estimatedInr?.paise ?? 0));
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        key: const Key('activity-foreign-banner'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: BambooInk.warningBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BambooInk.warningBorder),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.currency_exchange,
              size: 17,
              color: BambooInk.ink900,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                estimated > 0
                    ? '${payments.length} foreign ${payments.length == 1 ? 'payment' : 'payments'} awaiting INR · about ${Money.fromPaise(estimated).format(hidePaise: true)}'
                    : '${payments.length} foreign ${payments.length == 1 ? 'payment' : 'payments'} awaiting INR',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w600,
                  color: BambooInk.ink900,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: BambooInk.ink500,
            ),
          ],
        ),
      ),
    );
  }
}

class _PickOption {
  final String id;
  final String label;
  final int? count;
  const _PickOption(this.id, this.label, [this.count]);
}

/// A long list in one place: search it, tick any number, press Done.
Future<Set<String>?> _pickMany(
  BuildContext context, {
  required String title,
  required String searchHint,
  required List<_PickOption> options,
  required Set<String> selected,
}) => showModalBottomSheet<Set<String>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  backgroundColor: BambooInk.paper,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  builder: (_) => _MultiSelectSheet(
    title: title,
    searchHint: searchHint,
    options: options,
    selected: selected,
  ),
);

class _MultiSelectSheet extends StatefulWidget {
  final String title;
  final String searchHint;
  final List<_PickOption> options;
  final Set<String> selected;
  const _MultiSelectSheet({
    required this.title,
    required this.searchHint,
    required this.options,
    required this.selected,
  });

  @override
  State<_MultiSelectSheet> createState() => _MultiSelectSheetState();
}

class _MultiSelectSheetState extends State<_MultiSelectSheet> {
  late final Set<String> _picked = {...widget.selected};
  String _needle = '';

  @override
  Widget build(BuildContext context) {
    final needle = _needle.trim().toLowerCase();
    final shown = [
      for (final o in widget.options)
        if (needle.isEmpty || o.label.toLowerCase().contains(needle)) o,
    ];
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                0,
                AppSpace.lg,
                AppSpace.xs,
              ),
              child: Row(
                children: [
                  Text(
                    widget.title,
                    style: BambooFonts.heading(20, color: BambooInk.ink900),
                  ),
                  const Spacer(),
                  TextButton(
                    key: const Key('activity-pick-clear'),
                    onPressed: _picked.isEmpty
                        ? null
                        : () => setState(_picked.clear),
                    style: TextButton.styleFrom(
                      foregroundColor: BambooInk.jade,
                    ),
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.lg,
                vertical: AppSpace.xs,
              ),
              child: TextField(
                key: const Key('activity-pick-search'),
                onChanged: (v) => setState(() => _needle = v),
                decoration: InputDecoration(
                  hintText: widget.searchHint,
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: BambooInk.ink500,
                  ),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        'Nothing matches.',
                        style: BambooFonts.ui(14, color: BambooInk.ink500),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final o in shown)
                          CheckboxListTile(
                            key: Key('activity-pick-${o.id}'),
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            activeColor: BambooInk.jade,
                            value: _picked.contains(o.id),
                            onChanged: (v) => setState(() {
                              v == true
                                  ? _picked.add(o.id)
                                  : _picked.remove(o.id);
                            }),
                            title: Text(
                              o.label,
                              style: BambooFonts.ui(
                                14,
                                color: BambooInk.ink900,
                              ),
                            ),
                            secondary: o.count == null
                                ? null
                                : Text(
                                    '${o.count}',
                                    style: BambooFonts.ui(
                                      12.5,
                                      color: BambooInk.ink500,
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
                AppSpace.sm,
              ),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('activity-pick-done'),
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(_picked),
                  child: Text(
                    _picked.isEmpty
                        ? 'Done'
                        : 'Done, ${_picked.length} selected',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one place for every choice. Short lists are chips; a long list is a row
/// that opens a searchable multi-select. Nothing changes until Show.
class _ActivityFilterSheet extends StatefulWidget {
  final ActivityFilter initial;

  /// Every transaction on the phone, so the options and the count do not shrink
  /// to what the current filters already show.
  final List<TransactionEntry> entries;
  final Set<String> foreignTransactionIds;
  final List<UserCard> cards;
  final List<TransactionTag> tags;
  final List<SpendCategory> categories;
  final Totals Function(Iterable<TransactionEntry>)? totalForEntries;

  const _ActivityFilterSheet({
    required this.initial,
    required this.entries,
    required this.cards,
    required this.tags,
    required this.categories,
    this.foreignTransactionIds = const {},
    this.totalForEntries,
  });

  @override
  State<_ActivityFilterSheet> createState() => _ActivityFilterSheetState();
}

class _ActivityFilterSheetState extends State<_ActivityFilterSheet> {
  /// Up to this many options show as chips; more become a dropdown row.
  static const _chipLimit = 6;

  late _ActivityTypeFilter _type = widget.initial.type;
  late Set<String> _merchants = {...widget.initial.merchants};
  late Set<String> _categoryIds = {...widget.initial.categoryIds};
  late Set<String> _categoryLabels = {...widget.initial.categoryLabels};
  late Set<String> _cardIds = {...widget.initial.cardIds};
  late Set<String> _tagIds = {...widget.initial.tagIds};
  late bool _untagged = widget.initial.untagged;
  late bool _foreign = widget.initial.foreignOnly;
  late final TextEditingController _min = TextEditingController(
    text: _rupeesText(widget.initial.amountMinPaise),
  );
  late final TextEditingController _max = TextEditingController(
    text: _rupeesText(widget.initial.amountMaxPaise),
  );

  @override
  void initState() {
    super.initState();
    // A category only known by name (from a drill-down) becomes the same
    // category in the list, so it can be unticked there.
    for (final label in {..._categoryLabels}) {
      final match = widget.categories.cast<SpendCategory?>().firstWhere(
        (c) =>
            c != null &&
            c.name.trim().toLowerCase() == label.trim().toLowerCase(),
        orElse: () => null,
      );
      if (match != null) {
        _categoryIds.add(match.id);
        _categoryLabels.remove(label);
      }
    }
  }

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  static String _rupeesText(int? paise) => paise == null
      ? ''
      : (paise % 100 == 0
            ? '${paise ~/ 100}'
            : (paise / 100).toStringAsFixed(2));

  static int? _parsePaise(String text) {
    final value = double.tryParse(text.replaceAll(',', '').trim());
    return value == null || value < 0 ? null : (value * 100).round();
  }

  ActivityFilter get _draft => widget.initial.copyWith(
    type: _type,
    merchants: _merchants,
    categoryIds: _categoryIds,
    categoryLabels: _categoryLabels,
    cardIds: _cardIds,
    tagIds: _tagIds,
    untagged: _untagged,
    amountMinPaise: () => _parsePaise(_min.text),
    amountMaxPaise: () => _parsePaise(_max.text),
    foreignOnly: _foreign,
  );

  List<TransactionEntry> get _matchingEntries {
    final draft = _draft;
    final from = draft.from;
    final to = draft.to;
    final query = draft.query?.trim().toLowerCase();
    return widget.entries.where((entry) {
      if (!draft.matchesLocally(entry)) return false;
      if (_foreign && !widget.foreignTransactionIds.contains(entry.id)) {
        return false;
      }
      final entryTagIds = entry.tags.map((t) => t.id).toSet();
      if (_untagged && entryTagIds.isNotEmpty) return false;
      if (_tagIds.isNotEmpty && !entryTagIds.any(_tagIds.contains)) {
        return false;
      }
      if (from != null && entry.occurredAt.isBefore(from)) return false;
      if (to != null &&
          !entry.occurredAt.isBefore(DateTime(to.year, to.month, to.day + 1))) {
        return false;
      }
      if (query != null && query.isNotEmpty) {
        final text = '${entry.merchantName ?? ''} ${entry.note ?? ''}'
            .toLowerCase();
        if (!text.contains(query)) return false;
      }
      return true;
    }).toList();
  }

  void _reset() {
    setState(() {
      _type = _ActivityTypeFilter.all;
      _merchants = {};
      _categoryIds = {};
      _categoryLabels = {};
      _cardIds = {};
      _tagIds = {};
      _untagged = false;
      _foreign = false;
      _min.clear();
      _max.clear();
    });
  }

  String _names(Iterable<String> names, String empty) {
    final list = names.toList();
    if (list.isEmpty) return empty;
    if (list.length <= 2) return list.join(', ');
    return '${list.take(2).join(', ')} +${list.length - 2}';
  }

  String _cardName(UserCard c) =>
      c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName;

  Future<void> _pickMerchants() async {
    final options = [
      for (final m in _merchantStats(widget.entries))
        _PickOption(m.name, m.name, m.count),
    ];
    // A merchant already chosen that is no longer in the list still shows.
    for (final m in _merchants) {
      if (!options.any((o) => _merchantKey(o.id) == _merchantKey(m))) {
        options.insert(0, _PickOption(m, m));
      }
    }
    final picked = await _pickMany(
      context,
      title: 'Merchants',
      searchHint: 'Search merchants',
      options: options,
      selected: _merchants,
    );
    if (picked != null && mounted) setState(() => _merchants = picked);
  }

  Future<void> _pickCategories() async {
    final counts = <String, int>{};
    for (final e in widget.entries) {
      final id = e.parentCategoryId ?? e.categoryId;
      if (id != null) counts.update(id, (n) => n + 1, ifAbsent: () => 1);
    }
    final picked = await _pickMany(
      context,
      title: 'Category',
      searchHint: 'Search categories',
      options: [
        for (final c in widget.categories.where((c) => !c.isSubcategory))
          _PickOption(c.id, c.name, counts[c.id]),
      ],
      selected: _categoryIds,
    );
    if (picked != null && mounted) setState(() => _categoryIds = picked);
  }

  Future<void> _pickCards() async {
    final picked = await _pickMany(
      context,
      title: 'Account or card',
      searchHint: 'Search cards and accounts',
      options: [for (final c in widget.cards) _PickOption(c.id, _cardName(c))],
      selected: _cardIds,
    );
    if (picked != null && mounted) setState(() => _cardIds = picked);
  }

  Future<void> _pickTags() async {
    final picked = await _pickMany(
      context,
      title: 'Tags',
      searchHint: 'Search tags',
      options: [for (final t in widget.tags) _PickOption(t.id, t.name)],
      selected: _tagIds,
    );
    if (picked != null && mounted) {
      setState(() {
        _tagIds = picked;
        if (picked.isNotEmpty) _untagged = false;
      });
    }
  }

  Widget _chips<T>({
    required Iterable<(String, String)> options,
    required Set<String> selected,
    required void Function(String id, bool on) onChanged,
  }) => Wrap(
    spacing: AppSpace.sm,
    runSpacing: AppSpace.sm,
    children: [
      for (final (id, label) in options)
        _typePill(
          label: label,
          selected: selected.contains(id),
          onTap: () => setState(() => onChanged(id, !selected.contains(id))),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final categoryNames = [
      for (final id in _categoryIds)
        widget.categories
                .cast<SpendCategory?>()
                .firstWhere((c) => c?.id == id, orElse: () => null)
                ?.name ??
            'Category',
      ..._categoryLabels,
    ];
    final cardNames = [
      for (final c in widget.cards)
        if (_cardIds.contains(c.id)) _cardName(c),
    ];
    final tagNames = [
      for (final t in widget.tags)
        if (_tagIds.contains(t.id)) t.name,
    ];
    final matching = _matchingEntries.length;

    Widget dropdown({
      required Key key,
      required String value,
      required bool filled,
      required VoidCallback onTap,
    }) => _selectionField(
      key: key,
      child: Text(
        value,
        overflow: TextOverflow.ellipsis,
        style: BambooFonts.ui(
          14,
          weight: filled ? FontWeight.w600 : FontWeight.w400,
          color: filled ? BambooInk.ink900 : BambooInk.ink500,
        ),
      ),
      trailing: const Icon(Icons.keyboard_arrow_down_rounded),
      onTap: onTap,
    );

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                0,
                AppSpace.lg,
                AppSpace.md,
              ),
              child: Row(
                children: [
                  Text(
                    'Filters',
                    style: BambooFonts.heading(22, color: BambooInk.ink900),
                  ),
                  const Spacer(),
                  TextButton(
                    key: const Key('activity-filters-reset'),
                    onPressed: _reset,
                    style: TextButton.styleFrom(
                      foregroundColor: BambooInk.jade,
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                    ),
                    child: const Text('Reset'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  0,
                  AppSpace.lg,
                  AppSpace.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _FilterLabel('Transaction type'),
                    const SizedBox(height: AppSpace.xs),
                    Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.sm,
                      children: [
                        for (final type in _ActivityTypeFilter.values)
                          _typePill(
                            label: type.label,
                            icon: _typeIcon(type),
                            selected: _type == type,
                            onTap: () => setState(() => _type = type),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.lg),

                    const _FilterLabel('Merchants'),
                    const SizedBox(height: AppSpace.xs),
                    dropdown(
                      key: const Key('activity-filter-merchants'),
                      value: _names(_merchants, 'Any merchant'),
                      filled: _merchants.isNotEmpty,
                      onTap: _pickMerchants,
                    ),
                    const SizedBox(height: AppSpace.lg),

                    const _FilterLabel('Category'),
                    const SizedBox(height: AppSpace.xs),
                    dropdown(
                      key: const Key('activity-filter-categories'),
                      value: _names(categoryNames, 'All categories'),
                      filled: categoryNames.isNotEmpty,
                      onTap: _pickCategories,
                    ),
                    const SizedBox(height: AppSpace.lg),

                    const _FilterLabel('Account or card'),
                    const SizedBox(height: AppSpace.xs),
                    if (widget.cards.length <= _chipLimit)
                      _chips<String>(
                        options: [
                          for (final c in widget.cards) (c.id, _cardName(c)),
                        ],
                        selected: _cardIds,
                        onChanged: (id, on) =>
                            on ? _cardIds.add(id) : _cardIds.remove(id),
                      )
                    else
                      dropdown(
                        key: const Key('activity-filter-cards'),
                        value: _names(cardNames, 'All cards and accounts'),
                        filled: cardNames.isNotEmpty,
                        onTap: _pickCards,
                      ),
                    const SizedBox(height: AppSpace.lg),

                    const _FilterLabel('Tags'),
                    const SizedBox(height: AppSpace.xs),
                    Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.sm,
                      children: [
                        _typePill(
                          label: 'Untagged',
                          selected: _untagged,
                          onTap: () => setState(() {
                            _untagged = !_untagged;
                            if (_untagged) _tagIds.clear();
                          }),
                        ),
                        if (widget.tags.length <= _chipLimit)
                          for (final tag in widget.tags)
                            _typePill(
                              label: tag.name,
                              selected: _tagIds.contains(tag.id),
                              onTap: () => setState(() {
                                _untagged = false;
                                _tagIds.contains(tag.id)
                                    ? _tagIds.remove(tag.id)
                                    : _tagIds.add(tag.id);
                              }),
                            ),
                      ],
                    ),
                    if (widget.tags.length > _chipLimit) ...[
                      const SizedBox(height: AppSpace.sm),
                      dropdown(
                        key: const Key('activity-filter-tags'),
                        value: _names(tagNames, 'Any tag'),
                        filled: tagNames.isNotEmpty,
                        onTap: _pickTags,
                      ),
                    ],
                    const SizedBox(height: AppSpace.lg),

                    const _FilterLabel('Amount'),
                    const SizedBox(height: AppSpace.xs),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('activity-amount-min'),
                            controller: _min,
                            onChanged: (_) => setState(() {}),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              hintText: 'Min',
                              prefixText: '₹ ',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: TextField(
                            key: const Key('activity-amount-max'),
                            controller: _max,
                            onChanged: (_) => setState(() {}),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              hintText: 'Max',
                              prefixText: '₹ ',
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.sm),
                    SwitchListTile(
                      key: const Key('activity-foreign-switch'),
                      contentPadding: EdgeInsets.zero,
                      activeThumbColor: BambooInk.jade,
                      title: Text(
                        'Foreign currency only',
                        style: BambooFonts.ui(14, color: BambooInk.ink900),
                      ),
                      value: _foreign,
                      onChanged: (v) => setState(() => _foreign = v),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.md,
                AppSpace.lg,
                MediaQuery.viewInsetsOf(context).bottom + AppSpace.sm,
              ),
              decoration: const BoxDecoration(
                color: BambooInk.paper,
                border: Border(
                  top: BorderSide(color: BambooInk.hairlineOnPaper),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const Key('activity-filters-apply'),
                      style: FilledButton.styleFrom(
                        backgroundColor: BambooInk.lime,
                        foregroundColor: BambooInk.slate,
                        minimumSize: const Size.fromHeight(52),
                        textStyle: BambooFonts.ui(16, weight: FontWeight.w700),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(_draft),
                      child: Text(
                        'Show $matching ${matching == 1 ? 'transaction' : 'transactions'}',
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: BambooInk.jade,
                      textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                    ),
                    child: const Text('Cancel'),
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

class _FilterLabel extends StatelessWidget {
  final String label;
  const _FilterLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: BambooFonts.ui(
        13,
        weight: FontWeight.w700,
        color: BambooInk.ink500,
      ),
    );
  }
}

Widget _selectionField({
  Key? key,
  IconData? icon,
  String? label,
  Widget? child,
  Widget? trailing,
  VoidCallback? onTap,
}) => InkWell(
  key: key,
  onTap: onTap,
  borderRadius: BorderRadius.circular(16),
  child: Container(
    constraints: const BoxConstraints(minHeight: 52),
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
    decoration: BoxDecoration(
      color: BambooInk.paper,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BambooInk.hairlineOnPaper),
    ),
    child: Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 22, color: BambooInk.ink900),
          const SizedBox(width: 14),
        ],
        Expanded(
          child:
              child ??
              Text(
                label ?? '',
                style: BambooFonts.ui(14, color: BambooInk.ink500),
                overflow: TextOverflow.ellipsis,
              ),
        ),
        if (trailing != null) trailing,
      ],
    ),
  ),
);

Widget _typePill({
  required String label,
  required bool selected,
  required VoidCallback onTap,
  IconData? icon,
}) => InkWell(
  onTap: onTap,
  borderRadius: BorderRadius.circular(18),
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: selected ? BambooInk.slate : BambooInk.paper,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: selected ? BambooInk.slate : BambooInk.hairlineOnPaper,
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            size: 15,
            color: selected ? BambooInk.onSlate : BambooInk.ink700,
          ),
          const SizedBox(width: 5),
        ],
        Text(
          label,
          style: BambooFonts.ui(
            13,
            weight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? BambooInk.onSlate : BambooInk.ink700,
          ),
        ),
      ],
    ),
  ),
);

String _dateFilterLabel(ActivityFilter filter) {
  if (filter.datePreset != _ActivityDatePreset.allTime) {
    if (filter.datePreset != _ActivityDatePreset.custom ||
        filter.from != null ||
        filter.to != null) {
      return filter.datePreset == _ActivityDatePreset.custom
          ? '${_shortDateLabel(filter.from)} – ${_shortDateLabel(filter.to)}'
          : filter.datePreset.label;
    }
  }
  return filter.datePreset.label;
}

String _shortDateLabel(DateTime? date) {
  if (date == null) return '…';
  const months = [
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
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

IconData _datePresetIcon(_ActivityDatePreset preset) => switch (preset) {
  _ActivityDatePreset.allTime => Icons.all_inclusive_rounded,
  _ActivityDatePreset.today => Icons.today_rounded,
  _ActivityDatePreset.thisWeek => Icons.view_week_rounded,
  _ActivityDatePreset.thisMonth => Icons.calendar_month_rounded,
  _ActivityDatePreset.lastMonth => Icons.history_rounded,
  _ActivityDatePreset.last30Days => Icons.date_range_rounded,
  _ActivityDatePreset.last90Days => Icons.event_repeat_rounded,
  _ActivityDatePreset.thisYear => Icons.calendar_today_rounded,
  _ActivityDatePreset.custom => Icons.tune_rounded,
};

class _SummaryCard extends StatelessWidget {
  final Money totalIncoming;
  final Money totalOutgoing;
  final int count;
  const _SummaryCard({
    required this.totalIncoming,
    required this.totalOutgoing,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    // The spend-trends metrics-card language (paper, hairline, icon circles)
    // instead of a slate hero — the period chip right above already says
    // which window this covers.
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.paper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: _SummaryMetric(
              label: 'Money in',
              amount: totalIncoming,
              prefix: '+',
              color: BambooInk.jade,
            ),
          ),
          Container(width: 1, height: 28, color: BambooInk.hairlineOnPaper),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: _SummaryMetric(
              label: 'Money out',
              amount: totalOutgoing,
              prefix: '−',
              color: BambooInk.clay,
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Text(
            count == 0
                ? 'No activity'
                : totalOutgoing.paise == 0
                ? 'No spending'
                : '$count txns',
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  final String label;
  final Money amount;
  final String prefix;
  final Color color;

  const _SummaryMetric({
    required this.label,
    required this.amount,
    required this.prefix,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    // Keep headline totals readable on narrow phones. Once a total reaches a
    // lakh, the denomination is more useful than shrinking a long rupee
    // string until it becomes hard to scan. FittedBox still protects smaller
    // values and large accessibility text settings from clipping.
    final useCompactDenomination = amount.rupees.abs() >= 100000;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: BambooFonts.ui(11, color: BambooInk.ink500)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: MoneyText(
            amount,
            prefix: prefix,
            confidence: Confidence.estimated,
            style: BambooFonts.money(16, color: color),
            showConfidenceIcon: false,
            hidePaise: true,
            compact: useCompactDenomination,
          ),
        ),
      ],
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final TransactionEntry entry;
  final ForeignPayment? foreignPayment;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final List<String> tagNames;
  final bool selecting;
  final bool selected;

  /// Shows the day before the time: for a list that is not grouped by day.
  final bool showDate;
  const _TransactionTile(
    this.entry, {
    this.showDate = false,
    this.foreignPayment,
    required this.onTap,
    this.onLongPress,
    this.tagNames = const [],
    this.selecting = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final isInvestmentReturn =
        entry.entryKind == TxnEntryKind.investmentReturn;
    // Money back from an investment reads as money in (+, downward arrow) even
    // though it is never earned income.
    final isIncome =
        entry.entryKind == TxnEntryKind.income || isInvestmentReturn;
    final isInvestmentCategory =
        entry.categoryId == 'investments' ||
        entry.categoryName?.toLowerCase() == 'investments';
    final entryLabel = (isIncome && isInvestmentCategory)
        ? 'Investment return'
        : (entry.entryKind == TxnEntryKind.investment || isInvestmentCategory)
        ? 'Investment'
        : entry.entryKind.label;
    final isMoneyOut =
        entry.entryKind == TxnEntryKind.spend ||
        entry.entryKind == TxnEntryKind.investment;
    final isIgnored = entry.status == 'ignored';
    final isRefund = entry.note?.contains('[ignored: refund]') == true;
    final isReversal = entry.note?.contains('[ignored: reversal]') == true;
    final amountPrefix = isIncome
        ? '+'
        : isMoneyOut
        ? '−'
        : null;
    final directionColor = isRefund
        ? BambooInk.jade
        : isReversal
        ? BambooInk.amber
        : isIgnored
        ? BambooInk.ink500
        : isIncome
        ? BambooInk.jade
        : isMoneyOut
        ? BambooInk.clay
        : BambooInk.ink900;
    final isSmsImported = entry.source == 'sms' || entry.source == 'sms_bulk';
    final clock = _ActivityScreenState._timeLabel(
      context,
      isSmsImported
          ? (entry.smsReceivedAt ?? entry.occurredAt)
          : entry.occurredAt,
    );
    final timeLabel = showDate
        ? '${_ActivityScreenState._dayLabel(DateTime(entry.occurredAt.toLocal().year, entry.occurredAt.toLocal().month, entry.occurredAt.toLocal().day))} · $clock'
        : clock;
    // SMS import stores a P2P transfer as "Transfer to <payee>". Showing the
    // payee and moving "Transfer" into the chip slot keeps the cue when the
    // list is scanned (docs/design/spending-activity-redesign-2026-10-20.html).
    final merchantDisplay =
        MerchantIdentity.displayName(entry.merchantName, incoming: isIncome) ??
        entryLabel;
    final transferPayee = MerchantIdentity.transferPayee(merchantDisplay);
    // The payee-first title only exists to free the chip slot. When Refund or
    // Reversal claims it, the name keeps its verb — a row must not lose the
    // transfer cue and the chip in the same breath.
    final showTransferChip = transferPayee != null && !isRefund && !isReversal;
    // Investments carry their own chip, the same way Refund and Reversal do, so
    // a SIP or a redemption is recognisable in the list without opening it.
    final showInvestmentChip =
        (entry.entryKind == TxnEntryKind.investment || isInvestmentReturn) &&
        !isRefund &&
        !isReversal &&
        !showTransferChip;
    // Money that moved between the person's own accounts, to family, to a card
    // bill or into a wallet says so on the row, so it is never mistaken for
    // spending or income.
    final badge = txnBadgeKind(entry);
    final showSelfChip = badge != null && badge.isTransfer;
    final nameDisplay = showTransferChip ? transferPayee : merchantDisplay;
    final subtitleParts = <String>[
      if (foreignPayment != null)
        '${foreignPayment!.originalLabel} · Foreign currency',
      isSmsImported ? '$timeLabel · SMS' : timeLabel,
      if ((entry.entryKind != TxnEntryKind.spend || isInvestmentCategory) &&
          !showInvestmentChip &&
          !showSelfChip)
        entryLabel,
      if (entry.cardDisplayName != null) entry.cardDisplayName!,
      if (entry.cardDisplayName == null &&
          entry.instrument == TxnInstrument.creditCard)
        entry.cardLast4 == null
            ? 'Credit card · unmatched'
            : 'Credit card ending ${entry.cardLast4}',
      if (entry.cardDisplayName == null &&
          entry.instrument == TxnInstrument.upiBank)
        entry.accountLast4 == null
            ? 'Bank account · unmatched'
            : 'Bank account ending ${entry.accountLast4}',
      if (entry.cardDisplayName == null &&
          entry.instrument == TxnInstrument.other &&
          (entry.accountLast4 == 'Amazon Pay Later' ||
              entry.merchantName == 'Amazon Pay Later'))
        'Amazon Pay Later',
      if (isIgnored) 'Excluded from spend',
      if (!isIgnored && entry.excludeFromSpend) 'Not counted in spending',
      // The reward this card spend earned (priced by the server). Nothing for a
      // payment that cannot earn one, and nothing until it has been priced.
      if (activityRewardChip(entry) case final chip?) chip,
      // The Transfer chip is what replaces this segment, so the category goes
      // only when the chip is actually on the row. `other` is one of the
      // canonical fifteen and a user can pick it deliberately — nothing here
      // can tell that apart from an auto-assigned one, and a real subcategory
      // ("Other · UPI") still earns its place.
      if (entry.categoryName != null &&
          !(showTransferChip &&
              entry.categoryName!.toLowerCase() == 'other' &&
              entry.subcategoryName == null))
        entry.categoryLabel,
    ];
    // See account_screen.dart's _AccountTile for why Pressable, not InkWell.
    return Semantics(
      selected: selecting ? selected : null,
      hint: selecting
          ? (selected ? 'Double tap to deselect' : 'Double tap to select')
          : null,
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: BambooInk.hairlineOnPaper),
          ),
          // AppSpace.md stays the row's standard inset; density comes from the
          // 34pt tile and the two-line clamps, not from off-scale padding.
          padding: const EdgeInsets.all(AppSpace.md),
          child: Row(
            children: [
              // The check sits on the tile's corner instead of in its own
              // 40pt column, which used to eat the width the merchant name
              // needed; tapping anywhere on the row still toggles selection.
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: directionColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Icon(
                      isRefund
                          ? Icons.replay_rounded
                          : isReversal
                          ? Icons.undo_rounded
                          : isIgnored
                          ? Icons.block_rounded
                          : ((isInvestmentCategory || isInvestmentReturn) &&
                                isIncome)
                          ? Icons.trending_up_rounded
                          : isIncome
                          ? Icons.arrow_downward_rounded
                          : (entry.entryKind == TxnEntryKind.investment ||
                                isInvestmentCategory)
                          ? Icons.trending_up_rounded
                          : isMoneyOut
                          ? Icons.arrow_upward_rounded
                          : entry.entryKind == TxnEntryKind.transfer
                          ? Icons.swap_horiz_rounded
                          : Icons.trending_up_rounded,
                      size: 18,
                      color: directionColor,
                    ),
                  ),
                  if (selecting)
                    Positioned(
                      left: -5,
                      top: -5,
                      child: ExcludeSemantics(
                        child: Container(
                          key: ValueKey('activity-select-${entry.id}'),
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: selected ? BambooInk.lime : BambooInk.paper,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected
                                  ? BambooInk.lime
                                  : BambooInk.ink300,
                              width: 1.5,
                            ),
                          ),
                          child: selected
                              ? const Icon(
                                  Icons.check_rounded,
                                  size: 13,
                                  color: BambooInk.ink900,
                                )
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      // A wrapped name must not centre the Refund chip against
                      // both lines; top-align it and nudge it onto line one.
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: Text(
                            nameDisplay,
                            // Two lines of the real name beat one line of an
                            // ellipsis — Indian merchant strings routinely need
                            // the full 25 characters ("Shantesh gurudas gaude").
                            maxLines: 2,
                            style: BambooFonts.heading(
                              14.5,
                              color: isIgnored
                                  ? BambooInk.ink700
                                  : BambooInk.ink900,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: AppSpace.xs),
                          TransactionBadgePill(kind: badge),
                        ] else if (showTransferChip) ...[
                          // Neutral: jade and amber stay reserved for the
                          // Refund/Reversal money moves.
                          const SizedBox(width: AppSpace.xs),
                          TransactionBadgePill.plain(
                            entry.entryKind == TxnEntryKind.transfer
                                ? 'Transfer'
                                : 'Payment',
                          ),
                        ] else if (transferCheckMethod(entry) case final method?) ...[
                          // Paid by NEFT, IMPS, RTGS or cheque to a named payee:
                          // worth a look, spending is not changed.
                          const SizedBox(width: AppSpace.xs),
                          TransactionBadgePill.plain('Check · $method'),
                        ] else if (showInvestmentChip) ...[
                          const SizedBox(width: AppSpace.xs),
                          TransactionBadgePill.plain(
                            isInvestmentReturn
                                ? 'Investment return'
                                : 'Investment',
                          ),
                        ],
                      ],
                    ),
                    if (subtitleParts.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitleParts.join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                    ],
                    if (tagNames.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        tagNames.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BambooFonts.ui(11.5, color: BambooInk.jade),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  MoneyText(
                    entry.amount,
                    prefix: amountPrefix,
                    confidence: Confidence.estimated,
                    // The hourglass only pushed the figure off the row's right edge.
                    showConfidenceIcon: false,
                    style:
                        BambooFonts.money(
                          15,
                          color: isIgnored ? BambooInk.ink500 : directionColor,
                        ).copyWith(
                          decoration: isIgnored
                              ? TextDecoration.lineThrough
                              : null,
                          decorationColor: BambooInk.ink500,
                        ),
                  ),
                  if (isRefund) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Refunded',
                      style: BambooFonts.ui(
                        10.5,
                        weight: FontWeight.w600,
                        color: BambooInk.jade,
                      ),
                    ),
                  ] else if (isReversal) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Reversed',
                      style: BambooFonts.ui(
                        10.5,
                        weight: FontWeight.w600,
                        color: BambooInk.amber,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionCountChip extends StatelessWidget {
  final int count;
  final VoidCallback? onCancel;

  const _SelectionCountChip({required this.count, this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Cancel selection',
      child: Pressable(
        onTap: onCancel,
        enforceMinTarget: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: BambooInk.slate,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.close_rounded,
                size: 16,
                color: BambooInk.onSlate,
              ),
              const SizedBox(width: 6),
              Text(
                '$count selected',
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w600,
                  color: BambooInk.onSlate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The contextual bar the app shows while transactions are selected: one
/// primary "Edit" entry that opens every bulk action in a sheet, plus the
/// destructive shortcut. Count and Select all live in the list header, not
/// here, so the bar stays one row tall.
class _BulkActionBar extends StatelessWidget {
  final int selectedCount;
  final bool isBusy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _BulkActionBar({
    required this.selectedCount,
    required this.isBusy,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = selectedCount > 0 && !isBusy;
    return Padding(
      // Activity is a full-screen pushed route (no shell nav pill here), so
      // the bar docks to the bottom: system gesture inset + the same 16 gap
      // the bar uses on its sides.
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        MediaQuery.of(context).padding.bottom + AppSpace.lg,
      ),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: BambooInk.slate,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: BambooInk.ink900.withValues(alpha: 0.25),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Pressable(
                onTap: enabled ? onEdit : null,
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: BambooInk.lime.withValues(alpha: enabled ? 1 : 0.4),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.edit_rounded,
                        size: 17,
                        color: BambooInk.slate,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Edit $selectedCount '
                          'transaction${selectedCount == 1 ? '' : 's'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: BambooFonts.ui(
                            14,
                            weight: FontWeight.w700,
                            color: BambooInk.slate,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpace.xs),
            Pressable(
              onTap: enabled ? onDelete : null,
              child: Container(
                width: 56,
                height: 52,
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.delete_outline_rounded,
                      size: 21,
                      color: BambooInk.clay.withValues(
                        alpha: enabled ? 1 : 0.4,
                      ),
                    ),
                    Text(
                      'Delete',
                      style: BambooFonts.ui(
                        10.5,
                        weight: FontWeight.w600,
                        color: BambooInk.clay.withValues(
                          alpha: enabled ? 1 : 0.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Every bulk action, labelled — the icon-only popup bar these replace gave
/// no hint that tags had add *and* remove halves, or that assign-card exists.
class _BulkEditSheet extends StatelessWidget {
  final int count;
  final bool tagsAvailable;
  final VoidCallback onSetCategory;
  final VoidCallback? onAddTags;
  final VoidCallback? onRemoveTags;
  final VoidCallback onAssignCard;
  final VoidCallback onLeaveOutOfSpending;
  final VoidCallback onCountInSpending;

  const _BulkEditSheet({
    required this.count,
    required this.tagsAvailable,
    required this.onSetCategory,
    this.onAddTags,
    this.onRemoveTags,
    required this.onAssignCard,
    required this.onLeaveOutOfSpending,
    required this.onCountInSpending,
  });

  @override
  Widget build(BuildContext context) {
    final n = '$count transaction${count == 1 ? '' : 's'}';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.xs,
          AppSpace.lg,
          AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit $n',
              style: BambooFonts.heading(18, color: BambooInk.ink900),
            ),
            const SizedBox(height: 2),
            Text(
              'Applies to every selected transaction',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            _BulkEditTile(
              icon: Icons.category_outlined,
              title: 'Change category',
              subtitle: 'Use one category for all $n',
              onTap: onSetCategory,
            ),
            const SizedBox(height: AppSpace.xs),
            _BulkEditTile(
              icon: Icons.label_outline,
              title: 'Add tags',
              subtitle: 'Reimbursable, trip, family — all $n',
              onTap: onAddTags,
            ),
            const SizedBox(height: AppSpace.xs),
            _BulkEditTile(
              icon: Icons.label_off_outlined,
              title: 'Remove tags',
              subtitle: 'Clear tags from all $n',
              onTap: onRemoveTags,
            ),
            const SizedBox(height: AppSpace.xs),
            _BulkEditTile(
              icon: Icons.credit_card_outlined,
              title: 'Assign to a card',
              subtitle: 'Move all $n under one card',
              onTap: onAssignCard,
            ),
            const SizedBox(height: AppSpace.xs),
            _BulkEditTile(
              icon: Icons.visibility_off_outlined,
              title: "Don't count in spending",
              subtitle: 'Keep all $n in history and Money out, not in spending',
              onTap: onLeaveOutOfSpending,
            ),
            const SizedBox(height: AppSpace.xs),
            _BulkEditTile(
              icon: Icons.add_circle_outline_rounded,
              title: 'Count in spending again',
              subtitle: 'Add all $n back to your spending',
              onTap: onCountInSpending,
            ),
          ],
        ),
      ),
    );
  }
}

class _BulkEditTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _BulkEditTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: BambooInk.wash,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(
                icon,
                size: 18,
                color: BambooInk.jade.withValues(alpha: enabled ? 1 : 0.4),
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: BambooFonts.heading(
                      14,
                      color: BambooInk.ink900.withValues(
                        alpha: enabled ? 1 : 0.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BambooFonts.ui(
                      11.5,
                      color: BambooInk.ink500.withValues(
                        alpha: enabled ? 1 : 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: BambooInk.ink300.withValues(alpha: enabled ? 1 : 0.4),
            ),
          ],
        ),
      ),
    );
  }
}
