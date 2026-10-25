import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/local/response_cache.dart';
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
const _localSearchCachePrefix = 'pandapay_merchant_search_v1:';

class _MerchantSearchScreenState extends ConsumerState<MerchantSearchScreen> {
  final _controller = TextEditingController();
  final Map<String, List<NearbyMerchantCandidate>> _memoryCache = {};
  Timer? _debounce;
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
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _recent = prefs.getStringList(_recentSearchesKey) ?? const []);
  }

  Future<void> _saveRecent(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final updated = [trimmed, ..._recent.where((q) => q != trimmed)].take(_maxRecentSearches).toList();
    await prefs.setStringList(_recentSearchesKey, updated);
    if (mounted) setState(() => _recent = updated);
  }

  Future<ResponseCache?> _getCache() async {
    try {
      final db = await ref.read(appDatabaseProvider.future);
      return ResponseCache(db);
    } catch (_) {
      return null;
    }
  }

  Future<List<NearbyMerchantCandidate>?> _readLocalDbCache(String key) async {
    try {
      final cache = await _getCache();
      if (cache == null) return null;
      final raw = await cache.get('$_localSearchCachePrefix$key');
      if (raw == null) return null;
      final list = jsonDecode(raw) as List;
      return list.map((item) {
        final map = item as Map<String, dynamic>;
        return NearbyMerchantCandidate(
          merchantId: map['merchantId'] as String,
          displayName: map['displayName'] as String?,
          categoryId: map['categoryId'] as String?,
          location: const GeoPoint(lat: 0, lng: 0),
        );
      }).toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLocalDbCache(String key, List<NearbyMerchantCandidate> results) async {
    try {
      final cache = await _getCache();
      if (cache == null) return;
      final encoded = jsonEncode(
        results.map((r) => {
          'merchantId': r.merchantId,
          'displayName': r.displayName,
          'categoryId': r.categoryId,
        }).toList(),
      );
      await cache.put('$_localSearchCachePrefix$key', encoded);
    } catch (_) {}
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _results = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _search(trimmed, saveRecent: false);
    });
  }

  Future<void> _search(String query, {bool saveRecent = true}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final lowerQ = trimmed.toLowerCase();

    // 1. Gather user's local/detected transaction merchants immediately
    final history = ref.read(transactionsProvider).valueOrNull ?? const [];
    final localMatches = <NearbyMerchantCandidate>[];
    final seen = <String>{};

    for (final txn in history) {
      final name = txn.merchantName?.trim();
      if (name != null && name.toLowerCase().contains(lowerQ)) {
        final normKey = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (seen.add(normKey)) {
          localMatches.add(
            NearbyMerchantCandidate(
              merchantId: 'local-$normKey',
              displayName: name,
              categoryId: txn.categoryId ?? txn.parentCategoryId,
              location: const GeoPoint(lat: 0, lng: 0),
            ),
          );
        }
      }
    }

    // 2. Check in-memory cache first (0ms latency)
    if (_memoryCache.containsKey(lowerQ)) {
      final cachedServer = _memoryCache[lowerQ]!;
      final merged = <NearbyMerchantCandidate>[...localMatches];
      for (final s in cachedServer) {
        final name = s.displayName?.trim() ?? '';
        final normKey = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (seen.add(normKey)) merged.add(s);
      }
      if (mounted) setState(() => _results = merged);
      if (saveRecent) await _saveRecent(trimmed);
      return;
    }

    // 3. Check SQLite local database cache
    final localDbCached = await _readLocalDbCache(lowerQ);
    if (localDbCached != null && localDbCached.isNotEmpty) {
      _memoryCache[lowerQ] = localDbCached;
      final merged = <NearbyMerchantCandidate>[...localMatches];
      for (final s in localDbCached) {
        final name = s.displayName?.trim() ?? '';
        final normKey = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (seen.add(normKey)) merged.add(s);
      }
      if (mounted) setState(() => _results = merged);
      if (saveRecent) await _saveRecent(trimmed);
      return;
    }

    // 4. Query server and cache results locally
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      List<NearbyMerchantCandidate> serverResults = const [];
      try {
        final repo = ref.read(merchantSearchRepositoryProvider);
        serverResults = await repo.search(trimmed);
      } catch (err) {
        if (localMatches.isEmpty) rethrow;
      }

      _memoryCache[lowerQ] = serverResults;
      if (serverResults.isNotEmpty) {
        await _writeLocalDbCache(lowerQ, serverResults);
      }

      final merged = <NearbyMerchantCandidate>[...localMatches];
      for (final s in serverResults) {
        final name = s.displayName?.trim() ?? '';
        final normKey = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (seen.add(normKey)) merged.add(s);
      }

      if (saveRecent) await _saveRecent(trimmed);
      if (mounted) setState(() => _results = merged);
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
            suffixIcon: _controller.text.isNotEmpty
                ? IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded, size: 18, color: BambooInk.ink500),
                    onPressed: () {
                      _controller.clear();
                      _onQueryChanged('');
                    },
                  )
                : null,
          ),
          onChanged: _onQueryChanged,
          onSubmitted: (q) => _search(q, saveRecent: true),
        ),
        actions: [
          IconButton(
            tooltip: 'Search merchants',
            icon: const Icon(Icons.search_rounded, color: BambooInk.ink900),
            onPressed: () => _search(_controller.text, saveRecent: true),
          ),
        ],
      ),
      body: AppBackground(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return ErrorState(message: _error!, onRetry: () => _search(_controller.text, saveRecent: true));

    if (_results == null) {
      if (_recent.isEmpty) {
        return const EmptyState(
          icon: Icons.search_rounded,
          title: 'Search for a merchant',
          message: 'Recent searches will show up here.',
        );
      }
      return ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(
            'Recent searches',
            style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
          ),
          for (final q in _recent)
            ListTile(
              leading: const Icon(Icons.history_rounded, color: BambooInk.ink500),
              title: Text(q, style: BambooFonts.ui(14.5, color: BambooInk.ink900)),
              onTap: () {
                _controller.text = q;
                _search(q, saveRecent: true);
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
      itemBuilder: (context, index) =>
          _MerchantResultTile(
            key: ValueKey(_results![index].merchantId),
            _results![index],
            onTap: () => _saveRecent(_results![index].displayName ?? ''),
          ),
    );
  }
}

class _MerchantResultTile extends ConsumerWidget {
  final NearbyMerchantCandidate candidate;
  final VoidCallback? onTap;
  const _MerchantResultTile(this.candidate, {this.onTap, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final best = ref.watch(
      bestCardForMerchantProvider(
        MerchantRecommendationQuery(
          categoryId: candidate.categoryId,
          merchantName: candidate.displayName,
        ),
      ),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          onTap: onTap,
          title: Text(
            candidate.displayName ?? 'Unnamed merchant',
            style: BambooFonts.heading(14.5, color: BambooInk.ink900),
          ),
          subtitle: best.when(
            loading: () => Text('Ranking…', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
            error: (err, _) =>
                Text(userFacingErrorMessage(err), style: BambooFonts.ui(12.5, color: BambooInk.clay)),
            data: (rec) => Text(
              rec == null ? 'No usable card for this merchant.' : 'Use ${rec.card.name}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
          trailing: best.valueOrNull != null
              ? MoneyText(
                  best.value!.expectedValue,
                  confidence: best.value!.confidence,
                  style: BambooFonts.money(14, color: BambooInk.ink900),
                )
              : null,
        ),
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
