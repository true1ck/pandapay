import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import '../../../app/design/app_theme.dart';
import '../../../app/required_field.dart';
import '../ui/shared_components.dart';
import 'shared_editor.dart';

/// Sharing controls embedded in the existing Quick Add owner.
class SharedEditorFields extends StatelessWidget {
  final SharedEditor editor;
  final VoidCallback onChooseContext;
  final VoidCallback? onAddMember;
  final bool loading;
  final String? error;

  /// True once Submit was tapped with something missing: required inputs that
  /// are still empty get a red border.
  final bool submitted;
  const SharedEditorFields({
    super.key,
    required this.editor,
    required this.onChooseContext,
    this.onAddMember,
    this.loading = false,
    this.error,
    this.submitted = false,
  });
  Widget _field(
    String label,
    String value,
    ValueChanged<String> change, {
    String? suffix,
    String? errorKey,
  }) => TextFormField(
    key: ValueKey('$label:${editor.contextId}:${editor.mode.name}'),
    initialValue: value,
    readOnly: editor.sealed || editor.isSealing,
    style: BambooFonts.ui(14),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    textInputAction: TextInputAction.done,
    onChanged: change,
    onFieldSubmitted: (_) {
      FocusManager.instance.primaryFocus?.unfocus();
    },
    onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
    decoration: InputDecoration(
      label: requiredLabel(label),
      suffixText: suffix,
      errorText: submitted && errorKey != null
          ? editor.evaluation.errors[errorKey]
          : null,
      errorMaxLines: 2,
    ),
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
            RequiredBox(
              invalid: submitted && !editor.contextVerified,
              message: 'Choose who to split with',
              child: SharedTextAction(
                label: editor.contextName.isEmpty
                    ? 'Choose group or friend *'
                    : editor.contextName,
                icon: Icons.people_outline_rounded,
                onTap: onChooseContext,
              ),
            ),
            if (loading) const LinearProgressIndicator(color: BambooInk.slate),
            if (error != null)
              Text(error!, style: BambooFonts.ui(12, color: BambooInk.clayInk)),
            if (editor.contextId != null) ...[
              RequiredBox(
                invalid:
                    submitted &&
                    !editor.multiplePayers &&
                    !editor.members.any((m) => m.id == editor.singlePayer),
                message: 'Choose who paid',
                child: DropdownButtonFormField<String>(
                  key: ValueKey('${editor.contextId}:${editor.singlePayer}'),
                  initialValue:
                      editor.members.any((m) => m.id == editor.singlePayer)
                      ? editor.singlePayer
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(label: requiredLabel('Paid by')),
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
              _MoreOptions(
                editor: editor,
                children: [
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
                                style: BambooFonts.ui(
                                  14,
                                  weight: FontWeight.w600,
                                ),
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
                          errorKey: 'paid:${member.id}',
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
                    _field(
                      'Shared amount',
                      editor.sharedText,
                      editor.setShared,
                      errorKey: 'shared',
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              requiredLabel(
                'Shared with · ${_peopleCount(editor.participants.length)}',
                style: BambooFonts.ui(13, weight: FontWeight.w600),
              ),
              RequiredBox(
                invalid: submitted && editor.participants.isEmpty,
                message: 'Choose at least one person',
                child: Wrap(
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
                        errorKey: 'split:${m.id}',
                      ),
                    ),
              if (preview != null) ...[
                const Divider(color: BambooInk.hairlineOnPaper),
                // The answer first: who ends up paying whom.
                if (preview.yourFullPaid.isZero)
                  const SharedNotice(
                    'Someone else paid · no debit is created on your account.',
                  ),
                if (preview.yourBalance.paise != 0)
                  _ResultBanner(
                    getsBack: preview.yourBalance.paise > 0,
                    amount: Money.fromPaise(preview.yourBalance.paise.abs()),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.xs),
                  child: Text(
                    'Split',
                    style: BambooFonts.ui(
                      12,
                      weight: FontWeight.w700,
                      color: BambooInk.ink500,
                    ),
                  ),
                ),
                // Everyone's part, yours included: the one place a share shows.
                for (final m in editor.members)
                  if (preview.shares.containsKey(m.id))
                    SharedMoneyLine(
                      m.label,
                      preview.shares[m.id]!,
                      confidence: Confidence.confirmed,
                    ),
                // The bill's own figures only when they add something: with one
                // payer and the whole bill shared they just repeat the amount
                // typed above and the person chosen in "Paid by".
                if (editor.partial || editor.multiplePayers) ...[
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
                  if (!preview.yourResidual.isZero)
                    SharedMoneyLine(
                      'Your unshared amount',
                      preview.yourResidual,
                      confidence: Confidence.confirmed,
                    ),
                ],
                // What counts as spending: your share, said once in words. Only
                // when it differs (part of the bill kept for yourself) does it
                // need a figure of its own.
                if (preview.yourPersonalCost.paise != preview.yourShare.paise)
                  SharedMoneyLine(
                    'Counts as your spending',
                    preview.yourPersonalCost,
                    confidence: Confidence.confirmed,
                  )
                else if (!preview.yourShare.isZero)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.xs),
                    child: Text(
                      'Your share counts as your spending.',
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
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

/// "2 people", "1 person"; the 50-person cap only shows once it is close.
String _peopleCount(int count) =>
    count >= 40 ? '$count/50' : '$count ${count == 1 ? 'person' : 'people'}';

/// The rarely needed options (several payers, sharing only part of a bill) sit
/// behind one quiet row, so the common case is just: who paid, who shares, how.
/// Open already when either is on; the row says which are on when it is closed.
class _MoreOptions extends StatelessWidget {
  const _MoreOptions({required this.editor, required this.children});

  final SharedEditor editor;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final active = [
      if (editor.multiplePayers) 'Multiple payers',
      if (editor.partial) 'Part of the bill',
    ];
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: ValueKey('shared-more-options:${editor.contextId}'),
        initiallyExpanded: active.isNotEmpty,
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          'More options',
          style: BambooFonts.ui(13, weight: FontWeight.w600),
        ),
        subtitle: active.isEmpty
            ? null
            : Text(
                active.join(' · '),
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
        children: children,
      ),
    );
  }
}

/// Who ends up paying whom, as the first thing under the split: green when
/// money comes back to you, clay when you owe.
class _ResultBanner extends StatelessWidget {
  const _ResultBanner({required this.getsBack, required this.amount});

  final bool getsBack;
  final Money amount;

  @override
  Widget build(BuildContext context) {
    final tone = getsBack ? BambooInk.jade : BambooInk.clayInk;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: tone.withValues(alpha: 0.22)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpace.lg,
        runSpacing: AppSpace.xs,
        children: [
          Text(
            getsBack ? 'You get back' : 'You will owe',
            style: BambooFonts.ui(14, weight: FontWeight.w700, color: tone),
          ),
          SharedAmount(amount, confidence: Confidence.confirmed, color: tone),
        ],
      ),
    );
  }
}
