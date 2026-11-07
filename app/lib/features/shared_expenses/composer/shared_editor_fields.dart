import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import '../../../app/design/app_theme.dart';
import '../ui/shared_components.dart';
import 'shared_editor.dart';

/// Sharing controls embedded in the existing Quick Add owner.
class SharedEditorFields extends StatelessWidget {
  final SharedEditor editor;
  final VoidCallback onChooseContext;
  final VoidCallback? onAddMember;
  final bool loading;
  final String? error;
  const SharedEditorFields({
    super.key,
    required this.editor,
    required this.onChooseContext,
    this.onAddMember,
    this.loading = false,
    this.error,
  });
  Widget _field(
    String label,
    String value,
    ValueChanged<String> change, {
    String? suffix,
  }) => TextFormField(
    key: ValueKey('$label:${editor.contextId}:${editor.mode.name}'),
    initialValue: value,
    readOnly: editor.sealed,
    style: BambooFonts.ui(14),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    textInputAction: TextInputAction.done,
    onChanged: change,
    onFieldSubmitted: (_) {
      FocusManager.instance.primaryFocus?.unfocus();
    },
    onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
    decoration: InputDecoration(labelText: label, suffixText: suffix),
  );
  @override
  Widget build(BuildContext context) {
    final calculation = editor.evaluation, preview = calculation.preview;
    return SharedPanel(
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Sharing', style: BambooFonts.heading(17)),
            if (editor.lockedOwnPaid != null) ...[
              SharedMoneyLine(
                'Charged on your original payment',
                editor.lockedOwnPaid!,
                confidence: Confidence.confirmed,
              ),
              const SharedNotice(
                'The original payment is retained. This form does not create another bank transaction.',
              ),
            ],
            SharedTextAction(
              label: editor.contextName.isEmpty
                  ? 'Choose group or friend'
                  : editor.contextName,
              icon: Icons.people_outline_rounded,
              onTap: onChooseContext,
            ),
            if (loading) const LinearProgressIndicator(color: BambooInk.slate),
            if (error != null)
              Text(error!, style: BambooFonts.ui(12, color: BambooInk.clayInk)),
            if (editor.contextId != null) ...[
              DropdownButtonFormField<String>(
                key: ValueKey('${editor.contextId}:${editor.singlePayer}'),
                initialValue:
                    editor.members.any((m) => m.id == editor.singlePayer)
                    ? editor.singlePayer
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Paid by'),
                items: [
                  for (final m in editor.members)
                    DropdownMenuItem(
                      value: m.id,
                      child: Text(m.label, style: BambooFonts.ui(14)),
                    ),
                ],
                onChanged: editor.sealed
                    ? null
                    : (value) {
                        if (value != null) editor.choosePayer(value);
                      },
              ),
              if (editor.hasUnavailableMembers) ...[
                const SharedNotice(
                  'A selected person is no longer in this split. Review their share and payer amounts before submitting.',
                ),
                SharedTextAction(
                  label: 'Remove unavailable people from this expense',
                  onTap: editor.removeUnavailableMembers,
                ),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Multiple payers', style: BambooFonts.ui(13)),
                value: editor.multiplePayers,
                onChanged: editor.sealed
                    ? null
                    : (value) => editor.setMultiplePayers(value ?? false),
              ),
              if (editor.multiplePayers) ...[
                for (final member in editor.members)
                  if (editor.payerInputs.containsKey(member.id)) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            member.label,
                            style: BambooFonts.ui(14, weight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove ${member.name} as payer',
                          onPressed: () => editor.removePayer(member.id),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    _field(
                      '${member.name} paid',
                      editor.payerInputs[member.id]!.fullText,
                      (text) => editor.setPayer(
                        member.id,
                        text,
                        editor.partial
                            ? editor.payerInputs[member.id]!.sharedText
                            : text,
                      ),
                    ),
                    if (editor.partial)
                      _field(
                        '${member.name} shared contribution',
                        editor.payerInputs[member.id]!.sharedText,
                        (text) => editor.setPayer(
                          member.id,
                          editor.payerInputs[member.id]!.fullText,
                          text,
                        ),
                      ),
                  ],
                Wrap(
                  spacing: 8,
                  children: [
                    for (final member in editor.members)
                      if (!editor.payerInputs.containsKey(member.id))
                        SharedTextAction(
                          label: 'Add ${member.name} as payer',
                          onTap: () => editor.setPayer(member.id, '', ''),
                        ),
                  ],
                ),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  'Share only part of this bill',
                  style: BambooFonts.ui(13),
                ),
                value: editor.partial,
                onChanged: editor.sealed
                    ? null
                    : (value) => editor.setPartial(value ?? false),
              ),
              if (editor.partial)
                _field('Shared amount', editor.sharedText, editor.setShared),
              const SizedBox(height: AppSpace.md),
              Text(
                'Shared with · ${editor.participants.length}/50',
                style: BambooFonts.ui(13, weight: FontWeight.w600),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final member in editor.members)
                    FilterChip(
                      label: Text(
                        member.label,
                        style: BambooFonts.ui(
                          13,
                          weight: FontWeight.w600,
                          color: editor.participants.contains(member.id)
                              ? BambooInk.onSlate
                              : BambooInk.ink900,
                        ),
                      ),
                      selected: editor.participants.contains(member.id),
                      selectedColor: BambooInk.slate,
                      checkmarkColor: BambooInk.lime,
                      onSelected: editor.sealed
                          ? null
                          : (value) =>
                                editor.toggleParticipant(member.id, value),
                    ),
                ],
              ),
              if (onAddMember != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: SharedTextAction(
                    label: 'Add person',
                    icon: Icons.person_add_outlined,
                    onTap: onAddMember!,
                  ),
                ),
              const SizedBox(height: AppSpace.md),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final mode in SharedSplitMode.values)
                    ChoiceChip(
                      label: Text(
                        switch (mode) {
                          SharedSplitMode.equal => 'Equally',
                          SharedSplitMode.exact => 'Exact ₹',
                          SharedSplitMode.percentage => '%',
                          SharedSplitMode.shares => 'Shares',
                        },
                        style: BambooFonts.ui(
                          13,
                          weight: FontWeight.w600,
                          color: editor.mode == mode
                              ? BambooInk.onSlate
                              : BambooInk.ink900,
                        ),
                      ),
                      selected: editor.mode == mode,
                      selectedColor: BambooInk.slate,
                      checkmarkColor: BambooInk.lime,
                      onSelected: editor.sealed
                          ? null
                          : (_) => editor.setMode(mode),
                    ),
                ],
              ),
              if (editor.mode != SharedSplitMode.equal)
                for (final m in editor.members)
                  if (editor.participants.contains(m.id))
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpace.sm),
                      child: _field(
                        '${m.name} ${editor.mode == SharedSplitMode.percentage
                            ? 'percent'
                            : editor.mode == SharedSplitMode.shares
                            ? 'shares'
                            : 'amount'}',
                        editor.splitInputs[m.id] ?? '',
                        (value) => editor.setSplit(m.id, value),
                      ),
                    ),
              if (preview != null) ...[
                const Divider(color: BambooInk.hairlineOnPaper),
                SharedMoneyLine(
                  'Bill total',
                  preview.billTotal,
                  confidence: Confidence.confirmed,
                ),
                if (editor.partial)
                  SharedMoneyLine(
                    'Shared amount',
                    preview.sharedTotal,
                    confidence: Confidence.confirmed,
                  ),
                SharedMoneyLine(
                  'You paid',
                  preview.yourFullPaid,
                  confidence: Confidence.confirmed,
                ),
                SharedMoneyLine(
                  'Your share',
                  preview.yourShare,
                  confidence: Confidence.confirmed,
                ),
                if (!preview.yourResidual.isZero)
                  SharedMoneyLine(
                    'Your unshared amount',
                    preview.yourResidual,
                    confidence: Confidence.confirmed,
                  ),
                SharedMoneyLine(
                  'Your spending',
                  preview.yourPersonalCost,
                  confidence: Confidence.confirmed,
                ),
                for (final m in editor.members)
                  if (preview.shares.containsKey(m.id))
                    SharedMoneyLine(
                      m.label,
                      preview.shares[m.id]!,
                      confidence: Confidence.confirmed,
                    ),
                if (preview.yourFullPaid.isZero)
                  const SharedNotice(
                    'Someone else paid · no debit is created on your account.',
                  ),
                if (preview.yourBalance.paise != 0)
                  SharedMoneyLine(
                    preview.yourBalance.paise > 0
                        ? 'You get back'
                        : 'You will owe',
                    Money.fromPaise(preview.yourBalance.paise.abs()),
                    confidence: Confidence.confirmed,
                  ),
              ] else if (editor.billText.isNotEmpty)
                for (final message in calculation.errors.values.toSet())
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.xs),
                    child: Text(
                      message,
                      style: BambooFonts.ui(12, color: BambooInk.clayInk),
                    ),
                  ),
              if (calculation.blockers.isNotEmpty)
                const SharedNotice(
                  'Linking your own bank payment is not available yet. No shared debt or duplicate payment is created.',
                ),
              if (editor.sealed)
                const SharedNotice(
                  'Submitted once. Check its sync and review status in Splits.',
                ),
            ],
          ],
        ),
      ),
    );
  }
}
