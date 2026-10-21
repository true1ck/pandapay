import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/subscription_credits_repository.dart';

class SubscriptionCreditsScreen extends ConsumerStatefulWidget {
  const SubscriptionCreditsScreen({super.key});

  @override
  ConsumerState<SubscriptionCreditsScreen> createState() =>
      _SubscriptionCreditsScreenState();
}

class _SubscriptionCreditsScreenState
    extends ConsumerState<SubscriptionCreditsScreen>
    with WidgetsBindingObserver {
  bool _loadingMore = false;
  String? _loadMoreError;
  final List<SubscriptionCreditLedgerEntry> _additionalEntries = [];
  String? _nextCursor;
  bool _cursorInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _additionalEntries.clear();
      _nextCursor = null;
      _cursorInitialized = false;
      _loadMoreError = null;
    });
    ref.invalidate(subscriptionCreditDataProvider);
    try {
      await ref.read(subscriptionCreditDataProvider.future);
    } catch (_) {
      // The AsyncValue below owns the visible error state.
    }
  }

  Future<void> _loadMore(
    String cursor, {
    required Set<String> existingIds,
  }) async {
    final repository = ref.read(subscriptionCreditsRepositoryProvider);
    if (repository == null || _loadingMore) return;
    final namespace = ref.read(cacheNamespaceProvider);
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final page = await repository.loadMore(cursor);
      if (!mounted || ref.read(cacheNamespaceProvider) != namespace) return;
      final seen = {
        ...existingIds,
        ..._additionalEntries.map((entry) => entry.id),
      };
      setState(() {
        _nextCursor = page.nextCursor;
        _additionalEntries.addAll(
          page.entries.where((entry) => seen.add(entry.id)),
        );
      });
    } catch (error) {
      if (mounted) {
        setState(() => _loadMoreError = userFacingErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(cacheNamespaceProvider, (previous, next) {
      if (previous == null || previous == next || !mounted) return;
      setState(() {
        _additionalEntries.clear();
        _nextCursor = null;
        _cursorInitialized = false;
        _loadMoreError = null;
      });
      ref.invalidate(subscriptionCreditDataProvider);
    });
    final repository = ref.watch(subscriptionCreditsRepositoryProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Subscription credits',
          style: BambooFonts.heading(19, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: repository == null
            ? const EmptyState(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Sign in to view credits',
                message:
                    'Subscription credits are tied to your PandaPay account.',
              )
            : ref
                  .watch(subscriptionCreditDataProvider)
                  .when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => ErrorState(
                      message: userFacingErrorMessage(error),
                      onRetry: () =>
                          ref.invalidate(subscriptionCreditDataProvider),
                    ),
                    data: (data) => data == null
                        ? const EmptyState(
                            icon: Icons.account_balance_wallet_outlined,
                            title: 'Sign in to view credits',
                            message:
                                'Subscription credits are tied to your PandaPay account.',
                          )
                        : _buildData(data),
                  ),
      ),
    );
  }

  Widget _buildData(SubscriptionCreditData data) {
    if (!_cursorInitialized) {
      _cursorInitialized = true;
      _nextCursor = data.ledger.nextCursor;
    }
    final entries = [...data.ledger.entries, ..._additionalEntries];
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
        children: [
          if (data.isStale) ...[
            _StaleCreditNotice(cachedAt: data.cachedAt),
            const SizedBox(height: 12),
          ],
          Container(
            padding: const EdgeInsets.all(19),
            decoration: BoxDecoration(
              color: BambooInk.slate,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AVAILABLE CREDITS',
                  style: BambooFonts.ui(
                    11.5,
                    weight: FontWeight.w700,
                    color: BambooInk.onSlateSubtle,
                  ).copyWith(letterSpacing: 1.2),
                ),
                const SizedBox(height: 7),
                Text(
                  data.balance.available.inr,
                  style: BambooFonts.heading(31, color: BambooInk.lime),
                ),
                const SizedBox(height: 15),
                Row(
                  children: [
                    Expanded(
                      child: _BalanceMetric(
                        label: 'Reserved',
                        value: data.balance.reserved.inr,
                      ),
                    ),
                    Expanded(
                      child: _BalanceMetric(
                        label: 'Used',
                        value: data.balance.used?.inr ?? '—',
                      ),
                    ),
                  ],
                ),
                if (data.balance.lastConfirmedAt != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Balance confirmed ${_dateLabel(data.balance.lastConfirmedAt!)}',
                    style: BambooFonts.ui(11, color: BambooInk.onSlateSubtle),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 15),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: BambooInk.wash,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: BambooInk.hairlineOnPaper),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: BambooInk.jade,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'For a future PandaPay subscription benefit',
                        style: BambooFonts.ui(
                          14,
                          weight: FontWeight.w700,
                          color: BambooInk.ink900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  'Credits cannot be withdrawn or transferred. Subscription redemption is not '
                  'available yet, so no store discount can be applied today.',
                  style: BambooFonts.ui(
                    12.5,
                    color: BambooInk.ink700,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                const SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: null,
                    child: Text('Subscription redemption unavailable'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'CREDIT HISTORY',
            style: BambooFonts.ui(
              11.5,
              weight: FontWeight.w700,
              color: BambooInk.ink500,
            ).copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: 9),
          if (entries.isEmpty)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              child: Text(
                'No subscription-credit activity yet. Confirmed referral rewards will appear here.',
                style: BambooFonts.ui(
                  13,
                  color: BambooInk.ink500,
                  height: 1.45,
                ),
              ),
            )
          else
            for (final entry in entries) _LedgerRow(entry: entry),
          if (_nextCursor != null) ...[
            if (_loadMoreError != null) ...[
              const SizedBox(height: 5),
              Text(
                _loadMoreError!,
                style: BambooFonts.ui(12.5, color: BambooInk.clay),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _loadingMore
                  ? null
                  : () => _loadMore(
                      _nextCursor!,
                      existingIds: entries.map((entry) => entry.id).toSet(),
                    ),
              child: Text(_loadingMore ? 'Loading…' : 'Load older activity'),
            ),
          ],
        ],
      ),
    );
  }
}

class _StaleCreditNotice extends StatelessWidget {
  const _StaleCreditNotice({required this.cachedAt});

  final DateTime? cachedAt;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: BambooInk.wash,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BambooInk.hairlineOnPaper),
    ),
    child: Text(
      cachedAt == null
          ? 'Offline — showing saved credit information. Reconnect to confirm the latest balance.'
          : 'Offline — showing saved information from ${_dateLabel(cachedAt!)}. Reconnect to confirm the latest balance.',
      style: BambooFonts.ui(12.5, color: BambooInk.ink700, height: 1.4),
    ),
  );
}

class _BalanceMetric extends StatelessWidget {
  const _BalanceMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: BambooFonts.ui(11.5, color: BambooInk.onSlateSubtle)),
      const SizedBox(height: 3),
      Text(value, style: BambooFonts.heading(15, color: BambooInk.paper)),
    ],
  );
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.entry});

  final SubscriptionCreditLedgerEntry entry;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
    decoration: BoxDecoration(
      color: BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: BambooInk.hairlineOnPaper),
    ),
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: BambooInk.wash,
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(
            Icons.receipt_long_outlined,
            size: 18,
            color: BambooInk.jade,
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.displayKind,
                style: BambooFonts.ui(
                  13,
                  weight: FontWeight.w600,
                  color: BambooInk.ink900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                [
                  entry.state.replaceAll('_', ' '),
                  if (entry.createdAt != null) _dateLabel(entry.createdAt!),
                  if (entry.expiresAt != null)
                    'Expires ${_dateLabel(entry.expiresAt!)}',
                ].join(' · '),
                style: BambooFonts.ui(11.5, color: BambooInk.ink500),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          entry.amount.inr,
          style: BambooFonts.ui(
            13,
            weight: FontWeight.w700,
            color: BambooInk.ink900,
          ),
        ),
      ],
    ),
  );
}

String _dateLabel(DateTime date) =>
    '${date.toLocal().day}/${date.toLocal().month}/${date.toLocal().year}';
