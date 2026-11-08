import 'package:flutter/material.dart';

import '../../../app/design/app_theme.dart';
import 'similar_changes.dart';
import 'similar_finder.dart';

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

  /// The apply button for [selected] of [total] ticked. All of them keeps the
  /// "all N" wording; a part says how many; none says to choose.
  String applyFor(int selected, int total) {
    if (selected == 0) return 'Choose some';
    if (selected == total) return apply;
    final verb = apply.split(' ').first;
    return '$verb $selected';
  }

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
            'These are your other payments to the same payee. Changing their type changes your totals.',
        apply: n == 1 ? 'Change it' : 'Change all $n',
        skip: 'Only this one',
      ),
    };
  }
}

/// Asks which of the other transactions a change should also apply to, as a
/// checklist. Returns the event ids the person ticked and confirmed, or null
/// when they chose to leave the others alone (or closed the sheet). Applying
/// is the caller's job, so the person can carry on while it runs.
///
/// A name or category starts with everything ticked, because later SMS follow
/// it anyway. A change that moves money (payment method, type) starts with
/// nothing ticked, so each transaction is a choice.
Future<Set<String>?> showSimilarOfferSheet({
  required BuildContext context,
  required SimilarOffer offer,
  required SimilarChanges changes,
  required String shop,
  required String target,
}) => showModalBottomSheet<Set<String>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  backgroundColor: BambooInk.paper,
  builder: (_) => _SimilarOfferSheet(
    offer: offer,
    others: changes.others(offer),
    words: SimilarOfferWords.of(offer, shop: shop, target: target),
  ),
);

class _SimilarOfferSheet extends StatefulWidget {
  const _SimilarOfferSheet({
    required this.offer,
    required this.others,
    required this.words,
  });
  final SimilarOffer offer;
  final List<SimilarExample> others;
  final SimilarOfferWords words;

  @override
  State<_SimilarOfferSheet> createState() => _SimilarOfferSheetState();
}

class _SimilarOfferSheetState extends State<_SimilarOfferSheet> {
  late final Set<String> _ticked = widget.offer.movesMoney
      ? <String>{}
      : {for (final example in widget.others) example.eventId};

  String _money(int paise) => '₹${(paise / 100).toStringAsFixed(2)}';

  String _date(DateTime at) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final day = at.toLocal();
    return '${day.day} ${months[day.month - 1]} ${day.year}';
  }

  void _toggleAll(bool? on) => setState(() {
    _ticked.clear();
    if (on ?? false) _ticked.addAll(widget.others.map((e) => e.eventId));
  });

  @override
  Widget build(BuildContext context) {
    final total = widget.others.length;
    final selected = _ticked.length;
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
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const Key('similar-select-all'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            tristate: true,
            value: selected == 0
                ? false
                : selected == total
                ? true
                : null,
            onChanged: (value) => _toggleAll(selected != total),
            title: Text(
              'Select all',
              style: BambooFonts.ui(13.5, color: BambooInk.ink900),
            ),
            secondary: Text(
              '$selected of $total selected',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: total,
              itemBuilder: (context, index) {
                final example = widget.others[index];
                return CheckboxListTile(
                  key: Key('similar-row-${example.eventId}'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  value: _ticked.contains(example.eventId),
                  onChanged: (on) => setState(() {
                    if (on ?? false) {
                      _ticked.add(example.eventId);
                    } else {
                      _ticked.remove(example.eventId);
                    }
                  }),
                  title: Text(
                    example.merchantName ?? 'Transaction',
                    style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _date(example.occurredAt),
                    style: BambooFonts.ui(12, color: BambooInk.ink500),
                  ),
                  secondary: Text(
                    _money(example.amountPaise),
                    style: BambooFonts.ui(13, color: BambooInk.ink700),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
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
                  onPressed: selected == 0
                      ? null
                      : () => Navigator.of(context).pop({..._ticked}),
                  child: Text(widget.words.applyFor(selected, total)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
