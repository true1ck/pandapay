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
      appBar: AppBar(title: const Text('Report wrong data')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: _submitted ? _buildConfirmation(context) : _buildForm(context, product?.name),
      ),
    );
  }

  Widget _buildConfirmation(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 48, color: AppColors.success),
          const SizedBox(height: AppSpace.lg),
          Text('Thanks — we verify before publishing.', style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: AppSpace.xl),
          FilledButton(onPressed: () => context.pop(), child: const Text('Done')),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context, String? cardName) {
    return ListView(
      children: [
        if (cardName != null) ...[
          Text(cardName, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpace.lg),
        ],
        TextField(
          controller: _fieldController,
          decoration: const InputDecoration(labelText: 'Which field is wrong?', hintText: 'e.g. "5% cashback on dining"'),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _shownController,
          decoration: const InputDecoration(labelText: 'What we currently show'),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _claimedController,
          decoration: const InputDecoration(labelText: 'What it should be'),
        ),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: _sourceController,
          decoration: const InputDecoration(labelText: 'Source link (optional)'),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpace.md),
          Text(_error!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.error)),
        ],
        const SizedBox(height: AppSpace.xl),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
