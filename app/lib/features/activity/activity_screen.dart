import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../auth/login_screen.dart';

/// UA-3+ (Chunk 18): the last placeholder tab — a real list of transactions
/// logged via Cards' "log a spend" flow (Chunk 17). Signed-out shows the
/// same login flow as Cards/More (owning transaction history requires an
/// identity).
class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionInit = ref.watch(sessionInitProvider);
    if (sessionInit.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final token = ref.watch(accessTokenProvider);
    if (token == null) return const LoginScreen();

    final transactions = ref.watch(transactionsProvider);
    return transactions.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(transactionsProvider),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return const EmptyState(
            icon: Icons.receipt_long_outlined,
            title: 'No activity yet',
            message: 'Spend you log from the Cards tab shows up here.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(AppSpace.lg),
          itemCount: entries.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: _TransactionTile(entries[index]),
          ),
        );
      },
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final TransactionEntry entry;
  const _TransactionTile(this.entry);

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final subtitleParts = <String>[
      if (entry.cardDisplayName != null) entry.cardDisplayName!,
      if (entry.categoryName != null) entry.categoryName!,
    ];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.ink100),
      ),
      padding: const EdgeInsets.all(AppSpace.md),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.sm)),
            child: const Icon(Icons.shopping_bag_outlined, size: 18, color: AppColors.ink700),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.merchantName ?? 'Spend', style: textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                if (subtitleParts.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(subtitleParts.join(' · '), style: textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          MoneyText(entry.amount, confidence: Confidence.estimated, style: textTheme.titleSmall),
        ],
      ),
    );
  }
}
