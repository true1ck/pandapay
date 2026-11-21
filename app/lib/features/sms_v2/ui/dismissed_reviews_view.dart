import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import 'review_clustering.dart';

/// One group of messages the user marked "not financial" (they share a format),
/// as a History row. Recover removes the format's ignore rule and returns its
/// messages to Needs review.
class DismissedReviewPanel extends StatelessWidget {
  const DismissedReviewPanel({
    super.key,
    required this.bundle,
    required this.busy,
    required this.onRecover,
  });

  final ReviewBundle bundle;
  final bool busy;
  final VoidCallback onRecover;

  @override
  Widget build(BuildContext context) {
    final first = bundle.items.first;
    final count = bundle.items.length;
    final span = bundle.earliest != null && bundle.latest != null
        ? formatBundleSpan(bundle.earliest!, bundle.latest!)
        : null;
    return BambooPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.do_not_disturb_on_outlined,
                size: 16,
                color: BambooInk.ink500,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  [
                    '$count ${count == 1 ? 'message' : 'messages'}',
                    ?span,
                  ].join(' · '),
                  style: BambooFonts.ui(
                    12.5,
                    weight: FontWeight.w700,
                    color: BambooInk.ink500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          BambooMessageQuote(
            first.message?.message.body ?? '',
            sender: first.message?.message.sender,
          ),
          if (count > 1 && bundle.latest != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.sm),
              child: Text(
                'Latest: ${DateFormat('d MMM yyyy').format(bundle.latest!.toLocal())}',
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
            ),
          const SizedBox(height: AppSpace.lg),
          Text(
            'Dismissed from Needs review',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.sm),
          OutlinedButton(
            key: Key('recover-${first.id}'),
            style: BambooButtons.secondary,
            onPressed: busy ? null : onRecover,
            child: const Text('Recover'),
          ),
        ],
      ),
    );
  }
}
