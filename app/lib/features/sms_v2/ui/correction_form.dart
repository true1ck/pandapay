import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import '../pipeline/trace.dart';
import '../providers/data_providers.dart';

const correctionLabels = <CorrectionKind, String>{
  CorrectionKind.notFinancial: 'This isn’t a financial message',
  CorrectionKind.wrongKind: 'The payment type is wrong',
  CorrectionKind.wrongAmount: 'The amount is wrong',
  CorrectionKind.wrongDate: 'The date is wrong',
  CorrectionKind.wrongMerchant: 'The merchant is wrong',
  CorrectionKind.wrongInstrument: 'The account or card is wrong',
  CorrectionKind.wrongLink: 'These messages don’t belong together',
  CorrectionKind.duplicate: 'This payment is counted twice',
  CorrectionKind.wrongCategory: 'The category is wrong',
  CorrectionKind.missing: 'A financial entry is missing',
  CorrectionKind.preferenceOnly: 'Use my preferred category',
};

class CorrectionEdit {
  const CorrectionEdit(this.kind, this.corrected);
  final CorrectionKind kind;
  final Map<String, Object?> corrected;
}

class CorrectionForm extends ConsumerStatefulWidget {
  const CorrectionForm({super.key, this.groupCount = 1});
  final int groupCount;
  @override
  ConsumerState<CorrectionForm> createState() => _CorrectionFormState();
}

class _CorrectionFormState extends ConsumerState<CorrectionForm> {
  CorrectionKind _kind = CorrectionKind.wrongKind;
  final _value = TextEditingController();
  final _form = GlobalKey<FormState>();
  EventType _eventType = EventType.purchase;
  String _category = 'other';
  String? _instrument;
  String _role = 'posted';
  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final value = _value.text.trim();
    final corrected = <String, Object?>{
      if (_kind == CorrectionKind.wrongKind) 'eventType': _eventType.wire,
      if (_kind == CorrectionKind.wrongAmount) ...{
        'amountMinor': (double.parse(value) * 100).round(),
        'amountRole': _role,
      },
      if (_kind == CorrectionKind.wrongDate)
        'occurredAt': DateTime.parse(value).toUtc().toIso8601String(),
      if (_kind == CorrectionKind.wrongMerchant) 'merchantName': value,
      if (_kind == CorrectionKind.wrongInstrument) 'instrumentId': _instrument,
      if (_kind == CorrectionKind.wrongCategory ||
          _kind == CorrectionKind.preferenceOnly)
        'category': _category,
    };
    Navigator.pop(context, CorrectionEdit(_kind, corrected));
  }

  @override
  Widget build(BuildContext context) {
    final instruments =
        ref.watch(instrumentsProvider).valueOrNull ?? const <Instrument>[];
    final textValue = {
      CorrectionKind.wrongAmount,
      CorrectionKind.wrongDate,
      CorrectionKind.wrongMerchant,
    }.contains(_kind);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          8,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Report a problem',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<CorrectionKind>(
                initialValue: _kind,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'What needs changing?',
                ),
                items: [
                  for (final kind in CorrectionKind.values)
                    if (widget.groupCount == 1 ||
                        !{
                          CorrectionKind.wrongAmount,
                          CorrectionKind.wrongDate,
                          CorrectionKind.wrongLink,
                          CorrectionKind.duplicate,
                        }.contains(kind))
                      DropdownMenuItem(
                        value: kind,
                        child: Text(correctionLabels[kind]!),
                      ),
                ],
                onChanged: (value) => setState(() {
                  _kind = value!;
                  _value.clear();
                }),
              ),
              if (widget.groupCount > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Applies to ${widget.groupCount} messages of this format. Each keeps its own amount and date.',
                  ),
                ),
              if (_kind == CorrectionKind.wrongKind)
                DropdownButtonFormField<EventType>(
                  initialValue: _eventType,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Payment type'),
                  items: [
                    for (final type in EventType.values)
                      DropdownMenuItem(
                        value: type,
                        child: Text(type.wire.replaceAll('_', ' ')),
                      ),
                  ],
                  onChanged: (value) => _eventType = value!,
                ),
              if (_kind == CorrectionKind.wrongCategory ||
                  _kind == CorrectionKind.preferenceOnly)
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    for (final category in TaxonomyRegistry.v1.categories)
                      DropdownMenuItem(
                        value: category.slug,
                        child: Text(category.displayName),
                      ),
                  ],
                  onChanged: (value) => _category = value!,
                ),
              if (_kind == CorrectionKind.wrongInstrument)
                DropdownButtonFormField<String>(
                  initialValue: _instrument,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Account or card',
                  ),
                  items: [
                    for (final instrument in instruments.where(
                      (i) => i.status == InstrumentStatus.confirmed,
                    ))
                      DropdownMenuItem(
                        value: instrument.instrumentId,
                        child: Text(
                          '${instrument.displayName} ••${instrument.maskDigits ?? ''}',
                        ),
                      ),
                  ],
                  validator: (value) => value == null
                      ? 'Choose a confirmed account or card'
                      : null,
                  onChanged: (value) => _instrument = value,
                ),
              if (textValue)
                TextFormField(
                  controller: _value,
                  keyboardType: _kind == CorrectionKind.wrongAmount
                      ? const TextInputType.numberWithOptions(decimal: true)
                      : TextInputType.text,
                  decoration: InputDecoration(
                    labelText: _kind == CorrectionKind.wrongAmount
                        ? 'Amount in rupees'
                        : _kind == CorrectionKind.wrongDate
                        ? 'Date (YYYY-MM-DD)'
                        : 'Merchant name',
                  ),
                  maxLength: _kind == CorrectionKind.wrongMerchant ? 120 : 32,
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    if (text.isEmpty) return 'Enter a value';
                    if (_kind == CorrectionKind.wrongAmount &&
                        (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(text) ||
                            (double.tryParse(text) ?? 0) <= 0)) {
                      return 'Enter a positive amount with up to two decimals';
                    }
                    if (_kind == CorrectionKind.wrongDate &&
                        (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) ||
                            DateTime.tryParse(
                                  text,
                                )?.toIso8601String().substring(0, 10) !=
                                text)) {
                      return 'Enter a valid date';
                    }
                    return null;
                  },
                ),
              if (_kind == CorrectionKind.wrongAmount)
                DropdownButtonFormField<String>(
                  initialValue: _role,
                  decoration: const InputDecoration(
                    labelText: 'What does this amount mean?',
                  ),
                  items: [
                    for (final role in [
                      'posted',
                      'held',
                      'released',
                      'due_total',
                      'due_minimum',
                      'balance',
                      'available',
                      'limit',
                    ])
                      DropdownMenuItem(
                        value: role,
                        child: Text(role.replaceAll('_', ' ')),
                      ),
                  ],
                  onChanged: (value) => _role = value!,
                ),
              if (_kind == CorrectionKind.missing)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'We’ll report the missing reading for review. It will appear in totals once it has a reading you can confirm.',
                  ),
                ),
              if (_kind == CorrectionKind.wrongLink)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Choose a match in the review inbox to change linked messages.',
                  ),
                ),
              const SizedBox(height: 24),
              FilledButton(onPressed: _submit, child: const Text('Save')),
            ],
          ),
        ),
      ),
    );
  }
}
