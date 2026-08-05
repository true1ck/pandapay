import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// AD-8 Data Quality Dashboard: a single-query snapshot over
/// v_data_quality_dashboard. Explicitly NOT here (see api/'s
/// GET /admin/data-quality-dashboard doc comment): AD-8.3 trend lines
/// (needs a time-series snapshot table + job, not built) and AD-8.4
/// operator alerting (needs a notification channel, none exists). This
/// screen shows the current numbers only, labeled as such.
class DataQualityDashboardScreen extends ConsumerWidget {
  const DataQualityDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dashboard = ref.watch(dataQualityDashboardProvider);
    return dashboard.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Failed to load dashboard: $err')),
      data: (d) {
        if (d == null) return const SizedBox.shrink();
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text('Data quality snapshot',
                        style: Theme.of(context).textTheme.headlineSmall, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                    onPressed: () => ref.invalidate(dataQualityDashboardProvider),
                  ),
                ],
              ),
              const Text(
                'Current values only — no trend lines (would need a time-series snapshot table) '
                'and no threshold alerting (no notification channel wired up) yet.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _StatCard('Cards published', d['cards_published'], Icons.credit_card),
                  _StatCard('Cards stale > 180d', d['cards_stale_180d'], Icons.hourglass_bottom, warnIfNonzero: true),
                  _StatCard('Merchants total', d['merchants_total'], Icons.storefront),
                  _StatCard('Merchants published', d['merchants_published'], Icons.check_circle_outline),
                  _StatCard('Merchants high-confidence', d['merchants_high_conf'], Icons.verified),
                  _StatCard('Merchant locations', d['locations_total'], Icons.place_outlined),
                  _StatCard('Open policy alerts', d['alerts_open'], Icons.notifications_active, warnIfNonzero: true),
                  _StatCard('Pending error reports', d['error_reports_pending'], Icons.report_gmailerrorred, warnIfNonzero: true),
                  _StatCard('Pending card requests', d['card_requests_pending'], Icons.playlist_add_check),
                  _StatCard('Pending conflicts', d['conflicts_pending'], Icons.gavel, warnIfNonzero: true),
                  _StatCard('Scrape failures (7d)', d['scrape_failures_7d'], Icons.error_outline, warnIfNonzero: true),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final dynamic value;
  final IconData icon;
  final bool warnIfNonzero;

  const _StatCard(this.label, this.value, this.icon, {this.warnIfNonzero = false});

  @override
  Widget build(BuildContext context) {
    final numValue = value is String ? int.tryParse(value) ?? 0 : (value as int? ?? 0);
    final isWarning = warnIfNonzero && numValue > 0;
    return Card(
      color: isWarning ? Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.3) : null,
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: isWarning ? Theme.of(context).colorScheme.error : null),
            const SizedBox(height: 8),
            Text('$numValue', style: Theme.of(context).textTheme.headlineMedium),
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
