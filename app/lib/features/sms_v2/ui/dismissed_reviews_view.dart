import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/bamboo_components.dart';
import '../providers/data_providers.dart';
import 'review_clustering.dart';
import 'screen_parts.dart';

/// Messages the user marked "not financial", grouped by format, each group
/// with a way back. Moving a group back removes the format's ignore rule and
/// returns its messages to Needs review.
class DismissedReviewList extends StatelessWidget {
  const DismissedReviewList({
    super.key,
    required this.items,
    required this.onRestore,
    this.busy = false,
  });

  final List<LocalReviewItem> items;
  final bool busy;
  final void Function(List<LocalReviewItem>) onRestore;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SmsEmpty(
        'Nothing dismissed. Messages you mark as not financial appear here, so you can bring them back.',
        icon: Icons.inventory_2_outlined,
      );
    }
    final bundles = bundleReviewItems(items, (_) => 'template');
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      children: [
        const BambooNote(
          'Messages you marked as not financial. Moving a group back reads that format again and returns its messages to Needs review.',
        ),
        const SizedBox(height: AppSpace.md),
        for (final bundle in bundles)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: _DismissedPanel(
              bundle: bundle,
              busy: busy,
              onRestore: () => onRestore(bundle.items),
            ),
          ),
      ],
    );
  }
}

class _DismissedPanel extends StatelessWidget {
  const _DismissedPanel({
    required this.bundle,
    required this.busy,
    required this.onRestore,
  });

  final ReviewBundle bundle;
  final bool busy;
  final VoidCallback onRestore;

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
          OutlinedButton(
            style: BambooButtons.secondary,
            onPressed: busy ? null : onRestore,
            child: const Text('Move back to review'),
          ),
        ],
      ),
    );
  }
}
