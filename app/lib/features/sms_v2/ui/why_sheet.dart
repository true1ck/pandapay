import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/providers.dart' as app;
import '../storage/sync_state_store.dart';
import 'review_controller.dart';
import 'screen_parts.dart';

List<String> explainDecision(Map<String, Object?> trace) {
  final result = <String>[];
  final choices = (trace['userChoices'] as List? ?? const []).toSet();
  for (final choice in choices) {
    final explanation = switch (choice) {
      'wrong_amount' => 'You corrected the amount of this entry.',
      'wrong_merchant' => 'You corrected the merchant for this entry.',
      'wrong_date' => 'You corrected the date of this entry.',
      'wrong_kind' => 'You changed the type of this entry.',
      'wrong_link' => 'You chose which messages belong to this entry.',
      'not_financial' =>
        'You marked this message as not financial, so it stays out of totals.',
      'duplicate' =>
        'You marked this entry as a duplicate, so it stays out of totals.',
      _ => null,
    };
    if (explanation != null) result.add(explanation);
  }
  final rule = trace['ruleId'];
  if (rule != null) {
    result.add(
      '${choices.isEmpty ? 'Read' : 'Originally read'} with ${rule.toString().replaceAll('-', ' ')} (version ${trace['ruleVersion'] ?? 'unknown'}).',
    );
  }
  final instruments = trace['instruments'];
  if (instruments is List && instruments.isNotEmpty) {
    result.add(
      instruments.any((row) => row is Map && row['step'] == 'user_choice')
          ? 'You chose the account or card for this entry.'
          : 'Matched to your account using the bank and masked digits in the message.',
    );
  }
  final event = trace['event'];
  if (event is Map &&
      event['linkRuleId'] != null &&
      !choices.any(
        ['wrong_kind', 'wrong_link', 'not_financial', 'duplicate'].contains,
      )) {
    final rule = event['linkRuleId'].toString().toLowerCase();
    result.add(switch (rule) {
      String r when r.contains('card') =>
        'Matched the bank payment with the card receipt. This card bill is counted once and stays out of spending.',
      String r when r.contains('ipo') =>
        'Grouped the IPO hold, release and allotment. Blocked money stays out of spending.',
      String r when r.contains('refund') || r.contains('reversal') =>
        'Matched the return to the original payment so it reduces the same spending category.',
      String r when r.contains('wallet') =>
        'Grouped the wallet top-up with its bank payment to count the movement once.',
      String r when r.contains('duplicate') || r.contains('notice') =>
        'Matched notices for the same payment so it is counted once.',
      _ =>
        'Grouped related messages using their amount, date, account and payment reference.',
    });
  }
  final category = trace['category'];
  if (category is Map) {
    result.add(switch (category['source']) {
      'user' => 'Category: you chose this before.',
      'shared' => 'Category: a reviewed merchant rule.',
      'catalogue' => 'Category: the merchant catalogue.',
      'mcc' => 'Category: the merchant category code.',
      'history_confirmed' =>
        'Category: your earlier confirmed payments to this merchant.',
      'ai' => 'Category: a suggested reading. Please check it.',
      _ => 'Category: Other, until you choose a better fit.',
    });
  }
  if (result.isEmpty) {
    result.add(
      'There isn’t a saved explanation for this entry yet. You can still report a problem.',
    );
  }
  return result;
}

class WhyContent extends StatelessWidget {
  const WhyContent({super.key, required this.trace, required this.onReport});
  final Map<String, Object?> trace;
  final VoidCallback onReport;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Why this?', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),
            for (final explanation in explainDecision(trace))
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(explanation),
              ),
            OutlinedButton.icon(
              onPressed: onReport,
              icon: const Icon(Icons.flag_outlined),
              label: const Text('Report a problem'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showSmsWhy(
  BuildContext context,
  WidgetRef ref, {
  required String sourceKey,
  String? eventId,
}) async {
  final namespace = ref.read(app.cacheNamespaceProvider);
  try {
    final cache = await ref.read(app.responseCacheProvider.future);
    if (!context.mounted || namespace != ref.read(app.cacheNamespaceProvider)) {
      return;
    }
    final saved = SyncStateStore(
      cache.financialStore.database.db,
      namespace: namespace,
    ).get('trace:$sourceKey');
    final trace = saved == null
        ? <String, Object?>{}
        : (jsonDecode(saved) as Map).cast<String, Object?>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => WhyContent(
        trace: trace,
        onReport: () {
          Navigator.pop(sheetContext);
          if (namespace == ref.read(app.cacheNamespaceProvider)) {
            showSmsCorrection(
              context,
              ref,
              sourceKey: sourceKey,
              eventId: eventId,
            );
          }
        },
      ),
    );
  } catch (error) {
    if (context.mounted) smsShowError(context, error);
  }
}
