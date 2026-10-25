import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/category_picker.dart';
import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/catalogue_repository.dart';
import '../../data/merchant_category_rules_repository.dart';
import '../../data/merchant_issue_rules_repository.dart';

/// Lists the user's future-only merchant rules. Existing transactions are
/// intentionally absent from this screen: disabling or editing a rule never
/// rewrites history.
class MerchantFutureRulesScreen extends ConsumerStatefulWidget {
  const MerchantFutureRulesScreen({super.key});

  @override
  ConsumerState<MerchantFutureRulesScreen> createState() =>
      _MerchantFutureRulesScreenState();
}

class _MerchantFutureRulesScreenState
    extends ConsumerState<MerchantFutureRulesScreen> {
  List<MerchantCategoryRule> _rules = const [];
  bool _loading = true;
  String? _error;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final repository = ref.read(merchantCategoryRulesRepositoryProvider);
    if (repository == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rules = await repository.fetchRules();
      if (mounted) setState(() => _rules = rules);
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setActive(MerchantCategoryRule rule, bool active) async {
    final repository = ref.read(merchantCategoryRulesRepositoryProvider);
    if (repository == null || _busyId != null) return;
    setState(() {
      _busyId = rule.id;
      _error = null;
    });
    try {
      final updated = active
          ? await repository.update(
              rule.id,
              isActive: true,
              expectedVersion: rule.version,
            )
          : await repository.disable(rule.id, expectedVersion: rule.version);
      if (mounted) {
        setState(() {
          _rules = [
            for (final item in _rules) item.id == updated.id ? updated : item,
          ];
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _edit(MerchantCategoryRule rule) async {
    final repository = ref.read(merchantCategoryRulesRepositoryProvider);
    if (repository == null || _busyId != null) return;
    final categories = ref.read(categoriesProvider).valueOrNull ?? const <SpendCategory>[];
    if (categories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Categories are still loading. Try again.')),
      );
      return;
    }
    final selectedId = rule.userCategoryId == null
        ? rule.categoryId
        : 'custom:${rule.userCategoryId}';
    final value = await showCategoryBottomSheet(
      context,
      ref,
      categories,
      selectedId: selectedId,
      title: 'Update future category',
    );
    if (value == null || !mounted) return;
    final isCustom = isCustomCategoryId(value);
    setState(() {
      _busyId = rule.id;
      _error = null;
    });
    try {
      final updated = await repository.update(
        rule.id,
        categoryId: isCustom ? null : value,
        userCategoryId: isCustom ? userCategoryIdForServer(value) : null,
        expectedVersion: rule.version,
      );
      if (mounted) {
        setState(() {
          _rules = [
            for (final item in _rules) item.id == updated.id ? updated : item,
          ];
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = userFacingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Future merchant rules', style: BambooFonts.heading(18, color: BambooInk.ink900)),
        actions: [IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh))],
      ),
      body: AppBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(onRefresh: _load, child: _body()),
      ),
    );
  }

  Widget _body() {
    if (_error != null && _rules.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          _message(Icons.error_outline, _error!, BambooInk.clay),
          const SizedBox(height: AppSpace.md),
          FilledButton(onPressed: _load, child: const Text('Try again')),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Text('Rules for future spending', style: BambooFonts.heading(20, color: BambooInk.ink900)),
        const SizedBox(height: AppSpace.xs),
        Text('These rules apply only to new eligible spends. Existing transactions are unchanged.', style: BambooFonts.ui(13, color: BambooInk.ink700)),
        if (_error != null) ...[
          const SizedBox(height: AppSpace.md),
          _message(Icons.error_outline, _error!, BambooInk.clay),
        ],
        const SizedBox(height: AppSpace.lg),
        if (_rules.isEmpty)
          _message(Icons.auto_awesome_outlined, 'No future rules yet. Choose Remember for future transactions after categorising a merchant.', BambooInk.ink500)
        else
          for (final rule in _rules) ...[
            _ruleCard(rule),
            const SizedBox(height: AppSpace.sm),
          ],
      ],
    );
  }

  Widget _ruleCard(MerchantCategoryRule rule) {
    final busy = _busyId == rule.id;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: BambooInk.glassFillOnPaper,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(rule.displayMerchantName, style: BambooFonts.ui(15, color: BambooInk.ink900, weight: FontWeight.w700))),
                Chip(label: Text(rule.isActive ? 'Active' : 'Disabled')),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              rule.action == MerchantRuleAction.flag
                  ? 'Issue flag: ${rule.flag ?? 'unspecified'}'
                  : (rule.categoryName ?? 'Category'),
              style: BambooFonts.ui(13, color: BambooInk.ink700),
            ),
            Text(
              rule.matchBasis == MerchantRuleMatchBasis.vpa
                  ? 'Exact merchant VPA'
                  : 'Exact merchant name',
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: 8),
            if (busy)
              const LinearProgressIndicator()
            else
              Wrap(
                spacing: AppSpace.sm,
                children: [
                  if (rule.action == MerchantRuleAction.category)
                    OutlinedButton.icon(
                      onPressed: () => _edit(rule),
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      label: const Text('Edit category'),
                    ),
                  TextButton(
                    onPressed: () => _setActive(rule, !rule.isActive),
                    child: Text(rule.isActive ? 'Disable' : 'Enable'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _message(IconData icon, String text, Color color) => Material(
    color: color.withValues(alpha: 0.09),
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: AppSpace.sm),
          Expanded(child: Text(text, style: BambooFonts.ui(13, color: color))),
        ],
      ),
    ),
  );
}
