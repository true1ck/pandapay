import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:uuid/uuid.dart';

import '../../app/design/app_theme.dart';
import '../../app/category_picker.dart';
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
  final _editors = <_VoiceDraftEditor>[];
  List<VoiceActionDraft> _drafts = const [];
  String _transcript = '';
  String _interimTranscript = '';
  bool _available = false;
  bool _listening = false;
  bool _speechSessionCompleted = false;
  bool _keepListening = false;
  bool _speechInitialized = false;
  int _listenGeneration = 0;
  Timer? _completionTimer;
  Timer? _restartTimer;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _completionTimer?.cancel();
    _restartTimer?.cancel();
    _keepListening = false;
    unawaited(_stopSpeechSafely());
    for (final editor in _editors) {
      editor.dispose();
    }
    super.dispose();
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      _keepListening = false;
      await _stopSpeechSafely();
      // Android can deliver the final recognition result just after stop()
      // completes. Give that callback a brief window before interpreting the
      // transcript; otherwise a valid utterance can open an empty review.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _scheduleListeningCompletion();
      return;
    }
    setState(() {
      _error = null;
      _transcript = '';
      _interimTranscript = '';
      _drafts = const [];
    });
    for (final editor in _editors) {
      editor.dispose();
    }
    _editors.clear();
    _keepListening = true;
    _speechSessionCompleted = false;
    final generation = ++_listenGeneration;
    await _startSpeech(generation);
  }

  void _scheduleListeningCompletion() {
    if (!mounted || _speechSessionCompleted || _keepListening) return;
    _completionTimer?.cancel();
    _completionTimer = Timer(
      const Duration(milliseconds: 500),
      _completeListening,
    );
  }

  Future<void> _startSpeech(int generation) async {
    if (!mounted || !_keepListening || generation != _listenGeneration) return;
    try {
      if (!_speechInitialized) {
        _available = await _speech.initialize(
          // The app does not use Bluetooth audio. Disabling this optional
          // path prevents Android 12+ from requesting an undeclared Bluetooth
          // permission together with the first microphone prompt.
          options: [stt.SpeechToText.androidNoBluetooth],
          onStatus: (status) {
            if (status == stt.SpeechToText.doneStatus) {
              if (_keepListening) {
                _scheduleSpeechRestart(generation);
              } else {
                _scheduleListeningCompletion();
              }
            }
          },
          onError: (error) {
            if (!mounted || !_keepListening) return;
            _keepListening = false;
            setState(() {
              _listening = false;
              _error = error.errorMsg.trim().isEmpty
                  ? 'Speech recognition stopped. Try again.'
                  : error.errorMsg;
            });
          },
        );
        _speechInitialized = _available;
      }
      if (!_available) {
        _keepListening = false;
        if (mounted) {
          setState(
            () => _error = 'Microphone or speech recognition is unavailable.',
          );
        }
        return;
      }
      if (mounted) setState(() => _listening = true);
      await _speech.listen(
        onResult: (result) {
          if (!mounted || generation != _listenGeneration) return;
          final words = result.recognizedWords.trim();
          if (words.isEmpty) return;
          if (result.finalResult) {
            _appendFinalTranscript(words);
            if (_keepListening) {
              _scheduleSpeechRestart(generation);
            } else {
              _scheduleListeningCompletion();
            }
          } else {
            setState(() => _interimTranscript = words);
          }
        },
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          listenFor: const Duration(seconds: 45),
          pauseFor: const Duration(seconds: 4),
          listenMode: stt.ListenMode.dictation,
        ),
      );
    } catch (_) {
      if (mounted) {
        _keepListening = false;
        setState(() {
          _listening = false;
          _error =
              'Speech recognition could not start. Check microphone permission and try again.';
        });
      }
    }
  }

  void _appendFinalTranscript(String words) {
    _completionTimer?.cancel();
    _interimTranscript = '';
    if (_transcript.isEmpty) {
      _transcript = words;
    } else if (_transcript.toLowerCase() != words.toLowerCase() &&
        !_transcript.toLowerCase().endsWith(words.toLowerCase())) {
      _transcript = '$_transcript $words';
    }
    if (mounted) setState(() {});
  }

  void _scheduleSpeechRestart(int generation) {
    if (!mounted || !_keepListening || generation != _listenGeneration) return;
    _restartTimer?.cancel();
    _restartTimer = Timer(
      const Duration(milliseconds: 180),
      () => _startSpeech(generation),
    );
  }

  Future<void> _stopSpeechSafely() async {
    try {
      await _speech.stop();
    } catch (_) {
      // Permission/recognizer teardown errors must never crash the sheet.
    }
  }

  void _completeListening() {
    if (!mounted || _speechSessionCompleted || _keepListening) return;
    _completionTimer?.cancel();
    _completionTimer = null;
    _speechSessionCompleted = true;
    final transcript = _visibleTranscript.trim();
    setState(() {
      _listening = false;
      _interimTranscript = '';
      _transcript = transcript;
    });
    if (transcript.isEmpty) {
      setState(
        () => _error =
            'I could not hear anything. Check microphone permission and try again.',
      );
      return;
    }
    _makeDrafts();
  }

  void _makeDrafts() {
    final cards = ref.read(userCardsProvider).valueOrNull ?? const <UserCard>[];
    final categories =
        ref.read(categoriesProvider).valueOrNull ?? const <SpendCategory>[];
    final drafts = VoiceActionParser.parseMany(
      _transcript,
      cards: cards,
      categories: categories,
    );
    for (final editor in _editors) {
      editor.dispose();
    }
    _editors
      ..clear()
      ..addAll(drafts.map(_VoiceDraftEditor.new));
    setState(() {
      _drafts = drafts;
    });
  }

  String get _visibleTranscript => [
    _transcript.trim(),
    _interimTranscript.trim(),
  ].where((part) => part.isNotEmpty).join(' ');

  Future<void> _save() async {
    if (_drafts.isEmpty ||
        _drafts.any((draft) => draft.type == VoiceActionType.unsupported)) {
      return;
    }
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) {
      setState(() => _error = 'Sign in before saving a voice entry.');
      return;
    }
    final cards = ref.read(userCardsProvider).valueOrNull ?? const <UserCard>[];
    final values =
        <
          ({
            VoiceActionDraft draft,
            _VoiceDraftEditor editor,
            double? amount,
            int? points,
            UserCard? card,
          })
        >[];
    for (var index = 0; index < _drafts.length; index++) {
      final draft = _drafts[index];
      final editor = _editors[index];
      final amount = double.tryParse(
        editor.amountController.text.replaceAll(',', ''),
      );
      final points = int.tryParse(
        editor.pointsController.text.replaceAll(',', ''),
      );
      final card = editor.selectedCardId == null
          ? null
          : cards.where((item) => item.id == editor.selectedCardId).firstOrNull;
      if (draft.type == VoiceActionType.expense &&
          (amount == null || amount <= 0)) {
        setState(
          () => _error = 'Entry ${index + 1}: enter an amount greater than ₹0.',
        );
        return;
      }
      if (draft.type == VoiceActionType.pointsRedemption &&
          (points == null || points <= 0)) {
        setState(
          () => _error =
              'Entry ${index + 1}: enter the number of points to redeem.',
        );
        return;
      }
      if ((draft.type == VoiceActionType.pointsRedemption ||
              editor.instrument == TxnInstrument.creditCard) &&
          card == null) {
        setState(
          () => _error =
              'Entry ${index + 1}: choose the exact wallet card before confirming.',
        );
        return;
      }
      values.add((
        draft: draft,
        editor: editor,
        amount: amount,
        points: points,
        card: card,
      ));
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      for (final value in values) {
        final draft = value.draft;
        final editor = value.editor;
        if (draft.type == VoiceActionType.pointsRedemption) {
          final card = value.card!;
          final ledger = await repo.fetchPointsLedger(card.id);
          final current =
              (card.pointsBalance ?? 0) +
              ledger.fold<double>(0, (sum, row) => sum + row.deltaPoints);
          if (value.points! > current) {
            throw StateError(
              'This card has ${current.toStringAsFixed(0)} points available, so the entry was not saved.',
            );
          }
          await repo.adjustPointsBalance(
            card.id,
            newBalance: current - value.points!,
            reason:
                'Voice points redemption${editor.merchantController.text.trim().isEmpty ? '' : ': ${editor.merchantController.text.trim()}'}',
          );
        } else {
          await repo.logTransaction(
            userCardId: editor.instrument == TxnInstrument.creditCard
                ? editor.selectedCardId
                : null,
            amount: Money.fromRupees(value.amount!),
            categoryId: editor.selectedCategoryId,
            merchantName: editor.merchantController.text.trim().isEmpty
                ? null
                : editor.merchantController.text.trim(),
            note: editor.noteController.text.trim().isEmpty
                ? null
                : editor.noteController.text.trim(),
            occurredAt: DateTime.now(),
            instrument: editor.instrument,
            clientMutationId: const Uuid().v4(),
          );
        }
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
              _drafts.length == 1
                  ? (_drafts.single.type == VoiceActionType.pointsRedemption
                        ? 'Points entry saved.'
                        : 'Spend saved.')
                  : '${_drafts.length} entries saved.',
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
          child: _drafts.isEmpty
              ? _recordView()
              : _reviewView(cards, categories),
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
      if (_visibleTranscript.isNotEmpty) ...[
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _listening ? 'Live transcription' : 'Transcription',
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
        ),
        const SizedBox(height: 6),
        _quote(_visibleTranscript),
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

  Widget _reviewView(List<UserCard> cards, List<SpendCategory> categories) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.fact_check_rounded, color: BambooInk.jade),
            const SizedBox(width: 10),
            Text(
              _drafts.length == 1
                  ? 'Review voice entry'
                  : 'Review ${_drafts.length} voice entries',
              style: BambooFonts.heading(20, color: BambooInk.ink900),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _quote(_transcript),
        const SizedBox(height: 16),
        for (var index = 0; index < _drafts.length; index++) ...[
          _entryEditor(
            _drafts[index],
            _editors[index],
            cards,
            categories,
            index,
          ),
          if (index + 1 < _drafts.length) const Divider(height: 32),
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
                onPressed: _saving ? null : _resetToRecord,
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
    );
  }

  Widget _entryEditor(
    VoiceActionDraft draft,
    _VoiceDraftEditor editor,
    List<UserCard> cards,
    List<SpendCategory> categories,
    int index,
  ) {
    if (draft.type == VoiceActionType.unsupported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Entry ${index + 1} could not be interpreted',
            style: BambooFonts.heading(16, color: BambooInk.clay),
          ),
          const SizedBox(height: 6),
          _quote(draft.transcript),
          const SizedBox(height: 8),
          Text(
            draft.issues.join('\n'),
            style: BambooFonts.ui(14, color: BambooInk.clay),
          ),
        ],
      );
    }
    final requiresWalletCard =
        draft.type == VoiceActionType.pointsRedemption ||
        editor.instrument == TxnInstrument.creditCard;
    final hasWalletCard =
        editor.selectedCardId != null &&
        cards.any((card) => card.id == editor.selectedCardId);
    final visibleIssues = draft.issues.where((issue) {
      final isWalletCardIssue =
          issue ==
              'Choose the exact wallet card; more than one card matched.' ||
          issue == 'Choose the wallet card used for this entry.';
      if (!isWalletCardIssue) return true;
      return requiresWalletCard && !hasWalletCard;
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _drafts.length == 1 ? 'Spend details' : 'Entry ${index + 1}',
          style: BambooFonts.heading(16, color: BambooInk.ink900),
        ),
        const SizedBox(height: 10),
        if (draft.type == VoiceActionType.expense)
          TextField(
            controller: editor.amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount (₹)'),
          )
        else
          TextField(
            controller: editor.pointsController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Points'),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: editor.merchantController,
          decoration: const InputDecoration(
            labelText: 'Merchant or what it was for',
          ),
        ),
        const SizedBox(height: 12),
        if (draft.type == VoiceActionType.expense) ...[
          CategoryPickerField(
            categories: categories,
            selectedId: editor.selectedCategoryId,
            label: 'Category',
            onSelected: (value) =>
                setState(() => editor.selectedCategoryId = value),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<TxnInstrument>(
            initialValue: editor.instrument,
            decoration: const InputDecoration(labelText: 'Paid with'),
            items: [
              for (final instrument in TxnInstrument.values)
                DropdownMenuItem(
                  value: instrument,
                  child: Text(instrument.label),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => editor.instrument = value);
            },
          ),
          const SizedBox(height: 12),
        ],
        DropdownButtonFormField<String>(
          initialValue: editor.selectedCardId,
          decoration: InputDecoration(
            labelText:
                draft.type == VoiceActionType.pointsRedemption ||
                    editor.instrument == TxnInstrument.creditCard
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
          onChanged: (value) => setState(() => editor.selectedCardId = value),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: editor.noteController,
          minLines: 2,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Note / original voice text',
          ),
        ),
        if (visibleIssues.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            visibleIssues.join('\n'),
            style: BambooFonts.ui(13, color: BambooInk.clay),
          ),
        ],
      ],
    );
  }

  void _resetToRecord() {
    for (final editor in _editors) {
      editor.dispose();
    }
    _editors.clear();
    setState(() {
      _drafts = const [];
      _error = null;
    });
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

class _VoiceDraftEditor {
  _VoiceDraftEditor(VoiceActionDraft draft)
    : amountController = TextEditingController(
        text: draft.amount?.toStringAsFixed(2) ?? '',
      ),
      pointsController = TextEditingController(
        text: draft.points?.toString() ?? '',
      ),
      merchantController = TextEditingController(text: draft.merchant ?? ''),
      noteController = TextEditingController(text: draft.transcript),
      selectedCardId = draft.userCardId,
      selectedCategoryId = draft.categoryId,
      instrument = draft.instrument;

  final TextEditingController amountController;
  final TextEditingController pointsController;
  final TextEditingController merchantController;
  final TextEditingController noteController;
  String? selectedCardId;
  String? selectedCategoryId;
  TxnInstrument instrument;

  void dispose() {
    amountController.dispose();
    pointsController.dispose();
    merchantController.dispose();
    noteController.dispose();
  }
}

extension on Iterable<UserCard> {
  UserCard? get firstOrNull => isEmpty ? null : first;
}
