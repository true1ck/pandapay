import 'package:pandapay_domain/sms_v2.dart';
import '../personal/personal_format_service.dart';
import '../corrections/corrections_service.dart';
import 'personal_format_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
      final chosen = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Which card did this pay?'),
          children: [
            for (final card in cards)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, card.instrumentId),
                child: Text(
                  '${card.displayName} ••${card.maskDigits ?? 'unknown'}',
                ),
              ),
          ],
        ),
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
      final selected = await showDialog<Map>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Which payment matches?'),
          children: [
            for (final candidate in candidates.whereType<Map>())
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, candidate),
                child: Text(
                  candidate['label'] as String? ??
                      'Payment ${candidates.indexOf(candidate) + 1}',
                ),
              ),
          ],
        ),
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
        final choice = await showModalBottomSheet<PersonalFormatChoice>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
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
      edit = await showModalBottomSheet<CorrectionEdit>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
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
      final chosen = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(text.chooseAccountTitle),
          children: [
            for (final account in accounts)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, account.instrumentId),
                child: Text(
                  '${account.displayName} ••${account.maskDigits ?? 'unknown'}',
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, _anotherAccount),
              child: Text(text.anotherAccount),
            ),
          ],
        ),
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
    body: ref
        .watch(reviewItemsProvider)
        .when(skipLoadingOnReload: true, skipLoadingOnRefresh: true, 
          loading: () => const SmsLoading(),
          error: (_, _) =>
              SmsError(onRetry: () => ref.invalidate(reviewItemsProvider)),
          data: (items) =>
              ReviewInboxList(items: items, busy: _saving, onAction: _act),
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
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Your message text stays on this phone. A format choice applies to every message in that group.',
        ),
        if (busy) const LinearProgressIndicator(),
        for (final section in sections.entries) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              section.key,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          for (final group in section.value)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${group.length} ${group.length == 1 ? 'message' : 'messages'}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    if (reviewKindOf(group.first) == 'receipt')
                      Text(receiptQuestion(group.first))
                    else
                      Text(
                        group.first.message?.message.body ??
                            'The original message is no longer on this phone.',
                      ),
                    if (group.first.payload['reading']
                        case final String reading)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text('Suggested reading: $reading'),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (reviewKindOf(group.first) == 'receipt') ...[
                          FilledButton(
                            onPressed: busy
                                ? null
                                : () => onAction(group, 'receipt-yes'),
                            child: Text(receiptReviewText().yes),
                          ),
                          OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => onAction(group, 'receipt-no'),
                            child: Text(receiptReviewText().no),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => onAction(group, 'receipt-unsure'),
                            child: Text(receiptReviewText().notSure),
                          ),
                        ] else if (group.first.kind == 'bill_target')
                          FilledButton(
                            onPressed: busy
                                ? null
                                : () => onAction(group, 'choose-card'),
                            child: const Text('Which card did this pay?'),
                          )
                        else if (group.first.kind == 'link') ...[
                          FilledButton(
                            onPressed: busy
                                ? null
                                : () => onAction(group, 'match'),
                            child: const Text('Choose match'),
                          ),
                          OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => onAction(group, 'separate'),
                            child: const Text('Keep separate'),
                          ),
                        ] else if (group.every(
                          (i) => i.payload['hasReading'] == true,
                        ))
                          FilledButton(
                            onPressed: busy
                                ? null
                                : () => onAction(group, 'correct'),
                            child: const Text('Correct'),
                          ),
                        if (reviewKindOf(group.first) != 'receipt' &&
                            group.first.kind != 'link' &&
                            group.first.kind != 'bill_target')
                          OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => onAction(group, 'fix'),
                            child: const Text('Fix'),
                          ),
                        if (reviewKindOf(group.first) != 'receipt' &&
                            group.every((i) => i.message != null))
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                            ),
                            onPressed: busy
                                ? null
                                : () => onAction(group, 'ignore'),
                            child: const Text('Not financial'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}
