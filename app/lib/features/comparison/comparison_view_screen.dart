import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/analytics.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

enum _SortBy { value, name }

/// ui-spec B4 — full sortable comparison table, reachable from B1 (Task 5's
/// hero card adds a "Compare all" action — wired in this task's Step 3)
/// and from B3 (Task 12).
///
/// Now also design 09 "Why this card? · the receipt" — the deck's trust
/// screen, and the one place the app owes the user the actual calculation
/// rather than a summary of it.
///
/// Each row expands into [RecommendationBreakdown]'s itemised table: base
/// rate and what it pays on this amount, cap headroom, merchant
/// restriction, ₹-per-point where points are involved, any forex/fuel/
/// milestone adjustment, then "You get back". Runners-up carry design 09's
/// "₹N behind", measured against the ranking's winner rather than the row
/// above — so re-sorting by name doesn't change what "behind" means.
///
/// This used to work by **keyword-matching the engine's own prose**:
/// `Recommendation` carried only `expectedValue` and free-text
/// `reasonLines`, so the cap/milestone/forex badges came from
/// `reasonLines.contains('cap')` and friends. That was a parser over
/// human-facing copy — re-wording a reason line silently changed what this
/// screen claimed. The engine now emits the numbers as numbers (see
/// [RecommendationBreakdown]) and nothing here reads the prose except the
/// fallback path for cards ranked on their base rate, which produce no
/// breakdown to show.
class ComparisonViewScreen extends ConsumerStatefulWidget {
  const ComparisonViewScreen({super.key});

  @override
  ConsumerState<ComparisonViewScreen> createState() => _ComparisonViewScreenState();
}

class _ComparisonViewScreenState extends ConsumerState<ComparisonViewScreen> {
  _SortBy _sortBy = _SortBy.value;
  bool _ascending = false;

  @override
  void initState() {
    super.initState();
    // initState, not build: build re-runs on every sort toggle, which would
    // count one visit as a dozen and inflate the metric.
    ref.read(analyticsProvider).track(AnalyticsEvent.comparisonViewed);
  }

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
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Compare cards', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: ranked.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
          data: (recommendations) {
            if (recommendations.isEmpty) {
              return const EmptyState(
                icon: Icons.compare_arrows_rounded,
                title: 'Nothing to compare',
                message: 'Add a card first.',
              );
            }
            final sorted = _sorted(recommendations);
            // The winner's value, independent of the current sort order.
            final included = recommendations.where((r) => !r.isExcluded);
            final bestValue = included.isEmpty
                ? const Money.zero()
                : included.map((r) => r.expectedValue).reduce((a, b) => a.paise >= b.paise ? a : b);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppSpace.md),
                  child: Row(
                    children: [
                      _SortHeaderButton(
                        label: 'Card',
                        active: _sortBy == _SortBy.name,
                        ascending: _ascending,
                        onTap: () => _onSort(_SortBy.name),
                      ),
                      const SizedBox(width: AppSpace.md),
                      _SortHeaderButton(
                        label: '₹ value',
                        active: _sortBy == _SortBy.value,
                        ascending: _ascending,
                        onTap: () => _onSort(_SortBy.value),
                      ),
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
                    itemBuilder: (context, index) {
                      final rec = sorted[index];
                      // Design 09's "₹25 behind" is measured against the best
                      // card in the ranking, not against whatever happens to
                      // sit above it in the current sort — sorting by name
                      // must not change what "behind" means.
                      final behind = rec.isExcluded || rec.expectedValue >= bestValue
                          ? null
                          : bestValue - rec.expectedValue;
                      return _ComparisonRow(rec, behind: behind, key: ValueKey(rec.card.id));
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SortHeaderButton extends StatelessWidget {
  final String label;
  final bool active;
  final bool ascending;
  final VoidCallback onTap;
  const _SortHeaderButton({
    required this.label,
    required this.active,
    required this.ascending,
    required this.onTap,
  });

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
              Text(
                label,
                style: BambooFonts.ui(
                  13.5,
                  weight: active ? FontWeight.w800 : FontWeight.w500,
                  color: active ? BambooInk.ink900 : BambooInk.ink500,
                ),
              ),
              if (active)
                Icon(
                  ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                  size: 14,
                  color: BambooInk.ink900,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Design 09's per-card row. The badges below used to be derived by
/// keyword-matching the engine's own prose; they now read
/// [RecommendationBreakdown] directly, so re-wording a reason line can no
/// longer silently change what this screen claims.
///
/// [behind] is how far this card trails the winner — design 09's "\u20b925
/// behind". Null on the winner itself.
class _ComparisonRow extends ConsumerStatefulWidget {
  final Recommendation recommendation;
  final Money? behind;
  const _ComparisonRow(this.recommendation, {this.behind, super.key});

  @override
  ConsumerState<_ComparisonRow> createState() => _ComparisonRowState();
}

class _ComparisonRowState extends ConsumerState<_ComparisonRow> {
  bool _expanded = false;
  bool _applying = false;

  /// Plan Phase 2.3. Asks the server for the destination at tap time rather
  /// than opening a URL the app already had — that request is what records
  /// the click, so an app-side link would mean unattributed applications and,
  /// worse, a conversion figure the business believed was complete.
  Future<void> _apply(CardProduct card) async {
    final repo = ref.read(partnerApplyRepositoryProvider);
    if (repo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to apply for a card.')),
      );
      return;
    }
    setState(() => _applying = true);
    ref.read(analyticsProvider).track(
      AnalyticsEvent.partnerApplyTapped,
      props: const {'placement': 'comparison'},
    );
    try {
      final url = await repo.beginApply(cardProductId: card.id, placement: 'comparison');
      if (!mounted) return;
      if (url == null) {
        // Not an error: the catalogue simply has no application link for this
        // card yet. Saying so is more useful than a generic failure.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No application link for this card yet.')),
        );
        return;
      }
      final uri = Uri.parse(url);
      if (!await canLaunchUrl(uri) || !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open your browser.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.recommendation;
    final breakdown = rec.breakdown;
    final behind = widget.behind;
    // Only offered for a card the user does NOT already hold. Suggesting
    // someone apply for a card that's already in their wallet is the kind of
    // detail that makes a recommendation feel automated rather than useful.
    final wallet = ref.watch(userCardsProvider).valueOrNull ?? const [];
    final alreadyOwned = wallet.any((c) => c.cardProductId == rec.card.id);
    final canApply = rec.card.hasApplyUrl && !alreadyOwned && !rec.isExcluded;

    return Card(
      color: BambooInk.glassFillOnPaper,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
      ),
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            onTap: rec.isExcluded ? null : () => setState(() => _expanded = !_expanded),
            title: Text(rec.card.name, style: BambooFonts.heading(15, color: BambooInk.ink900)),
            subtitle: rec.isExcluded
                ? Text(rec.exclusionReason!, style: BambooFonts.ui(12.5, color: BambooInk.ink500))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (breakdown != null)
                        Text(_headlineFor(breakdown), style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                      if (behind != null && !behind.isZero)
                        Text(
                          '${behind.format()} behind',
                          style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.clay),
                        ),
                    ],
                  ),
            trailing: rec.isExcluded
                ? const Icon(Icons.block_rounded, color: BambooInk.ink500)
                : MoneyText(
                    rec.expectedValue,
                    confidence: rec.confidence,
                    style: BambooFonts.money(17, color: BambooInk.ink900),
                  ),
          ),
          if (_expanded && !rec.isExcluded)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.md),
              child: breakdown == null
                  // The base-rate fallback path produces no breakdown \u2014 fall
                  // back to the engine's own prose rather than showing an
                  // empty panel.
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in rec.reasonLines)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '\u2022  $line',
                              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                            ),
                          ),
                      ],
                    )
                  : _BreakdownTable(breakdown: breakdown, total: rec.expectedValue),
            ),
          if (canApply)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.md),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _applying ? null : () => _apply(rec.card),
                    icon: _applying
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Apply on issuer site'),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  // Disclosed, not buried. A user comparing cards is entitled
                  // to know the link is commercial before they tap it, and
                  // the ranking above it deliberately does not account for
                  // it (see migration 0030's header).
                  Expanded(
                    child: Text(
                      'We may earn a commission. It does not affect this ranking.',
                      style: BambooFonts.ui(11, color: BambooInk.ink500),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The one-line summary under the card name \u2014 the rate the row was
  /// computed at, plus whatever single fact most changes the answer.
  static String _headlineFor(RecommendationBreakdown b) {
    final rate = '${(b.baseRatePerRupee * 100).toStringAsFixed(1)}%';
    if (b.capNote != null) return '$rate \u00b7 ${b.capNote}';
    final headroom = b.capHeadroom;
    if (headroom != null) return '$rate \u00b7 ${headroom.format()} of cap headroom left';
    return '$rate \u00b7 no cap in your way';
  }
}

/// Design 09's itemised table: base rate, cap headroom, merchant
/// restriction, points value used, then what you actually get back.
class _BreakdownTable extends StatelessWidget {
  final RecommendationBreakdown breakdown;
  final Money total;
  const _BreakdownTable({required this.breakdown, required this.total});

  @override
  Widget build(BuildContext context) {
    final b = breakdown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BreakdownRow(
          label: 'Base rate ${(b.baseRatePerRupee * 100).toStringAsFixed(1)}%',
          value: '+${b.baseValue.format()}',
        ),
        _BreakdownRow(
          label: 'Monthly cap headroom',
          // Null headroom means the rule has no spend cap at all, which is
          // "None" \u2014 distinct from a cap that exists and is exhausted.
          value: b.capHeadroom != null ? '${b.capHeadroom!.format()} free' : (b.capNote ?? 'None'),
        ),
        _BreakdownRow(label: 'Merchant restriction', value: b.merchantRestriction ?? 'None'),
        if (b.pointValueInr != null)
          _BreakdownRow(
            label: 'Points value used',
            value: '\u20b9${b.pointValueInr!.toStringAsFixed(2)} / point',
          ),
        if (!b.forexCost.isZero) _BreakdownRow(label: 'Less forex markup', value: '-${b.forexCost.format()}'),
        if (!b.fuelWaiver.isZero)
          _BreakdownRow(label: 'Fuel surcharge waiver', value: '+${b.fuelWaiver.format()}'),
        if (!b.milestoneBonus.isZero)
          _BreakdownRow(label: 'Milestone bonus', value: '+${b.milestoneBonus.format()}'),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Divider(height: 1, color: BambooInk.hairlineOnPaper),
        ),
        _BreakdownRow(label: 'You get back', value: total.format(), emphasised: true),
      ],
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasised;
  const _BreakdownRow({required this.label, required this.value, this.emphasised = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: BambooFonts.ui(
                12.5,
                weight: emphasised ? FontWeight.w700 : FontWeight.w400,
                color: emphasised ? BambooInk.ink900 : BambooInk.ink500,
              ),
            ),
          ),
          Text(
            value,
            style: emphasised
                ? BambooFonts.money(15, color: BambooInk.ink900)
                : BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.ink900),
          ),
        ],
      ),
    );
  }
}
