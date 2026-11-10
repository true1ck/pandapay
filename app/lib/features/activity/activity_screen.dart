import 'package:pandapay_domain/sms_v2.dart' show Totals;
import '../sms_v2/ledger/providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

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
import 'foreign_payments_screen.dart';
import 'deleted_transactions_screen.dart';
import 'local_category_learning.dart';
import '../../data/local/sms_intake_repository.dart';
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
    List<TransactionEntry> entries,
  ) async {
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
  bool _foreignOnly = false;
  bool _isBulkOperating = false;
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(_activityFilterProvider.notifier).state =
            _activityMonthFilter();
      });
    }
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
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(_activityFilterProvider.notifier).state =
              _activityMonthFilter();
        });
      }
    }
  }

  void _applyInitialFilterAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
    final previewForeign = _foreignOnly
        ? pendingForeign
        : pendingForeign.take(3).toList();

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
                    const SizedBox(width: AppSpace.xs),
                    IconButton(
                      key: const Key('activity-sort-button'),
                      tooltip: 'Sort: ${sort.label}',
                      color: sort == ActivitySort.newest
                          ? null
                          : BambooInk.jade,
                      onPressed: () => _openSortSheet(context, sort),
                      icon: const Icon(Icons.swap_vert_rounded),
                    ),
                    IconButton(
                      tooltip: 'Select transactions',
                      onPressed: _selecting || _isBulkOperating
                          ? null
                          : () => setState(() => _selecting = true),
                      icon: const Icon(Icons.checklist),
                    ),
                    IconButton(
                      tooltip: 'Deleted transactions',
                      color: BambooInk.clayInk,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DeletedTransactionsScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.history),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                _SpendPeriodAndFilterBar(
                  filter: filter,
                  onOpenPeriod: () => _openPeriodSheet(context, filter),
                  onOpenFilters: () => _openFilterSheet(
                    context,
                    filter,
                    transactions.valueOrNull ?? const [],
                  ),
                ),
                const SizedBox(height: AppSpace.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: AppSpace.xs,
                    children: [
                      FilterChip(
                        key: const Key('activity-foreign-filter'),
                        avatar: const Icon(Icons.currency_exchange, size: 16),
                        label: const Text('Foreign currency'),
                        selected: _foreignOnly,
                        onSelected: (selected) => setState(() {
                          _foreignOnly = selected;
                          _selecting = false;
                          _selectedIds.clear();
                        }),
                      ),
                      if (sort != ActivitySort.newest)
                        InputChip(
                          key: const Key('activity-sort-chip'),
                          avatar: Icon(_activitySortIcon(sort), size: 16),
                          label: Text(sort.label),
                          onPressed: () => _openSortSheet(context, sort),
                          onDeleted: () =>
                              ref.read(_activitySortProvider.notifier).state =
                                  ActivitySort.newest,
                          deleteButtonTooltipMessage: 'Back to newest first',
                        ),
                    ],
                  ),
                ),
                if (filter.hasClearableFilters) ...[
                  const SizedBox(height: AppSpace.xs),
                  _ActiveFilterBadgesRow(filter: filter),
                ],
              ],
            ),
          ),
          Expanded(
            child: transactions.when(
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
                onRetry: () => ref.invalidate(activityTransactionsProvider),
              ),
              data: (allEntries) {
                final entries = _foreignOnly
                    ? allEntries
                          .where(
                            (entry) =>
                                foreignByTransaction.containsKey(entry.id),
                          )
                          .toList()
                    : allEntries;
                if (entries.isEmpty && previewForeign.isEmpty) {
                  return RefreshIndicator(
                    onRefresh: () async {
                      ref.invalidate(activityTransactionsProvider);
                      ref.invalidate(transactionsProvider);
                      try {
                        await ref.read(activityTransactionsProvider.future);
                      } catch (_) {}
                    },
                    child: LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: EmptyState(
                            icon: Icons.receipt_long_outlined,
                            title: _foreignOnly
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
                final v2Enabled = ref.watch(smsV2ReportingEnabledProvider);
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
                              const Text('Couldn’t load activity totals.'),
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
                  ledgerTotals: ledgerModel?.totalsForTransactions(entries),
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
                            await ref.read(activityTransactionsProvider.future);
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
                                child: ForeignPaymentSummaryCard(
                                  payments: pendingForeign,
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => ForeignPaymentsScreen(
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
                                  onTap: () =>
                                      openForeignPayment(context, payment),
                                ),
                              );
                            }
                            index -= foreignOffset;
                            final row = _selecting && index == 0
                                ? const ActivityListRow.selection()
                                : projection.rows[index - selectionOffset];
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
                                                    entries.map((e) => e.id),
                                                  );
                                                }
                                              }),
                                        child: Text(
                                          visibleSelected == entries.length
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
                                    selected: _selectedIds.contains(entry.id),
                                    tagNames:
                                        (tagRepository?.tagsForTransaction(
                                                  entry.id,
                                                  fallback: entry.tags,
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
                                        context.push(
                                          '/activity/${entry.id}',
                                          extra: entry,
                                        );
                                      }
                                    },
                                    onLongPress: _selecting || _isBulkOperating
                                        ? null
                                        : () => setState(() {
                                            _selecting = true;
                                            _selectedIds.add(entry.id);
                                          }),
                                  ),
                                );
                              case ActivityRowKind.spacer:
                                return const SizedBox(height: AppSpace.sm);
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
  final String? cardId;
  final String? categoryId;
  final String? categoryLabel;
  final Set<String> tagIds;
  final bool untagged;
  final DateTime? from;
  final DateTime? to;

  /// Free-text search over merchant name and note, matched server-side
  /// (`GET /transactions?q=`). Client-side filtering would only ever have
  /// searched the rows already loaded, which is why this shipped as a
  /// documented gap rather than a box that quietly searched the last 50
  /// transactions.
  final String? query;
  final _ActivityTypeFilter type;
  final _ActivityDatePreset datePreset;

  const ActivityFilter({
    this.cardId,
    this.categoryId,
    this.categoryLabel,
    this.tagIds = const {},
    this.untagged = false,
    this.from,
    this.to,
    this.query,
    this.type = _ActivityTypeFilter.all,
    this.datePreset = _ActivityDatePreset.allTime,
  });

  bool get isActive =>
      cardId != null ||
      categoryId != null ||
      categoryLabel != null ||
      tagIds.isNotEmpty ||
      untagged ||
      from != null ||
      to != null ||
      (query != null && query!.isNotEmpty) ||
      hasTypeFilter;

  /// The current month is the default scope, so it should not by itself show
  /// the Clear chip. Any other selected filter or date preset remains clearable.
  bool get hasClearableFilters =>
      cardId != null ||
      categoryId != null ||
      categoryLabel != null ||
      tagIds.isNotEmpty ||
      untagged ||
      (query != null && query!.isNotEmpty) ||
      hasTypeFilter ||
      datePreset != _ActivityDatePreset.thisMonth;

  bool get hasTypeFilter => type != _ActivityTypeFilter.all;

  ActivityFilter copyWith({
    String? Function()? cardId,
    String? Function()? categoryId,
    String? Function()? categoryLabel,
    Set<String>? tagIds,
    bool? untagged,
    DateTime? Function()? from,
    DateTime? Function()? to,
    String? Function()? query,
    _ActivityTypeFilter? type,
    _ActivityDatePreset? datePreset,
  }) {
    return ActivityFilter(
      cardId: cardId != null ? cardId() : this.cardId,
      categoryId: categoryId != null ? categoryId() : this.categoryId,
      categoryLabel: categoryLabel != null
          ? categoryLabel()
          : this.categoryLabel,
      tagIds: tagIds ?? this.tagIds,
      untagged: untagged ?? this.untagged,
      from: from != null ? from() : this.from,
      to: to != null ? to() : this.to,
      query: query != null ? query() : this.query,
      type: type ?? this.type,
      datePreset: datePreset ?? this.datePreset,
    );
  }
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
            filter.type.matches(entry) &&
            (filter.cardId == null || entry.userCardId == filter.cardId) &&
            (filter.categoryId == null ||
                entry.categoryId == filter.categoryId ||
                entry.parentCategoryId == filter.categoryId) &&
            (filter.categoryLabel == null ||
                filter.categoryLabel!.trim().toLowerCase() ==
                    entry.categoryLabel.trim().toLowerCase()) &&
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
    _ActivityTypeFilter.spending => entry.entryKind == TxnEntryKind.spend,
    _ActivityTypeFilter.moneyIn => entry.entryKind == TxnEntryKind.income,
    _ActivityTypeFilter.moneyOut =>
      entry.entryKind == TxnEntryKind.spend ||
          entry.entryKind == TxnEntryKind.investment,
    _ActivityTypeFilter.transfers => entry.entryKind == TxnEntryKind.transfer,
    _ActivityTypeFilter.investments =>
      entry.entryKind == TxnEntryKind.investment ||
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
class _SearchField extends ConsumerStatefulWidget {
  const _SearchField();

  @override
  ConsumerState<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<_SearchField> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(_activityFilterProvider).query ?? '';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final trimmed = value.trim();
      ref
          .read(_activityFilterProvider.notifier)
          .update(
            (f) => f.copyWith(query: () => trimmed.isEmpty ? null : trimmed),
          );
    });
    // Rebuild for the clear button's visibility, which shouldn't wait on
    // the debounce.
    setState(() {});
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    ref
        .read(_activityFilterProvider.notifier)
        .update((f) => f.copyWith(query: () => null));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(_activityFilterProvider.select((f) => f.query), (
      _,
      next,
    ) {
      final incoming = next ?? '';
      if (_controller.text != incoming) {
        _controller.text = incoming;
        setState(() {});
      }
    });

    return TextField(
      controller: _controller,
      onChanged: _onChanged,
      textInputAction: TextInputAction.search,
      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
      decoration: InputDecoration(
        hintText: 'Search merchant or note',
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
    );
  }
}

class _SpendPeriodAndFilterBar extends StatelessWidget {
  final ActivityFilter filter;
  final VoidCallback onOpenPeriod;
  final VoidCallback onOpenFilters;

  const _SpendPeriodAndFilterBar({
    required this.filter,
    required this.onOpenPeriod,
    required this.onOpenFilters,
  });

  @override
  Widget build(BuildContext context) {
    final filtersActive = filter.hasClearableFilters;
    final periodLabel = _dateFilterLabel(filter);

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onOpenPeriod,
            icon: const Icon(Icons.calendar_month_rounded, size: 18),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(periodLabel, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              ],
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: BambooInk.ink900,
              side: const BorderSide(color: BambooInk.hairlineOnPaper),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        OutlinedButton.icon(
          onPressed: onOpenFilters,
          icon: const Icon(Icons.tune_rounded, size: 18),
          label: Text(filtersActive ? 'Filters ·' : 'Filters'),
          style: OutlinedButton.styleFrom(
            foregroundColor: filtersActive ? BambooInk.jade : BambooInk.ink900,
            side: BorderSide(
              color: filtersActive ? BambooInk.jade : BambooInk.hairlineOnPaper,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
        ),
      ],
    );
  }
}

class _ActiveFilterBadgesRow extends ConsumerWidget {
  final ActivityFilter filter;
  const _ActiveFilterBadgesRow({required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];
    final card = filter.cardId != null
        ? cards.cast<UserCard?>().firstWhere(
            (c) => c?.id == filter.cardId,
            orElse: () => null,
          )
        : null;
    final cardTitle = card?.nickname?.isNotEmpty == true
        ? card!.nickname!
        : (card?.cardName ?? 'Card');

    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _FilterChipButton(
              label: 'Clear',
              active: false,
              icon: Icons.close_rounded,
              onTap: () => ref.read(_activityFilterProvider.notifier).state =
                  _activityMonthFilter(),
            ),
          ),
          if (filter.type != _ActivityTypeFilter.all)
            _badge(
              label: filter.type.label,
              onRemove: () => ref
                  .read(_activityFilterProvider.notifier)
                  .update(
                    (current) =>
                        current.copyWith(type: _ActivityTypeFilter.all),
                  ),
            ),
          if (filter.categoryId != null || filter.categoryLabel != null)
            _badge(
              label: filter.categoryLabel ?? 'Category',
              onRemove: () => ref
                  .read(_activityFilterProvider.notifier)
                  .update(
                    (current) => current.copyWith(
                      categoryId: () => null,
                      categoryLabel: () => null,
                    ),
                  ),
            ),
          if (filter.cardId != null)
            _badge(
              label: cardTitle,
              onRemove: () => ref
                  .read(_activityFilterProvider.notifier)
                  .update((current) => current.copyWith(cardId: () => null)),
            ),
          if (filter.tagIds.isNotEmpty || filter.untagged)
            _badge(
              label: filter.untagged
                  ? 'Untagged'
                  : '${filter.tagIds.length} tags',
              onRemove: () => ref
                  .read(_activityFilterProvider.notifier)
                  .update(
                    (current) =>
                        current.copyWith(tagIds: const {}, untagged: false),
                  ),
            ),
        ],
      ),
    );
  }

  Widget _badge({required String label, required VoidCallback onRemove}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        avatar: const Icon(
          Icons.close_rounded,
          size: 15,
          color: BambooInk.onSlate,
        ),
        label: Text(label),
        backgroundColor: BambooInk.slate,
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        labelStyle: BambooFonts.ui(
          12,
          weight: FontWeight.w600,
          color: BambooInk.onSlate,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        onPressed: onRemove,
      ),
    );
  }
}

class _ActivityFilterSheet extends StatefulWidget {
  final ActivityFilter initial;
  final List<TransactionEntry> entries;
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
    this.totalForEntries,
  });

  @override
  State<_ActivityFilterSheet> createState() => _ActivityFilterSheetState();
}

class _ActivityFilterSheetState extends State<_ActivityFilterSheet> {
  late _ActivityTypeFilter _type = widget.initial.type;
  late _ActivityDatePreset _datePreset = widget.initial.datePreset;
  late DateTime? _from = widget.initial.from;
  late DateTime? _to = widget.initial.to;
  late String? _cardId = widget.initial.cardId;
  late String? _categoryId = widget.initial.categoryId;
  late String? _categoryLabel = widget.initial.categoryLabel;
  late Set<String> _tagIds = {...widget.initial.tagIds};
  late bool _untagged = widget.initial.untagged;

  List<TransactionEntry> get _matchingEntries {
    return widget.entries.where((entry) {
      if (_type != _ActivityTypeFilter.all && !_type.matches(entry)) {
        return false;
      }
      if (_cardId != null && entry.userCardId != _cardId) return false;
      if (_categoryId != null &&
          entry.categoryId != _categoryId &&
          entry.parentCategoryId != _categoryId) {
        return false;
      }
      if (_categoryLabel != null && entry.categoryName != _categoryLabel) {
        return false;
      }
      final entryTagIds = entry.tags.map((t) => t.id).toSet();
      if (_untagged && entryTagIds.isNotEmpty) return false;
      if (_tagIds.isNotEmpty && !entryTagIds.any(_tagIds.contains)) {
        return false;
      }
      if (_from != null && entry.occurredAt.isBefore(_from!)) return false;
      if (_to != null &&
          !entry.occurredAt.isBefore(
            DateTime(_to!.year, _to!.month, _to!.day + 1),
          )) {
        return false;
      }
      return true;
    }).toList();
  }

  Money get _matchingTotal {
    final totals = widget.totalForEntries?.call(_matchingEntries);
    if (totals != null) return Money.fromPaise(totals.spendMinor);
    return _matchingEntries
        .where(
          (e) => e.status == 'active' && e.entryKind != TxnEntryKind.income,
        )
        .fold<Money>(const Money.zero(), (sum, e) => sum + e.amount);
  }

  void _reset() {
    final def = _activityMonthFilter();
    setState(() {
      _type = def.type;
      _datePreset = def.datePreset;
      _from = def.from;
      _to = def.to;
      _cardId = def.cardId;
      _categoryId = def.categoryId;
      _categoryLabel = def.categoryLabel;
      _tagIds = {...def.tagIds};
      _untagged = def.untagged;
    });
  }

  String get _currentDateLabel {
    if (_datePreset != _ActivityDatePreset.allTime) {
      if (_datePreset != _ActivityDatePreset.custom ||
          _from != null ||
          _to != null) {
        return _datePreset == _ActivityDatePreset.custom
            ? '${_shortDateLabel(_from)} – ${_shortDateLabel(_to)}'
            : _datePreset.label;
      }
    }
    return _datePreset.label;
  }

  String? get _selectedCardName {
    if (_cardId == null) return null;
    final c = widget.cards.cast<UserCard?>().firstWhere(
      (c) => c?.id == _cardId,
      orElse: () => null,
    );
    if (c == null) return null;
    return c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName;
  }

  String? get _selectedCategoryName {
    if (_categoryId != null) {
      final c = widget.categories.cast<SpendCategory?>().firstWhere(
        (cat) => cat?.id == _categoryId,
        orElse: () => null,
      );
      if (c != null) return c.name;
    }
    return _categoryLabel;
  }

  @override
  Widget build(BuildContext context) {
    final topLevelCategories = widget.categories
        .where((c) => !c.isSubcategory)
        .toList();

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: Column(
          children: [
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
                    Row(
                      children: [
                        Text(
                          'Filter activity',
                          style: BambooFonts.heading(
                            22,
                            color: BambooInk.ink900,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _reset,
                          style: TextButton.styleFrom(
                            foregroundColor: BambooInk.jade,
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: BambooFonts.ui(
                              15,
                              weight: FontWeight.w700,
                            ),
                          ),
                          child: const Text('Reset'),
                        ),
                      ],
                    ),
                    Text(
                      'Applies across all activity views',
                      style: BambooFonts.ui(14, color: BambooInk.ink500),
                    ),
                    const SizedBox(height: AppSpace.xl),

                    const _FilterLabel('Date range'),
                    const SizedBox(height: AppSpace.xs),
                    _selectionField(
                      icon: Icons.calendar_today_outlined,
                      label: _currentDateLabel,
                      trailing: const Icon(Icons.keyboard_arrow_down_rounded),
                      onTap: () async {
                        final picked =
                            await showModalBottomSheet<_ActivityDatePreset>(
                              context: context,
                              showDragHandle: true,
                              builder: (sheetContext) => SafeArea(
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: AppSpace.sm,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                          style: BambooFonts.heading(
                                            17,
                                            color: BambooInk.ink900,
                                          ),
                                        ),
                                      ),
                                      for (final preset
                                          in _ActivityDatePreset.values)
                                        ListTile(
                                          leading: Icon(
                                            _datePresetIcon(preset),
                                            color: preset == _datePreset
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
                                          selected: preset == _datePreset,
                                          selectedTileColor:
                                              BambooInk.paperMuted,
                                          onTap: () => Navigator.of(
                                            sheetContext,
                                          ).pop(preset),
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
                          if (!context.mounted) return;
                          final range = await showDateRangePicker(
                            context: context,
                            firstDate: firstDate,
                            lastDate: lastDate,
                            initialDateRange: _from != null && _to != null
                                ? DateTimeRange(start: _from!, end: _to!)
                                : null,
                          );
                          if (range != null && mounted) {
                            setState(() {
                              _from = range.start;
                              _to = range.end;
                              _datePreset = _ActivityDatePreset.custom;
                            });
                          }
                          return;
                        }
                        final range = picked.range(DateTime.now());
                        setState(() {
                          _from = range?.start;
                          _to = range?.end;
                          _datePreset = picked;
                        });
                      },
                    ),
                    const SizedBox(height: AppSpace.xl),

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
                    const SizedBox(height: AppSpace.xl),

                    const _FilterLabel('Category'),
                    const SizedBox(height: AppSpace.xs),
                    _selectionField(
                      icon: Icons.shopping_bag_outlined,
                      child: _selectedCategoryName == null
                          ? Text(
                              'All categories',
                              style: BambooFonts.ui(
                                14,
                                color: BambooInk.ink500,
                              ),
                            )
                          : _valueChip(
                              _selectedCategoryName!,
                              onRemove: () => setState(() {
                                _categoryId = null;
                                _categoryLabel = null;
                              }),
                            ),
                      trailing: _selectedCategoryName == null
                          ? const Icon(Icons.keyboard_arrow_down_rounded)
                          : null,
                      onTap: () async {
                        final picked =
                            await showModalBottomSheet<
                              ({bool all, String? id, String? name})
                            >(
                              context: context,
                              showDragHandle: true,
                              builder: (sheetContext) => SafeArea(
                                child: ListView(
                                  shrinkWrap: true,
                                  children: [
                                    ListTile(
                                      title: const Text('All categories'),
                                      selected:
                                          _categoryId == null &&
                                          _categoryLabel == null,
                                      onTap: () => Navigator.of(
                                        sheetContext,
                                      ).pop((all: true, id: null, name: null)),
                                    ),
                                    for (final c in topLevelCategories)
                                      ListTile(
                                        title: Text(c.name),
                                        selected: c.id == _categoryId,
                                        onTap: () =>
                                            Navigator.of(sheetContext).pop((
                                              all: false,
                                              id: c.id,
                                              name: c.name,
                                            )),
                                      ),
                                  ],
                                ),
                              ),
                            );
                        if (picked == null || !mounted) return;
                        setState(() {
                          _categoryId = picked.all ? null : picked.id;
                          _categoryLabel = picked.all ? null : picked.name;
                        });
                      },
                    ),
                    const SizedBox(height: AppSpace.xl),

                    const _FilterLabel('Account or card'),
                    const SizedBox(height: AppSpace.xs),
                    _selectionField(
                      icon: Icons.credit_card_outlined,
                      child: _selectedCardName == null
                          ? Text(
                              'All cards & accounts',
                              style: BambooFonts.ui(
                                14,
                                color: BambooInk.ink500,
                              ),
                            )
                          : _valueChip(
                              _selectedCardName!,
                              onRemove: () => setState(() => _cardId = null),
                            ),
                      trailing: _selectedCardName == null
                          ? const Icon(Icons.keyboard_arrow_down_rounded)
                          : null,
                      onTap: () async {
                        final picked =
                            await showModalBottomSheet<
                              ({bool all, String? id})
                            >(
                              context: context,
                              showDragHandle: true,
                              builder: (sheetContext) => SafeArea(
                                child: ListView(
                                  shrinkWrap: true,
                                  children: [
                                    ListTile(
                                      title: const Text('All cards & accounts'),
                                      selected: _cardId == null,
                                      onTap: () => Navigator.of(
                                        sheetContext,
                                      ).pop((all: true, id: null)),
                                    ),
                                    for (final c in widget.cards)
                                      ListTile(
                                        title: Text(
                                          c.nickname?.isNotEmpty == true
                                              ? c.nickname!
                                              : c.cardName,
                                        ),
                                        selected: c.id == _cardId,
                                        onTap: () => Navigator.of(
                                          sheetContext,
                                        ).pop((all: false, id: c.id)),
                                      ),
                                  ],
                                ),
                              ),
                            );
                        if (picked == null || !mounted) return;
                        setState(() => _cardId = picked.all ? null : picked.id);
                      },
                    ),
                    const SizedBox(height: AppSpace.xl),

                    const _FilterLabel('Tags'),
                    const SizedBox(height: AppSpace.xs),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        FilterChip(
                          label: const Text('Untagged'),
                          selected: _untagged,
                          onSelected: (val) => setState(() {
                            _untagged = val;
                            if (val) _tagIds.clear();
                          }),
                        ),
                        for (final tag in widget.tags)
                          FilterChip(
                            label: Text(tag.name),
                            selected: _tagIds.contains(tag.id),
                            onSelected: (val) => setState(() {
                              _untagged = false;
                              val
                                  ? _tagIds.add(tag.id)
                                  : _tagIds.remove(tag.id);
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      'Matches any selected tag across categories.',
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
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
                  Text.rich(
                    TextSpan(
                      style: BambooFonts.ui(14, color: BambooInk.ink900),
                      children: [
                        TextSpan(
                          text:
                              '${_matchingEntries.length} matching ${_matchingEntries.length == 1 ? 'transaction' : 'transactions'} · ',
                        ),
                        TextSpan(
                          text: _matchingTotal.format(hidePaise: true),
                          style: BambooFonts.ui(
                            14,
                            weight: FontWeight.w700,
                            color: BambooInk.ink900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: BambooInk.lime,
                        foregroundColor: BambooInk.slate,
                        minimumSize: const Size.fromHeight(52),
                        textStyle: BambooFonts.ui(16, weight: FontWeight.w700),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () {
                        final result = widget.initial.copyWith(
                          type: _type,
                          datePreset: _datePreset,
                          from: () => _from,
                          to: () => _to,
                          cardId: () => _cardId,
                          categoryId: () => _categoryId,
                          categoryLabel: () => _categoryLabel,
                          tagIds: _tagIds,
                          untagged: _untagged,
                        );
                        Navigator.of(context).pop(result);
                      },
                      child: const Text('Show results'),
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
  IconData? icon,
  String? label,
  Widget? child,
  Widget? trailing,
  VoidCallback? onTap,
}) => InkWell(
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

Widget _valueChip(String label, {VoidCallback? onRemove}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
  decoration: BoxDecoration(
    color: BambooInk.paperMuted,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: BambooInk.hairlineOnPaper),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: BambooFonts.ui(
          13,
          weight: FontWeight.w600,
          color: BambooInk.ink900,
        ),
      ),
      if (onRemove != null) ...[
        const SizedBox(width: 4),
        GestureDetector(
          onTap: onRemove,
          child: const Icon(
            Icons.close_rounded,
            size: 16,
            color: BambooInk.ink500,
          ),
        ),
      ],
    ],
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

class _FilterChipButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;
  const _FilterChipButton({
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 0),
      child: ActionChip(
        avatar: icon != null
            ? Icon(
                icon,
                size: 16,
                color: active ? BambooInk.onSlate : BambooInk.ink700,
              )
            : null,
        label: Text(label, overflow: TextOverflow.ellipsis),
        backgroundColor: active ? BambooInk.slate : BambooInk.paperMuted,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        labelStyle: BambooFonts.ui(
          13,
          weight: FontWeight.w600,
          color: active ? BambooInk.onSlate : BambooInk.ink900,
        ),
        onPressed: onTap,
      ),
    );
  }
}

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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _SummaryBadge(
            icon: Icons.arrow_downward_rounded,
            color: BambooInk.jade,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: _SummaryMetric(
              label: 'Money in',
              amount: totalIncoming,
              prefix: '+',
              color: BambooInk.jade,
            ),
          ),
          Container(width: 1, height: 30, color: BambooInk.hairlineOnPaper),
          const SizedBox(width: AppSpace.sm),
          _SummaryBadge(
            icon: Icons.arrow_upward_rounded,
            color: BambooInk.clay,
          ),
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

class _SummaryBadge extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _SummaryBadge({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 16, color: color),
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

/// The tinted pill beside a transaction title — Refund, Reversal or Transfer.
class _MovementChip extends StatelessWidget {
  const _MovementChip({
    required this.label,
    required this.tint,
    required this.fillAlpha,
    required this.borderAlpha,
    this.textColor,
  });

  final String label;
  final Color tint;
  final double fillAlpha;
  final double borderAlpha;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: fillAlpha),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: tint.withValues(alpha: borderAlpha),
          width: 0.8,
        ),
      ),
      child: Text(
        label,
        style: BambooFonts.ui(
          10.5,
          weight: FontWeight.w700,
          color: textColor ?? tint,
        ),
      ),
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
    final isIncome = entry.entryKind == TxnEntryKind.income;
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
    final merchantDisplay = entry.merchantName ?? entryLabel;
    final transferPayee = MerchantIdentity.transferPayee(merchantDisplay);
    // The payee-first title only exists to free the chip slot. When Refund or
    // Reversal claims it, the name keeps its verb — a row must not lose the
    // transfer cue and the chip in the same breath.
    final showTransferChip = transferPayee != null && !isRefund && !isReversal;
    final nameDisplay = showTransferChip ? transferPayee : merchantDisplay;
    final subtitleParts = <String>[
      if (foreignPayment != null)
        '${foreignPayment!.originalLabel} · Foreign currency',
      isSmsImported ? '$timeLabel · SMS' : timeLabel,
      if (entry.entryKind != TxnEntryKind.spend || isInvestmentCategory)
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
      if (entry.status == 'active' &&
          entry.rewardState == 'estimated' &&
          (entry.source == 'sms' || entry.source == 'sms_bulk'))
        'Pending confirmation',
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
                          : (isInvestmentCategory && isIncome)
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
                        if (isRefund) ...[
                          const SizedBox(width: AppSpace.xs),
                          const _MovementChip(
                            label: 'Refund',
                            tint: BambooInk.jade,
                            fillAlpha: 0.12,
                            borderAlpha: 0.3,
                          ),
                        ] else if (isReversal) ...[
                          const SizedBox(width: AppSpace.xs),
                          const _MovementChip(
                            label: 'Reversal',
                            tint: BambooInk.amber,
                            fillAlpha: 0.15,
                            borderAlpha: 0.35,
                          ),
                        ] else if (showTransferChip) ...[
                          // Neutral: jade and amber stay reserved for the
                          // Refund/Reversal money moves.
                          const SizedBox(width: AppSpace.xs),
                          _MovementChip(
                            label: entry.entryKind == TxnEntryKind.transfer
                                ? 'Transfer'
                                : 'Payment',
                            tint: BambooInk.ink900,
                            fillAlpha: 0.07,
                            borderAlpha: 0.14,
                            textColor: BambooInk.ink700,
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
                    // The subtitle already carries "Pending confirmation", so the
                    // hourglass only pushed the figure off the row's right edge.
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

  const _BulkEditSheet({
    required this.count,
    required this.tagsAvailable,
    required this.onSetCategory,
    this.onAddTags,
    this.onRemoveTags,
    required this.onAssignCard,
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
