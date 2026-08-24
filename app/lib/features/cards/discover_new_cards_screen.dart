import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/analytics.dart';
import '../../data/api_exception.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../main.dart' show MoneyText;

/// New scope beyond product-plan.md's documented v1 (§22.2, listed there
/// only as a future "Spend Simulator" bet) — surfaces
/// [CardAcquisitionRecommender]'s output: cards NOT already in the wallet,
/// ranked by projected annual portfolio uplift given the user's real
/// trailing-12-month spend.
///
/// Deliberately a separate screen from FindCardsScreen ("find cards you
/// already own", matched from forwarded email/SMS, added with one tap) —
/// this screen recommends cards the user does NOT have, and nothing here
/// ever writes a user_cards row. The only action is "Apply", which opens
/// the issuer's own application flow outside the app.
class DiscoverNewCardsScreen extends ConsumerStatefulWidget {
  const DiscoverNewCardsScreen({super.key});

  @override
  ConsumerState<DiscoverNewCardsScreen> createState() => _DiscoverNewCardsScreenState();
}

class _DiscoverNewCardsScreenState extends ConsumerState<DiscoverNewCardsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(analyticsProvider).track(AnalyticsEvent.recommendationViewed, props: const {
        'surface': 'discover_new_cards',
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final candidates = ref.watch(acquisitionCandidatesProvider);
    final categories = ref.watch(categoriesProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Cards worth getting', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(child: _body(candidates, categories)),
    );
  }

  Widget _body(AsyncValue<List<AcquisitionCandidate>> candidates, AsyncValue<List<SpendCategory>> categories) {
    if (candidates.isLoading || categories.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = candidates.error ?? categories.error;
    if (error != null) {
      return ErrorState(
        message: userFacingErrorMessage(error),
        onRetry: () {
          ref.invalidate(categorySpendProvider);
          ref.invalidate(catalogueProvider);
        },
      );
    }

    final worthwhile = candidates.requireValue.where((c) => c.isWorthwhile).toList();
    final categoryNames = {for (final c in categories.requireValue) c.id: c.name};

    if (worthwhile.isEmpty) {
      return const EmptyState(
        icon: Icons.auto_awesome_outlined,
        title: 'Nothing to recommend yet',
        message:
            'Based on your real spend so far, none of the cards you don\'t already own would '
            'earn you more than your current wallet. Check back once we have more of your '
            'spending history, or after new cards are added to the catalogue.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, 30),
      children: [
        Text(
          'Ranked by how much better off your whole wallet would be over a year, based on your '
          'own spending — not just this card\'s advertised rate.',
          style: BambooFonts.ui(13, color: BambooInk.ink500, height: 1.5),
        ),
        const SizedBox(height: AppSpace.lg),
        for (final candidate in worthwhile)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: _CandidateCard(candidate: candidate, categoryNames: categoryNames),
          ),
      ],
    );
  }
}

class _CandidateCard extends ConsumerStatefulWidget {
  final AcquisitionCandidate candidate;
  final Map<String, String> categoryNames;

  const _CandidateCard({required this.candidate, required this.categoryNames});

  @override
  ConsumerState<_CandidateCard> createState() => _CandidateCardState();
}

class _CandidateCardState extends ConsumerState<_CandidateCard> {
  bool _applying = false;
  bool _expanded = false;

  /// Same "ask the server for the destination at tap time" flow
  /// comparison_view_screen.dart already uses — the URL is never cached or
  /// shipped in the catalogue, so a click is always attributed.
  Future<void> _apply() async {
    final repo = ref.read(partnerApplyRepositoryProvider);
    if (repo == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Sign in to apply for a card.')));
      return;
    }
    setState(() => _applying = true);
    ref.read(analyticsProvider).track(
      AnalyticsEvent.partnerApplyTapped,
      props: const {'placement': 'discover_new_cards'},
    );
    try {
      final url = await repo.beginApply(cardProductId: widget.candidate.card.id, placement: 'discover');
      if (!mounted) return;
      if (url == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No application link for this card yet.')));
        return;
      }
      final uri = Uri.parse(url);
      if (!await canLaunchUrl(uri) || !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open your browser.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    final card = candidate.card;

    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(card.name, style: BambooFonts.heading(15.5, color: BambooInk.ink900)),
                    if (card.issuerName != null) ...[
                      const SizedBox(height: 2),
                      Text(card.issuerName!, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                    ],
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.trending_up_rounded, size: 15, color: BambooInk.jade),
                      const SizedBox(width: 3),
                      MoneyText(
                        candidate.uplift,
                        confidence: Confidence.estimated,
                        style: BambooFonts.heading(15, color: BambooInk.jade),
                      ),
                    ],
                  ),
                  Text('extra per year', style: BambooFonts.ui(11, color: BambooInk.ink500)),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (!card.annualFeeInr.isZeroOrNull)
            Text(
              'Annual fee ${candidate.annualFeeNet.format(hidePaise: true)}'
              '${candidate.annualFeeNet.isZero && !card.annualFeeInr!.isZero ? ' (waived by your spend)' : ''}',
              style: BambooFonts.ui(12, color: BambooInk.ink500),
            ),
          const SizedBox(height: AppSpace.sm),
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              children: [
                Text(
                  _expanded ? 'Hide why' : 'Why this card?',
                  style: BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.slate),
                ),
                Icon(
                  _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 18,
                  color: BambooInk.slate,
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: AppSpace.xs),
            for (final entry in candidate.valueByCategory.entries)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${widget.categoryNames[entry.key] ?? 'Other spending'}: '
                  '${entry.value.format(hidePaise: true)}/year',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
              ),
          ],
          const SizedBox(height: AppSpace.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _applying ? null : _apply,
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
              ),
              child: Text(_applying ? 'Opening…' : 'Apply'),
            ),
          ),
        ],
      ),
    );
  }
}

extension _NullableMoneyCheck on Money? {
  bool get isZeroOrNull => this == null || this!.isZero;
}
