import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

enum _SortBy { value, name }

/// ui-spec B4 — full sortable comparison table, reachable from B1 (Task 5's
/// hero card adds a "Compare all" action — wired in this task's Step 3)
/// and from B3 (Task 12).
///
/// `Recommendation` doesn't carry separate rate/cap/milestone/forex fields
/// (only `expectedValue` and free-text `reasonLines` — see
/// packages/pandapay_domain/lib/src/engine/engine.dart lines 43-61);
/// re-deriving those from `CardProduct.rewardRules`/`capRules` here would
/// duplicate the engine's own arithmetic in a second place, which is
/// exactly the kind of drift this codebase avoids. Instead, the comparison
/// table's per-row summary badges (cap/milestone/forex indicators) are
/// derived by matching keywords already present in `reasonLines` — the
/// same strings the "Why this card?" expansion (Task 5) already shows
/// verbatim — and each row expands to the exact same full `reasonLines`
/// list, so the table never claims a number the engine didn't produce.
class ComparisonViewScreen extends ConsumerStatefulWidget {
  const ComparisonViewScreen({super.key});

  @override
  ConsumerState<ComparisonViewScreen> createState() => _ComparisonViewScreenState();
}

class _ComparisonViewScreenState extends ConsumerState<ComparisonViewScreen> {
  _SortBy _sortBy = _SortBy.value;
  bool _ascending = false;

  List<Recommendation> _sorted(List<Recommendation> input) {
    final list = [...input];
    list.sort((a, b) {
      final cmp = switch (_sortBy) {
        _SortBy.value => a.expectedValue.paise.compareTo(b.expectedValue.paise),
        _SortBy.name => a.card.name.compareTo(b.card.name),
      };
      return _ascending ? cmp : -cmp;
    });
    return list;
  }

  void _onSort(_SortBy column) {
    setState(() {
      if (_sortBy == column) {
        _ascending = !_ascending;
      } else {
        _sortBy = column;
        _ascending = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ranked = ref.watch(rankedRecommendationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Compare cards')),
      body: ranked.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
        data: (recommendations) {
          if (recommendations.isEmpty) {
            return const EmptyState(icon: Icons.compare_arrows_rounded, title: 'Nothing to compare', message: 'Add a card first.');
          }
          final sorted = _sorted(recommendations);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Row(
                  children: [
                    _SortHeaderButton(label: 'Card', active: _sortBy == _SortBy.name, ascending: _ascending, onTap: () => _onSort(_SortBy.name)),
                    const SizedBox(width: AppSpace.md),
                    _SortHeaderButton(label: '₹ value', active: _sortBy == _SortBy.value, ascending: _ascending, onTap: () => _onSort(_SortBy.value)),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                  itemCount: sorted.length,
                  // Keyed by card identity, not just position: _ComparisonRow
                  // is a StatefulWidget holding its own expand/collapse
                  // state, and `sorted` reorders in place whenever a column
                  // header is tapped (same list of Recommendations,
                  // different order) — unlike home_screen.dart's ranked
                  // list, which gets a wholesale new list from the provider
                  // on every change. A ValueKey alone does NOT protect
                  // against state loss on an in-place reorder: SliverChild-
                  // BuilderDelegate (what ListView.builder uses under the
                  // hood) only matches keyed children found at their
                  // previous index unless given findChildIndexCallback to
                  // search by key — without it, swapping two rows'
                  // positions silently drops/resets their Element state
                  // instead of moving it. findChildIndexCallback below
                  // closes that gap.
                  findChildIndexCallback: (key) {
                    final valueKey = key as ValueKey<String>;
                    final index = sorted.indexWhere((r) => r.card.id == valueKey.value);
                    return index == -1 ? null : index;
                  },
                  itemBuilder: (context, index) => _ComparisonRow(sorted[index], key: ValueKey(sorted[index].card.id)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SortHeaderButton extends StatelessWidget {
  final String label;
  final bool active;
  final bool ascending;
  final VoidCallback onTap;
  const _SortHeaderButton({required this.label, required this.active, required this.ascending, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // Sort header is a compact text+icon row visually, but the tappable
      // region is padded out to the 48x48dp minimum touch target.
      constraints: const BoxConstraints(minHeight: 48),
      child: InkWell(
        onTap: onTap,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: active ? FontWeight.w800 : FontWeight.w500)),
              if (active) Icon(ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keyword match against the engine's own reasonLines strings (engine.dart
/// lines ~164-274) — never a re-derivation of the underlying numbers.
class _ComparisonRow extends StatefulWidget {
  final Recommendation recommendation;
  const _ComparisonRow(this.recommendation, {super.key});

  @override
  State<_ComparisonRow> createState() => _ComparisonRowState();
}

class _ComparisonRowState extends State<_ComparisonRow> {
  bool _expanded = false;

  bool _mentions(String keyword) =>
      widget.recommendation.reasonLines.any((l) => l.toLowerCase().contains(keyword));

  @override
  Widget build(BuildContext context) {
    final rec = widget.recommendation;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            onTap: () => setState(() => _expanded = !_expanded),
            title: Text(rec.card.name, style: textTheme.titleSmall),
            subtitle: rec.isExcluded
                ? Text(rec.exclusionReason!, style: textTheme.bodySmall?.copyWith(color: AppColors.ink500))
                : Wrap(
                    spacing: AppSpace.xs,
                    children: [
                      if (_mentions('cap')) const StatusPill(label: 'Cap-aware', foreground: AppColors.navy800, background: AppColors.surfaceMuted),
                      if (_mentions('milestone')) const StatusPill(label: 'Milestone', foreground: AppColors.navy800, background: AppColors.surfaceMuted),
                      if (_mentions('forex')) const StatusPill(label: 'Forex', foreground: AppColors.navy800, background: AppColors.surfaceMuted),
                    ],
                  ),
            trailing: rec.isExcluded
                ? const Icon(Icons.block_rounded, color: AppColors.ink500)
                : MoneyText(rec.expectedValue, confidence: rec.confidence),
          ),
          if (_expanded && !rec.isExcluded)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in rec.reasonLines)
                    Padding(padding: const EdgeInsets.only(top: 2), child: Text('•  $line', style: textTheme.bodySmall)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
