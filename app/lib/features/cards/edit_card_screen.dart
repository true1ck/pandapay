import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import 'card_network_util.dart';
import 'card_visual.dart';
import '../insights/credit_utilization_ui.dart';

/// C4 Edit Card (ui-spec Group C, implementation-plan-group-c-d.md).
///
/// The catalogue section is intentionally read-only: fees, rewards, caps and
/// benefits belong to the card product and are already fetched from the
/// catalogue. The settings below it are the values that can differ for one
/// customer, such as their last four digits, credit limit and fee offer.
class EditCardScreen extends ConsumerStatefulWidget {
  final String userCardId;
  const EditCardScreen({super.key, required this.userCardId});

  @override
  ConsumerState<EditCardScreen> createState() => _EditCardScreenState();
}

class _EditCardScreenState extends ConsumerState<EditCardScreen> {
  final _nicknameController = TextEditingController();
  final _creditLimitController = TextEditingController();
  final _pointsBalanceController = TextEditingController();
  final _last4Controller = TextEditingController();
  final _annualFeeController = TextEditingController();
  int? _statementDay;
  int? _dueDay;
  bool _initialized = false;
  bool _saving = false;
  bool _archiving = false;
  bool _settingDefault = false;
  bool _feeOverrideEnabled = false;
  bool _lifetimeFree = false;
  AutopayMode _autopayMode = AutopayMode.off;
  Money? _originalAnnualFeeOverride;
  String? _error;

  @override
  void dispose() {
    _nicknameController.dispose();
    _creditLimitController.dispose();
    _pointsBalanceController.dispose();
    _last4Controller.dispose();
    _annualFeeController.dispose();
    super.dispose();
  }

  double? _originalPointsBalance;

  void _initFrom(UserCard card) {
    if (_initialized) return;
    _initialized = true;
    _nicknameController.text = card.nickname ?? '';
    if (card.creditLimit != null) {
      _creditLimitController.text = card.creditLimit!.rupees.toStringAsFixed(0);
    }
    // totalPointsEarned is a lifetime calculated total. The editable field is
    // the raw current/starting balance stored on user_cards.
    _pointsBalanceController.text =
        card.pointsBalance?.toStringAsFixed(0) ?? '';
    _originalPointsBalance = card.pointsBalance;
    _statementDay = card.statementDay;
    _dueDay = card.dueDay;
    _last4Controller.text = card.last4 ?? '';
    _autopayMode = card.autopayMode;
    _feeOverrideEnabled = card.annualFeeOverride != null;
    _lifetimeFree = card.annualFeeOverride?.isZero ?? false;
    _originalAnnualFeeOverride = card.annualFeeOverride;
    if (_feeOverrideEnabled && !_lifetimeFree) {
      _annualFeeController.text = card.annualFeeOverride!.rupees
          .toStringAsFixed(0);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final editedAnnualFeeOverride = _feeOverrideEnabled
        ? (_lifetimeFree
              ? 0.0
              : double.tryParse(_annualFeeController.text.trim()) ?? 0.0)
        : null;
    final annualFeeOverrideChanged =
        editedAnnualFeeOverride != _originalAnnualFeeOverride?.rupees;
    try {
      final nickname = _nicknameController.text.trim().isEmpty
          ? null
          : _nicknameController.text.trim();
      final repo = ref.read(userCardsRepositoryProvider);
      if (repo == null) {
        // Guest mode: only nickname has a local backing column — see
        // LocalUserCardsRepository.updateCard's own doc comment.
        final local = await ref.read(localUserCardsRepositoryProvider.future);
        await local.updateCard(widget.userCardId, nickname: nickname);
      } else {
        await repo.updateCard(
          widget.userCardId,
          nickname: nickname,
          creditLimitInr: _creditLimitController.text.trim().isEmpty
              ? null
              : double.tryParse(_creditLimitController.text.trim()),
          statementDay: _statementDay,
          dueDay: _dueDay,
          pointsBalance: _pointsBalanceController.text.trim().isEmpty
              ? null
              : double.tryParse(_pointsBalanceController.text.trim()),
          autopayMode: _autopayMode,
          // Always sent (never null-skipped), so clearing the field really
          // clears the stored digits — '' is a meaningful value here, not
          // "leave it alone". See UserCardsRepository.updateCard.
          last4: _last4Controller.text.trim(),
        );
        if (annualFeeOverrideChanged) {
          await repo.updateAnnualFeeOverride(
            widget.userCardId,
            annualFeeOverrideInr: editedAnnualFeeOverride,
            clear: !_feeOverrideEnabled,
          );
        }
      }
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      if (mounted) context.pop();
    } catch (e) {
      // Same offline-queue pattern as edit_transaction_screen.dart's _save —
      // this is an edit to a row that already exists, which the sync queue
      // can represent. Points balance is not queued: pandapay.sync_fields_for
      // ('user_cards') does NOT include it — that field is corrected through
      // points_ledger/adjustPointsBalance's own reconciliation path, not a
      // blind field overwrite, so queuing it here would be silently dropped
      // by the server rather than applied. A changed points balance is
      // called out explicitly instead of being queued-and-forgotten.
      final offline = ref.read(isOnlineProvider).valueOrNull == false;
      final repo = ref.read(userCardsRepositoryProvider);
      if (offline && repo != null) {
        final newPointsBalance = _pointsBalanceController.text.trim().isEmpty
            ? null
            : double.tryParse(_pointsBalanceController.text.trim());
        final pointsBalanceChanged =
            newPointsBalance != null &&
            newPointsBalance != _originalPointsBalance;

        final queue = await ref.read(syncQueueProvider.future);
        queue.enqueueUpdate(
          entity: 'user_cards',
          entityId: widget.userCardId,
          fields: {
            'nickname': _nicknameController.text.trim().isEmpty
                ? null
                : _nicknameController.text.trim(),
            'credit_limit_inr': _creditLimitController.text.trim().isEmpty
                ? null
                : double.tryParse(_creditLimitController.text.trim()),
            'statement_day': _statementDay,
            'due_day': _dueDay,
            'autopay_mode': _autopayMode.wireValue,
            'last4': _last4Controller.text.trim().isEmpty
                ? null
                : _last4Controller.text.trim(),
            if (annualFeeOverrideChanged)
              'annual_fee_override_inr': editedAnnualFeeOverride,
          },
        );
        ref.invalidate(pendingSyncCountProvider);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                pointsBalanceChanged
                    ? 'Saved offline — will sync when you reconnect. Points balance needs a live '
                          'connection though, so that change wasn\'t saved; correct it again once you\'re online.'
                    : 'Saved offline — will sync when you reconnect.',
              ),
            ),
          );
          context.pop();
        }
        return;
      }
      setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Design 23's destructive "remove". R4 is "archive, never delete" —
  /// there is deliberately no DELETE /user-cards route — so this removes the
  /// card from the wallet without destroying its history, and says exactly
  /// that in the confirmation sheet rather than implying data is erased.
  /// The design asks for a confirming sheet on destructive actions, which
  /// is what this adds over the previous one-tap archive button.
  Future<void> _archive() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Remove this card?',
                style: BambooFonts.heading(18, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                "It stops appearing in recommendations right away. Its transaction history is kept, and you can "
                "restore it any time from Wallet → Archived.",
                style: BambooFonts.ui(13.5, color: BambooInk.ink500),
              ),
              const SizedBox(height: AppSpace.lg),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.clay,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: () => Navigator.of(sheetContext).pop(true),
                child: const Text('Remove card'),
              ),
              const SizedBox(height: AppSpace.sm),
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(false),
                style: TextButton.styleFrom(foregroundColor: BambooInk.ink500),
                child: const Text('Keep it'),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;

    setState(() => _archiving = true);
    try {
      final repo = ref.read(userCardsRepositoryProvider);
      if (repo == null) {
        final local = await ref.read(localUserCardsRepositoryProvider.future);
        await local.archiveCard(widget.userCardId);
      } else {
        await repo.archiveCard(widget.userCardId);
      }
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      if (mounted) context.pop();
    } catch (e) {
      // Archiving is just `is_archived = true` on a row that already exists
      // (R4 "archive, never delete" — see this method's own doc comment),
      // and `is_archived` is one of the fields pandapay.sync_fields_for
      // ('user_cards') allows, so this queues the same way _save does above.
      final offline = ref.read(isOnlineProvider).valueOrNull == false;
      final repo = ref.read(userCardsRepositoryProvider);
      if (offline && repo != null) {
        final queue = await ref.read(syncQueueProvider.future);
        queue.enqueueUpdate(
          entity: 'user_cards',
          entityId: widget.userCardId,
          fields: {'is_archived': true},
        );
        ref.invalidate(pendingSyncCountProvider);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Removed offline — will sync when you reconnect.'),
            ),
          );
          context.pop();
        }
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }

  /// Design 23 "set as default". Branches on guest mode the same way every
  /// other wallet action does (see LocalUserCardsRepository) — a signed-out
  /// user's wallet is real and on-device, so this must work there too.
  Future<void> _setDefault() async {
    setState(() => _settingDefault = true);
    try {
      final repo = ref.read(userCardsRepositoryProvider);
      if (repo == null) {
        final local = await ref.read(localUserCardsRepositoryProvider.future);
        await local.setDefaultCard(widget.userCardId);
      } else {
        await repo.setDefaultCard(widget.userCardId);
      }
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Set as your default card.')),
        );
      }
    } catch (e) {
      // Deliberately NOT queued offline, unlike _save/_archive above. "Only
      // one default card" isn't a database constraint (no unique index on
      // is_default) — it's enforced by setDefaultCard's own endpoint
      // atomically clearing every other card's flag before setting this
      // one. The generic sync_apply_change (migration 0034) only ever
      // touches the single row named in the queued change, so queuing just
      // {'is_default': true} for this card would leave whichever card is
      // CURRENTLY default also still flagged default once both changes
      // eventually applied — two "default" cards at once. Safer to ask for
      // connectivity than to risk that.
      final offline = ref.read(isOnlineProvider).valueOrNull == false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              offline
                  ? 'Setting a default card needs an internet connection — try again once you\'re back online.'
                  : userFacingErrorMessage(e),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _settingDefault = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pairs = ref.watch(myCardsWithProductProvider);
    final utilization = ref.watch(creditUtilizationProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Edit card',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: pairs.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
          data: (owned) {
            final match = owned
                .where((p) => p.$1.id == widget.userCardId)
                .firstOrNull;
            if (match == null) {
              return const ErrorState(
                message:
                    'This card could not be found — it may have been removed.',
              );
            }
            final (userCard, product) = match;
            _initFrom(userCard);
            final utilizationResult = utilization[userCard.id];
            final feePreview = _feeOverrideEnabled
                ? (_lifetimeFree
                      ? const Money.zero()
                      : Money.fromRupees(
                          double.tryParse(_annualFeeController.text.trim()) ??
                              0,
                        ))
                : null;

            return ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                _CatalogueCardDetails(
                  product: product,
                  userCard: userCard,
                  feePreview: feePreview,
                ),
                const SizedBox(height: AppSpace.lg),
                Text(
                  'YOUR CARD SETTINGS',
                  style: BambooFonts.ui(
                    11,
                    weight: FontWeight.w600,
                    color: BambooInk.ink500,
                  ).copyWith(letterSpacing: 1),
                ),
                const SizedBox(height: AppSpace.sm),
                TextField(
                  controller: _nicknameController,
                  decoration: const InputDecoration(labelText: 'Nickname'),
                ),
                const SizedBox(height: AppSpace.lg),
                // The field that makes automatic capture work. Without it,
                // every bank SMS and forwarded email has to be assigned a
                // card by hand, one message at a time. Labelled and
                // helper-texted to say exactly what it's for and what it
                // isn't — four digits are a matching key, and the app never
                // asks for, stores, or transmits a full card number.
                TextField(
                  controller: _last4Controller,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  decoration: const InputDecoration(
                    labelText: 'Last 4 digits',
                    helperText:
                        'Lets PandaPay match your bank\'s SMS and email alerts to this card '
                        'automatically. Never your full card number.',
                    helperMaxLines: 3,
                    counterText: '',
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                TextField(
                  controller: _creditLimitController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Credit limit (₹)',
                    helperText:
                        'Detected from bank SMS when available. Edit it if your issuer changed the limit.',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _creditLimitController,
                  builder: (context, value, child) {
                    final parsedLimit = double.tryParse(value.text.trim());
                    final editedLimit = parsedLimit == null
                        ? userCard.creditLimit
                        : Money.fromRupees(parsedLimit);
                    final editedResult =
                        utilizationResult == null ||
                            editedLimit == null ||
                            editedLimit.isZero
                        ? null
                        : creditUtilization(
                            utilizationResult.currentBalance,
                            editedLimit,
                          );
                    return _CreditUtilizationSummary(
                      result: editedResult,
                      creditLimit: editedLimit,
                    );
                  },
                ),
                const SizedBox(height: AppSpace.lg),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _statementDay,
                        decoration: const InputDecoration(
                          labelText: 'Statement day',
                        ),
                        items: [
                          for (var d = 1; d <= 31; d++)
                            DropdownMenuItem(value: d, child: Text('$d')),
                        ],
                        onChanged: (v) => setState(() => _statementDay = v),
                      ),
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _dueDay,
                        decoration: const InputDecoration(labelText: 'Due day'),
                        items: [
                          for (var d = 1; d <= 31; d++)
                            DropdownMenuItem(value: d, child: Text('$d')),
                        ],
                        onChanged: (v) => setState(() => _dueDay = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.lg),
                TextField(
                  controller: _pointsBalanceController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Current points balance',
                    helperText: "Starting point — we'll track from here",
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                DropdownButtonFormField<AutopayMode>(
                  initialValue: _autopayMode,
                  decoration: const InputDecoration(
                    labelText: 'Autopay preference',
                    helperText:
                        'This records your answer only. PandaPay cannot verify or change your bank mandate.',
                    helperMaxLines: 2,
                  ),
                  items: [
                    for (final mode in AutopayMode.values)
                      DropdownMenuItem(
                        value: mode,
                        child: Text(_autopayLabel(mode)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _autopayMode = value);
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpace.md),
                  Text(
                    _error!,
                    style: BambooFonts.ui(12.5, color: BambooInk.clay),
                  ),
                ],
                const SizedBox(height: AppSpace.xl),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                  ),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: BambooInk.lime,
                          ),
                        )
                      : const Text('Save'),
                ),
                const SizedBox(height: AppSpace.xl),
                // Design 23 "Card actions": set as default / remove.
                Text(
                  'CARD ACTIONS',
                  style: BambooFonts.ui(
                    11,
                    weight: FontWeight.w600,
                    color: BambooInk.ink500,
                  ).copyWith(letterSpacing: 1),
                ),
                const SizedBox(height: AppSpace.sm),
                if (userCard.isDefault)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.md,
                      vertical: AppSpace.md,
                    ),
                    decoration: BoxDecoration(
                      color: BambooInk.paperMuted,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: BambooInk.hairlineOnPaper),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.star_rounded,
                          size: 18,
                          color: BambooInk.jade,
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            'This is your default card',
                            style: BambooFonts.ui(
                              13.5,
                              weight: FontWeight.w600,
                              color: BambooInk.ink900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BambooInk.ink900,
                      minimumSize: const Size.fromHeight(48),
                      side: const BorderSide(color: BambooInk.hairlineOnPaper),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _settingDefault ? null : _setDefault,
                    icon: _settingDefault
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.star_outline_rounded),
                    label: const Text('Set as default card'),
                  ),
                const SizedBox(height: AppSpace.md),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BambooInk.clay,
                    minimumSize: const Size.fromHeight(48),
                    side: BorderSide(
                      color: BambooInk.clay.withValues(alpha: 0.4),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _archiving ? null : _archive,
                  icon: _archiving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: BambooInk.clay,
                          ),
                        )
                      : const Icon(Icons.delete_outline_rounded),
                  label: const Text('Remove card'),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  "Removing keeps this card's full transaction history — nothing is deleted, and you can restore it any time from Wallet → Archived.",
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpace.xl),
                Text(
                  'FEE FOR THIS CARD',
                  style: BambooFonts.ui(
                    11,
                    weight: FontWeight.w600,
                    color: BambooInk.ink500,
                  ).copyWith(letterSpacing: 1),
                ),
                const SizedBox(height: AppSpace.sm),
                Container(
                  padding: const EdgeInsets.all(AppSpace.md),
                  decoration: BoxDecoration(
                    color: BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: BambooInk.hairlineOnPaper),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            'Override annual fee for me',
                            style: BambooFonts.ui(
                              14,
                              weight: FontWeight.w700,
                              color: BambooInk.ink900,
                            ),
                          ),
                          subtitle: Text(
                            'Use this when your bank gave you a lifetime-free or custom-fee offer.',
                            style: BambooFonts.ui(
                              12.5,
                              color: BambooInk.ink500,
                            ),
                          ),
                          value: _feeOverrideEnabled,
                          onChanged: (value) => setState(() {
                            _feeOverrideEnabled = value;
                            if (!value) {
                              _lifetimeFree = false;
                              _annualFeeController.clear();
                            } else if (_annualFeeController.text
                                .trim()
                                .isEmpty) {
                              _annualFeeController.text = '0';
                            }
                          }),
                          activeThumbColor: BambooInk.jade,
                          activeTrackColor: BambooInk.jade.withValues(
                            alpha: 0.35,
                          ),
                        ),
                        if (_feeOverrideEnabled) ...[
                          const Divider(height: AppSpace.lg),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              'Lifetime free (LTF)',
                              style: BambooFonts.ui(
                                13.5,
                                color: BambooInk.ink900,
                              ),
                            ),
                            value: _lifetimeFree,
                            onChanged: (value) => setState(() {
                              _lifetimeFree = value ?? false;
                              if (_lifetimeFree) {
                                _annualFeeController.text = '0';
                              }
                            }),
                            activeColor: BambooInk.jade,
                          ),
                          if (!_lifetimeFree)
                            TextField(
                              controller: _annualFeeController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Your annual fee (₹)',
                                helperText:
                                    'Leave the catalogue fee unchanged by switching the override off.',
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CreditUtilizationSummary extends StatelessWidget {
  final UtilizationResult? result;
  final Money? creditLimit;

  const _CreditUtilizationSummary({
    required this.result,
    required this.creditLimit,
  });

  @override
  Widget build(BuildContext context) {
    if (result == null || creditLimit == null || creditLimit!.isZero) {
      return const SizedBox.shrink();
    }

    final current = result!;
    final color = CreditUtilizationUi.color(current.ratio);
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Credit health this cycle',
                  style: BambooFonts.ui(
                    13,
                    weight: FontWeight.w700,
                    color: BambooInk.ink900,
                  ),
                ),
              ),
              Icon(
                CreditUtilizationUi.icon(current.ratio),
                size: 16,
                color: color,
              ),
              const SizedBox(width: 4),
              Text(
                '${(current.ratio * 100).clamp(0, 999).toStringAsFixed(0)}%',
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: current.ratio.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: BambooInk.paperMuted,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${current.currentBalance.format(hidePaise: true)} tracked spend of ${creditLimit!.format(hidePaise: true)} this statement cycle',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: 4),
          Text(
            CreditUtilizationUi.guidance(current.ratio),
            style: BambooFonts.ui(12, color: color),
          ),
          const SizedBox(height: 6),
          Text(
            'This is calculated from imported card transactions, not an issuer statement balance. Correct a wrong transaction from Activity.',
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
        ],
      ),
    );
  }
}

class _CatalogueCardDetails extends StatelessWidget {
  final CardProduct product;
  final UserCard userCard;
  final Money? feePreview;

  const _CatalogueCardDetails({
    required this.product,
    required this.userCard,
    this.feePreview,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveFee =
        feePreview ?? userCard.annualFeeOverride ?? product.annualFeeInr;
    final loungeCount = product.benefits
        .where(
          (benefit) =>
              benefit.kind == BenefitKind.loungeDomestic ||
              benefit.kind == BenefitKind.loungeInternational,
        )
        .length;
    final rewardCount =
        product.rewardRules.length + (product.fuelRule == null ? 0 : 1);
    final verified = product.verifiedAt == null
        ? null
        : _shortDate(product.verifiedAt!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardVisual(product: product, height: 142),
        const SizedBox(height: AppSpace.md),
        Text(
          product.name,
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
        const SizedBox(height: 4),
        Text(
          [
            if (product.issuerName?.trim().isNotEmpty == true)
              product.issuerName!,
            cardNetworkLabel(product.network),
          ].join(' · '),
          style: BambooFonts.ui(13, color: BambooInk.ink500),
        ),
        const SizedBox(height: AppSpace.md),
        Container(
          padding: const EdgeInsets.all(AppSpace.md),
          decoration: BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: BambooInk.hairlineOnPaper),
          ),
          child: Column(
            children: [
              _CatalogueInfoRow(
                label: feePreview == null && userCard.annualFeeOverride == null
                    ? 'Annual fee'
                    : 'Your annual fee',
                value: effectiveFee == null
                    ? 'Not recorded'
                    : effectiveFee.isZero
                    ? 'Lifetime free'
                    : effectiveFee.format(hidePaise: true),
                valueColor: effectiveFee?.isZero == true
                    ? BambooInk.jade
                    : BambooInk.ink900,
              ),
              if (product.joiningFeeInr != null)
                _CatalogueInfoRow(
                  label: 'Joining fee',
                  value: product.joiningFeeInr!.isZero
                      ? 'Free'
                      : product.joiningFeeInr!.format(hidePaise: true),
                ),
              _CatalogueInfoRow(
                label: 'Rewards',
                value: rewardCount == 0
                    ? 'No reward rules recorded'
                    : '$rewardCount earning rules',
              ),
              _CatalogueInfoRow(
                label: 'Tracked limits',
                value:
                    '${product.capRules.length} caps · ${product.milestoneRules.length} milestones',
              ),
              _CatalogueInfoRow(
                label: 'Benefits',
                value: product.benefits.isEmpty
                    ? 'None recorded'
                    : '${product.benefits.length} benefits${loungeCount == 0 ? '' : ' · $loungeCount lounge'}',
              ),
              if (verified != null)
                _CatalogueInfoRow(label: 'Catalogue verified', value: verified),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          'These card details come from PandaPay’s catalogue. Edit only your personal settings below; catalogue rules stay consistent everywhere in the app.',
          style: BambooFonts.ui(12, color: BambooInk.ink500),
        ),
      ],
    );
  }
}

class _CatalogueInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _CatalogueInfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: BambooFonts.ui(
              12.5,
              weight: FontWeight.w700,
              color: valueColor ?? BambooInk.ink900,
            ),
          ),
        ),
      ],
    ),
  );
}

String _autopayLabel(AutopayMode mode) => switch (mode) {
  AutopayMode.off => 'Not verified',
  AutopayMode.minimum => 'Minimum due',
  AutopayMode.full => 'Full statement balance',
};

String _shortDate(DateTime value) {
  final date = value.toLocal();
  return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
