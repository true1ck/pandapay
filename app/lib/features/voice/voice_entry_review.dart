import 'package:flutter/material.dart';

import '../../app/category_picker.dart';
import '../../app/design/app_theme.dart';
import '../../app/transaction_tag_picker.dart' show TransactionTagField;
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/user_cards_repository.dart' show TxnInstrument, UserCard;
import 'follow_up/follow_up.dart';
import 'voice_action_parser.dart';
import 'voice_draft_editor.dart';
import 'voice_format.dart';

/// One entry of the review sheet: what was heard, the editable fields, and
/// at most one follow-up question. Nothing here saves; the sheet does.
class VoiceEntryReview extends StatelessWidget {
  const VoiceEntryReview({
    super.key,
    required this.draft,
    required this.editor,
    required this.cards,
    required this.categories,
    required this.index,
    required this.total,
    required this.now,
    required this.onChanged,
    required this.followUp,
    required this.onFollowUpChoice,
    required this.onFollowUpNumber,
    required this.onFollowUpSkip,
    required this.onFollowUpListen,
    required this.listeningForAnswer,
  });

  final VoiceActionDraft draft;
  final VoiceDraftEditor editor;
  final List<UserCard> cards;
  final List<SpendCategory> categories;
  final int index;
  final int total;
  final DateTime now;

  /// Call after changing anything on [editor] so the sheet rebuilds.
  final VoidCallback onChanged;
  final FollowUp? followUp;
  final void Function(FollowUp, FollowUpChoice) onFollowUpChoice;
  final void Function(FollowUp, double) onFollowUpNumber;
  final void Function(FollowUp) onFollowUpSkip;
  final void Function(FollowUp) onFollowUpListen;
  final bool listeningForAnswer;

  static const _moneyInHow = {
    TxnInstrument.upiBank: 'Bank or UPI',
    TxnInstrument.cash: 'Cash',
    TxnInstrument.other: 'Other',
  };

  String get _title {
    final prefix = total == 1 ? null : 'Entry ${index + 1}';
    final what = switch (editor.type) {
      VoiceActionType.moneyIn => 'Money in',
      VoiceActionType.refund => 'Refund',
      VoiceActionType.pointsRedemption => 'Points redemption',
      _ => 'Spend',
    };
    return prefix == null ? '$what details' : '$prefix · $what';
  }

  @override
  Widget build(BuildContext context) {
    final issues = editor.currentIssues(cards);
    final isMoneyIn = editor.type == VoiceActionType.moneyIn;
    final isPoints = editor.type == VoiceActionType.pointsRedemption;
    final showCategory = !isMoneyIn && !isPoints;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_title, style: BambooFonts.heading(16, color: BambooInk.ink900)),
        const SizedBox(height: 10),
        if (!isPoints) _kindChips(),
        _heardChips(),
        if (followUp != null) ...[
          _FollowUpCard(
            key: ValueKey('${index}_${followUp!.slot.name}'),
            followUp: followUp!,
            listening: listeningForAnswer,
            onChoice: (c) => onFollowUpChoice(followUp!, c),
            onNumber: (v) => onFollowUpNumber(followUp!, v),
            onSkip: () => onFollowUpSkip(followUp!),
            onListen: () => onFollowUpListen(followUp!),
          ),
          const SizedBox(height: 12),
        ],
        if (!isPoints) ...[
          if (draft.isForeign)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'You said ${draft.foreignCurrency} ${_plain(draft.foreignAmount)}. '
                'Enter the rupee amount your bank charged; the foreign amount is kept in the note.',
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
            ),
          TextField(
            controller: editor.amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              labelText: switch (editor.type) {
                VoiceActionType.moneyIn => 'Amount received (₹)',
                VoiceActionType.refund => 'Refund amount (₹)',
                _ => draft.isForeign ? 'Amount in rupees (₹)' : 'Amount (₹)',
              },
            ),
          ),
        ] else
          TextField(
            controller: editor.pointsController,
            keyboardType: TextInputType.number,
            onChanged: (_) => onChanged(),
            decoration: const InputDecoration(labelText: 'Points'),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: editor.merchantController,
          decoration: InputDecoration(
            labelText: switch (editor.type) {
              VoiceActionType.moneyIn => 'Who or what it was from',
              VoiceActionType.refund => 'Refund from',
              _ => 'Merchant or what it was for',
            },
          ),
        ),
        const SizedBox(height: 12),
        if (showCategory || editor.type == VoiceActionType.refund) ...[
          CategoryPickerField(
            categories: categories,
            selectedId: editor.selectedCategoryId,
            label: 'Category',
            onSelected: (value) {
              editor.selectedCategoryId = value;
              onChanged();
            },
          ),
          const SizedBox(height: 12),
        ],
        if (!isPoints) ...[
          if (isMoneyIn)
            DropdownButtonFormField<TxnInstrument>(
              initialValue: _moneyInHow.containsKey(editor.instrument)
                  ? editor.instrument
                  : TxnInstrument.other,
              decoration: const InputDecoration(labelText: 'How it reached you'),
              items: [
                for (final e in _moneyInHow.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (value) {
                if (value == null) return;
                editor.instrument = value;
                editor.moneyInHowChosen = true;
                onChanged();
              },
            )
          else
            DropdownButtonFormField<TxnInstrument>(
              initialValue: editor.instrument,
              decoration: InputDecoration(
                labelText: editor.type == VoiceActionType.refund
                    ? 'Refunded to'
                    : 'Paid with',
              ),
              items: [
                for (final instrument in TxnInstrument.values)
                  DropdownMenuItem(
                    value: instrument,
                    child: Text(instrument.label),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                editor.instrument = value;
                onChanged();
              },
            ),
          const SizedBox(height: 12),
          _dateField(context),
          const SizedBox(height: 12),
        ],
        if (!isMoneyIn && !isPoints) ...[
          TransactionTagField(
            selectedIds: editor.selectedTagIds,
            onChanged: (value) {
              editor.selectedTagIds = value;
              onChanged();
            },
          ),
          const SizedBox(height: 12),
        ],
        if (!isMoneyIn)
          DropdownButtonFormField<String>(
            initialValue: cards.any((c) => c.id == editor.selectedCardId)
                ? editor.selectedCardId
                : null,
            decoration: InputDecoration(
              labelText: editor.requiresWalletCard
                  ? 'Wallet card'
                  : 'Wallet card (optional)',
            ),
            items: [
              for (final card in cards)
                DropdownMenuItem(
                  value: card.id,
                  child: Text(
                    '${card.nickname?.isNotEmpty == true ? card.nickname : card.cardName}${card.last4 == null ? '' : ' ••${card.last4}'}',
                  ),
                ),
            ],
            onChanged: (value) {
              editor.selectedCardId = value;
              onChanged();
            },
          ),
        if (!isMoneyIn) const SizedBox(height: 12),
        TextField(
          controller: editor.noteController,
          minLines: 2,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Note / original voice text',
          ),
        ),
        if (draft.warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final w in draft.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: BambooInk.ink500,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      w,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (issues.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            issues.join('\n'),
            style: BambooFonts.ui(13, color: BambooInk.clay),
          ),
        ],
      ],
    );
  }

  Widget _kindChips() {
    const kinds = [
      (VoiceActionType.expense, 'Spend'),
      (VoiceActionType.moneyIn, 'Money in'),
      (VoiceActionType.refund, 'Refund'),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(
        spacing: 8,
        children: [
          for (final (type, label) in kinds)
            ChoiceChip(
              label: Text(label),
              selected: editor.type == type,
              onSelected: (_) {
                if (editor.type == type) return;
                final wasMoneyIn = editor.type == VoiceActionType.moneyIn;
                editor.type = type;
                editor.kindAlternative = null;
                if (type == VoiceActionType.moneyIn &&
                    editor.instrument == TxnInstrument.creditCard) {
                  editor.instrument = TxnInstrument.other;
                } else if (wasMoneyIn &&
                    editor.instrument == TxnInstrument.other) {
                  editor.instrument = TxnInstrument.creditCard;
                }
                onChanged();
              },
            ),
        ],
      ),
    );
  }

  Widget _heardChips() {
    final amountAlternatives = draft.alternatives
        .where((a) => a.role == 'amount' && a.amount != null)
        .toList();
    if (draft.heard.isEmpty && amountAlternatives.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final h in draft.heard)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                h.source.isEmpty || h.source == h.shown
                    ? h.shown
                    : '${h.shown}  ←  “${h.source}”',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
            ),
          for (final a in amountAlternatives)
            ActionChip(
              label: Text(a.label),
              onPressed: () {
                editor.amountController.text = a.amount!.toStringAsFixed(2);
                onChanged();
              },
            ),
        ],
      ),
    );
  }

  Widget _dateField(BuildContext context) {
    final label = editor.occurredAt == null
        ? 'Today'
        : VoiceFormat.day(editor.occurredAt!, now);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final today = DateTime(now.year, now.month, now.day);
        final picked = await showDatePicker(
          context: context,
          initialDate: editor.occurredAt ?? today,
          firstDate: DateTime(now.year - 5),
          lastDate: today,
        );
        if (picked == null) return;
        editor.occurredAt = picked == today
            ? null
            : DateTime(picked.year, picked.month, picked.day, 12);
        editor.dateConfirmed = true;
        onChanged();
      },
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Date',
          suffixIcon: Icon(Icons.calendar_today_rounded, size: 18),
        ),
        child: Text(label, style: BambooFonts.ui(15, color: BambooInk.ink900)),
      ),
    );
  }

  static String _plain(double? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
  }
}

/// Panda's question: chips to tap, a number to type, a mic to answer aloud,
/// and a way to leave it for the form below.
class _FollowUpCard extends StatefulWidget {
  const _FollowUpCard({
    super.key,
    required this.followUp,
    required this.listening,
    required this.onChoice,
    required this.onNumber,
    required this.onSkip,
    required this.onListen,
  });

  final FollowUp followUp;
  final bool listening;
  final ValueChanged<FollowUpChoice> onChoice;
  final ValueChanged<double> onNumber;
  final VoidCallback onSkip;
  final VoidCallback onListen;

  @override
  State<_FollowUpCard> createState() => _FollowUpCardState();
}

class _FollowUpCardState extends State<_FollowUpCard> {
  final _number = TextEditingController();

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  void _submit() {
    final v = double.tryParse(_number.text.replaceAll(',', ''));
    if (v != null && v > 0) widget.onNumber(v);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.followUp;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.jade.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.chat_bubble_outline_rounded,
                size: 18,
                color: BambooInk.jade,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  f.question,
                  style: BambooFonts.heading(15, color: BambooInk.ink900),
                ),
              ),
              IconButton(
                tooltip: 'Answer by voice',
                visualDensity: VisualDensity.compact,
                onPressed: widget.listening ? null : widget.onListen,
                icon: Icon(
                  widget.listening ? Icons.graphic_eq_rounded : Icons.mic_rounded,
                  color: BambooInk.jade,
                ),
              ),
            ],
          ),
          if (f.hint != null) ...[
            const SizedBox(height: 4),
            Text(f.hint!, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
          ],
          if (widget.listening) ...[
            const SizedBox(height: 6),
            Text(
              'Listening for your answer…',
              style: BambooFonts.ui(12.5, color: BambooInk.jade),
            ),
          ],
          if (f.choices.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final c in f.choices)
                  ActionChip(
                    label: Text(c.label),
                    onPressed: () => widget.onChoice(c),
                  ),
              ],
            ),
          ],
          if (f.numeric) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _number,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixText: '₹ ',
                      hintText: 'Amount',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _submit, child: const Text('Use')),
              ],
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: widget.onSkip,
              child: const Text('Fill in below'),
            ),
          ),
        ],
      ),
    );
  }
}
