import 'package:flutter/material.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/required_field.dart';
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
  Widget build(BuildContext context) => Form(
    key: _form,
    child: BambooSheet(
      title: 'Teach this format',
      subtitle:
          'Saved only on this device. Choose the printed fields and your account or card.',
      icon: Icons.auto_fix_high_outlined,
      actions: [
        FilledButton(onPressed: _save, child: const Text('Use this format')),
      ],
      children: [
        if (widget.groupCount > 1)
          BambooNote(
            'Applies to ${widget.groupCount} messages. Each keeps its own amount, merchant and date.',
            icon: Icons.layers_outlined,
          ),
        BambooMessageQuote(widget.message.body, sender: widget.message.sender),
        const BambooSectionLabel(
          'From this message',
          padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
        ),
        DropdownButtonFormField<int>(
          key: const Key('personal-amount'),
          isExpanded: true,
          decoration: InputDecoration(
            label: requiredLabel('Printed amount'),
            prefixIcon: const Icon(Icons.currency_rupee_rounded),
          ),
          items: [
            for (final (index, match) in _amounts.indexed)
              DropdownMenuItem(
                value: index,
                child: Text('${match.group(0)}  (position ${match.start + 1})'),
              ),
          ],
          onChanged: (value) => _amount = value,
          validator: (value) =>
              value == null ? 'Choose the amount, not account digits' : null,
        ),
        TextFormField(
          key: const Key('personal-merchant'),
          controller: _merchant,
          maxLength: 120,
          decoration: const InputDecoration(
            labelText: 'Printed merchant or party (optional)',
            helperText: 'Copy the exact name from this message.',
            prefixIcon: Icon(Icons.storefront_outlined),
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
            prefixIcon: Icon(Icons.event_outlined),
          ),
          items: [
            const DropdownMenuItem<int>(
              value: -1,
              child: Text('Use message received date'),
            ),
            for (final (index, match) in _dates.indexed)
              DropdownMenuItem(value: index, child: Text(match.group(0)!)),
          ],
          onChanged: (value) =>
              setState(() => _date = value == null || value < 0 ? null : value),
        ),
        if (_date != null)
          DropdownButtonFormField<String>(
            key: const Key('personal-date-format'),
            initialValue: _dateFormat,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Printed date format',
              prefixIcon: Icon(Icons.calendar_view_month_outlined),
            ),
            items: [
              for (final format in personalDateFormats)
                DropdownMenuItem(value: format, child: Text(format)),
            ],
            onChanged: (value) => _dateFormat = value!,
          ),
        const BambooSectionLabel(
          'About the payment',
          padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
        ),
        DropdownButtonFormField<String>(
          key: const Key('personal-instrument'),
          isExpanded: true,
          decoration: InputDecoration(
            label: requiredLabel('Account or card'),
            prefixIcon: const Icon(Icons.account_balance_wallet_outlined),
          ),
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
          decoration: const InputDecoration(
            labelText: 'What happened?',
            prefixIcon: Icon(Icons.swap_vert_rounded),
          ),
          items: [
            for (final type in personalFormatTypes)
              DropdownMenuItem(
                value: type,
                child: Text(switch (type) {
                  EventType.ownTransfer => 'Transfer between my accounts',
                  EventType.ipoApplication => 'IPO money held or released',
                  _ => _sentence(type.wire),
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
        if (_type == EventType.ipoApplication)
          DropdownButtonFormField<AmountRole>(
            key: ValueKey(_type),
            initialValue: _role,
            decoration: const InputDecoration(
              labelText: 'What does the amount mean?',
              prefixIcon: Icon(Icons.lock_clock_outlined),
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
        DropdownButtonFormField<Rail>(
          key: const Key('personal-rail'),
          initialValue: _rail,
          decoration: const InputDecoration(
            labelText: 'Payment method',
            prefixIcon: Icon(Icons.payments_outlined),
          ),
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
              DropdownMenuItem(value: rail, child: Text(_railLabel(rail))),
          ],
          onChanged: (value) => _rail = value!,
        ),
        const BambooNote(
          'Future messages must keep the same sender, account digits and wording. Changed or uncertain formats still come back for review.',
          icon: Icons.info_outline,
        ),
        if (_error != null) BambooAlertNote(_error!),
      ],
    ),
  );
}

String _sentence(String wire) {
  final text = wire.replaceAll('_', ' ');
  return text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}

String _railLabel(Rail rail) => switch (rail) {
  Rail.unknown => 'Not sure',
  Rail.upi => 'UPI',
  Rail.imps => 'IMPS',
  Rail.neft => 'NEFT',
  _ => _sentence(rail.wire),
};
