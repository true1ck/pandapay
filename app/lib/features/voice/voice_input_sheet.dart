import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:uuid/uuid.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/user_cards_repository.dart' show TxnInstrument, UserCard;
import 'voice_action_parser.dart';

Future<void> showVoiceInputSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const VoiceInputSheet(),
  );
}

class VoiceInputSheet extends ConsumerStatefulWidget {
  const VoiceInputSheet({super.key});

  @override
  ConsumerState<VoiceInputSheet> createState() => _VoiceInputSheetState();
}

class _VoiceInputSheetState extends ConsumerState<VoiceInputSheet> {
  final _speech = stt.SpeechToText();
  final _amountController = TextEditingController();
  final _pointsController = TextEditingController();
  final _merchantController = TextEditingController();
  final _noteController = TextEditingController();
  VoiceActionDraft? _draft;
  String _transcript = '';
  String? _selectedCardId;
  String? _selectedCategoryId;
  bool _available = false;
  bool _listening = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _speech.stop();
    _amountController.dispose();
    _pointsController.dispose();
    _merchantController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) {
        setState(() => _listening = false);
        _makeDraft();
      }
      return;
    }
    setState(() {
      _error = null;
      _transcript = '';
      _draft = null;
    });
    _available = await _speech.initialize(
      onStatus: (status) {
        if (!mounted || status != 'done') return;
        setState(() => _listening = false);
        if (_transcript.trim().isNotEmpty) _makeDraft();
      },
      onError: (error) {
        if (mounted) setState(() => _error = error.errorMsg);
      },
    );
    if (!_available) {
      if (mounted) {
        setState(
          () => _error = 'Microphone or speech recognition is unavailable.',
        );
      }
      return;
    }
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() => _transcript = result.recognizedWords);
        if (result.finalResult) _makeDraft();
      },
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        listenFor: const Duration(seconds: 45),
        pauseFor: const Duration(seconds: 4),
        listenMode: stt.ListenMode.dictation,
      ),
    );
  }

  void _makeDraft() {
    final cards = ref.read(userCardsProvider).valueOrNull ?? const <UserCard>[];
    final categories =
        ref.read(categoriesProvider).valueOrNull ?? const <SpendCategory>[];
    final draft = VoiceActionParser.parse(
      _transcript,
      cards: cards,
      categories: categories,
    );
    _amountController.text = draft.amount?.toStringAsFixed(2) ?? '';
    _pointsController.text = draft.points?.toString() ?? '';
    _merchantController.text = draft.merchant ?? '';
    _noteController.text = draft.transcript;
    setState(() {
      _draft = draft;
      _selectedCardId = draft.userCardId;
      _selectedCategoryId = draft.categoryId;
    });
  }

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null || draft.type == VoiceActionType.unsupported) return;
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) {
      setState(() => _error = 'Sign in before saving a voice entry.');
      return;
    }
    final cards = ref.read(userCardsProvider).valueOrNull ?? const <UserCard>[];
    final amount = double.tryParse(_amountController.text.replaceAll(',', ''));
    final points = int.tryParse(_pointsController.text.replaceAll(',', ''));
    if (draft.type == VoiceActionType.expense &&
        (amount == null || amount <= 0)) {
      setState(() => _error = 'Enter an amount greater than ₹0.');
      return;
    }
    if (draft.type == VoiceActionType.pointsRedemption &&
        (points == null || points <= 0)) {
      setState(() => _error = 'Enter the number of points to redeem.');
      return;
    }
    final card = _selectedCardId == null
        ? null
        : cards.where((item) => item.id == _selectedCardId).firstOrNull;
    if (draft.instrument == TxnInstrument.creditCard && card == null) {
      setState(
        () => _error = 'Choose the exact wallet card before confirming.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (draft.type == VoiceActionType.pointsRedemption) {
        if (card == null) {
          throw StateError(
            'Choose the wallet card used for the points redemption.',
          );
        }
        final ledger = await repo.fetchPointsLedger(card.id);
        final current =
            (card.pointsBalance ?? 0) +
            ledger.fold<double>(0, (sum, row) => sum + row.deltaPoints);
        if (points! > current) {
          throw StateError(
            'This card has ${current.toStringAsFixed(0)} points available, so the entry was not saved.',
          );
        }
        await repo.adjustPointsBalance(
          card.id,
          newBalance: current - points,
          reason:
              'Voice points redemption${_merchantController.text.trim().isEmpty ? '' : ': ${_merchantController.text.trim()}'}',
        );
      } else {
        await repo.logTransaction(
          userCardId: draft.instrument == TxnInstrument.creditCard
              ? _selectedCardId
              : null,
          amount: Money.fromRupees(amount!),
          categoryId: _selectedCategoryId,
          merchantName: _merchantController.text.trim().isEmpty
              ? null
              : _merchantController.text.trim(),
          note: _noteController.text.trim().isEmpty
              ? null
              : _noteController.text.trim(),
          occurredAt: DateTime.now(),
          instrument: draft.instrument,
          clientMutationId: const Uuid().v4(),
        );
      }
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      ref.invalidate(transactionsProvider);
      ref.invalidate(homeSummaryProvider);
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              draft.type == VoiceActionType.pointsRedemption
                  ? 'Points entry saved.'
                  : 'Spend saved.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cards =
        ref.watch(userCardsProvider).valueOrNull ?? const <UserCard>[];
    final categories =
        ref.watch(categoriesProvider).valueOrNull ?? const <SpendCategory>[];
    final draft = _draft;
    return Material(
      color: BambooInk.paper,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          14,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: draft == null
              ? _recordView()
              : _reviewView(draft, cards, categories),
        ),
      ),
    );
  }

  Widget _recordView() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 42,
        height: 4,
        decoration: BoxDecoration(
          color: BambooInk.ink300,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      const SizedBox(height: 24),
      const Icon(Icons.mic_none_rounded, size: 34, color: BambooInk.jade),
      const SizedBox(height: 8),
      Text(
        'Add by voice',
        style: BambooFonts.heading(22, color: BambooInk.ink900),
      ),
      const SizedBox(height: 6),
      Text(
        'Say a spend or points redemption. Nothing is saved until you confirm it.',
        textAlign: TextAlign.center,
        style: BambooFonts.ui(13, color: BambooInk.ink500),
      ),
      const SizedBox(height: 20),
      GestureDetector(
        onTap: _toggleListening,
        onLongPressStart: (_) => _toggleListening(),
        onLongPressEnd: (_) {
          if (_listening) _toggleListening();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: _listening ? 112 : 88,
          height: _listening ? 112 : 88,
          decoration: BoxDecoration(
            color: _listening ? BambooInk.jade : BambooInk.slate,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: BambooInk.jade.withValues(alpha: .25),
                blurRadius: 22,
              ),
            ],
          ),
          child: Icon(
            _listening ? Icons.stop_rounded : Icons.mic_rounded,
            color: Colors.white,
            size: 38,
          ),
        ),
      ),
      const SizedBox(height: 18),
      if (_listening)
        Text(
          'Listening… tap again when finished',
          style: BambooFonts.ui(13, color: BambooInk.jade),
        ),
      if (_transcript.isNotEmpty && !_listening) ...[
        const SizedBox(height: 14),
        _quote(_transcript),
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: BambooFonts.ui(13, color: BambooInk.clay),
        ),
      ],
      const SizedBox(height: 8),
    ],
  );

  Widget _reviewView(
    VoiceActionDraft draft,
    List<UserCard> cards,
    List<SpendCategory> categories,
  ) {
    final unsupported = draft.type == VoiceActionType.unsupported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.fact_check_rounded, color: BambooInk.jade),
            const SizedBox(width: 10),
            Text(
              'Review voice entry',
              style: BambooFonts.heading(20, color: BambooInk.ink900),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _quote(draft.transcript),
        const SizedBox(height: 16),
        if (unsupported) ...[
          Text(
            draft.issues.join('\n'),
            style: BambooFonts.ui(14, color: BambooInk.clay),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: () => setState(() => _draft = null),
            child: const Text('Try again'),
          ),
        ] else ...[
          DropdownButtonFormField<VoiceActionType>(
            initialValue: draft.type,
            decoration: const InputDecoration(
              labelText: 'What should be recorded',
            ),
            items: const [
              DropdownMenuItem(
                value: VoiceActionType.expense,
                child: Text('Spend'),
              ),
              DropdownMenuItem(
                value: VoiceActionType.pointsRedemption,
                child: Text('Points redeemed'),
              ),
            ],
            onChanged: null,
          ),
          const SizedBox(height: 12),
          if (draft.type == VoiceActionType.expense)
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Amount (₹)'),
            )
          else
            TextField(
              controller: _pointsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Points'),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _merchantController,
            decoration: const InputDecoration(
              labelText: 'Merchant or what it was for',
            ),
          ),
          const SizedBox(height: 12),
          if (draft.type == VoiceActionType.expense) ...[
            DropdownButtonFormField<String>(
              initialValue: _selectedCategoryId,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                for (final category in categories)
                  DropdownMenuItem(
                    value: category.id,
                    child: Text(category.name),
                  ),
              ],
              onChanged: (value) => setState(() => _selectedCategoryId = value),
            ),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<String>(
            initialValue: _selectedCardId,
            decoration: InputDecoration(
              labelText:
                  draft.type == VoiceActionType.pointsRedemption ||
                      draft.instrument == TxnInstrument.creditCard
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
            onChanged: (value) => setState(() => _selectedCardId = value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _noteController,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Note / original voice text',
            ),
          ),
          if (draft.issues.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              draft.issues.join('\n'),
              style: BambooFonts.ui(13, color: BambooInk.clay),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: BambooFonts.ui(13, color: BambooInk.clay)),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _draft = null),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Confirm & save'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _quote(String value) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(
      '“$value”',
      style: BambooFonts.ui(13.5, color: BambooInk.ink500),
    ),
  );
}

extension on Iterable<UserCard> {
  UserCard? get firstOrNull => isEmpty ? null : first;
}
