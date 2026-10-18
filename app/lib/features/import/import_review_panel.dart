import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/import_models.dart';
import '../../data/transaction_import_pipeline.dart';

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
      builder: (_) =>
          _EditImportRow(row: row, raw: rejected?.cells.join(' | ')),
    );
    if (edited == null || !mounted) return;
    setState(() {
      if (index == null) {
        session.addCorrectedRow(rejected!, edited);
      } else {
        session.replaceRow(index, edited);
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
                '${session.rows.length - session.selected.length} detected rows were excluded. ${rejected.length} unrecognized rows were not imported.',
              ),
              if (session.progress.duplicates > 0)
                const Text(
                  'Possible duplicates are held for review and excluded from spending until resolved.',
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
    final selected = session.selected.toSet();
    final unresolved = session.rows
        .where(
          (r) =>
              !r.isCredit &&
              !r.isTransfer &&
              validateImportedTransaction(r) != null,
        )
        .length;

    return PopScope(
      canPop: !session.submitting,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: 1 + session.rows.length + rejected.length,
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
                        '${selected.length} selected · ₹${(session.selectedPaise / 100).toStringAsFixed(2)}',
                      ),
                      Text(
                        '${session.rows.where((r) => r.isCredit).length} credits · ${session.rows.where((r) => !r.isCredit && r.isTransfer).length} transfers excluded · $unresolved need checking · ${rejected.length} unrecognized rows',
                      ),
                      const Text(
                        'Check dates and amounts. Map each source account to its matching card or Other spending. Credits and transfers are excluded from this spending import.',
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
                      for (final account in session.accounts)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('destination:$account'),
                            initialValue: session.destinations[account],
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: 'Destination: $account',
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('Other spending (no card)'),
                              ),
                              if (session.destinations[account]?.isNotEmpty ==
                                      true &&
                                  !(cards.valueOrNull ?? []).any(
                                    (card) =>
                                        card.id ==
                                        session.destinations[account],
                                  ))
                                DropdownMenuItem(
                                  value: session.destinations[account],
                                  enabled: false,
                                  child: const Text(
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
                                    if (value != null) {
                                      session.destinations[account] = value;
                                    }
                                  }),
                          ),
                        ),
                      if (cards.hasError)
                        Text(
                          'Cards could not be loaded. Other spending is available; retry the card list before assigning a card.',
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
                            child: const Text('Select valid spending'),
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
                final rowIndex = position - 1;
                if (rowIndex >= session.rows.length) {
                  final rejectedRow = rejected[rowIndex - session.rows.length];
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
                final row = session.rows[rowIndex];
                final issue = validateImportedTransaction(row);
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
                  subtitle: Text(
                    '${row.date.toIso8601String().replaceFirst('T', ' ')} · ${session.accountFor(row)}\n'
                    '${row.isCredit
                        ? 'Credit, excluded'
                        : row.isTransfer
                        ? 'Transfer, excluded'
                        : issue ?? 'Spending'}',
                  ),
                  trailing: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('₹${row.amount.rupees.toStringAsFixed(2)}'),
                      InkWell(
                        onTap: locked ? null : () => _edit(rowIndex),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Text(
                            'Edit',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
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
                    session.submitting ||
                        !session.ready ||
                        ref.watch(importRepositoryProvider) == null
                    ? null
                    : _submit,
                child: Text(
                  session.hasCommittedBatches && _error != null
                      ? 'Retry remaining import'
                      : 'Confirm import',
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
  const _EditImportRow({this.row, this.raw});
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
  late var _kind = widget.row?.isCredit == true
      ? 'credit'
      : widget.row?.isTransfer == true
      ? 'transfer'
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
      isCredit: _kind == 'credit',
      isTransfer: _kind == 'transfer',
      sourceAccount: widget.row?.sourceAccount,
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
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount (INR)'),
          ),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _kind,
            items: const [
              DropdownMenuItem(value: 'spend', child: Text('Spending')),
              DropdownMenuItem(
                value: 'credit',
                child: Text('Credit / income (excluded)'),
              ),
              DropdownMenuItem(
                value: 'transfer',
                child: Text('Transfer / repayment (excluded)'),
              ),
            ],
            onChanged: (v) => _kind = v!,
          ),
          if (_error != null) Text(_error!),
        ],
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
