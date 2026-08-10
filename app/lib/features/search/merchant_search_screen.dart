import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

/// ui-spec B5. Recent searches persisted locally (same shared_preferences
/// pattern onboardingCompleteProvider uses in providers.dart) — no backend
/// needed for that part, per this plan's brief.
class MerchantSearchScreen extends ConsumerStatefulWidget {
  const MerchantSearchScreen({super.key});

  @override
  ConsumerState<MerchantSearchScreen> createState() => _MerchantSearchScreenState();
}

const _recentSearchesKey = 'pandapay_app.merchant_recent_searches_v1';
const _maxRecentSearches = 8;

class _MerchantSearchScreenState extends ConsumerState<MerchantSearchScreen> {
  final _controller = TextEditingController();
  List<String> _recent = const [];
  List<NearbyMerchantCandidate>? _results;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _recent = prefs.getStringList(_recentSearchesKey) ?? const []);
  }

  Future<void> _saveRecent(String query) async {
    final prefs = await SharedPreferences.getInstance();
    final updated = [query, ..._recent.where((q) => q != query)].take(_maxRecentSearches).toList();
    await prefs.setStringList(_recentSearchesKey, updated);
    if (mounted) setState(() => _recent = updated);
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(merchantSearchRepositoryProvider);
      final results = await repo.search(query.trim());
      await _saveRecent(query.trim());
      if (mounted) setState(() => _results = results);
    } catch (err) {
      if (mounted) setState(() => _error = userFacingErrorMessage(err));
    } finally {
      if (mounted) setState(() => _loading = false);
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
        title: TextField(
          controller: _controller,
          autofocus: true,
          style: BambooFonts.ui(15, color: BambooInk.ink900),
          decoration: InputDecoration(
            hintText: 'Search merchants',
            hintStyle: BambooFonts.ui(15, color: BambooInk.ink500),
            border: InputBorder.none,
          ),
          onSubmitted: _search,
        ),
        actions: [IconButton(icon: const Icon(Icons.search_rounded, color: BambooInk.ink900), onPressed: () => _search(_controller.text))],
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
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return ErrorState(message: _error!, onRetry: () => _search(_controller.text));

    if (_results == null) {
      if (_recent.isEmpty) {
        return const EmptyState(icon: Icons.search_rounded, title: 'Search for a merchant', message: 'Recent searches will show up here.');
      }
      return ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text('Recent searches', style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900)),
          for (final q in _recent)
            ListTile(
              leading: const Icon(Icons.history_rounded, color: BambooInk.ink500),
              title: Text(q, style: BambooFonts.ui(14.5, color: BambooInk.ink900)),
              onTap: () {
                _controller.text = q;
                _search(q);
              },
            ),
        ],
      );
    }

    if (_results!.isEmpty) {
      // ui-spec B5: "category fallback when no match" — the user picks a
      // category directly instead of a specific merchant.
      return _CategoryFallback(query: _controller.text);
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpace.lg),
      itemCount: _results!.length,
      // Keyed by merchant identity, on the exact widget instance the
      // builder returns — same lesson as Home's ranked list
      // (_RankedList in home_screen.dart): _MerchantResultTile watches
      // bestCardForMerchantProvider per-tile, so without a stable key on
      // this top-level item, Flutter can't tell rebuilt tiles apart across
      // rebuilds/reorders and would drop/reset element state.
      itemBuilder: (context, index) => _MerchantResultTile(
        key: ValueKey(_results![index].merchantId),
        _results![index],
      ),
    );
  }
}

class _MerchantResultTile extends ConsumerWidget {
  final NearbyMerchantCandidate candidate;
  const _MerchantResultTile(this.candidate, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final best = ref.watch(bestCardForMerchantProvider(candidate.categoryId));
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: ListTile(
        title: Text(candidate.displayName ?? 'Unnamed merchant', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
        subtitle: best.when(
          loading: () => Text('Ranking…', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
          error: (err, _) => Text(userFacingErrorMessage(err), style: BambooFonts.ui(12.5, color: BambooInk.clay)),
          data: (rec) => Text(
            rec == null ? 'No usable card for this merchant.' : 'Use ${rec.card.name}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        ),
        trailing: best.valueOrNull != null
            ? MoneyText(best.value!.expectedValue, confidence: best.value!.confidence, style: BambooFonts.money(14, color: BambooInk.ink900))
            : null,
      ),
    );
  }
}

class _CategoryFallback extends ConsumerWidget {
  final String query;
  const _CategoryFallback({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    return categories.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
      data: (list) => ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(
            'No merchant found for "$query" — pick a category instead:',
            style: BambooFonts.ui(13.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.xs,
            children: [
              for (final c in list)
                ActionChip(
                  label: Text(c.name),
                  labelStyle: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.ink900),
                  backgroundColor: BambooInk.paperMuted,
                  side: BorderSide.none,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  onPressed: () {
                    ref.read(selectedCategoryProvider.notifier).state = c.slug;
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
