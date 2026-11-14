import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import '../../../app/providers.dart' as app;
import '../../../app/required_field.dart';
import '../../consent/template_sharing_disclosure.dart';
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

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final current = DateTime.tryParse(_value.text.trim());
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(2000),
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    final month = picked.month.toString().padLeft(2, '0');
    final day = picked.day.toString().padLeft(2, '0');
    setState(() => _value.text = '${picked.year}-$month-$day');
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
    return Form(
      key: _form,
      child: BambooSheet(
        title: 'Report a problem',
        subtitle: 'Choose what’s wrong, then give the right value.',
        icon: Icons.flag_outlined,
        actions: [FilledButton(onPressed: _submit, child: const Text('Save'))],
        children: [
          DropdownButtonFormField<CorrectionKind>(
            initialValue: _kind,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'What needs changing?',
              prefixIcon: Icon(Icons.edit_note_rounded),
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
            BambooNote(
              'Applies to ${widget.groupCount} messages of this format. Each keeps its own amount and date.',
              icon: Icons.layers_outlined,
            ),
          if (_kind == CorrectionKind.wrongKind)
            DropdownButtonFormField<EventType>(
              initialValue: _eventType,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Payment type',
                prefixIcon: Icon(Icons.swap_vert_rounded),
              ),
              items: [
                for (final type in EventType.values)
                  DropdownMenuItem(
                    value: type,
                    child: Text(_sentence(type.wire)),
                  ),
              ],
              onChanged: (value) => _eventType = value!,
            ),
          if (_kind == CorrectionKind.wrongCategory ||
              _kind == CorrectionKind.preferenceOnly)
            DropdownButtonFormField<String>(
              initialValue: _category,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Category',
                prefixIcon: Icon(Icons.category_outlined),
              ),
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
              decoration: InputDecoration(
                label: requiredLabel('Account or card'),
                prefixIcon: const Icon(Icons.account_balance_wallet_outlined),
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
              validator: (value) =>
                  value == null ? 'Choose a confirmed account or card' : null,
              onChanged: (value) => _instrument = value,
            ),
          if (textValue)
            TextFormField(
              controller: _value,
              keyboardType: _kind == CorrectionKind.wrongAmount
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : TextInputType.text,
              decoration: InputDecoration(
                label: requiredLabel(
                  _kind == CorrectionKind.wrongAmount
                      ? 'Amount in rupees'
                      : _kind == CorrectionKind.wrongDate
                      ? 'Date (YYYY-MM-DD)'
                      : 'Merchant name',
                ),
                prefixIcon: Icon(switch (_kind) {
                  CorrectionKind.wrongAmount => Icons.currency_rupee_rounded,
                  CorrectionKind.wrongDate => Icons.event_outlined,
                  _ => Icons.storefront_outlined,
                }),
                suffixIcon: _kind == CorrectionKind.wrongDate
                    ? IconButton(
                        tooltip: 'Pick a date',
                        icon: const Icon(Icons.calendar_month_outlined),
                        onPressed: _pickDate,
                      )
                    : null,
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
                prefixIcon: Icon(Icons.help_outline_rounded),
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
                  DropdownMenuItem(value: role, child: Text(_sentence(role))),
              ],
              onChanged: (value) => _role = value!,
            ),
          if (_kind == CorrectionKind.missing)
            const BambooNote(
              'We’ll report the missing reading for review. It will appear in totals once it has a reading you can confirm.',
              icon: Icons.info_outline,
            ),
          if (_kind == CorrectionKind.wrongLink)
            const BambooNote(
              'Choose a match in the review inbox to change linked messages.',
              icon: Icons.info_outline,
            ),
          _SharingStatusLine(kind: _kind),
        ],
      ),
    );
  }
}

String _sentence(String wire) {
  final text = wire.replaceAll('_', ' ');
  return text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}

/// Says plainly whether this fix leaves the phone. A personal preference never
/// does, whatever the sharing setting.
class _SharingStatusLine extends ConsumerWidget {
  const _SharingStatusLine({required this.kind});
  final CorrectionKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.4);
    final consent = ref.watch(app.smsSharedLearningConsentProvider);
    if (consent.isLoading && !consent.hasValue) return const SizedBox.shrink();
    final local = Text('This fix stays on your phone.', style: style);
    if (kind == CorrectionKind.preferenceOnly) return local;
    if (consent.valueOrNull != null) {
      return Text(
        'This fix helps everyone. It\'s shared without amounts, names or numbers.',
        style: style,
      );
    }
    return Row(
      children: [
        Expanded(child: local),
        TextButton(
          onPressed: () async {
            await TemplateSharingDisclosure.show(
              context,
              sourceScreen: 'correction_form',
            );
            ref.invalidate(app.smsSharedLearningConsentProvider);
          },
          child: const Text('Share fixes'),
        ),
      ],
    );
  }
}
