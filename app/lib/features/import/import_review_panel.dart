import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/providers.dart';
import '../../data/api_exception.dart';
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
  bool _done = false;
  String _filter = 'All';
  List<TransactionEntry> _saved = [];
  bool _checking = false;
  bool _savedCheckUnavailable = false;
  bool _destinationsSuggested = false;
  String? _duplicateError;

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
    if (repository == null || session.submitting) return;
    setState(() => _error = null);
    try {
      final future = session.submit(
        repository,
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
      if (mounted) setState(() => _done = true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              '${userFacingErrorMessage(error)} Your reviewed rows are retained. Retry continues safely.',
        );
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _edit(int? index, {ImportRejectedRow? rejected}) async {
    final row = index == null ? null : session.rows[index];
    final edited = await showDialog<ParsedStatementLine>(
      context: context,
      builder: (_) => _EditImportRow(
        row: row,
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
      canPop: !session.submitting,
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
                return ListTile(
                  leading: Checkbox(
                    value: selected.contains(rowIndex),
                    onChanged: locked || !session.eligible(rowIndex)
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              session.excluded.remove(rowIndex);
                            } else {
                              session.excluded.add(rowIndex);
                            }
                          }),
                  ),
                  title: Text(row.description),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${row.isTransfer
                            ? 'Transfer'
                            : row.isInvestment
                            ? 'Investment'
                            : row.isCredit
                            ? 'Money in'
                            : 'Money out'} · ${row.date.toIso8601String().replaceFirst('T', ' ')} · ${session.accountFor(row)}',
                      ),
                      Text(row.sourceRowId ?? 'Source row ${rowIndex + 1}'),
                      Text(issue ?? 'Ready to import'),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 0,
                        children: [
                          if (session.savedDuplicates.containsKey(rowIndex))
                            TextButton(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              onPressed: locked
                                  ? null
                                  : () => setState(
                                      () => session.confirmSeparate(rowIndex),
                                    ),
                              child: const Text('Keep both'),
                            ),
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                            onPressed: locked ? null : () => _edit(rowIndex),
                            child: const Text('Edit'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  trailing: Text('₹${row.amount.rupees.toStringAsFixed(2)}'),
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

class _EditImportRow extends StatefulWidget {
  final ParsedStatementLine? row;
  final String? raw;
  final String? reason;
  const _EditImportRow({this.row, this.raw, this.reason});
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
  late var _kind = widget.row?.isTransfer == true
      ? 'transfer'
      : widget.row?.isInvestment == true
      ? 'investment'
      : widget.row?.isCredit == true
      ? 'income'
      : 'spend';
  String? _error;
  @override
  void dispose() {
    _date.dispose();
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _save() {
    final date = DateTime.tryParse(_date.text.trim());
    final parts = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})(?:$|T| )',
    ).firstMatch(_date.text.trim());
    final money = _amount.text.trim();
    final value = double.tryParse(money);
    if (date == null ||
        parts == null ||
        date.year != int.parse(parts.group(1)!) ||
        date.month != int.parse(parts.group(2)!) ||
        date.day != int.parse(parts.group(3)!) ||
        !RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(money) ||
        value == null ||
        !value.isFinite ||
        value <= 0 ||
        value > 9999999999.99) {
      setState(
        () => _error =
            'Use a real YYYY-MM-DD date and a positive INR amount with up to two decimals.',
      );
      return;
    }
    final row = ParsedStatementLine(
      date: date,
      description: _description.text.trim(),
      amount: Money.fromRupees(value),
      isCredit: _kind == 'income',
      isTransfer: _kind == 'transfer',
      isInvestment: _kind == 'investment',
      sourceAccount: widget.row?.sourceAccount,
      bankReference: widget.row?.bankReference,
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
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Review transaction'),
    content: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.65,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.reason != null) ...[
              Text(
                widget.reason!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 12),
              const Text(
                'Check the original statement, correct any fields or transaction type, then save. The reviewed row is included automatically. A possible duplicate can also be kept or skipped.',
              ),
            ],
            if (widget.raw != null) SelectableText(widget.raw!),
            TextField(
              controller: _date,
              decoration: const InputDecoration(
                labelText: 'Date (YYYY-MM-DD, optional time)',
              ),
            ),
            TextField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Amount (INR)'),
            ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _kind,
              items: const [
                DropdownMenuItem(value: 'spend', child: Text('Money out')),
                DropdownMenuItem(value: 'income', child: Text('Money in')),
                DropdownMenuItem(
                  value: 'investment',
                  child: Text('Investment'),
                ),
                DropdownMenuItem(value: 'transfer', child: Text('Transfer')),
              ],
              onChanged: (v) => _kind = v!,
            ),
            if (_error != null) Text(_error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save reviewed row')),
    ],
  );
}
