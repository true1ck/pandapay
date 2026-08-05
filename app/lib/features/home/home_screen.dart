import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/providers.dart';
import '../../main.dart' show MoneyText;

/// B1 Home, cut down to what's real today: category chips + ranked list
/// with reason lines, backed by the actual engine and a live API fetch.
/// Missing vs the full ui-spec B1: hero-card treatment, alerts strip,
/// backup-card row, geofence-driven context line, offline bundling — all
/// noted as not-yet-done rather than faked.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const _categories = [
    ('groceries', 'Groceries'),
    ('fuel', 'Fuel'),
    ('dining', 'Dining'),
    ('online', 'Online'),
    ('travel', 'Travel'),
    ('bills', 'Bills'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedCategory = ref.watch(selectedCategoryProvider);
    final ranked = ref.watch(rankedRecommendationsProvider);

    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final (slug, label) in _categories)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: selectedCategory == slug,
                    onSelected: (_) =>
                        ref.read(selectedCategoryProvider.notifier).state = slug,
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _RankedList(ranked: ranked)),
      ],
    );
  }
}

class _RankedList extends StatelessWidget {
  final AsyncValue<List<Recommendation>> ranked;
  const _RankedList({required this.ranked});

  @override
  Widget build(BuildContext context) {
    return ranked.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            "Couldn't load your cards — ${err.toString()}\n\n"
            'Is the api/ service running on localhost:4000?',
            textAlign: TextAlign.center,
          ),
        ),
      ),
      data: (recommendations) {
        if (recommendations.isEmpty) {
          return const Center(child: Text('No cards yet — add one to get started.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: recommendations.length,
          itemBuilder: (context, index) => _RecommendationCard(recommendations[index]),
        );
      },
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  final Recommendation recommendation;
  const _RecommendationCard(this.recommendation);

  @override
  Widget build(BuildContext context) {
    final excluded = recommendation.isExcluded;
    return Card(
      color: excluded ? Theme.of(context).disabledColor.withValues(alpha: 0.08) : null,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    recommendation.card.name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: excluded ? Theme.of(context).disabledColor : null,
                        ),
                  ),
                ),
                if (recommendation.isOverride)
                  const Chip(label: Text('Override'), visualDensity: VisualDensity.compact),
                if (!excluded)
                  MoneyText(recommendation.expectedValue, confidence: recommendation.confidence),
              ],
            ),
            if (excluded)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  recommendation.exclusionReason!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            else
              for (final line in recommendation.reasonLines)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(line, style: Theme.of(context).textTheme.bodySmall),
                ),
          ],
        ),
      ),
    );
  }
}
