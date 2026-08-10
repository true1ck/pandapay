import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';

/// ui-spec.md A9 Card Details Setup. Walks [userCardIds] one at a time
/// ("Card N of M"), collecting the same fields C4 Edit Card already PATCHes
/// (nickname/creditLimitInr/statementDay/dueDay/pointsBalance — all real
/// columns, all wired through `PATCH /user-cards/:id`, same as
/// edit_card_screen.dart). Every field is skippable; nickname is
/// pre-filled from the card's own name so it's never blank even if
/// untouched.
///
/// Points balance: `PATCH /user-cards/:id`'s `pointsBalance` field is real
/// (it writes `points_balance` and flips `points_balance_state` to
/// 'estimated' — see api/src/index.js's USER_CARD_PATCH_FIELDS), so unlike
/// an earlier draft of this plan assumed, this is NOT a documented no-op:
/// entering a starting balance here actually seeds `points_balance`, same
/// as C4's own points field already does.
class CardDetailsSetupScreen extends ConsumerStatefulWidget {
  final List<String> userCardIds;
  const CardDetailsSetupScreen({super.key, required this.userCardIds});

  @override
  ConsumerState<CardDetailsSetupScreen> createState() => _CardDetailsSetupScreenState();
}

class _CardDetailsSetupScreenState extends ConsumerState<CardDetailsSetupScreen> {
  int _index = 0;
  final _nicknameController = TextEditingController();
  final _creditLimitController = TextEditingController();
  final _pointsBalanceController = TextEditingController();
  int? _statementDay;
  int? _dueDay;
  String? _initializedForId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nicknameController.dispose();
    _creditLimitController.dispose();
    _pointsBalanceController.dispose();
    super.dispose();
  }

  void _initFrom(UserCard card) {
    if (_initializedForId == card.id) return;
    _initializedForId = card.id;
    _nicknameController.text = card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName;
    _creditLimitController.text = '';
    _pointsBalanceController.text = '';
    _statementDay = card.statementDay;
    _dueDay = card.dueDay;
  }

  bool get _isLast => _index == widget.userCardIds.length - 1;

  Future<void> _next(UserCard card) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final nickname = _nicknameController.text.trim();
      final creditLimit = _creditLimitController.text.trim();
      final points = _pointsBalanceController.text.trim();
      // Skip the PATCH entirely if nothing changed on this card — matches
      // C4's own "only provided fields update" contract, and avoids a
      // pointless write for a card the user skipped outright.
      final nicknameChanged = nickname.isNotEmpty && nickname != card.cardName;
      if (nicknameChanged || creditLimit.isNotEmpty || _statementDay != null || _dueDay != null || points.isNotEmpty) {
        final repo = ref.read(userCardsRepositoryProvider)!;
        await repo.updateCard(
          card.id,
          nickname: nicknameChanged ? nickname : null,
          creditLimitInr: creditLimit.isEmpty ? null : double.tryParse(creditLimit),
          statementDay: _statementDay,
          dueDay: _dueDay,
          pointsBalance: points.isEmpty ? null : double.tryParse(points),
        );
        ref.invalidate(userCardsProvider);
        ref.invalidate(myCardsProvider);
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingErrorMessage(e));
      if (mounted) setState(() => _saving = false);
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (_isLast) {
      context.go(AppRoute.trackingSetup);
    } else {
      setState(() => _index++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.userCardIds[_index];
    final userCards = ref.watch(userCardsProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Card ${_index + 1} of ${widget.userCardIds.length}',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.9, -0.5),
            radius: 1.3,
            colors: [BambooInk.wash, BambooInk.paper],
            stops: [0.0, 0.6],
          ),
        ),
        child: userCards.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(message: userFacingErrorMessage(err), onRetry: () => ref.invalidate(userCardsProvider)),
        data: (cards) {
          final card = cards.where((c) => c.id == id).firstOrNull;
          if (card == null) {
            // Card vanished (e.g. archived elsewhere mid-flow) — skip ahead
            // rather than get stuck on a card that no longer exists.
            return ErrorState(
              message: 'This card could not be found.',
              onRetry: _isLast ? null : () => setState(() => _index++),
            );
          }
          _initFrom(card);
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              Text(card.cardName, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
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
                  helperText: 'Used to protect your credit score',
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _statementDay,
                      decoration: const InputDecoration(
                        labelText: 'Statement day',
                        helperText: 'Maximises interest-free days',
                      ),
                      items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
                      onChanged: (v) => setState(() => _statementDay = v),
                    ),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _dueDay,
                      decoration: const InputDecoration(
                        labelText: 'Due day',
                        helperText: 'For bill reminders',
                      ),
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
              Row(
                children: [
                  if (_index > 0)
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: BambooInk.ink900,
                          minimumSize: const Size.fromHeight(52),
                          side: const BorderSide(color: BambooInk.hairlineOnPaper),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        onPressed: _saving ? null : () => setState(() => _index--),
                        child: const Text('Back'),
                      ),
                    ),
                  if (_index > 0) const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: BambooInk.slate,
                        foregroundColor: BambooInk.lime,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                      ),
                      onPressed: _saving ? null : () => _next(card),
                      child: _saving
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.lime))
                          : Text(_isLast ? 'Finish' : 'Next'),
                    ),
                  ),
                ],
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
