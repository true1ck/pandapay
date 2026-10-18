import 'package:flutter/material.dart';

import '../../data/csv_statement_parser.dart';
import '../../data/import_models.dart';

class ImportMappingDialog extends StatefulWidget {
  final Map<String, List<List<String>>> tables;
  final Map<String, StatementTableOptions> options;
  const ImportMappingDialog({
    super.key,
    required this.tables,
    required this.options,
  });
  @override
  State<ImportMappingDialog> createState() => _ImportMappingDialogState();
}

class _ImportMappingDialogState extends State<ImportMappingDialog> {
  late final _options = Map<String, StatementTableOptions>.of(widget.options);
  late String _sheet = widget.tables.keys.firstOrNull ?? 'pdf';
  final _year = TextEditingController();
  final _headerInput = TextEditingController();
  ImportDateOrder? _dateOrder;
  ImportNumberFormat _numberFormat = ImportNumberFormat.decimalPoint;
  bool _negativeIsExpense = false;
  int _header = -1;
  Map<ImportColumn, int> _columns = {};
  String? _error;
  List<List<String>> get rows => widget.tables[_sheet] ?? [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final option = _options[_sheet] ?? const StatementTableOptions();
    _dateOrder = option.dateOrderConfirmed ? option.dateOrder : null;
    _numberFormat = option.numberFormat;
    _negativeIsExpense = option.negativeIsExpense;
    _year.text = option.year?.toString() ?? '';
    _header = option.headerRow ?? detectStatementHeader(rows) ?? -1;
    _headerInput.text = (_header + 1).toString();
    _columns = Map.of(option.columns);
  }

  void _store() {
    _options[_sheet] = StatementTableOptions(
      dateOrder: _dateOrder ?? ImportDateOrder.dayFirst,
      dateOrderConfirmed: _dateOrder != null,
      numberFormat: _numberFormat,
      negativeIsExpense: _negativeIsExpense,
      year: int.tryParse(_year.text),
      headerRow: _header,
      columns: Map.of(_columns),
    );
  }

  @override
  void dispose() {
    _year.dispose();
    _headerInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = <int>{..._columns.values.where((i) => i >= 0)};
    for (final row in [
      ...rows.take(200),
      if (_header >= 0 && _header < rows.length) rows[_header],
      if (_header + 1 >= 0 && _header + 1 < rows.length) rows[_header + 1],
    ]) {
      for (var i = 0; i < row.length; i++) {
        if (row[i].trim().isNotEmpty) active.add(i);
      }
    }
    final choices = active.toList()..sort();
    String label(int i) {
      final heading =
          _header >= 0 && _header < rows.length && i < rows[_header].length
          ? rows[_header][i]
          : '';
      final sampleIndex = _header + 1;
      final sample = sampleIndex < rows.length && i < rows[sampleIndex].length
          ? rows[sampleIndex][i]
          : '';
      return '${i + 1}: $heading${sample.isEmpty ? '' : ' · $sample'}';
    }

    return AlertDialog(
      title: const Text('Columns and formats'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Automatic detection is the starting point. Choose formats or map unfamiliar columns here. Applying changes reparses the file and resets row edits.',
              ),
              if (widget.tables.length > 1)
                DropdownButtonFormField<String>(
                  initialValue: _sheet,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Worksheet'),
                  items: [
                    for (final sheet in widget.tables.keys)
                      DropdownMenuItem(value: sheet, child: Text(sheet)),
                  ],
                  onChanged: (v) => setState(() {
                    _store();
                    _sheet = v!;
                    _load();
                  }),
                ),
              DropdownButtonFormField<ImportDateOrder>(
                isExpanded: true,
                key: ValueKey('date-order:$_sheet'),
                initialValue: _dateOrder,
                decoration: const InputDecoration(
                  labelText: 'Date order (confirm ambiguous dates)',
                ),
                items: const [
                  DropdownMenuItem(
                    value: ImportDateOrder.dayFirst,
                    child: Text('Day / Month / Year'),
                  ),
                  DropdownMenuItem(
                    value: ImportDateOrder.monthFirst,
                    child: Text('Month / Day / Year'),
                  ),
                ],
                onChanged: (v) => _dateOrder = v,
              ),
              if (rows.isNotEmpty) ...[
                TextField(
                  controller: _year,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Year for dates without a year (optional)',
                  ),
                ),
                DropdownButtonFormField<ImportNumberFormat>(
                  isExpanded: true,
                  key: ValueKey('number:$_sheet'),
                  initialValue: _numberFormat,
                  decoration: const InputDecoration(labelText: 'Amount format'),
                  items: const [
                    DropdownMenuItem(
                      value: ImportNumberFormat.decimalPoint,
                      child: Text('1,234.56 or 1,23,456.78'),
                    ),
                    DropdownMenuItem(
                      value: ImportNumberFormat.decimalComma,
                      child: Text('1.234,56'),
                    ),
                  ],
                  onChanged: (v) => _numberFormat = v!,
                ),
                DropdownButtonFormField<bool>(
                  isExpanded: true,
                  key: ValueKey('sign:$_sheet'),
                  initialValue: _negativeIsExpense,
                  decoration: const InputDecoration(
                    labelText: 'Signed amount convention',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: false,
                      child: Text(
                        'Positive = spending, negative = credit',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: true,
                      child: Text(
                        'Negative = spending, positive = credit',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  onChanged: (v) => _negativeIsExpense = v!,
                ),
                TextField(
                  controller: _headerInput,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Header row number (0 = no header)',
                  ),
                  onChanged: (value) {
                    final row = int.tryParse(value);
                    if (row != null && row >= 0 && row <= rows.length) {
                      setState(() {
                        _header = row - 1;
                        _columns.clear();
                      });
                    }
                  },
                ),
                if (_header >= 0 && _header < rows.length)
                  Text(
                    'Header: ${rows[_header].join(' | ')}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                for (final column in ImportColumn.values)
                  DropdownButtonFormField<int>(
                    key: ValueKey('$_sheet:$_header:${column.name}'),
                    initialValue: _columns[column] ?? -2,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: column.name),
                    items: [
                      const DropdownMenuItem(
                        value: -2,
                        child: Text('Detect automatically'),
                      ),
                      const DropdownMenuItem(
                        value: -1,
                        child: Text('Not present'),
                      ),
                      for (final i in choices)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            label(i),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v == -2) {
                        _columns.remove(column);
                      } else {
                        _columns[column] = v!;
                      }
                    },
                  ),
              ],
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
        FilledButton(
          onPressed: () {
            final headerNumber = int.tryParse(_headerInput.text);
            if (rows.isNotEmpty &&
                (headerNumber == null ||
                    headerNumber < 0 ||
                    headerNumber > rows.length)) {
              setState(
                () => _error =
                    'Choose an existing header row, or 0 for no header.',
              );
              return;
            }
            final year = int.tryParse(_year.text);
            if (_year.text.isNotEmpty &&
                (year == null || year < 1900 || year > 2100)) {
              setState(() => _error = 'Choose a year between 1900 and 2100.');
              return;
            }
            final mapped = _columns.values.where((v) => v >= 0).toList();
            if (mapped.toSet().length != mapped.length) {
              setState(() => _error = 'Map each field to a different column.');
              return;
            }
            _store();
            Navigator.pop(context, _options);
          },
          child: const Text('Apply formats'),
        ),
      ],
    );
  }
}
