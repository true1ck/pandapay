import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_overrides_repository.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/user_cards_repository.dart' show UserCard;

/// B8 ("was missing" per ui-spec.md): view and manage every "always use X
/// here" rule.
///
/// Offline behavior: NOT supported. Listing, creating, editing/toggling,
/// and deleting an override all require a live API call — there is no
/// local persistence layer for owner-scoped data anywhere in this app yet
/// (same as every other user_cards/transactions screen today), so this
/// screen simply surfaces [ErrorState]/a snackbar on failure rather than
/// silently hanging or pretending to work offline.
class ManualOverridesScreen extends ConsumerWidget {
  const ManualOverridesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overrides = ref.watch(cardOverridesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Manual overrides')),
      body: overrides.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(cardOverridesProvider),
        ),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.rule_rounded,
              title: 'No overrides yet',
              message: 'Create one from a Scan Result screen with "Always use this '
                  'card here", or add one manually below.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(AppSpace.lg),
            itemCount: list.length,
            itemBuilder: (context, index) => _OverrideTile(list[index]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openCreateSheet(context, ref),
        child: const Icon(Icons.add_rounded),
      ),
    );
  }

  Future<void> _openCreateSheet(BuildContext context, WidgetRef ref) async {
    final userCards = await ref.read(userCardsProvider.future);
    final categories = await ref.read(categoriesProvider.future);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CreateOverrideSheet(userCards: userCards, categories: categories),
    );
  }
}

class _OverrideTile extends ConsumerWidget {
  final CardOverride rule;
  const _OverrideTile(this.rule);

  String get _targetLabel => switch (rule.scope) {
        OverrideScope.vpa => 'VPA: ${rule.vpa}',
        OverrideScope.merchantName => 'Merchant: ${rule.merchantName}',
        OverrideScope.category => 'Category: ${rule.categoryName ?? rule.categoryId}',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_targetLabel, style: Theme.of(context).textTheme.titleSmall),
                ),
                StatusPill(
                  label: rule.isEnabled ? 'Active' : 'Disabled',
                  foreground: rule.isEnabled ? Colors.white : AppColors.ink500,
                  background: rule.isEnabled ? AppColors.teal600 : AppColors.surfaceMuted,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('→ ${rule.cardDisplayName}', style: Theme.of(context).textTheme.bodyMedium),
            if (rule.reasonNote?.isNotEmpty == true) ...[
              const SizedBox(height: 2),
              Text(rule.reasonNote!, style: Theme.of(context).textTheme.bodySmall),
            ],
            Text(
              'Created ${rule.createdAt.toLocal().toString().split(' ').first}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink500),
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _openEditSheet(context, ref),
                  child: const Text('Edit'),
                ),
                TextButton(
                  onPressed: () => _toggle(context, ref),
                  child: Text(rule.isEnabled ? 'Disable' : 'Enable'),
                ),
                TextButton(
                  onPressed: () => _confirmDelete(context, ref),
                  style: TextButton.styleFrom(foregroundColor: AppColors.error),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// B8 edit: card reassignment + note only — scope/vpa/merchantName/
  /// categoryId are deliberately not editable here (see
  /// CardOverridesRepository.updateOverride's doc comment); changing what a
  /// rule targets stays delete-and-recreate via the Delete + FAB flow.
  Future<void> _openEditSheet(BuildContext context, WidgetRef ref) async {
    final userCards = await ref.read(userCardsProvider.future);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EditOverrideSheet(rule: rule, userCards: userCards),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(cardOverridesRepositoryProvider);
    if (repo == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('You need to be signed in to do that.')));
      }
      return;
    }
    try {
      await repo.setEnabled(rule.id, !rule.isEnabled);
      ref.invalidate(cardOverridesProvider);
      ref.invalidate(rankedRecommendationsProvider);
    } catch (err) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    }
  }

  /// Destructive-action confirmation per this plan's Global Constraints —
  /// deleting an override silently would be exactly the "forgotten rule
  /// producing worse advice" trust bug ui-spec calls out for B8 in reverse:
  /// removing one without the user meaning to.
  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this override?'),
        content: Text('This card will no longer be forced for "$_targetLabel".'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final repo = ref.read(cardOverridesRepositoryProvider);
    if (repo == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('You need to be signed in to do that.')));
      }
      return;
    }
    try {
      await repo.delete(rule.id);
      ref.invalidate(cardOverridesProvider);
      ref.invalidate(rankedRecommendationsProvider);
    } catch (err) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    }
  }
}

class _CreateOverrideSheet extends ConsumerStatefulWidget {
  final List<UserCard> userCards;
  final List<SpendCategory> categories;
  const _CreateOverrideSheet({required this.userCards, required this.categories});

  @override
  ConsumerState<_CreateOverrideSheet> createState() => _CreateOverrideSheetState();
}

class _CreateOverrideSheetState extends ConsumerState<_CreateOverrideSheet> {
  OverrideScope _scope = OverrideScope.category;
  String? _selectedUserCardId;
  String? _selectedCategoryId;
  final _merchantController = TextEditingController();
  final _vpaController = TextEditingController();
  final _noteController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _merchantController.dispose();
    _vpaController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_selectedUserCardId == null) return false;
    return switch (_scope) {
      OverrideScope.vpa => _vpaController.text.trim().isNotEmpty,
      OverrideScope.merchantName => _merchantController.text.trim().isNotEmpty,
      OverrideScope.category => _selectedCategoryId != null,
    };
  }

  Future<void> _save() async {
    final repo = ref.read(cardOverridesRepositoryProvider);
    if (repo == null || !_canSave) return;
    setState(() => _saving = true);
    try {
      await repo.createOverride(
        userCardId: _selectedUserCardId!,
        scope: _scope,
        vpa: _scope == OverrideScope.vpa ? _vpaController.text.trim() : null,
        merchantName: _scope == OverrideScope.merchantName ? _merchantController.text.trim() : null,
        categoryId: _scope == OverrideScope.category ? _selectedCategoryId : null,
        reasonNote: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
      );
      ref.invalidate(cardOverridesProvider);
      ref.invalidate(rankedRecommendationsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.lg, right: AppSpace.lg, top: AppSpace.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New override', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpace.md),
            DropdownButtonFormField<String>(
              initialValue: _selectedUserCardId,
              decoration: const InputDecoration(labelText: 'Card'),
              items: widget.userCards
                  .map((c) => DropdownMenuItem(
                        value: c.id,
                        child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _selectedUserCardId = v),
            ),
            const SizedBox(height: AppSpace.md),
            SegmentedButton<OverrideScope>(
              segments: const [
                ButtonSegment(value: OverrideScope.category, label: Text('Category')),
                ButtonSegment(value: OverrideScope.merchantName, label: Text('Merchant')),
                ButtonSegment(value: OverrideScope.vpa, label: Text('VPA')),
              ],
              selected: {_scope},
              onSelectionChanged: (s) => setState(() => _scope = s.first),
            ),
            const SizedBox(height: AppSpace.md),
            if (_scope == OverrideScope.category)
              DropdownButtonFormField<String>(
                initialValue: _selectedCategoryId,
                decoration: const InputDecoration(labelText: 'Category'),
                items: widget.categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                onChanged: (v) => setState(() => _selectedCategoryId = v),
              )
            else if (_scope == OverrideScope.merchantName)
              TextField(
                controller: _merchantController,
                decoration: const InputDecoration(labelText: 'Merchant name'),
                onChanged: (_) => setState(() {}),
              )
            else
              TextField(
                controller: _vpaController,
                decoration: const InputDecoration(labelText: 'VPA (e.g. shop@upi)'),
                onChanged: (_) => setState(() {}),
              ),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              onPressed: _canSave && !_saving ? _save : null,
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save override'),
            ),
          ],
        ),
      ),
    );
  }
}

/// B8 edit sheet: reassign the card and/or change the note on an *existing*
/// rule via `CardOverridesRepository.updateOverride` (a real PATCH, not a
/// delete-and-recreate). Deliberately has no scope/vpa/merchantName/
/// categoryId fields — see that method's doc comment for why those stay
/// out of this flow.
class _EditOverrideSheet extends ConsumerStatefulWidget {
  final CardOverride rule;
  final List<UserCard> userCards;
  const _EditOverrideSheet({required this.rule, required this.userCards});

  @override
  ConsumerState<_EditOverrideSheet> createState() => _EditOverrideSheetState();
}

class _EditOverrideSheetState extends ConsumerState<_EditOverrideSheet> {
  // GET /card-overrides doesn't exclude overrides pointing at archived
  // cards (unlike GET /user-cards, which userCards here comes from), so a
  // rule can reference a card no longer in this list — e.g. create an
  // override, then archive that card. Feeding a value absent from `items`
  // into DropdownButtonFormField is a debug assertion crash, so fall back
  // to no-selection when the rule's card isn't actually present.
  late String? _selectedUserCardId = widget.userCards.any((c) => c.id == widget.rule.userCardId)
      ? widget.rule.userCardId
      : null;
  late final _noteController = TextEditingController(text: widget.rule.reasonNote ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  bool get _canSave => _selectedUserCardId != null;

  Future<void> _save() async {
    final repo = ref.read(cardOverridesRepositoryProvider);
    if (repo == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('You need to be signed in to do that.')));
      }
      return;
    }
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      await repo.updateOverride(
        widget.rule.id,
        userCardId: _selectedUserCardId,
        // Always sent (even empty) so clearing the note field actually
        // clears it server-side — see updateOverride's doc comment.
        reasonNote: _noteController.text.trim(),
      );
      ref.invalidate(cardOverridesProvider);
      ref.invalidate(rankedRecommendationsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(err))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.lg, right: AppSpace.lg, top: AppSpace.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Edit override', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpace.md),
            DropdownButtonFormField<String>(
              initialValue: _selectedUserCardId,
              decoration: const InputDecoration(labelText: 'Card'),
              items: widget.userCards
                  .map((c) => DropdownMenuItem(
                        value: c.id,
                        child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _selectedUserCardId = v),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              onPressed: _canSave && !_saving ? _save : null,
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}
