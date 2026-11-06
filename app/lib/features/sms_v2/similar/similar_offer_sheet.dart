import 'package:flutter/material.dart';

import '../../../app/design/app_theme.dart';
import 'similar_changes.dart';

/// What the sheet shows for one offer. Kept apart from the widget so the
/// wording can be tested without pumping a screen.
class SimilarOfferWords {
  const SimilarOfferWords({
    required this.title,
    required this.body,
    required this.apply,
    required this.skip,
  });
  final String title;
  final String body;
  final String apply;
  final String skip;

  /// [shop] is the shop as the SMS prints it; [target] is what the person
  /// chose (the name, the category, the card or the type) in words.
  factory SimilarOfferWords.of(
    SimilarOffer offer, {
    required String shop,
    required String target,
  }) {
    final n = offer.summary.count;
    final others = n == 1 ? '1 other transaction' : '$n other transactions';
    final earlier = n == 1 ? '1 earlier one' : '$n earlier ones';
    return switch (offer.field) {
      SimilarField.shopName => SimilarOfferWords(
        title: 'Rename $others from $shop?',
        body:
            'From now on every SMS from $shop shows as “$target”. Change $earlier too?',
        apply: n == 1 ? 'Rename it' : 'Rename all $n',
        skip: 'Only from now on',
      ),
      SimilarField.category => SimilarOfferWords(
        title: 'Also put $others from $shop in $target?',
        body:
            'Later SMS from $shop already go to $target. Move $earlier as well? Any you set yourself stay as they are.',
        apply: n == 1 ? 'Move it' : 'Move all $n',
        skip: 'Only from now on',
      ),
      SimilarField.paymentMethod => SimilarOfferWords(
        title: 'Move $others to $target?',
        body:
            'These were read as the same card or account. Moving them changes which card their spends count against: limits, rewards and totals.',
        apply: n == 1 ? 'Move it' : 'Move all $n',
        skip: 'Only this one',
      ),
      SimilarField.type => SimilarOfferWords(
        title: 'Change $others to $target?',
        body:
            'These came from the same kind of SMS and are read the same way. Changing their type changes your totals.',
        apply: n == 1 ? 'Change it' : 'Change all $n',
        skip: 'Only this one',
      ),
    };
  }
}

/// Asks the person whether to apply a change to the others that look the same,
/// and does it with progress. Returns the result, or null when they chose to
/// leave the others alone.
Future<SimilarResult?> showSimilarOfferSheet({
  required BuildContext context,
  required SimilarOffer offer,
  required SimilarChanges changes,
  required String shop,
  required String target,
}) => showModalBottomSheet<SimilarResult>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  isDismissible: false,
  enableDrag: false,
  backgroundColor: BambooInk.paper,
  builder: (_) => _SimilarOfferSheet(
    offer: offer,
    changes: changes,
    words: SimilarOfferWords.of(offer, shop: shop, target: target),
  ),
);

class _SimilarOfferSheet extends StatefulWidget {
  const _SimilarOfferSheet({
    required this.offer,
    required this.changes,
    required this.words,
  });
  final SimilarOffer offer;
  final SimilarChanges changes;
  final SimilarOfferWords words;

  @override
  State<_SimilarOfferSheet> createState() => _SimilarOfferSheetState();
}

class _SimilarOfferSheetState extends State<_SimilarOfferSheet> {
  bool _working = false;
  bool _cancelled = false;
  int _done = 0;
  String? _error;

  Future<void> _apply() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final result = await widget.changes.apply(
        widget.offer,
        onProgress: (done, total) {
          if (mounted) setState(() => _done = done);
        },
        shouldContinue: () => !_cancelled && mounted,
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error =
            'Could not change the others. This transaction is saved; you can try again from its edit screen.';
      });
    }
  }

  String _money(int paise) => '₹${(paise / 100).toStringAsFixed(2)}';

  String _date(DateTime at) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final day = at.toLocal();
    return '${day.day} ${months[day.month - 1]} ${day.year}';
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.offer.summary.count;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.words.title,
            style: BambooFonts.heading(19, color: BambooInk.ink900),
          ),
          const SizedBox(height: 8),
          Text(
            widget.words.body,
            style: BambooFonts.ui(13.5, color: BambooInk.ink700),
          ),
          const SizedBox(height: 12),
          for (final example in widget.offer.summary.examples)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${example.merchantName ?? 'Transaction'} · ${_date(example.occurredAt)}',
                      style: BambooFonts.ui(13, color: BambooInk.ink900),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    _money(example.amountPaise),
                    style: BambooFonts.ui(13, color: BambooInk.ink700),
                  ),
                ],
              ),
            ),
          if (total > widget.offer.summary.examples.length)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'and ${total - widget.offer.summary.examples.length} more',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: BambooFonts.ui(12.5, color: BambooInk.clay)),
          ],
          const SizedBox(height: 16),
          if (_working) ...[
            LinearProgressIndicator(value: total == 0 ? null : _done / total),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _cancelled
                        ? 'Stopping…'
                        : 'Changing $_done of $total…',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink700),
                  ),
                ),
                TextButton(
                  onPressed: _cancelled
                      ? null
                      : () => setState(() => _cancelled = true),
                  child: const Text('Stop'),
                ),
              ],
            ),
          ] else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(widget.words.skip),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _apply,
                    child: Text(widget.words.apply),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
