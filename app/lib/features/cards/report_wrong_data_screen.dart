import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

/// C7 Report Wrong Data (ui-spec Group C). Pre-filled card (required) +
/// field (optional — a specific row's field name when reached from a more
/// granular entry point; free text otherwise), what we show, what it
/// should be, optional source link. Confirmation sets the expectation:
/// "we verify before publishing."
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
  ConsumerState<ReportWrongDataScreen> createState() => _ReportWrongDataScreenState();
}

class _ReportWrongDataScreenState extends ConsumerState<ReportWrongDataScreen> {
  late final _fieldController = TextEditingController(text: widget.initialFieldPath ?? '');
  late final _shownController = TextEditingController(text: widget.initialShownValue ?? '');
  final _claimedController = TextEditingController();
  final _sourceController = TextEditingController();
  bool _submitting = false;
  bool _submitted = false;
  String? _error;

  @override
  void dispose() {
    _fieldController.dispose();
    _shownController.dispose();
    _claimedController.dispose();
    _sourceController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_fieldController.text.trim().isEmpty) {
      setState(() => _error = 'Tell us which field is wrong.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(cardFeedbackRepositoryProvider)!.reportWrongData(
            cardProductId: widget.cardProductId,
            fieldPath: _fieldController.text.trim(),
            shownValue: _shownController.text.trim().isEmpty ? null : _shownController.text.trim(),
            claimedValue: _claimedController.text.trim().isEmpty ? null : _claimedController.text.trim(),
            sourceUrl: _sourceController.text.trim().isEmpty ? null : _sourceController.text.trim(),
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
    final product = ref.watch(catalogueProvider).valueOrNull?.where((c) => c.id == widget.cardProductId).firstOrNull;
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Report wrong data', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.9, -0.5),
            radius: 1.3,
            colors: [BambooInk.wash, BambooInk.paper],
            stops: [0.0, 0.6],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: _submitted ? _buildConfirmation(context) : _buildForm(context, product?.name),
        ),
      ),
    );
  }

  Widget _buildConfirmation(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 48, color: BambooInk.jade),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
    final inputDecoration = (String label, {String? hint}) => InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
          hintStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
          filled: true,
          fillColor: BambooInk.glassFillOnPaper,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
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
          Text(cardName, style: BambooFonts.heading(17, color: BambooInk.ink900)),
          const SizedBox(height: AppSpace.lg),
        ],
        TextField(
          controller: _fieldController,
          style: BambooFonts.ui(14.5, color: BambooInk.ink900),
          decoration: inputDecoration('Which field is wrong?', hint: 'e.g. "5% cashback on dining"'),
        ),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
          ),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.lime))
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
