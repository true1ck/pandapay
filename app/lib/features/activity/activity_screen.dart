import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/providers.dart';
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
      error: (err, _) => Center(child: Text('Failed to load activity: $err')),
      data: (entries) {
        if (entries.isEmpty) {
          return const Center(child: Text('No activity yet — log a spend from the Cards tab.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: entries.length,
          itemBuilder: (context, index) => _TransactionTile(entries[index]),
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
    final subtitleParts = <String>[
      if (entry.cardDisplayName != null) entry.cardDisplayName!,
      if (entry.categoryName != null) entry.categoryName!,
    ];
    return Card(
      child: ListTile(
        title: Text(entry.merchantName ?? 'Spend'),
        subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' · ')),
        trailing: MoneyText(entry.amount, confidence: Confidence.estimated),
      ),
    );
  }
}
