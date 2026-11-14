import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import 'transaction_action_flow.dart';
import 'transaction_action_history.dart';

/// Every action taken from "Choose an action", newest first, each with Undo.
/// With [transactionId] it lists only the ones that touched that payment.
class TransactionHistoryScreen extends ConsumerWidget {
  const TransactionHistoryScreen({super.key, this.transactionId});
  final String? transactionId;

  static String _label(String action) {
    for (final a in TxnAction.values) {
      if (a.name == action) return a.label;
    }
    return action;
  }

  static String _when(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day}/${d.month}/${d.year}, $h:$m ${d.hour < 12 ? 'am' : 'pm'}';
  }

  Future<void> _undo(
    BuildContext context,
    WidgetRef ref,
    TxnActionRecord r,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await undoTxnAction(ref, r);
      messenger.showSnackBar(const SnackBar(content: Text('Undone.')));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That could not be undone. Try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(transactionActionHistoryProvider(transactionId));
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'History',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: history.when(
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const EmptyState(
            icon: Icons.history,
            title: 'History is not available',
            message: 'Try again in a moment.',
          ),
          data: (items) => items.isEmpty
              ? const EmptyState(
                  icon: Icons.history,
                  title: 'Nothing here yet',
                  message:
                      'Transfers, refunds, reversals and other changes you make '
                      'to a payment will be listed here, and can be undone.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  itemCount: items.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpace.sm),
                  itemBuilder: (context, i) {
                    final r = items[i];
                    return Material(
                      color: BambooInk.glassFillOnPaper,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: const BorderSide(
                          color: BambooInk.hairlineOnPaper,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      // Tap opens the payment itself so it can be reviewed
                      // (and undone) with all its details in view.
                      child: InkWell(
                        key: Key('history-open-${r.id}'),
                        onTap: r.targets.isEmpty
                            ? null
                            : () => context.push(
                                '/activity/${Uri.encodeComponent(r.targets.first)}',
                              ),
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpace.md),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _label(r.action),
                                      style: BambooFonts.ui(
                                        14.5,
                                        weight: FontWeight.w700,
                                        color: r.isUndone
                                            ? BambooInk.ink500
                                            : BambooInk.ink900,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${r.title} · ₹${(r.amountPaise / 100).toStringAsFixed(r.amountPaise % 100 == 0 ? 0 : 2)}',
                                      style: BambooFonts.ui(
                                        13,
                                        color: BambooInk.ink700,
                                      ),
                                    ),
                                    Text(
                                      '${r.scope} · ${_when(r.at)}',
                                      style: BambooFonts.ui(
                                        12,
                                        color: BambooInk.ink500,
                                      ),
                                    ),
                                    if (r.isUndone)
                                      Text(
                                        'Undone ${_when(r.undoneAt!)}',
                                        style: BambooFonts.ui(
                                          12,
                                          color: BambooInk.ink500,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (!r.isUndone)
                                TextButton(
                                  key: Key('history-undo-${r.id}'),
                                  onPressed: () => _undo(context, ref, r),
                                  child: const Text('Undo'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
