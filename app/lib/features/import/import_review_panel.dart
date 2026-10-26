import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../app/env.dart';
import 'statement_import_continuation_provider.dart';
import '../../data/api_exception.dart';
import '../../data/catalogue_repository.dart'
    show SpendCategory, categoryIdForServer, userCategoryIdForServer;
import '../../data/import_models.dart';
import '../../data/transaction_import_pipeline.dart';
import '../../data/user_cards_repository.dart';

/// All document and screenshot adapters share this review and commit workflow.
class ImportReviewPanel extends ConsumerStatefulWidget {
  final TransactionImportSession session;
  final VoidCallback? configure;
  final String doneTitle;
  const ImportReviewPanel({
    super.key,
    required this.session,
    this.configure,
    this.doneTitle = 'Import complete',
  });
  @override
  ConsumerState<ImportReviewPanel> createState() => _ImportReviewPanelState();
}

class _ImportReviewPanelState extends ConsumerState<ImportReviewPanel> {
  late final _defaultTags = TextEditingController(
    text: widget.session.defaultTagNames.isEmpty
        ? ''
        : jsonEncode(widget.session.defaultTagNames),
  );
  bool _done = false;
  bool _preparingContinuation = false;
  String _filter = 'All';
  List<TransactionEntry> _saved = [];
  bool _checking = false;
  bool _savedCheckUnavailable = false;
  bool _destinationsSuggested = false;
  String? _duplicateError;

  @override
  void dispose() {
    _defaultTags.dispose();
    super.dispose();
  }

  Future<void> _tagSelected() async {
    final controller = TextEditingController();
    final names = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Tag ${session.selected.length} selected transactions'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Tags',
            helperText: 'Separate names with semicolons, or paste a JSON list.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final names = parseImportedTagNames(controller.text);
              if (names.any((name) => name.length > 80)) return;
              Navigator.pop(context, names);
            },
            child: const Text('Apply tags'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (names == null || !mounted) return;
    setState(() => session.applyTagsToSelected(names));
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_checkDuplicates);
  }

  Future<void> _checkDuplicates() async {
    final repository = ref.read(userCardsRepositoryProvider);
    if (repository == null) {
      setState(() => _savedCheckUnavailable = true);
      return;
    }
    setState(() {
      _checking = true;
      _duplicateError = null;
    });
    try {
      // Fetch from the database, not the potentially stale Activity cache.
      final saved = await repository.fetchTransactions();
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _savedCheckUnavailable = false;
        session.checkSavedDuplicates(_saved);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _savedCheckUnavailable = true;
          _duplicateError =
              'Saved transactions could not be checked. Retry, or continue with server duplicate checks at import.';
        });
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String? _error;
  TransactionImportSession get session => widget.session;
  bool get locked => session.reviewLocked;

  Future<void> _submit() async {
    final repository = ref.read(importRepositoryProvider);
    if (repository == null || session.submitting || _preparingContinuation) {
      return;
    }
    setState(() {
      _error = null;
      _preparingContinuation = true;
    });
    try {
      final continuation = Env.statementImportContinuationEnabled
          ? await ref.read(statementImportContinuationProvider.future)
          : null;
      if (Env.statementImportContinuationEnabled && continuation == null) {
        throw StateError('Sign in to save this import for continuation.');
      }
      final future = session.submit(
        repository,
        continuation: continuation,
        onProgress: (_) {
          ref.invalidate(statementImportsProvider);
          ref.invalidate(duplicateCandidatesProvider);
          ref.invalidate(transactionsProvider);
          ref.invalidate(utilizationTransactionsProvider);
          ref.invalidate(homeSummaryProvider);
          ref.invalidate(userCardsProvider);
          if (mounted) setState(() {});
        },
      );
      setState(() {});
      await future;
      try {
        await ref.read(transactionTagsProvider)?.sync();
      } catch (_) {
        // The import already committed. The normal sync loop can retry tag reads.
      }
      if (mounted) setState(() => _done = true);
    } catch (error) {
      if (mounted) {
        final message =
            error is ApiException && error.errorCode == 'internal_error'
            ? 'The server could not finish this import.${error.requestId == null ? '' : ' Reference: ${error.requestId}.'}'
            : userFacingErrorMessage(error);
        setState(
          () => _error =
              '$message Your reviewed rows are retained. Retry is safe.',
        );
      }
    } finally {
      if (mounted) setState(() => _preparingContinuation = false);
    }
  }

  Future<void> _edit(int? index, {ImportRejectedRow? rejected}) async {
    final row = index == null ? null : session.rows[index];
    final edited = await showDialog<ParsedStatementLine>(
      context: context,
      builder: (_) => _EditImportRow(
        row: row,
        categories: ref.read(categoriesProvider).valueOrNull ?? const [],
        raw: rejected?.cells.join(' | '),
        reason: index == null
            ? rejected?.reason
            : session.exclusionReason(index),
      ),
    );
    if (edited == null || !mounted) return;
    setState(() {
      if (index == null) {
        session.addCorrectedRow(rejected!, edited);
        session.checkSavedDuplicates(_saved);
      } else {
        session.replaceRow(index, edited);
        session.checkSavedDuplicates(_saved);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (Env.statementImportContinuationEnabled) {
      ref.watch(statementImportContinuationProvider);
    }
    final recognizedLocations = session.rows
        .map((row) => row.sourceRowId)
        .toSet();
    final rejected = session.statement.rejectedRows
        .where((r) => !recognizedLocations.contains(r.sourceRowId))
        .toList();
    if (_done) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, size: 48),
              Text(
                widget.doneTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(session.progress.description, textAlign: TextAlign.center),
              Text(
                '${session.rows.length - session.selected.length} detected rows were skipped or held for duplicate review. ${rejected.length} unrecognized rows were not imported.',
              ),
              if (session.progress.duplicates > 0)
                const Text(
                  'Possible duplicates are held for review until you resolve them.',
                ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );
    }
    final cards = ref.watch(userCardsProvider);
    final categories =
        ref.watch(categoriesProvider).valueOrNull ?? const <SpendCategory>[];
    final bankAccounts = ref.watch(bankAccountSummariesProvider);
    final bankDataResolved = bankAccounts.hasValue || bankAccounts.hasError;
    if (cards.hasValue && bankDataResolved && !_destinationsSuggested) {
      _destinationsSuggested = true;
      session.suggestDestinations(
        cards.valueOrNull ?? const [],
        bankAccounts: bankAccounts.valueOrNull ?? const [],
      );
      session.checkSavedDuplicates(_saved);
    } else if (cards.hasError && bankDataResolved && !_destinationsSuggested) {
      _destinationsSuggested = true;
      session.suggestDestinations(
        const [],
        bankAccounts: bankAccounts.valueOrNull ?? const [],
      );
    }
    final selected = session.selected.toSet();
    final selectedOutPaise = session.selected
        .where(
          (i) =>
              !session.rows[i].isCredit &&
              !session.rows[i].isTransfer &&
              !session.rows[i].isInvestment,
        )
        .fold(0, (sum, i) => sum + session.rows[i].amount.paise);
    final selectedInPaise = session.selected
        .where((i) => session.rows[i].isCredit && !session.rows[i].isInvestment)
        .fold(0, (sum, i) => sum + session.rows[i].amount.paise);
    final unresolved =
        session.rows
            .where(
              (r) =>
                  r.reviewReasons.isNotEmpty ||
                  validateImportedTransaction(r) != null,
            )
            .length +
        session.savedDuplicates.length +
        rejected.length;

    final excludedCount =
        session.rows.length - selected.length + rejected.length;
    final visible = [
      for (var i = 0; i < session.rows.length; i++)
        if (_filter == 'All' ||
            (_filter == 'Ready' && selected.contains(i)) ||
            (_filter == 'Needs review' &&
                (session.savedDuplicates.containsKey(i) ||
                    session.rows[i].reviewReasons.isNotEmpty ||
                    validateImportedTransaction(session.rows[i]) != null)) ||
            (_filter == 'Skipped' &&
                session.excluded.contains(i) &&
                !session.savedDuplicates.containsKey(i) &&
                session.rows[i].reviewReasons.isEmpty &&
                validateImportedTransaction(session.rows[i]) == null) ||
            (_filter == 'Money in' && session.rows[i].isCredit) ||
            (_filter == 'Money out' &&
                !session.rows[i].isCredit &&
                !session.rows[i].isTransfer &&
                !session.rows[i].isInvestment) ||
            (_filter == 'Investments' && session.rows[i].isInvestment) ||
            (_filter == 'Transfers' && session.rows[i].isTransfer) ||
            (_filter == 'Duplicates' && session.savedDuplicates.containsKey(i)))
          i,
    ];
    final visibleRejected = ['All', 'Needs review'].contains(_filter)
        ? rejected
        : <ImportRejectedRow>[];
    return PopScope(
      canPop: !session.submitting && !_preparingContinuation,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: 1 + visible.length + visibleRejected.length,
              itemBuilder: (context, position) {
                if (position == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Detected transactions',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text('${session.rows.length} transactions found'),
                      Text(
                        '${selected.length} selected · money out ₹${(selectedOutPaise / 100).toStringAsFixed(2)} · money in ₹${(selectedInPaise / 100).toStringAsFixed(2)}',
                      ),
                      Text(
                        '${session.rows.where((r) => !r.isCredit && !r.isTransfer && !r.isInvestment).length} money out · ${session.rows.where((r) => r.isCredit && !r.isInvestment).length} money in · ${session.rows.where((r) => r.isTransfer).length} transfers · ${session.rows.where((r) => r.isInvestment).length} investments · $unresolved need review',
                      ),
                      Card(
                        child: ListTile(
                          leading: Icon(
                            Icons.rule,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          title: Text(
                            '$unresolved rows need review · $excludedCount not selected',
                          ),
                          subtitle: const Text(
                            'Review the reason, correct the row, keep a possible duplicate, or skip it. Recognized transactions are selected automatically.',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => setState(() => _filter = 'Needs review'),
                        ),
                      ),
                      if (_checking) const LinearProgressIndicator(),
                      Text(
                        _checking
                            ? 'Checking saved transactions…'
                            : _savedCheckUnavailable
                            ? 'Saved transaction check unavailable. The server still checks for duplicates during import.'
                            : 'Possible saved duplicates: ${session.savedDuplicates.length}. Review each match before importing.',
                      ),
                      if (_duplicateError != null) Text(_duplicateError!),
                      TextButton(
                        onPressed: locked || _checking
                            ? null
                            : _checkDuplicates,
                        child: const Text('Recheck saved transactions'),
                      ),
                      TextField(
                        key: const ValueKey('import-default-tags'),
                        controller: _defaultTags,
                        enabled: !locked,
                        decoration: InputDecoration(
                          labelText: 'Tags for entire import (optional)',
                          helperText:
                              'Added to every imported row alongside its source tags. Separate names with semicolons, or paste a JSON list.',
                          helperMaxLines: 3,
                          errorText: session.defaultTagsError,
                        ),
                        onChanged: (value) => setState(
                          () => session.setDefaultTags(
                            parseImportedTagNames(value),
                          ),
                        ),
                      ),
                      TextButton.icon(
                        key: const ValueKey('import-tag-selected'),
                        onPressed: locked || selected.isEmpty
                            ? null
                            : _tagSelected,
                        icon: const Icon(Icons.label_outline),
                        label: Text('Tag ${selected.length} selected rows'),
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final filter in [
                            'All',
                            'Ready',
                            'Needs review',
                            'Skipped',
                            'Money in',
                            'Money out',
                            'Investments',
                            'Transfers',
                            'Duplicates',
                          ])
                            ChoiceChip(
                              label: Text(filter),
                              selected: _filter == filter,
                              onSelected: (_) =>
                                  setState(() => _filter = filter),
                            ),
                        ],
                      ),
                      if (visible.isEmpty && visibleRejected.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'No transactions in this filter. Choose All to see the full preview.',
                          ),
                        ),
                      for (final warning in session.statement.warnings.toSet())
                        Text(
                          warning,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      if (widget.configure != null)
                        TextButton.icon(
                          onPressed: locked ? null : widget.configure,
                          icon: const Icon(Icons.tune),
                          label: const Text('Columns and formats'),
                        ),
                      if (session.accounts.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 8, bottom: 2),
                          child: Text('Statement accounts'),
                        ),
                      for (final account in session.accounts)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              DropdownButtonFormField<String>(
                                key: ValueKey('destination:$account'),
                                initialValue: session.destinations[account],
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: account,
                                  helperText: session.destinationNotes[account],
                                ),
                                items: [
                                  const DropdownMenuItem(
                                    value: '',
                                    child: Text(
                                      'Other account (no linked card)',
                                    ),
                                  ),
                                  const DropdownMenuItem(
                                    value: 'instrument:cash',
                                    child: Text('Cash (unlinked)'),
                                  ),
                                  const DropdownMenuItem(
                                    value: 'instrument:upi_bank',
                                    child: Text(
                                      'Bank account / UPI (unlinked)',
                                    ),
                                  ),
                                  const DropdownMenuItem(
                                    value: 'instrument:wallet',
                                    child: Text('Digital wallet (unlinked)'),
                                  ),
                                  const DropdownMenuItem(
                                    value: 'instrument:credit_card',
                                    child: Text('Credit card (unlinked)'),
                                  ),
                                  const DropdownMenuItem(
                                    value: 'instrument:debit_card',
                                    child: Text('Debit card (unlinked)'),
                                  ),
                                  const DropdownMenuItem(
                                    value: 'instrument:other',
                                    child: Text(
                                      'Other account (no linked card)',
                                    ),
                                  ),
                                  if (session.destinations[account]?.startsWith(
                                            'instrument:',
                                          ) !=
                                          true &&
                                      session
                                              .destinations[account]
                                              ?.isNotEmpty ==
                                          true &&
                                      !(cards.valueOrNull ?? []).any(
                                        (card) =>
                                            card.id ==
                                            session.destinations[account],
                                      ))
                                    const DropdownMenuItem(
                                      value: 'missing-card',
                                      enabled: false,
                                      child: Text(
                                        'Previously selected card (unavailable)',
                                      ),
                                    ),
                                  for (final card in cards.valueOrNull ?? [])
                                    DropdownMenuItem(
                                      value: card.id,
                                      child: Text(
                                        card.nickname?.isNotEmpty == true
                                            ? card.nickname!
                                            : card.cardName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: locked
                                    ? null
                                    : (value) => setState(() {
                                        if (value == null) return;
                                        session.destinations[account] = value;
                                        if (value.startsWith('instrument:')) {
                                          session.instruments[account] =
                                              TxnInstrument.values.firstWhere(
                                                (type) =>
                                                    type.wireValue ==
                                                    value.substring(
                                                      'instrument:'.length,
                                                    ),
                                              );
                                          session.destinationNotes[account] =
                                              'Saved as ${session.instruments[account]!.label.toLowerCase()} without linking a card.';
                                        } else {
                                          final matchingCards =
                                              (cards.valueOrNull ?? [])
                                                  .where(
                                                    (item) => item.id == value,
                                                  )
                                                  .toList();
                                          final card = matchingCards.isEmpty
                                              ? null
                                              : matchingCards.first;
                                          session.instruments[account] =
                                              card?.cardType == 'credit'
                                              ? TxnInstrument.creditCard
                                              : TxnInstrument.debitCard;
                                          session.destinationNotes[account] =
                                              card == null
                                              ? 'The saved card is unavailable. Choose another account type.'
                                              : 'Linked to ${card.nickname?.isNotEmpty == true ? card.nickname : card.cardName}.';
                                        }
                                        session.checkSavedDuplicates(_saved);
                                      }),
                              ),
                            ],
                          ),
                        ),
                      if (cards.hasError)
                        Text(
                          'Cards could not be loaded. An unlinked account is available; retry the card list before assigning a card.',
                        ),
                      if (cards.hasError)
                        TextButton(
                          onPressed: () => ref.invalidate(userCardsProvider),
                          child: const Text('Reload cards'),
                        ),
                      if (cards.isLoading) const LinearProgressIndicator(),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: locked
                                ? null
                                : () => setState(() {
                                    session.excluded.clear();
                                  }),
                            child: const Text('Select all ready transactions'),
                          ),
                          TextButton(
                            onPressed: locked
                                ? null
                                : () => setState(() {
                                    session.excluded.addAll(
                                      List.generate(
                                        session.rows.length,
                                        (i) => i,
                                      ),
                                    );
                                  }),
                            child: const Text('Deselect all'),
                          ),
                        ],
                      ),
                    ],
                  );
                }
                final offset = position - 1;
                if (offset >= visible.length) {
                  final rejectedRow = visibleRejected[offset - visible.length];
                  return ListTile(
                    title: Text('Unrecognized: ${rejectedRow.sourceRowId}'),
                    subtitle: Text(
                      '${rejectedRow.reason}\n${rejectedRow.cells.join(' | ')}',
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: TextButton(
                      onPressed: locked
                          ? null
                          : () => _edit(null, rejected: rejectedRow),
                      child: const Text('Correct'),
                    ),
                  );
                }
                final rowIndex = visible[offset];
                final row = session.rows[rowIndex];
                final issue = session.exclusionReason(rowIndex);
                return _ImportTransactionCard(
                  key: ValueKey('import-row-$rowIndex'),
                  row: row,
                  tagNames: normalizeImportedTagNames([
                    ...row.tagNames,
                    ...session.defaultTagNames,
                  ]),
                  categories: categories,
                  instrument:
                      row.instrument ??
                      session.instruments[session.accountFor(row)],
                  amount: '₹${row.amount.rupees.toStringAsFixed(2)}',
                  date: DateFormat('d MMM').format(row.date),
                  sourceLabel: _sourceLabel(session.importSource),
                  accountLabel: session.accountFor(row),
                  sourceRow: row.sourceRowId ?? 'Source row ${rowIndex + 1}',
                  kindLabel: row.isTransfer
                      ? 'Transfer'
                      : row.isInvestment
                      ? 'Investment'
                      : row.isCredit
                      ? 'Money in'
                      : 'Money out',
                  issue: issue,
                  selected: selected.contains(rowIndex),
                  canSelect: session.eligible(rowIndex),
                  duplicate: session.savedDuplicates.containsKey(rowIndex),
                  locked: locked,
                  onSelectionChanged: (value) => setState(() {
                    if (value) {
                      session.excluded.remove(rowIndex);
                    } else {
                      session.excluded.add(rowIndex);
                    }
                  }),
                  onEdit: () => _edit(rowIndex),
                  onKeepBoth: () =>
                      setState(() => session.confirmSeparate(rowIndex)),
                );
              },
            ),
          ),
          if (excludedCount > 0 && !locked)
            TextButton.icon(
              onPressed: () => setState(() => _filter = 'Needs review'),
              icon: const Icon(Icons.edit_note),
              label: const Text('Review rows needing attention'),
            ),
          if (excludedCount > 0)
            Text(
              '$unresolved rows need review. $excludedCount rows are not selected; correct, include, or skip them. All selected transaction types will be imported.',
            ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (session.reviewLocked) ...[
            Text(
              session.submitting && session.progress.totalBatches == 0
                  ? 'Preparing import…'
                  : '${session.progress.completedBatches}/${session.progress.totalBatches} batches · ${session.progress.description}',
            ),
            if (session.submitting) const LinearProgressIndicator(),
          ],
          if (!session.ready && selected.isNotEmpty)
            const Text(
              'Choose a destination for every selected source account.',
            ),
          if (ref.watch(importRepositoryProvider) == null)
            const Text(
              'Sign in and connect before importing. Your preview stays on this device.',
            ),
          SafeArea(
            top: false,
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed:
                    _checking ||
                        session.submitting ||
                        _preparingContinuation ||
                        !session.ready ||
                        ref.watch(importRepositoryProvider) == null
                    ? null
                    : _submit,
                child: Text(
                  session.hasCommittedBatches && _error != null
                      ? 'Retry remaining import'
                      : excludedCount > 0
                      ? 'Import ${selected.length} transactions · skip $excludedCount'
                      : 'Import ${selected.length} transactions',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _sourceLabel(String source) {
  final normalized = source.toLowerCase();
  if (normalized.contains('pdf')) return 'PDF statement';
  if (normalized.contains('csv')) return 'CSV statement';
  if (normalized.contains('image') || normalized.contains('screenshot')) {
    return 'Screenshot';
  }
  if (normalized.contains('sheet') || normalized.contains('excel')) {
    return 'Spreadsheet';
  }
  return source.isEmpty ? 'Imported statement' : source;
}

String _railLabel(String rail) => switch (rail) {
  'upi_qr' => 'UPI QR',
  'swipe' => 'Card swipe',
  'online' => 'Online',
  'contactless' => 'Contactless',
  'atm' => 'ATM',
  'emi' => 'EMI',
  _ => 'Unknown rail',
};

String _rowCategoryLabel(
  ParsedStatementLine row,
  List<SpendCategory> categories,
) {
  final selectedId = row.userCategoryId == null
      ? row.categoryId
      : 'custom:${row.userCategoryId}';
  final selected = categories.where((category) => category.id == selectedId);
  if (selected.isNotEmpty) {
    return _qualifiedCategoryName(selected.first, categories);
  }
  final parts = [row.categoryHint, row.subcategoryHint]
      .whereType<String>()
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();
  if (parts.isNotEmpty) return 'Category from source: ${parts.join(' · ')}';
  return 'Category: automatic classification during import';
}

String _qualifiedCategoryName(
  SpendCategory category,
  List<SpendCategory> categories,
) {
  if (!category.isSubcategory) return category.name;
  final parentId = category.parentCategoryId ?? category.parentUserCategoryId;
  final parent = categories.where((candidate) => candidate.id == parentId);
  return parent.isEmpty
      ? category.name
      : '${parent.first.name} · ${category.name}';
}

class _ImportTransactionCard extends StatelessWidget {
  final ParsedStatementLine row;
  final List<String> tagNames;
  final List<SpendCategory> categories;
  final TxnInstrument? instrument;
  final String amount, date, sourceLabel, accountLabel, sourceRow, kindLabel;
  final String? issue;
  final bool selected, canSelect, duplicate, locked;
  final ValueChanged<bool> onSelectionChanged;
  final VoidCallback onEdit, onKeepBoth;

  const _ImportTransactionCard({
    super.key,
    required this.row,
    required this.tagNames,
    required this.categories,
    required this.instrument,
    required this.amount,
    required this.date,
    required this.sourceLabel,
    required this.accountLabel,
    required this.sourceRow,
    required this.kindLabel,
    required this.issue,
    required this.selected,
    required this.canSelect,
    required this.duplicate,
    required this.locked,
    required this.onSelectionChanged,
    required this.onEdit,
    required this.onKeepBoth,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final ready = issue == null;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: Colors.white,
      elevation: 1,
      shadowColor: BambooInk.ink900.withValues(alpha: .06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFF0F1F5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: locked || !canSelect
                      ? null
                      : () => onSelectionChanged(!selected),
                  child: Container(
                    margin: const EdgeInsets.only(top: 1),
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: selected ? BambooInk.jade : Colors.transparent,
                      border: Border.all(
                        color: selected ? BambooInk.jade : muted,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: selected
                        ? const Icon(
                            Icons.check_rounded,
                            size: 24,
                            color: Colors.white,
                          )
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    row.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: BambooFonts.heading(17, color: BambooInk.ink900),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    amount,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: BambooFonts.heading(17, color: BambooInk.ink900),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 42, top: 5),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 7,
                runSpacing: 2,
                children: [
                  Icon(
                    sourceLabel == 'Screenshot'
                        ? Icons.smartphone_rounded
                        : sourceLabel == 'PDF statement'
                        ? Icons.picture_as_pdf_outlined
                        : Icons.receipt_long_outlined,
                    size: 16,
                    color: muted,
                  ),
                  Text(sourceLabel, style: BambooFonts.ui(14, color: muted)),
                  Text('•', style: BambooFonts.ui(14, color: muted)),
                  Text(date, style: BambooFonts.ui(14, color: muted)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 42, top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$sourceRow  •  ${ready ? 'Ready to import' : 'Needs review'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(
                        12.5,
                        color: ready
                            ? BambooInk.ink500
                            : const Color(0xFFAA3A32),
                      ),
                    ),
                  ),
                  if (duplicate)
                    TextButton(
                      onPressed: locked ? null : onKeepBoth,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Keep both'),
                    ),
                ],
              ),
            ),
            if (issue != null)
              Padding(
                padding: const EdgeInsets.only(left: 42, top: 2),
                child: Text(
                  issue!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(12.5, color: const Color(0xFFAA3A32)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 42, top: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.category_outlined, size: 15, color: muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _rowCategoryLabel(row, categories),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(12.5, color: muted),
                    ),
                  ),
                ],
              ),
            ),
            if (row.note?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(left: 42, top: 3),
                child: Text(
                  'Note: ${row.note}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(12, color: muted),
                ),
              ),
            if (row.bankReference?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(left: 42, top: 3),
                child: Text(
                  'Bank reference: ${row.bankReference}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(12, color: muted),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 42, top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _ImportInfoChip(
                          label: kindLabel,
                          foreground: BambooInk.ink900,
                          background: const Color(0xFFE9EDFF),
                          icon: row.isTransfer
                              ? Icons.swap_horiz_rounded
                              : row.isInvestment
                              ? Icons.trending_up_rounded
                              : row.isCredit
                              ? Icons.south_west_rounded
                              : Icons.north_east_rounded,
                        ),
                        _ImportInfoChip(
                          label: accountLabel,
                          foreground: BambooInk.ink700,
                          background: const Color(0xFFF0F2FA),
                          icon: Icons.account_balance_wallet_outlined,
                        ),
                        if (instrument != null)
                          _ImportInfoChip(
                            label: instrument!.label,
                            foreground: BambooInk.ink700,
                            background: const Color(0xFFF0F2FA),
                            icon: Icons.credit_card_outlined,
                          ),
                        if (row.rail != null)
                          _ImportInfoChip(
                            label: _railLabel(row.rail!),
                            foreground: BambooInk.ink700,
                            background: const Color(0xFFF0F2FA),
                            icon: Icons.payment_outlined,
                          ),
                        for (final tag in tagNames)
                          _ImportInfoChip(
                            label: tag,
                            foreground: BambooInk.jade,
                            background: BambooInk.paperMuted,
                            icon: Icons.label_outline,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('import-edit-transaction'),
                    tooltip: 'Edit transaction',
                    onPressed: locked ? null : onEdit,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined, size: 22),
                    color: BambooInk.ink700,
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

class _ImportInfoChip extends StatelessWidget {
  final String label;
  final Color foreground;
  final Color background;
  final IconData icon;
  const _ImportInfoChip({
    required this.label,
    required this.foreground,
    required this.background,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 190),
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: foreground),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: BambooFonts.ui(13, color: foreground),
          ),
        ),
      ],
    ),
  );
}

class _EditImportRow extends StatefulWidget {
  final ParsedStatementLine? row;
  final List<SpendCategory> categories;
  final String? raw;
  final String? reason;
  const _EditImportRow({
    this.row,
    this.categories = const [],
    this.raw,
    this.reason,
  });
  @override
  State<_EditImportRow> createState() => _EditImportRowState();
}

class _EditImportRowState extends State<_EditImportRow> {
  late final _date = TextEditingController(
    text: widget.row?.date.toIso8601String() ?? '',
  );
  late final _description = TextEditingController(
    text: widget.row?.description ?? '',
  );
  late final _amount = TextEditingController(
    text: widget.row?.amount.rupees.toStringAsFixed(2) ?? '',
  );
  late final _sourceAccount = TextEditingController(
    text: widget.row?.sourceAccount ?? '',
  );
  late final _bankReference = TextEditingController(
    text: widget.row?.bankReference ?? '',
  );
  late final _categoryHint = TextEditingController(
    text: widget.row?.categoryHint ?? '',
  );
  late final _subcategoryHint = TextEditingController(
    text: widget.row?.subcategoryHint ?? '',
  );
  late final _tags = TextEditingController(
    text: widget.row?.tagNames.isNotEmpty == true
        ? jsonEncode(widget.row!.tagNames)
        : '',
  );
  late final _note = TextEditingController(text: widget.row?.note ?? '');
  late var _kind = widget.row?.isTransfer == true
      ? 'transfer'
      : widget.row?.isInvestment == true
      ? 'investment'
      : widget.row?.isCredit == true
      ? 'income'
      : 'spend';
  late String? _selectedCategoryId = _initialCategoryId();
  late TxnInstrument? _instrument = widget.row?.instrument;
  late String? _rail = widget.row?.rail;
  String? _error;
  final Set<String> _confirmedReviewFields = {};

  String? get _dateError {
    final text = _date.text.trim();
    final parts = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:$|T| )').firstMatch(text);
    final date = DateTime.tryParse(text);
    if (date == null ||
        parts == null ||
        date.year != int.parse(parts.group(1)!) ||
        date.month != int.parse(parts.group(2)!) ||
        date.day != int.parse(parts.group(3)!) ||
        date.year < 1900 ||
        date.year > 2100) {
      return 'Enter a real date between 1900 and 2100.';
    }
    return null;
  }

  String? get _amountError {
    final text = _amount.text.trim();
    final value = double.tryParse(text);
    if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(text) ||
        value == null ||
        !value.isFinite ||
        value <= 0 ||
        value > 9999999999.99) {
      return 'Enter a positive amount with up to two decimals.';
    }
    return null;
  }

  Map<String, String?> get _fieldErrors {
    final reference = _bankReference.text.trim();
    final tags = parseImportedTagNames(_tags.text);
    final reviewHint = [
      ...?widget.row?.reviewReasons,
      if (widget.reason != null) widget.reason!,
    ].join(' ').toLowerCase();
    final dateNeedsReview =
        reviewHint.contains('date') || reviewHint.contains('day/month');
    final amountNeedsReview =
        reviewHint.contains('amount') ||
        reviewHint.contains('numeric column') ||
        reviewHint.contains('payable');
    final descriptionNeedsReview =
        reviewHint.contains('description') ||
        reviewHint.contains('merchant') ||
        reviewHint.contains('narration');
    return {
      'date':
          _dateError ??
          (dateNeedsReview && !_confirmedReviewFields.contains('date')
              ? 'Check this date against the source document.'
              : null),
      'description':
          _description.text.trim().isEmpty || _description.text.length > 500
          ? 'Enter a description with 1–500 characters.'
          : descriptionNeedsReview &&
                !_confirmedReviewFields.contains('description')
          ? 'Check this description against the source document.'
          : null,
      'amount':
          _amountError ??
          (amountNeedsReview && !_confirmedReviewFields.contains('amount')
              ? 'Check this amount against the source document.'
              : null),
      'sourceAccount': _sourceAccount.text.length > 200
          ? 'Use 200 characters or fewer.'
          : null,
      'bankReference':
          reference.isNotEmpty &&
              !RegExp(r'^[a-zA-Z0-9-]{6,40}$').hasMatch(reference)
          ? 'Use 6–40 letters, numbers, or hyphens.'
          : null,
      'categoryHint': _categoryHint.text.length > 120
          ? 'Use 120 characters or fewer.'
          : null,
      'subcategoryHint': _subcategoryHint.text.length > 120
          ? 'Use 120 characters or fewer.'
          : null,
      'tags': tags.length > 30 || tags.any((name) => name.length > 60)
          ? 'Use up to 30 tags, each with 1–60 characters.'
          : null,
      'note': _note.text.length > 500 ? 'Use 500 characters or fewer.' : null,
    };
  }

  InputDecoration _fieldDecoration(
    String label, {
    String? errorText,
    String? helperText,
    int? helperMaxLines,
  }) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(
        color: errorText == null ? BambooInk.hairlineOnPaper : AppColors.error,
        width: errorText == null ? 1 : 1.6,
      ),
    );
    return InputDecoration(
      labelText: label,
      helperText: helperText,
      helperMaxLines: helperMaxLines,
      errorText: errorText,
      errorStyle: BambooFonts.ui(12, color: AppColors.error),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(
          color: errorText == null ? BambooInk.slate : AppColors.error,
          width: 1.6,
        ),
      ),
      errorBorder: border.copyWith(
        borderSide: const BorderSide(color: AppColors.error, width: 1.6),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: const BorderSide(color: AppColors.error, width: 1.8),
      ),
    );
  }

  String? _initialCategoryId() {
    final row = widget.row;
    if (row == null) return null;
    if (row.userCategoryId != null) return 'custom:${row.userCategoryId}';
    if (row.categoryId != null) return row.categoryId;
    final categoryHint = row.categoryHint?.trim().toLowerCase();
    final subcategoryHint = row.subcategoryHint?.trim().toLowerCase();
    if (subcategoryHint?.isNotEmpty == true) {
      for (final category in widget.categories) {
        if (!category.isSubcategory ||
            category.name.toLowerCase() != subcategoryHint) {
          continue;
        }
        final parentId =
            category.parentCategoryId ?? category.parentUserCategoryId;
        final parent = widget.categories.where((item) => item.id == parentId);
        if (parent.isNotEmpty &&
            parent.first.name.toLowerCase() == categoryHint) {
          return category.id;
        }
      }
    }
    if (categoryHint?.isNotEmpty == true) {
      for (final category in widget.categories) {
        if (!category.isSubcategory &&
            category.name.toLowerCase() == categoryHint) {
          return category.id;
        }
      }
    }
    return null;
  }

  void _selectCategory(String? value) {
    setState(() {
      _selectedCategoryId = value;
      if (value == null) {
        _categoryHint.clear();
        _subcategoryHint.clear();
        return;
      }
      final match = widget.categories.where((category) => category.id == value);
      if (match.isEmpty) return;
      final category = match.first;
      if (category.isSubcategory) {
        final parentId =
            category.parentCategoryId ?? category.parentUserCategoryId;
        final parent = widget.categories.where((item) => item.id == parentId);
        _categoryHint.text = parent.isEmpty ? '' : parent.first.name;
        _subcategoryHint.text = category.name;
      } else {
        _categoryHint.text = category.name;
        _subcategoryHint.clear();
      }
    });
  }

  @override
  void dispose() {
    _date.dispose();
    _description.dispose();
    _amount.dispose();
    _sourceAccount.dispose();
    _bankReference.dispose();
    _categoryHint.dispose();
    _subcategoryHint.dispose();
    _tags.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final fieldErrors = _fieldErrors;
    final firstFieldError = fieldErrors.values.whereType<String>().firstOrNull;
    if (firstFieldError != null) {
      setState(() => _error = firstFieldError);
      return;
    }
    final date = DateTime.tryParse(_date.text.trim());
    final money = _amount.text.trim();
    final value = double.tryParse(money);
    if (date == null || value == null) return;
    final selectedCategory = widget.categories
        .where((category) => category.id == _selectedCategoryId)
        .firstOrNull;
    final bankReference = _bankReference.text.trim();
    final row = ParsedStatementLine(
      date: date,
      description: _description.text.trim(),
      amount: Money.fromRupees(value),
      isCredit: _kind == 'income',
      isTransfer: _kind == 'transfer',
      isInvestment: _kind == 'investment',
      sourceAccount: _sourceAccount.text.trim().isEmpty
          ? null
          : _sourceAccount.text.trim(),
      bankReference: bankReference.isEmpty ? null : bankReference,
      categoryHint: _categoryHint.text.trim().isEmpty
          ? null
          : _categoryHint.text.trim(),
      subcategoryHint: _subcategoryHint.text.trim().isEmpty
          ? null
          : _subcategoryHint.text.trim(),
      tagNames: parseImportedTagNames(_tags.text),
      categoryId: selectedCategory == null
          ? null
          : categoryIdForServer(selectedCategory.id, widget.categories),
      userCategoryId: selectedCategory == null
          ? null
          : userCategoryIdForServer(selectedCategory.id),
      instrument: _instrument,
      rail: _rail,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      sourceRowId: widget.row?.sourceRowId,
    );
    final error = validateImportedTransaction(row);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(row);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final fieldErrors = _fieldErrors;
    final maxDialogHeight = (media.size.height - media.viewInsets.bottom - 40)
        .clamp(260.0, 760.0);
    const fieldGap = SizedBox(height: 14);

    return Dialog(
      key: const ValueKey('import-edit-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      backgroundColor: BambooInk.paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SizedBox(
        key: const ValueKey('import-edit-dialog-panel'),
        width: double.infinity,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxDialogHeight),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 16, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Review transaction',
                        style: BambooFonts.heading(21),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
                  child: Column(
                    children: [
                      if (widget.reason != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: BambooInk.paperMuted,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.reason!,
                                style: BambooFonts.ui(
                                  14,
                                  weight: FontWeight.w600,
                                  color: BambooInk.clay,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Check the original statement, correct any fields or transaction type, then save. The reviewed row is included automatically.',
                                style: BambooFonts.ui(
                                  13,
                                  color: BambooInk.ink500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        fieldGap,
                      ],
                      if (widget.raw != null) ...[
                        SelectableText(widget.raw!),
                        fieldGap,
                      ],
                      TextField(
                        controller: _date,
                        onChanged: (_) => setState(() {
                          _confirmedReviewFields.add('date');
                          _error = null;
                        }),
                        decoration: _fieldDecoration(
                          'Date (YYYY-MM-DD, optional time)',
                          errorText: fieldErrors['date'],
                        ),
                      ),
                      fieldGap,
                      TextField(
                        controller: _description,
                        onChanged: (_) => setState(() {
                          _confirmedReviewFields.add('description');
                          _error = null;
                        }),
                        decoration: _fieldDecoration(
                          'Description',
                          errorText: fieldErrors['description'],
                        ),
                      ),
                      fieldGap,
                      TextField(
                        controller: _amount,
                        onChanged: (_) => setState(() {
                          _confirmedReviewFields.add('amount');
                          _error = null;
                        }),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: _fieldDecoration(
                          'Amount (INR)',
                          errorText: fieldErrors['amount'],
                        ),
                      ),
                      fieldGap,
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _kind,
                        decoration: const InputDecoration(
                          labelText: 'Transaction type',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'spend',
                            child: Text('Money out'),
                          ),
                          DropdownMenuItem(
                            value: 'income',
                            child: Text('Money in'),
                          ),
                          DropdownMenuItem(
                            value: 'investment',
                            child: Text('Investment'),
                          ),
                          DropdownMenuItem(
                            value: 'transfer',
                            child: Text('Transfer'),
                          ),
                        ],
                        onChanged: (value) => setState(() => _kind = value!),
                      ),
                      fieldGap,
                      TextField(
                        controller: _sourceAccount,
                        maxLength: 200,
                        onChanged: (_) => setState(() => _error = null),
                        decoration: _fieldDecoration(
                          'Source account / card label',
                          helperText:
                              'The account shown on the original statement.',
                          helperMaxLines: 2,
                          errorText: fieldErrors['sourceAccount'],
                        ),
                      ),
                      fieldGap,
                      TextField(
                        controller: _bankReference,
                        maxLength: 40,
                        onChanged: (_) => setState(() => _error = null),
                        decoration: _fieldDecoration(
                          'Bank reference (optional)',
                          helperText: '6–40 letters, numbers, or hyphens.',
                          helperMaxLines: 2,
                          errorText: fieldErrors['bankReference'],
                        ),
                      ),
                      fieldGap,
                      DropdownButtonFormField<String?>(
                        key: const ValueKey('import-edit-category'),
                        isExpanded: true,
                        initialValue: _selectedCategoryId,
                        decoration: const InputDecoration(
                          labelText: 'PandaPay category',
                          helperText:
                              'Choose a category, or use automatic classification.',
                          helperMaxLines: 2,
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Automatic classification'),
                          ),
                          for (final category in widget.categories)
                            DropdownMenuItem<String?>(
                              value: category.id,
                              child: Text(
                                _qualifiedCategoryName(
                                  category,
                                  widget.categories,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _selectCategory,
                      ),
                      fieldGap,
                      TextField(
                        controller: _categoryHint,
                        maxLength: 120,
                        onChanged: (_) {
                          if (_selectedCategoryId != null) {
                            setState(() => _selectedCategoryId = null);
                          } else {
                            setState(() => _error = null);
                          }
                        },
                        decoration: _fieldDecoration(
                          'Category from source (optional)',
                          errorText: fieldErrors['categoryHint'],
                        ),
                      ),
                      fieldGap,
                      TextField(
                        controller: _subcategoryHint,
                        maxLength: 120,
                        onChanged: (_) {
                          if (_selectedCategoryId != null) {
                            setState(() => _selectedCategoryId = null);
                          } else {
                            setState(() => _error = null);
                          }
                        },
                        decoration: _fieldDecoration(
                          'Subcategory from source (optional)',
                          errorText: fieldErrors['subcategoryHint'],
                        ),
                      ),
                      fieldGap,
                      TextField(
                        key: const ValueKey('import-edit-tags'),
                        controller: _tags,
                        onChanged: (_) => setState(() => _error = null),
                        decoration: _fieldDecoration(
                          'Tags (optional)',
                          helperText:
                              'Separate names with semicolons, or paste a JSON list.',
                          helperMaxLines: 2,
                          errorText: fieldErrors['tags'],
                        ),
                      ),
                      fieldGap,
                      DropdownButtonFormField<TxnInstrument?>(
                        isExpanded: true,
                        initialValue: _instrument,
                        decoration: const InputDecoration(
                          labelText: 'Paid with',
                        ),
                        items: [
                          const DropdownMenuItem<TxnInstrument?>(
                            value: null,
                            child: Text('Use account mapping'),
                          ),
                          for (final instrument in TxnInstrument.values)
                            DropdownMenuItem<TxnInstrument?>(
                              value: instrument,
                              child: Text(instrument.label),
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => _instrument = value),
                      ),
                      fieldGap,
                      DropdownButtonFormField<String?>(
                        isExpanded: true,
                        initialValue: _rail,
                        decoration: const InputDecoration(
                          labelText: 'Payment rail',
                        ),
                        items: const [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Not specified'),
                          ),
                          DropdownMenuItem<String?>(
                            value: 'upi_qr',
                            child: Text('UPI QR'),
                          ),
                          DropdownMenuItem<String?>(
                            value: 'swipe',
                            child: Text('Card swipe'),
                          ),
                          DropdownMenuItem<String?>(
                            value: 'online',
                            child: Text('Online'),
                          ),
                          DropdownMenuItem<String?>(
                            value: 'contactless',
                            child: Text('Contactless'),
                          ),
                          DropdownMenuItem<String?>(
                            value: 'atm',
                            child: Text('ATM'),
                          ),
                          DropdownMenuItem<String?>(
                            value: 'emi',
                            child: Text('EMI'),
                          ),
                          DropdownMenuItem<String?>(
                            value: 'unknown',
                            child: Text('Unknown'),
                          ),
                        ],
                        onChanged: (value) => setState(() => _rail = value),
                      ),
                      fieldGap,
                      TextField(
                        controller: _note,
                        maxLength: 500,
                        maxLines: 2,
                        onChanged: (_) => setState(() => _error = null),
                        decoration: _fieldDecoration(
                          'Note / remarks (optional)',
                          errorText: fieldErrors['note'],
                        ),
                      ),
                      if (_error != null) ...[
                        fieldGap,
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _error!,
                            style: BambooFonts.ui(13, color: BambooInk.clay),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _save,
                        child: const Text('Save reviewed row'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
