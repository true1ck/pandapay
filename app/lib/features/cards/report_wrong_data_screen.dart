import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

class _ReportFieldOption {
  final String value;
  final String label;

  const _ReportFieldOption({required this.value, required this.label});
}

const _reportFieldOptions = [
  _ReportFieldOption(value: 'card_name', label: 'Card name or product'),
  _ReportFieldOption(value: 'issuer', label: 'Issuer or bank'),
  _ReportFieldOption(value: 'network', label: 'Card network or variant'),
  _ReportFieldOption(value: 'joining_fee', label: 'Joining fee'),
  _ReportFieldOption(value: 'annual_fee', label: 'Annual fee'),
  _ReportFieldOption(value: 'reward_rate', label: 'Reward rate or cashback'),
  _ReportFieldOption(
    value: 'reward_categories',
    label: 'Reward categories or exclusions',
  ),
  _ReportFieldOption(value: 'reward_caps', label: 'Reward cap or limit'),
  _ReportFieldOption(value: 'lounge_access', label: 'Lounge access'),
  _ReportFieldOption(value: 'other_benefit', label: 'Other benefit'),
  _ReportFieldOption(
    value: 'milestone',
    label: 'Milestone or spend requirement',
  ),
  _ReportFieldOption(value: 'fee_waiver', label: 'Fee waiver'),
  _ReportFieldOption(value: 'fuel_waiver', label: 'Fuel surcharge waiver'),
  _ReportFieldOption(value: 'other', label: 'Other field — specify below'),
];

/// C7 Report Wrong Data (ui-spec Group C). Pre-filled card (required) +
/// a selectable field, what we show, what it should be, optional source link.
/// Confirmation sets the expectation: "we verify before publishing."
class ReportWrongDataScreen extends ConsumerStatefulWidget {
  final String cardProductId;
  final String? initialFieldPath;
  final String? initialShownValue;

  const ReportWrongDataScreen({
    super.key,
    required this.cardProductId,
    this.initialFieldPath,
    this.initialShownValue,
  });

  @override
  ConsumerState<ReportWrongDataScreen> createState() =>
      _ReportWrongDataScreenState();
}

class _ReportWrongDataScreenState extends ConsumerState<ReportWrongDataScreen> {
  late final TextEditingController _fieldController;
  late final _shownController = TextEditingController(
    text: widget.initialShownValue ?? '',
  );
  final _claimedController = TextEditingController();
  final _sourceController = TextEditingController();
  String? _selectedFieldPath;
  bool _submitting = false;
  bool _submitted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initialField = widget.initialFieldPath?.trim();
    _fieldController = TextEditingController(text: initialField ?? '');
    _selectedFieldPath =
        _optionFor(initialField)?.value ??
        (initialField?.isNotEmpty == true ? 'other' : null);
  }

  _ReportFieldOption? _optionFor(String? value) {
    if (value == null || value.isEmpty) return null;
    for (final option in _reportFieldOptions) {
      if (option.value == value || option.label == value) return option;
    }
    return null;
  }

  String? get _fieldPathForSubmission {
    if (_selectedFieldPath == null) return null;
    if (_selectedFieldPath == 'other') {
      final customField = _fieldController.text.trim();
      return customField.isEmpty ? null : customField;
    }
    return _selectedFieldPath;
  }

  @override
  void dispose() {
    _fieldController.dispose();
    _shownController.dispose();
    _claimedController.dispose();
    _sourceController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final fieldPath = _fieldPathForSubmission;
    if (fieldPath == null) {
      setState(() => _error = 'Tell us which field is wrong.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref
          .read(cardFeedbackRepositoryProvider)!
          .reportWrongData(
            cardProductId: widget.cardProductId,
            fieldPath: fieldPath,
            shownValue: _shownController.text.trim().isEmpty
                ? null
                : _shownController.text.trim(),
            claimedValue: _claimedController.text.trim().isEmpty
                ? null
                : _claimedController.text.trim(),
            sourceUrl: _sourceController.text.trim().isEmpty
                ? null
                : _sourceController.text.trim(),
          );
      if (mounted) setState(() => _submitted = true);
    } catch (e) {
      setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = ref
        .watch(catalogueProvider)
        .valueOrNull
        ?.where((c) => c.id == widget.cardProductId)
        .firstOrNull;
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Report wrong data',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: _submitted
              ? _buildConfirmation(context)
              : _buildForm(context, product?.name),
        ),
      ),
    );
  }

  Widget _buildConfirmation(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            size: 48,
            color: BambooInk.jade,
          ),
          const SizedBox(height: AppSpace.lg),
          Text(
            'Thanks — we verify before publishing.',
            style: BambooFonts.heading(17, color: BambooInk.ink900),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpace.xl),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.slate,
              foregroundColor: BambooInk.lime,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
            ),
            onPressed: () => context.pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context, String? cardName) {
    InputDecoration inputDecoration(String label, {String? hint}) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
          hintStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
          filled: true,
          fillColor: BambooInk.glassFillOnPaper,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
          ),
        );

    return ListView(
      children: [
        if (cardName != null) ...[
          Text(
            cardName,
            style: BambooFonts.heading(17, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.lg),
        ],
        Text(
          'Which field is wrong?',
          style: BambooFonts.ui(
            14.5,
            color: BambooInk.ink900,
            weight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Container(
          decoration: BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: BambooInk.hairlineOnPaper),
          ),
          child: RadioGroup<String>(
            groupValue: _selectedFieldPath,
            onChanged: (value) {
              if (_submitting) return;
              setState(() {
                _selectedFieldPath = value;
                _error = null;
                if (value != 'other') _fieldController.clear();
              });
            },
            child: Column(
              children: [
                for (
                  var index = 0;
                  index < _reportFieldOptions.length;
                  index++
                ) ...[
                  Material(
                    color: Colors.transparent,
                    child: RadioListTile<String>(
                      value: _reportFieldOptions[index].value,
                      title: Text(
                        _reportFieldOptions[index].label,
                        style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                      ),
                      activeColor: BambooInk.jade,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.sm,
                      ),
                      dense: true,
                    ),
                  ),
                  if (index != _reportFieldOptions.length - 1)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                ],
              ],
            ),
          ),
        ),
        if (_selectedFieldPath == 'other') ...[
          const SizedBox(height: AppSpace.md),
          TextField(
            controller: _fieldController,
            style: BambooFonts.ui(14.5, color: BambooInk.ink900),
            decoration: inputDecoration(
              'Describe the field',
              hint: 'e.g. 5% cashback on dining',
            ),
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _shownController,
          style: BambooFonts.ui(14.5, color: BambooInk.ink900),
          decoration: inputDecoration('What we currently show'),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _claimedController,
          style: BambooFonts.ui(14.5, color: BambooInk.ink900),
          decoration: inputDecoration('What it should be'),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _sourceController,
          style: BambooFonts.ui(14.5, color: BambooInk.ink900),
          decoration: inputDecoration('Source link (optional)'),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpace.md),
          Text(_error!, style: BambooFonts.ui(12.5, color: BambooInk.clay)),
        ],
        const SizedBox(height: AppSpace.xl),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: BambooInk.slate,
            foregroundColor: BambooInk.lime,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
          ),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: BambooInk.lime,
                  ),
                )
              : const Text('Submit report'),
        ),
      ],
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
