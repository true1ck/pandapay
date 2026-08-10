import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import 'storage_util.dart';

/// H5 Data & Storage. Entirely local-device work — no new backend routes
/// (per the plan's own audit: "Storage-used/cache-clear/record-counts are
/// device-local concerns ... no new backend needed"). Reached via a plain
/// `Navigator.push` from the settings hub, same pattern as
/// `tools/tools_hub_screen.dart`'s leaf screens.
///
/// Providers below are deliberately defined in this file (not
/// `app/providers.dart`) — this screen is being built in parallel with
/// sibling H-group screens and must not create merge conflicts in the
/// shared providers file.

/// Recursive byte size of the app's cache directory. Re-invalidated after
/// "Clear cache" / "Reset all data" so the reported number visibly drops.
final _cacheSizeProvider = FutureProvider.autoDispose<int>((ref) async {
  final dir = await getApplicationCacheDirectory();
  return computeDirectorySize(dir);
});

/// One-shot transaction count. `userCardsProvider` is already a provider
/// elsewhere in the app (reused, not re-fetched via a new endpoint); this
/// mirrors that shape for transactions via a single `fetchTransactions()`
/// call rather than counting on every rebuild.
final _transactionCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return 0;
  final transactions = await repo.fetchTransactions();
  return transactions.length;
});

class DataStorageScreen extends ConsumerWidget {
  const DataStorageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(accessTokenProvider) != null;
    final cacheSize = ref.watch(_cacheSizeProvider);
    final cardsAsync = ref.watch(userCardsProvider);
    final txnCountAsync = ref.watch(_transactionCountProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Data & Storage', style: BambooFonts.heading(18, color: BambooInk.ink900)),
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
        child: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          _SectionLabel('Storage used'),
          const SizedBox(height: AppSpace.sm),
          _StorageRow(cacheSize: cacheSize),
          const SizedBox(height: AppSpace.xl),
          _SectionLabel('Record counts'),
          const SizedBox(height: AppSpace.sm),
          if (!signedIn)
            const _InfoCard(text: 'Sign in to see your record counts')
          else
            _RecordCountsCard(cardsAsync: cardsAsync, txnCountAsync: txnCountAsync),
          const SizedBox(height: AppSpace.xl),
          _SectionLabel('Manage'),
          const SizedBox(height: AppSpace.sm),
          _ActionTile(
            icon: Icons.cleaning_services_outlined,
            title: 'Clear cache',
            subtitle: 'Deletes cached images and temp files only',
            onTap: () => _clearCache(context, ref),
          ),
          const SizedBox(height: AppSpace.md),
          _ActionTile(
            icon: Icons.refresh_rounded,
            title: 'Re-download bundled data',
            subtitle: 'Refreshes the card catalogue and nearby-merchant data',
            onTap: () => _redownloadBundledData(context, ref),
          ),
          const SizedBox(height: AppSpace.xl),
          _SectionLabel('Danger zone'),
          const SizedBox(height: AppSpace.sm),
          _ActionTile(
            icon: Icons.restart_alt_rounded,
            title: 'Reset all data',
            subtitle: 'Clears local cache and preferences — does not sign you out',
            destructive: true,
            onTap: () => _confirmResetAllData(context, ref),
          ),
        ],
        ),
      ),
    );
  }

  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    final dir = await getApplicationCacheDirectory();
    await clearDirectoryContents(dir);
    ref.invalidate(_cacheSizeProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cache cleared')));
  }

  Future<void> _redownloadBundledData(BuildContext context, WidgetRef ref) async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Refreshing bundled data...')));
    ref.invalidate(catalogueProvider);
    ref.invalidate(nearbyMerchantsRepositoryProvider);
  }

  Future<void> _confirmResetAllData(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset all data?'),
        content: const Text(
          'This clears local cache and app preferences only — your account, cards, and transaction '
          'history are untouched. This does not sign you out.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset', style: TextStyle(color: BambooInk.clay)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final prefs = await SharedPreferences.getInstance();
    // token_store.dart's own keys: 'pandapay_app.access_token' /
    // 'pandapay_app.refresh_token' — both share this prefix, so excluding
    // it preserves the signed-in session exactly, nothing more.
    await clearPreferencesExceptPrefixes(prefs, const ['pandapay_app.']);

    final dir = await getApplicationCacheDirectory();
    await clearDirectoryContents(dir);
    ref.invalidate(_cacheSizeProvider);

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Local data reset')));
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: BambooFonts.ui(12, weight: FontWeight.w700, color: BambooInk.ink500).copyWith(letterSpacing: 1.1),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String text;
  const _InfoCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: BambooInk.ink500)),
    );
  }
}

class _StorageRow extends StatelessWidget {
  final AsyncValue<int> cacheSize;
  const _StorageRow({required this.cacheSize});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          const Icon(Icons.sd_storage_outlined, size: 20, color: BambooInk.ink900),
          const SizedBox(width: AppSpace.md),
          const Expanded(child: Text('Cache size')),
          cacheSize.when(
            data: (bytes) => Text(formatBytes(bytes), style: Theme.of(context).textTheme.titleSmall),
            loading: () => const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            error: (_, _) => const Text('—'),
          ),
        ],
      ),
    );
  }
}

class _RecordCountsCard extends StatelessWidget {
  final AsyncValue<List<dynamic>> cardsAsync;
  final AsyncValue<int> txnCountAsync;
  const _RecordCountsCard({required this.cardsAsync, required this.txnCountAsync});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CountLine(
            icon: Icons.credit_card_outlined,
            label: cardsAsync.when(
              data: (cards) => '${cards.length} cards',
              loading: () => 'Loading cards...',
              error: (_, _) => 'Unable to load cards',
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          _CountLine(
            icon: Icons.receipt_long_outlined,
            label: txnCountAsync.when(
              data: (count) => '$count transactions',
              loading: () => 'Loading transactions...',
              error: (_, _) => 'Unable to load transactions',
            ),
          ),
        ],
      ),
    );
  }
}

class _CountLine extends StatelessWidget {
  final IconData icon;
  final String label;
  const _CountLine({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: BambooInk.ink500),
        const SizedBox(width: AppSpace.sm),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool destructive;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? BambooInk.clay : BambooInk.ink900;
    return Material(
      color: destructive ? BambooInk.clay.withValues(alpha: 0.1) : BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: destructive ? BambooInk.clay.withValues(alpha: 0.3) : BambooInk.hairlineOnPaper),
          ),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: color)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: destructive ? BambooInk.clay : BambooInk.ink300),
            ],
          ),
        ),
      ),
    );
  }
}
