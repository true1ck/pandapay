import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/providers.dart' as app;
import '../../../data/merchant_identity.dart';
import '../../../data/user_cards_repository.dart'
    show TransactionEntry, TxnEntryKind;
import '../instruments/card_transaction_relinker.dart';
import '../ledger/providers.dart'
    show instrumentChoiceRevisionProvider, smsV2LedgerReadModelProvider;
import 'found_instruments_screen.dart';
import 'screen_parts.dart';

/// The saved transactions behind one card or account the messages found,
/// newest first: what it stands for, so the person can check it before adding
/// it to the wallet (and see, after, why it was linked). Bounded by that
/// instrument's own messages (the v2_facts instrument index, then
/// `financial_source_identity`), never the whole history.
final instrumentTransactionsProvider = FutureProvider.autoDispose
    .family<List<TransactionEntry>, String>((ref, instrumentId) async {
      final namespace = ref.watch(app.cacheNamespaceProvider);
      final cache = await ref.watch(app.responseCacheProvider.future);
      // A choice on this screen, a new message or a sync changes the list.
      ref.watch(instrumentChoiceRevisionProvider);
      ref.watch(smsV2LedgerReadModelProvider);
      final store = cache.financialStore;
      final keys = [
        for (final row in store.database.db.select(
          CardTransactionRelinker.factKeysSql,
          [namespace, instrumentId],
        ))
          row['source_key'] as String,
      ];
      final byId = <String, TransactionEntry>{
        for (final entry in store.smsTransactionsForSourceKeys(namespace, keys))
          if (entry.status != 'ignored') entry.id: entry,
      };
      return byId.values.toList()
        ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    });

/// Spends among [rows] and what they add up to, in paise.
({int count, int paise}) _spends(List<TransactionEntry> rows) {
  var count = 0;
  var paise = 0;
  for (final row in rows) {
    if (row.entryKind != TxnEntryKind.spend) continue;
    count++;
    paise += row.amount.paise;
  }
  return (count: count, paise: paise);
}

/// What the person can do about this card or account, at the top of its
/// page: add a found card to the wallet (with what that brings), confirm an
/// account, or see that it is already theirs.
class InstrumentStatusPanel extends ConsumerWidget {
  const InstrumentStatusPanel({super.key, required this.instrument});
  final Instrument instrument;

  Future<void> _run(BuildContext context, WidgetRef ref, String action) async {
    final before = ref
        .read(instrumentTransactionsProvider(instrument.instrumentId))
        .valueOrNull;
    final done = await runInstrumentAction(context, ref, instrument, action);
    if (!done || !context.mounted) return;
    if (action == 'reject') {
      // It leaves the list; there is nothing left to show here.
      Navigator.of(context).maybePop();
      return;
    }
    final count = before?.length ?? 0;
    final added = instrument.kind == InstrumentKind.creditCard;
    final text = added
        ? count == 0
              ? 'Added to your wallet.'
              : 'Added to your wallet. $count transactions now count on this card.'
        : 'Confirmed as your account.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCard = instrument.kind == InstrumentKind.creditCard;
    final needs = instrumentNeedsAction(instrument);
    if (!needs) {
      return BambooNote(
        isCard
            ? 'In your wallet. Its transactions count on this card, and new messages from it are added at once.'
            : 'Confirmed as your account.',
        icon: Icons.check_circle_outline_rounded,
      );
    }
    final rows =
        ref
            .watch(instrumentTransactionsProvider(instrument.instrumentId))
            .valueOrNull ??
        const <TransactionEntry>[];
    final spends = _spends(rows);
    final String body;
    if (!isCard) {
      body = rows.isEmpty
          ? 'We found this account in your messages. Confirm it if it is yours.'
          : 'We found this account in ${instrument.evidenceCount} messages. Check the transactions below, then confirm it if it is yours.';
    } else if (spends.count == 0) {
      body =
          'Add it to your wallet so spends on it count on it: card totals, caps and rewards.';
    } else {
      body =
          'Add it to your wallet and its ${spends.count} spends (${smsMoney(spends.paise)}) '
          'count on it: card totals, caps and rewards. Check them below first.';
    }
    return BambooPanel(
      key: const Key('instrument-status-panel'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.md,
        AppSpace.md,
        AppSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            isCard ? 'Not in your wallet' : 'Is this your account?',
            style: BambooFonts.heading(16.5, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            body,
            style: BambooFonts.ui(13, color: BambooInk.ink700, height: 1.4),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              TextButton(
                style: BambooButtons.quiet,
                onPressed: () => _run(context, ref, 'reject'),
                child: const Text('Not mine'),
              ),
              const Spacer(),
              FilledButton(
                key: const Key('instrument-add'),
                style: BambooButtons.primary,
                onPressed: () => _run(context, ref, 'confirm'),
                child: Text(isCard ? 'Add to wallet' : 'Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The transactions behind this card or account, newest first; each opens in
/// full with its original SMS, so the person can check the card is right.
class InstrumentEvidenceSection extends ConsumerStatefulWidget {
  const InstrumentEvidenceSection({super.key, required this.instrument});
  final Instrument instrument;

  /// Rows shown before "Show all".
  static const firstPage = 25;

  @override
  ConsumerState<InstrumentEvidenceSection> createState() =>
      _InstrumentEvidenceSectionState();
}

class _InstrumentEvidenceSectionState
    extends ConsumerState<InstrumentEvidenceSection> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final id = widget.instrument.instrumentId;
    final rows = ref.watch(instrumentTransactionsProvider(id));
    return rows.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpace.lg),
        child: ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
          child: LinearProgressIndicator(minHeight: 3),
        ),
      ),
      error: (_, _) => TextButton.icon(
        style: BambooButtons.quiet,
        onPressed: () => ref.invalidate(instrumentTransactionsProvider(id)),
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('Retry transactions'),
      ),
      data: (list) {
        final shown = _all
            ? list
            : list.take(InstrumentEvidenceSection.firstPage).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BambooSectionLabel(
              'Transactions from its messages',
              asTitle: true,
              trailing: '${list.length}',
            ),
            if (list.isEmpty)
              const BambooNote(
                'No transactions from its messages yet. Balance, limit and due-date notices count as messages but are not transactions.',
                icon: Icons.receipt_long_outlined,
              )
            else
              BambooPanel(
                key: const Key('instrument-evidence'),
                padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                child: Column(
                  children: [
                    for (final (index, entry) in shown.indexed) ...[
                      if (index > 0)
                        const Divider(
                          height: 1,
                          indent: AppSpace.md,
                          endIndent: AppSpace.md,
                          color: BambooInk.hairlineOnPaper,
                        ),
                      _EvidenceRow(entry: entry),
                    ],
                  ],
                ),
              ),
            if (!_all && list.length > shown.length)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: BambooButtons.quiet,
                  onPressed: () => setState(() => _all = true),
                  child: Text('Show all ${list.length}'),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EvidenceRow extends StatelessWidget {
  const _EvidenceRow({required this.entry});
  final TransactionEntry entry;

  @override
  Widget build(BuildContext context) {
    final incoming = entry.entryKind.isMoneyIn;
    final out = entry.entryKind.isMoneyOut;
    final name =
        MerchantIdentity.displayName(entry.merchantName, incoming: incoming) ??
        entry.entryKind.label;
    final kind = entry.entryKind == TxnEntryKind.spend
        ? null
        : entry.entryKind.label;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      onTap: () => context.push(
        '/activity/${Uri.encodeComponent(entry.id)}',
        extra: entry,
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: BambooFonts.ui(
          14.5,
          weight: FontWeight.w600,
          color: BambooInk.ink900,
        ),
      ),
      subtitle: Text(
        [smsDate(entry.occurredAt), ?kind, ?entry.categoryName].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: BambooFonts.ui(12.5, color: BambooInk.ink500),
      ),
      trailing: Text(
        '${out
            ? '−'
            : incoming
            ? '+'
            : ''}${smsMoney(entry.amount.paise)}',
        style: BambooFonts.money(
          14.5,
          weight: FontWeight.w700,
          color: out
              ? BambooInk.clay
              : incoming
              ? BambooInk.jade
              : BambooInk.ink900,
        ),
      ),
    );
  }
}
