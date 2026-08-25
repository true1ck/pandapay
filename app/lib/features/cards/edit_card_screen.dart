import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';

/// C4 Edit Card (ui-spec Group C, implementation-plan-group-c-d.md).
/// Fields: nickname, credit limit, statement/due dates, points balance —
/// every field with a real backing column (`PATCH /user-cards/:id`).
/// "Card art/colour" is in the spec's field list too, but no per-user
/// override column exists in the schema (only card_products' own
/// catalogue-wide art) — flagged, not faked; see the backend route's own
/// doc-comment.
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
  int? _statementDay;
  int? _dueDay;
  bool _initialized = false;
  bool _saving = false;
  bool _archiving = false;
  bool _settingDefault = false;
  String? _error;

  @override
  void dispose() {
    _nicknameController.dispose();
    _creditLimitController.dispose();
    _pointsBalanceController.dispose();
    super.dispose();
  }

  double? _originalPointsBalance;

  void _initFrom(UserCard card) {
    if (_initialized) return;
    _initialized = true;
    _nicknameController.text = card.nickname ?? '';
    if (card.creditLimit != null) _creditLimitController.text = card.creditLimit!.rupees.toStringAsFixed(0);
    _pointsBalanceController.text = card.totalPointsEarned > 0
        ? card.totalPointsEarned.toStringAsFixed(0)
        : '';
    _originalPointsBalance = card.totalPointsEarned;
    _statementDay = card.statementDay;
    _dueDay = card.dueDay;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final nickname = _nicknameController.text.trim().isEmpty ? null : _nicknameController.text.trim();
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
        );
      }
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      if (mounted) context.pop();
    } catch (e) {
      // Same offline-queue pattern as edit_transaction_screen.dart's _save —
      // this is an edit to a row that already exists, which the sync queue
      // can represent. Only nickname/credit-limit/statement-day/due-day are
      // queued: pandapay.sync_fields_for('user_cards') (migration 0034) does
      // NOT include points balance — that field is corrected through
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
            newPointsBalance != null && newPointsBalance != _originalPointsBalance;

        final queue = await ref.read(syncQueueProvider.future);
        queue.enqueueUpdate(
          entity: 'user_cards',
          entityId: widget.userCardId,
          fields: {
            'nickname': _nicknameController.text.trim().isEmpty ? null : _nicknameController.text.trim(),
            'credit_limit_inr': _creditLimitController.text.trim().isEmpty
                ? null
                : double.tryParse(_creditLimitController.text.trim()),
            'statement_day': _statementDay,
            'due_day': _dueDay,
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
              Text('Remove this card?', style: BambooFonts.heading(18, color: BambooInk.ink900)),
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
            const SnackBar(content: Text('Removed offline — will sync when you reconnect.')),
          );
          context.pop();
        }
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Set as your default card.')));
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
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Edit card', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: pairs.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
          data: (owned) {
            final match = owned.where((p) => p.$1.id == widget.userCardId).firstOrNull;
            if (match == null) {
              return const ErrorState(message: 'This card could not be found — it may have been removed.');
            }
            final (userCard, product) = match;
            _initFrom(userCard);

            return ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                Text(product.name, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                const SizedBox(height: AppSpace.lg),
                TextField(
                  controller: _nicknameController,
                  decoration: const InputDecoration(labelText: 'Nickname'),
                ),
                const SizedBox(height: AppSpace.lg),
                TextField(
                  controller: _creditLimitController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Credit limit (₹)',
                    helperText: 'Used to protect your credit score (Credit Utilization)',
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _statementDay,
                        decoration: const InputDecoration(labelText: 'Statement day'),
                        items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
                        onChanged: (v) => setState(() => _statementDay = v),
                      ),
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _dueDay,
                        decoration: const InputDecoration(labelText: 'Due day'),
                        items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
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
                if (_error != null) ...[
                  const SizedBox(height: AppSpace.md),
                  Text(_error!, style: BambooFonts.ui(12.5, color: BambooInk.clay)),
                ],
                const SizedBox(height: AppSpace.xl),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                  ),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.lime),
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
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.md),
                    decoration: BoxDecoration(
                      color: BambooInk.paperMuted,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: BambooInk.hairlineOnPaper),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.star_rounded, size: 18, color: BambooInk.jade),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            'This is your default card',
                            style: BambooFonts.ui(13.5, weight: FontWeight.w600, color: BambooInk.ink900),
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                    side: BorderSide(color: BambooInk.clay.withValues(alpha: 0.4)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _archiving ? null : _archive,
                  icon: _archiving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.clay),
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
              ],
            );
          },
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
