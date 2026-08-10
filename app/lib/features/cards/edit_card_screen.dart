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
  String? _error;

  @override
  void dispose() {
    _nicknameController.dispose();
    _creditLimitController.dispose();
    _pointsBalanceController.dispose();
    super.dispose();
  }

  void _initFrom(UserCard card) {
    if (_initialized) return;
    _initialized = true;
    _nicknameController.text = card.nickname ?? '';
    if (card.creditLimit != null) _creditLimitController.text = card.creditLimit!.rupees.toStringAsFixed(0);
    _pointsBalanceController.text = card.totalPointsEarned > 0 ? card.totalPointsEarned.toStringAsFixed(0) : '';
    _statementDay = card.statementDay;
    _dueDay = card.dueDay;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(userCardsRepositoryProvider)!;
      await repo.updateCard(
        widget.userCardId,
        nickname: _nicknameController.text.trim().isEmpty ? null : _nicknameController.text.trim(),
        creditLimitInr: _creditLimitController.text.trim().isEmpty ? null : double.tryParse(_creditLimitController.text.trim()),
        statementDay: _statementDay,
        dueDay: _dueDay,
        pointsBalance: _pointsBalanceController.text.trim().isEmpty ? null : double.tryParse(_pointsBalanceController.text.trim()),
      );
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      if (mounted) context.pop();
    } catch (e) {
      setState(() => _error = userFacingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _archive() async {
    setState(() => _archiving = true);
    try {
      await ref.read(userCardsRepositoryProvider)!.archiveCard(widget.userCardId);
      ref.invalidate(myCardsProvider);
      ref.invalidate(userCardsProvider);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _archiving = false);
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
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.9, -0.5),
            radius: 1.3,
            colors: [BambooInk.wash, BambooInk.paper],
            stops: [0.0, 0.6],
          ),
        ),
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
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.lime))
                    : const Text('Save'),
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
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.clay))
                    : const Icon(Icons.archive_outlined),
                label: const Text('Archive card'),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                "Archiving keeps this card's full transaction history — nothing is deleted, and you can restore it any time from My Cards.",
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
