import 'package:flutter/material.dart';
import 'package:pandapay_domain/sms_v2.dart';
import '../personal/personal_format_service.dart';

/// Field selections point into this SMS; applying the format never copies its
/// amount, merchant or date onto the other messages in a group.
class PersonalFormatForm extends StatefulWidget {
  const PersonalFormatForm({
    super.key,
    required this.message,
    required this.instruments,
    this.groupCount = 1,
  });
  final SmsMessage message;
  final List<Instrument> instruments;
  final int groupCount;
  @override
  State<PersonalFormatForm> createState() => _PersonalFormatFormState();
}

class _PersonalFormatFormState extends State<PersonalFormatForm> {
  final _form = GlobalKey<FormState>();
  final _merchant = TextEditingController();
  String? _instrument;
  int? _amount;
  int? _date;
  EventType _type = EventType.purchase;
  AmountRole _role = AmountRole.posted;
  String _dateFormat = personalDateFormats.first;
  Rail _rail = Rail.unknown;
  String? _error;
  late final _amounts = RegExp(
    r'(?<![0-9])[0-9][0-9,]*(?:\.[0-9]{1,2})?(?![0-9])',
  ).allMatches(widget.message.body).toList();
  late final _dates = RegExp(
    r'\b(?:\d{4}-\d{2}-\d{2}(?::\d{2}:\d{2}:\d{2})?|\d{2}[-/](?:\d{2}|[A-Za-z]{3})[-/]\d{2,4}|\d{2} [A-Za-z]{3} \d{4})\b',
  ).allMatches(widget.message.body).toList();
  @override
  void dispose() {
    _merchant.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final body = widget.message.body;
    final name = _merchant.text.trim();
    final start = name.isEmpty ? -1 : body.indexOf(name);
    final amount = _amounts[_amount!];
    final date = _date == null ? null : _dates[_date!];
    final choice = PersonalFormatChoice(
      sourceKey: widget.message.sourceKey,
      instrumentId: _instrument!,
      amount: PersonalFieldSpan(amount.start, amount.end),
      merchant: start < 0
          ? null
          : PersonalFieldSpan(start, start + name.length),
      date: date == null ? null : PersonalFieldSpan(date.start, date.end),
      dateFormat: date == null ? null : _dateFormat,
      type: _type,
      amountRole: _role,
      rail: _rail,
    );
    try {
      buildPersonalRule(
        message: widget.message,
        choice: choice,
        instrument: widget.instruments.firstWhere(
          (i) => i.instrumentId == _instrument,
        ),
      );
      Navigator.pop(context, choice);
    } on ArgumentError catch (error) {
      setState(() => _error = error.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
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
              'Teach this format',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              'Saved only on this device. Choose the printed fields and your account or card.',
            ),
            if (widget.groupCount > 1)
              Text(
                'Applies to ${widget.groupCount} messages. Each keeps its own amount, merchant and date.',
              ),
            const SizedBox(height: 12),
            SelectableText(widget.message.body),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const Key('personal-instrument'),
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Account or card'),
              items: [
                for (final i in widget.instruments.where(
                  (i) =>
                      i.status == InstrumentStatus.confirmed &&
                      i.maskDigits != null,
                ))
                  DropdownMenuItem(
                    value: i.instrumentId,
                    child: Text('${i.displayName} ••${i.maskDigits}'),
                  ),
              ],
              onChanged: (value) => _instrument = value,
              validator: (value) =>
                  value == null ? 'Choose a confirmed account or card' : null,
            ),
            DropdownButtonFormField<EventType>(
              key: const Key('personal-type'),
              initialValue: _type,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'What happened?'),
              items: [
                for (final type in personalFormatTypes)
                  DropdownMenuItem(
                    value: type,
                    child: Text(switch (type) {
                      EventType.ownTransfer => 'Transfer between my accounts',
                      EventType.ipoApplication => 'IPO money held or released',
                      _ => type.wire.replaceAll('_', ' '),
                    }),
                  ),
              ],
              onChanged: (value) => setState(() {
                _type = value!;
                _role = value == EventType.ipoApplication
                    ? AmountRole.held
                    : AmountRole.posted;
              }),
            ),
            DropdownButtonFormField<int>(
              key: const Key('personal-amount'),
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Printed amount'),
              items: [
                for (final (index, match) in _amounts.indexed)
                  DropdownMenuItem(
                    value: index,
                    child: Text(
                      '${match.group(0)}  (position ${match.start + 1})',
                    ),
                  ),
              ],
              onChanged: (value) => _amount = value,
              validator: (value) => value == null
                  ? 'Choose the amount, not account digits'
                  : null,
            ),
            if (_type == EventType.ipoApplication)
              DropdownButtonFormField<AmountRole>(
                key: ValueKey(_type),
                initialValue: _role,
                decoration: const InputDecoration(
                  labelText: 'What does the amount mean?',
                ),
                items: const [
                  DropdownMenuItem(
                    value: AmountRole.held,
                    child: Text('Money blocked (not spending)'),
                  ),
                  DropdownMenuItem(
                    value: AmountRole.released,
                    child: Text('Blocked money released'),
                  ),
                ],
                onChanged: (value) => _role = value!,
              ),
            TextFormField(
              key: const Key('personal-merchant'),
              controller: _merchant,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Printed merchant or party (optional)',
                helperText: 'Copy the exact name from this message.',
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isNotEmpty &&
                    (!widget.message.body.contains(text) ||
                        widget.message.body.indexOf(text) !=
                            widget.message.body.lastIndexOf(text))) {
                  return 'Use a name that appears once in the message';
                }
                return null;
              },
            ),
            DropdownButtonFormField<int>(
              key: const Key('personal-date'),
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Printed date (optional)',
              ),
              items: [
                const DropdownMenuItem<int>(
                  value: -1,
                  child: Text('Use message received date'),
                ),
                for (final (index, match) in _dates.indexed)
                  DropdownMenuItem(value: index, child: Text(match.group(0)!)),
              ],
              onChanged: (value) => setState(
                () => _date = value == null || value < 0 ? null : value,
              ),
            ),
            if (_date != null)
              DropdownButtonFormField<String>(
                key: const Key('personal-date-format'),
                initialValue: _dateFormat,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Printed date format',
                ),
                items: [
                  for (final format in personalDateFormats)
                    DropdownMenuItem(value: format, child: Text(format)),
                ],
                onChanged: (value) => _dateFormat = value!,
              ),
            DropdownButtonFormField<Rail>(
              key: const Key('personal-rail'),
              initialValue: _rail,
              decoration: const InputDecoration(labelText: 'Payment method'),
              items: [
                for (final rail in [
                  Rail.unknown,
                  Rail.card,
                  Rail.upi,
                  Rail.wallet,
                  Rail.imps,
                  Rail.neft,
                  Rail.cash,
                ])
                  DropdownMenuItem(value: rail, child: Text(rail.wire)),
              ],
              onChanged: (value) => _rail = value!,
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Future messages must keep the same sender, account digits and wording. Changed or uncertain formats still come back for review.',
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            FilledButton(
              onPressed: _save,
              child: const Text('Use this format'),
            ),
          ],
        ),
      ),
    ),
  );
}
