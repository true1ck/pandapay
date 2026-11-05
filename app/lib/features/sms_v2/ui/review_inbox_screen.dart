import 'package:pandapay_domain/sms_v2.dart';
import '../personal/personal_format_service.dart';
import '../corrections/corrections_service.dart';
import 'personal_format_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../../../app/design/widgets.dart';
import '../../../app/providers.dart' as app;
import '../pipeline/trace.dart';
import '../providers/data_providers.dart';
import 'correction_form.dart';
import 'review_controller.dart';
import 'screen_parts.dart';

/// The receipt question (Lane X): a bill-payment receipt with no matching debit.
bool isReceiptQuestion(LocalReviewItem item) =>
    item.payload['reason'] == kReceiptWithoutPaymentReason;

/// The kind that decides which section and buttons an item gets.
String reviewKindOf(LocalReviewItem item) =>
    isReceiptQuestion(item) ? 'receipt' : item.kind;

/// The question, from the stored facts of the receipt and the wording set.
String receiptQuestion(LocalReviewItem item, [String locale = 'en']) {
  final payload = item.payload;
  final minor = (payload['amountMinor'] as num?)?.toInt() ?? 0;
  final at = DateTime.tryParse(payload['receiptAt'] as String? ?? '');
  return receiptReviewText(locale).question(
    cardBill: payload['cardBill'] == true,
    amount: formatReceiptRupees(minor),
    date: at == null ? '' : formatReceiptDate(at),
    app: (payload['app'] ?? payload['biller']) as String?,
  );
}

/// Sentinel the account picker returns for "Another account".
const _anotherAccount = '__another_account__';

class ReviewInboxScreen extends ConsumerStatefulWidget {
  const ReviewInboxScreen({super.key});
  @override
  ConsumerState<ReviewInboxScreen> createState() => _ReviewInboxScreenState();
}

class _ReviewInboxScreenState extends ConsumerState<ReviewInboxScreen> {
  bool _saving = false;
  Future<void> _act(List<LocalReviewItem> group, String action) async {
    if (_saving) return;
    final namespace = ref.read(app.cacheNamespaceProvider);
    CorrectionEdit? edit;
    if (action.startsWith('receipt-')) {
      await _answerReceipt(group, action, namespace);
      return;
    }
    if (action == 'choose-card') {
      final cards = (await ref.read(instrumentsProvider.future))
          .where(
            (i) =>
                i.kind == InstrumentKind.creditCard &&
                i.status == InstrumentStatus.confirmed,
          )
          .toList();
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      final chosen = await showBambooChoiceSheet<String>(
        context: context,
        title: 'Which card did this pay?',
        subtitle: 'The bill payment is counted once, against this card.',
        icon: Icons.credit_card_rounded,
        emptyMessage:
            'Confirm your credit cards under Accounts first, then come back.',
        options: [
          for (final card in cards)
            BambooChoice(
              value: card.instrumentId,
              label: card.displayName,
              detail: '••${card.maskDigits ?? 'unknown'}',
              icon: Icons.credit_card_rounded,
            ),
        ],
      );
      if (chosen == null ||
          !mounted ||
          namespace != ref.read(app.cacheNamespaceProvider))
        return;
      edit = CorrectionEdit(CorrectionKind.wrongInstrument, {
        'targetInstrumentId': chosen,
      });
    }
    if (action == 'match') {
      final candidates = group.first.payload['candidates'] as List? ?? const [];
      final selected = await showBambooChoiceSheet<Map>(
        context: context,
        title: 'Which payment matches?',
        subtitle: 'The two messages will be counted as one payment.',
        icon: Icons.link_rounded,
        options: [
          for (final candidate in candidates.whereType<Map>())
            BambooChoice(
              value: candidate,
              label:
                  candidate['label'] as String? ??
                  'Payment ${candidates.indexOf(candidate) + 1}',
              icon: Icons.receipt_long_outlined,
            ),
        ],
      );
      if (selected == null ||
          !mounted ||
          namespace != ref.read(app.cacheNamespaceProvider)) {
        return;
      }
      edit = CorrectionEdit(CorrectionKind.wrongLink, {
        '_matchEventId': selected['eventId'],
        '_candidateFactId': selected['factId'],
        '_candidateRole': selected['role'],
      });
    }
    if (action == 'fix' &&
        (group.length > 1 ||
            group.every((item) => item.payload['hasReading'] != true))) {
      try {
        final raw = group.first.message;
        if (raw == null) {
          throw ArgumentError(
            'The original message is unavailable on this phone',
          );
        }
        final instruments = await ref.read(instrumentsProvider.future);
        if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) {
          return;
        }
        final choice = await showBambooSheet<PersonalFormatChoice>(
          context: context,
          builder: (_) => PersonalFormatForm(
            message: SmsMessage(
              sender: raw.message.sender,
              body: raw.message.body,
              observedAt: raw.message.receivedAt.toUtc(),
              sourceKey: raw.id,
            ),
            instruments: instruments,
            groupCount: group.length,
          ),
        );
        if (choice == null ||
            !mounted ||
            namespace != ref.read(app.cacheNamespaceProvider)) {
          return;
        }
        final controller = await smsReviewController(ref);
        if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) {
          return;
        }
        CorrectionsService(
          financial: controller.financial,
          namespace: namespace,
          bundle: controller.bundle,
        ).teachFormat(
          choice: choice,
          sourceKeys: group.map(
            (item) => item.payload['sourceKey'] as String? ?? item.message!.id,
          ),
          appVersion: ref.read(app.appVersionProvider).valueOrNull ?? '1.0.0',
        );
        ref.invalidate(reviewItemsProvider);
      } catch (error) {
        if (mounted) smsShowError(context, error);
      }
      return;
    }
    if (action == 'fix') {
      edit = await showBambooSheet<CorrectionEdit>(
        context: context,
        builder: (_) => CorrectionForm(groupCount: group.length),
      );
      if (edit == null ||
          !mounted ||
          namespace != ref.read(app.cacheNamespaceProvider)) {
        return;
      }
    }
    setState(() => _saving = true);
    try {
      final controller = await smsReviewController(ref);
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      controller.apply(
        items: group,
        kind:
            edit?.kind ??
            (action == 'correct' || action == 'separate'
                ? CorrectionKind.wrongLink
                : CorrectionKind.notFinancial),
        corrected: edit?.corrected ?? const {},
        confirm: action == 'correct' || action == 'separate',
      );
      ref.invalidate(reviewItemsProvider);
    } catch (error) {
      if (mounted) smsShowError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _answerReceipt(
    List<LocalReviewItem> group,
    String action,
    String namespace,
  ) async {
    final text = receiptReviewText();
    if (action == 'receipt-unsure') {
      // Stays in review: nothing changes.
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(text.notSureSnack)));
      return;
    }
    String? funding;
    if (action == 'receipt-yes') {
      final accounts = (await ref.read(instrumentsProvider.future))
          .where(
            (i) =>
                (i.kind == InstrumentKind.bankAccount ||
                    i.kind == InstrumentKind.wallet) &&
                i.status == InstrumentStatus.confirmed,
          )
          .toList();
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      final chosen = await showBambooChoiceSheet<String>(
        context: context,
        title: text.chooseAccountTitle,
        icon: Icons.account_balance_outlined,
        options: [
          for (final account in accounts)
            BambooChoice(
              value: account.instrumentId,
              label: account.displayName,
              detail: '••${account.maskDigits ?? 'unknown'}',
              icon: account.kind == InstrumentKind.wallet
                  ? Icons.account_balance_wallet_outlined
                  : Icons.account_balance_outlined,
            ),
          BambooChoice(
            value: _anotherAccount,
            label: text.anotherAccount,
            icon: Icons.more_horiz_rounded,
          ),
        ],
      );
      if (chosen == null ||
          !mounted ||
          namespace != ref.read(app.cacheNamespaceProvider)) {
        return;
      }
      funding = chosen == _anotherAccount ? null : chosen;
    }
    setState(() => _saving = true);
    try {
      final reviews = await smsReceiptReviews(ref);
      if (!mounted || namespace != ref.read(app.cacheNamespaceProvider)) return;
      for (final item in group) {
        if (action == 'receipt-yes') {
          reviews.confirm(reviewId: item.id, fundingInstrumentId: funding);
        } else {
          reviews.dismiss(reviewId: item.id);
        }
      }
      ref.invalidate(reviewItemsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              action == 'receipt-yes' ? text.countedSnack : text.dismissedSnack,
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) smsShowError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Needs review')),
    body: AppBackground(
      child: ref
          .watch(reviewItemsProvider)
          .when(
            skipLoadingOnReload: true,
            skipLoadingOnRefresh: true,
            loading: () => const SmsLoading(),
            error: (_, _) =>
                SmsError(onRetry: () => ref.invalidate(reviewItemsProvider)),
            data: (items) =>
                ReviewInboxList(items: items, busy: _saving, onAction: _act),
          ),
    ),
  );
}

class ReviewInboxList extends StatelessWidget {
  const ReviewInboxList({
    super.key,
    required this.items,
    required this.onAction,
    this.busy = false,
  });
  final List<LocalReviewItem> items;
  final bool busy;
  final void Function(List<LocalReviewItem>, String) onAction;
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SmsEmpty(
        'You’re all caught up. New formats and payments that need your help will appear here.',
        icon: Icons.task_alt_rounded,
      );
    }
    final groups = <String, List<LocalReviewItem>>{};
    for (final item in items) {
      groups
          .putIfAbsent('${reviewKindOf(item)}:${item.groupKey}', () => [])
          .add(item);
    }
    final sections = <String, List<List<LocalReviewItem>>>{};
    for (final group in groups.values) {
      final title = switch (reviewKindOf(group.first)) {
        'receipt' => receiptReviewText().title,
        'template' => 'New message formats',
        'link' => 'Is this the same payment?',
        'category' => 'What is this merchant?',
        _ => 'Please confirm',
      };
      sections.putIfAbsent(title, () => []).add(group);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      children: [
        const BambooNote(
          'Your message text stays on this phone. A format choice applies to every message in that group.',
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.only(top: AppSpace.md),
            child: ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
              child: LinearProgressIndicator(minHeight: 3),
            ),
          ),
        for (final section in sections.entries) ...[
          BambooSectionLabel(section.key, asTitle: true),
          for (final group in section.value)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: _ReviewGroupPanel(
                group: group,
                busy: busy,
                onAction: onAction,
              ),
            ),
        ],
      ],
    );
  }
}

class _ReviewGroupPanel extends StatelessWidget {
  const _ReviewGroupPanel({
    required this.group,
    required this.busy,
    required this.onAction,
  });
  final List<LocalReviewItem> group;
  final bool busy;
  final void Function(List<LocalReviewItem>, String) onAction;

  VoidCallback? _on(String action) =>
      busy ? null : () => onAction(group, action);

  @override
  Widget build(BuildContext context) {
    final first = group.first;
    final kind = reviewKindOf(first);
    final isReceipt = kind == 'receipt';
    final hasReading = group.every((i) => i.payload['hasReading'] == true);
    final allMessages = group.every((i) => i.message != null);
    final notFinancial = TextButton(
      style: BambooButtons.quiet,
      onPressed: _on('ignore'),
      child: const Text('Not financial'),
    );
    Widget fix(bool primary) => primary
        ? FilledButton(
            style: BambooButtons.primary,
            onPressed: _on('fix'),
            child: const Text('Fix'),
          )
        : OutlinedButton(
            style: BambooButtons.secondary,
            onPressed: _on('fix'),
            child: const Text('Fix'),
          );

    final Widget actions;
    if (isReceipt) {
      final text = receiptReviewText();
      actions = BambooActionBar(
        primary: FilledButton(
          style: BambooButtons.primary,
          onPressed: _on('receipt-yes'),
          child: Text(text.yes),
        ),
        secondary: [
          OutlinedButton(
            style: BambooButtons.secondary,
            onPressed: _on('receipt-no'),
            child: Text(text.no),
          ),
        ],
        quiet: [
          TextButton(
            style: BambooButtons.quiet,
            onPressed: _on('receipt-unsure'),
            child: Text(text.notSure),
          ),
        ],
      );
    } else if (first.kind == 'bill_target') {
      actions = BambooActionBar(
        primary: FilledButton(
          style: BambooButtons.primary,
          onPressed: _on('choose-card'),
          child: const Text('Which card did this pay?'),
        ),
        quiet: [if (allMessages) notFinancial],
      );
    } else if (first.kind == 'link') {
      actions = BambooActionBar(
        primary: FilledButton(
          style: BambooButtons.primary,
          onPressed: _on('match'),
          child: const Text('Choose match'),
        ),
        secondary: [
          OutlinedButton(
            style: BambooButtons.secondary,
            onPressed: _on('separate'),
            child: const Text('Keep separate'),
          ),
        ],
        quiet: [if (allMessages) notFinancial],
      );
    } else {
      actions = BambooActionBar(
        primary: hasReading
            ? FilledButton(
                style: BambooButtons.primary,
                onPressed: _on('correct'),
                child: const Text('Correct'),
              )
            : fix(true),
        secondary: [if (hasReading) fix(false)],
        quiet: [if (allMessages) notFinancial],
      );
    }

    return BambooPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                isReceipt ? Icons.receipt_long_outlined : Icons.sms_outlined,
                size: 16,
                color: BambooInk.ink500,
              ),
              const SizedBox(width: 6),
              Text(
                '${group.length} ${group.length == 1 ? 'message' : 'messages'}',
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (isReceipt)
            Text(
              receiptQuestion(first),
              style: BambooFonts.ui(
                14.5,
                weight: FontWeight.w500,
                color: BambooInk.ink900,
                height: 1.45,
              ),
            )
          else
            BambooMessageQuote(
              first.message?.message.body ??
                  'The original message is no longer on this phone.',
              sender: first.message?.message.sender,
            ),
          if (first.payload['reading'] case final String reading) ...[
            const SizedBox(height: AppSpace.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.auto_awesome_outlined,
                    size: 16,
                    color: BambooInk.ink700,
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'Suggested reading: $reading',
                    style: BambooFonts.ui(
                      13.5,
                      weight: FontWeight.w600,
                      color: BambooInk.ink900,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpace.lg),
          actions,
        ],
      ),
    );
  }
}
