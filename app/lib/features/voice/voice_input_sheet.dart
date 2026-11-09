import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:uuid/uuid.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/transaction_tags_repository.dart' show TransactionTag;
import '../../data/user_cards_repository.dart'
    show TxnEntryKind, TxnInstrument, UserCard;
import '../sms_v2/ledger/providers.dart' show smsV2LedgerReadModelProvider;
import 'answers/question_model.dart';
import 'answers/voice_answer.dart';
import 'answers/voice_answer_card.dart';
import 'answers/voice_answer_service.dart';
import 'follow_up/follow_up.dart';
import 'follow_up/refund_candidates.dart';
import 'understanding/en_pack.dart';
import 'understanding/language_pack.dart';
import 'voice_action_parser.dart';
import 'voice_draft_editor.dart';
import 'voice_entry_review.dart';
import 'voice_settings.dart';
import 'voice_speaker.dart';
import 'voice_transcript_buffer.dart';

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
  final _transcriptBuffer = VoiceTranscriptBuffer();
  final _editors = <VoiceDraftEditor>[];
  final _typed = TextEditingController();
  final LanguagePack _pack = enPack;
  List<VoiceActionDraft> _drafts = const [];
  bool _available = false;
  bool _listening = false;
  bool _speechSessionCompleted = false;
  bool _keepListening = false;
  bool _speechInitialized = false;
  int _listenGeneration = 0;
  int _activeSession = 0;
  int _endedSession = 0;
  int _listenReturnedSession = 0;
  Timer? _completionTimer;
  Timer? _restartTimer;
  bool _saving = false;
  String? _error;

  /// On-device recognition could not start; the typed box is the way on.
  bool _onDeviceProblem = false;
  String? _localeId;
  List<String>? _merchantCache;
  bool _answerListening = false;
  VoiceAnswer? _answer;
  bool _thinking = false;

  /// The sentence was typed, not spoken. Typed questions are answered on
  /// screen only.
  bool _typedInput = false;
  bool? _speaking;
  final VoiceSpeaker _speaker = VoiceSpeaker();
  DateTime _now = DateTime.now();
  final Map<int, ({String key, List<RefundCandidate> list})> _refundCache = {};

  @override
  void initState() {
    super.initState();
    _speaker.setOnEnd(() {
      if (mounted && _speaking == true) setState(() => _speaking = false);
    });
  }

  @override
  void dispose() {
    _speaker.dispose();
    _completionTimer?.cancel();
    _restartTimer?.cancel();
    _keepListening = false;
    unawaited(_stopSpeechSafely());
    for (final editor in _editors) {
      editor.dispose();
    }
    _typed.dispose();
    super.dispose();
  }

  // ---- the user's own words, for recognition and understanding ---------------

  /// Merchants the user has actually paid, most used first. Read once per
  /// sheet from the on-phone ledger.
  List<String> _merchants() => _merchantCache ??= _computeMerchants();

  List<String> _computeMerchants() {
    final model = ref.read(smsV2LedgerReadModelProvider).valueOrNull;
    if (model == null) return const [];
    final counts = <String, int>{};
    final display = <String, String>{};
    for (final t in model.transactions) {
      final name = t.merchantName?.trim();
      if (name == null || name.isEmpty || name.length > 40) continue;
      final key = name.toLowerCase();
      counts[key] = (counts[key] ?? 0) + 1;
      display.putIfAbsent(key, () => name);
    }
    final keys = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return [for (final k in keys.take(150)) display[k]!];
  }

  /// Names the recognizer should expect: merchants, cards, tags, categories.
  List<String> _contextPhrases() {
    final cards = ref.read(userCardsProvider).valueOrNull ?? const <UserCard>[];
    final categories =
        ref.read(categoriesProvider).valueOrNull ?? const <SpendCategory>[];
    final tags =
        ref.read(transactionTagsProvider)?.tags ?? const <TransactionTag>[];
    final out = <String>{};
    void add(String? s) {
      final t = s?.trim();
      if (t != null && t.isNotEmpty && t.length <= 40) out.add(t);
    }

    _merchants().take(60).forEach(add);
    for (final c in cards) {
      add(c.nickname);
      add(c.cardName);
    }
    for (final c in categories) {
      add(c.name);
    }
    for (final t in tags) {
      add(t.name);
    }
    return out.take(100).toList();
  }

  Future<void> _resolveLocale() async {
    if (_localeId != null) return;
    try {
      String norm(String s) => s.replaceAll('-', '_').toLowerCase();
      final locales = await _speech.locales();
      final byNorm = {for (final l in locales) norm(l.localeId): l.localeId};
      for (final wanted in _pack.recognizerLocales) {
        final hit = byNorm[norm(wanted)];
        if (hit != null) {
          _localeId = hit;
          return;
        }
      }
      _localeId = (await _speech.systemLocale())?.localeId;
    } catch (_) {
      // The device default is used.
    }
  }

  String _onDeviceMessage() => Platform.isIOS
      ? 'On-device speech isn’t ready for English on this phone. In Settings → General → Keyboard, turn on Dictation, or type below. Panda never sends your voice to a server.'
      : 'On-device speech isn’t ready for English on this phone. In Settings, download the offline English speech pack for Google, or type below. Panda never sends your voice to a server.';

  /// Starts the recognizer once. Shared by dictation and spoken answers.
  Future<bool> _ensureSpeech() async {
    if (_speechInitialized) return _available;
    _available = await _speech.initialize(
      // The app does not use Bluetooth audio. Disabling this optional
      // path prevents Android 12+ from requesting an undeclared Bluetooth
      // permission together with the first microphone prompt.
      options: [stt.SpeechToText.androidNoBluetooth],
      onStatus: (status) {
        final ended =
            status == stt.SpeechToText.doneStatus ||
            status == stt.SpeechToText.notListeningStatus;
        if (_answerListening && ended) {
          if (mounted) setState(() => _answerListening = false);
          return;
        }
        if (status == stt.SpeechToText.doneStatus) {
          if (_keepListening) {
            _endedSession = _activeSession;
            if (_listenReturnedSession == _activeSession) {
              _scheduleSpeechRestart(_listenGeneration, _activeSession);
            }
          } else if (!_keepListening) {
            _scheduleListeningCompletion();
          }
        }
      },
      onError: (error) {
        if (_answerListening) {
          if (mounted) {
            setState(() {
              _answerListening = false;
              _error = 'I couldn’t hear an answer. Tap an option or type it.';
            });
          }
          return;
        }
        if (!mounted || !_keepListening) return;
        _keepListening = false;
        final msg = error.errorMsg.trim();
        const benign = {'error_no_match', 'error_speech_timeout'};
        final onDeviceIssue =
            _transcriptBuffer.text.trim().isEmpty && !benign.contains(msg);
        setState(() {
          _listening = false;
          _onDeviceProblem = onDeviceIssue;
          _error = onDeviceIssue
              ? _onDeviceMessage()
              : (msg.isEmpty ? 'Speech recognition stopped. Try again.' : msg);
        });
      },
    );
    _speechInitialized = _available;
    return _available;
  }

  // ---- dictation -------------------------------------------------------------

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
      _onDeviceProblem = false;
      _transcriptBuffer.clear();
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
      if (!await _ensureSpeech()) {
        _keepListening = false;
        if (mounted) {
          setState(() {
            _onDeviceProblem = true;
            _error = 'Microphone or speech recognition is unavailable.';
          });
        }
        return;
      }
      await _resolveLocale();
      final session = _transcriptBuffer.beginSession();
      _activeSession = session;
      _endedSession = 0;
      _listenReturnedSession = 0;
      var listenCallReturned = false;
      var restartRequested = false;
      if (mounted) setState(() => _listening = true);
      await _speech.listen(
        onResult: (result) {
          if (!mounted ||
              generation != _listenGeneration ||
              _speechSessionCompleted) {
            return;
          }
          final words = result.recognizedWords.trim();
          if (words.isEmpty) {
            if (!_keepListening) _scheduleListeningCompletion();
            return;
          }
          _completionTimer?.cancel();
          _transcriptBuffer.update(session, words, isFinal: result.finalResult);
          setState(() {});
          if (result.finalResult) {
            if (session == _activeSession && _keepListening) {
              restartRequested = true;
              if (listenCallReturned) {
                _scheduleSpeechRestart(generation, session);
              }
            } else if (!_keepListening) {
              _scheduleListeningCompletion();
            }
          } else if (!_keepListening) {
            _scheduleListeningCompletion();
          }
        },
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          listenFor: const Duration(seconds: 45),
          pauseFor: const Duration(seconds: 4),
          listenMode: stt.ListenMode.dictation,
          // Audio is recognized on this phone or not at all. Panda never
          // falls back to Apple's or Google's servers.
          onDevice: true,
          localeId: _localeId,
          contextualPhrases: _contextPhrases(),
        ),
      );
      listenCallReturned = true;
      _listenReturnedSession = session;
      if (generation != _listenGeneration) {
        // A newer native session superseded this start while listen() was
        // awaiting the platform channel.
        await _stopSpeechSafely();
        return;
      }
      if ((_endedSession == session || restartRequested) && _keepListening) {
        _scheduleSpeechRestart(generation, session);
      }
    } catch (_) {
      if (mounted) {
        _keepListening = false;
        setState(() {
          _listening = false;
          _onDeviceProblem = true;
          _error = _onDeviceMessage();
        });
      }
    }
  }

  void _scheduleSpeechRestart(int generation, int session) {
    if (!mounted ||
        !_keepListening ||
        generation != _listenGeneration ||
        session != _activeSession) {
      return;
    }
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 180), () {
      if (session != _activeSession ||
          generation != _listenGeneration ||
          !_keepListening) {
        return;
      }
      if (_speech.isListening) {
        _scheduleSpeechRestart(generation, session);
        return;
      }
      _transcriptBuffer.commitProvisional(session);
      if (mounted) setState(() {});
      _startSpeech(generation);
    });
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
    _typedInput = false;
    // Fence late platform callbacks before parsing so the displayed transcript
    // and the drafts being confirmed always represent the same speech.
    _listenGeneration++;
    _transcriptBuffer.commitProvisional();
    final transcript = _transcriptBuffer.text.trim();
    setState(() {
      _listening = false;
    });
    if (transcript.isEmpty) {
      setState(
        () => _error =
            'I could not hear anything. Check microphone permission and try again, or type it below.',
      );
      return;
    }
    _makeDrafts();
  }

  /// The typed box goes through exactly the same understanding.
  Future<void> _understandTyped(String text) async {
    final value = text.trim();
    if (value.isEmpty) return;
    _completionTimer?.cancel();
    _restartTimer?.cancel();
    _keepListening = false;
    if (_listening) await _stopSpeechSafely();
    if (!mounted) return;
    _listenGeneration++;
    _speechSessionCompleted = true;
    _typedInput = true;
    _transcriptBuffer.clear();
    final session = _transcriptBuffer.beginSession();
    _transcriptBuffer.update(session, value, isFinal: true);
    setState(() {
      _listening = false;
      _error = null;
    });
    _makeDrafts();
  }

  // ---- understanding ----------------------------------------------------------

  void _makeDrafts() {
    final cards = ref.read(userCardsProvider).valueOrNull ?? const <UserCard>[];
    final categories =
        ref.read(categoriesProvider).valueOrNull ?? const <SpendCategory>[];
    final tags =
        ref.read(transactionTagsProvider)?.tags ?? const <TransactionTag>[];
    final now = ref.read(clockProvider).now();
    final drafts = VoiceActionParser.parseMany(
      _transcriptBuffer.text,
      cards: cards,
      categories: categories,
      tags: tags,
      knownMerchants: _merchants(),
      now: now,
      pack: _pack,
    );
    if (drafts.length == 1 && drafts.single.type == VoiceActionType.question) {
      _handleQuestion(drafts.single);
      return;
    }
    for (final editor in _editors) {
      editor.dispose();
    }
    _refundCache.clear();
    _editors
      ..clear()
      ..addAll(drafts.map((d) => VoiceDraftEditor(d)..initKindAlternative()));
    setState(() {
      _drafts = drafts;
      _now = now;
    });
  }

  /// A question: read what it asks, work it out from the data on the phone,
  /// show the answer with buttons to the right screens, and say it aloud when
  /// it was asked by voice and the user has not turned speech off.
  Future<void> _handleQuestion(VoiceActionDraft draft) async {
    setState(() {
      _thinking = true;
      _error = null;
    });
    final cards = ref.read(userCardsProvider).valueOrNull ?? const <UserCard>[];
    final categories =
        ref.read(categoriesProvider).valueOrNull ?? const <SpendCategory>[];
    final now = ref.read(clockProvider).now();
    final question = QuestionReader(_pack).read(
      draft.transcript,
      now: now,
      cards: cards,
      categories: categories,
      knownMerchants: _merchants(),
    );
    final answer = await VoiceAnswerService(ref).answer(question);
    if (!mounted) return;
    setState(() {
      _answer = answer;
      _thinking = false;
      _now = now;
      _speaking = null;
    });
    if (!_typedInput &&
        answer.status == AnswerStatus.ok &&
        ref.read(voiceSpeakAnswersProvider)) {
      final ok = await _speaker.speak(answer.spoken);
      if (mounted) setState(() => _speaking = ok ? true : null);
    }
  }

  Future<void> _toggleSpeech() async {
    final answer = _answer;
    if (answer == null) return;
    if (_speaking == true) {
      await _speaker.stop();
      if (mounted) setState(() => _speaking = false);
      return;
    }
    final ok = await _speaker.speak(answer.spoken);
    if (!mounted) return;
    setState(() {
      _speaking = ok;
      if (!ok) {
        _error =
            'This phone has no English voice installed, so I can’t read it aloud.';
      }
    });
  }

  void _openAction(AnswerAction action) {
    final router = GoRouter.of(context);
    final route = routeFor(action);
    Navigator.of(context).pop();
    router.push(route);
  }

  String get _visibleTranscript => [
    _transcriptBuffer.text.trim(),
  ].where((part) => part.isNotEmpty).join(' ');

  // ---- follow-up questions ------------------------------------------------------

  List<FollowUpChoice> _refundChoices(int i) {
    final editor = _editors[i];
    if (editor.type != VoiceActionType.refund) return const [];
    final merchant = editor.merchantController.text.trim();
    final key = '$merchant|${editor.amount}';
    final cached = _refundCache[i];
    List<RefundCandidate> list;
    if (cached != null && cached.key == key) {
      list = cached.list;
    } else {
      final model = ref.read(smsV2LedgerReadModelProvider).valueOrNull;
      list = model == null
          ? const []
          : RefundCandidates.find(
              model.transactions,
              now: _now,
              merchant: merchant.isEmpty ? null : merchant,
              amount: editor.amount,
            );
      _refundCache[i] = (key: key, list: list);
    }
    return [for (final c in list) FollowUpChoice(c.transactionId, c.label(_now))];
  }

  FollowUp? _followUpFor(int i, List<UserCard> cards) {
    final editor = _editors[i];
    if (_drafts[i].type == VoiceActionType.unsupported) return null;
    return FollowUpPlanner.next(
      editor.followUpState(cards: cards, refundChoices: _refundChoices(i)),
    );
  }

  void _applyChoice(int i, FollowUp f, FollowUpChoice c) {
    final editor = _editors[i];
    switch (f.slot) {
      case FollowUpSlot.kind:
        final wasMoneyIn = editor.type == VoiceActionType.moneyIn;
        editor.type = VoiceActionType.values.byName(c.id);
        editor.kindAlternative = null;
        if (editor.type == VoiceActionType.moneyIn &&
            editor.instrument == TxnInstrument.creditCard) {
          editor.instrument = TxnInstrument.other;
        } else if (wasMoneyIn && editor.instrument == TxnInstrument.other) {
          editor.instrument = TxnInstrument.creditCard;
        }
      case FollowUpSlot.refundPurchase:
        if (c.id != 'none') {
          final cand = (_refundCache[i]?.list ?? const <RefundCandidate>[])
              .where((x) => x.transactionId == c.id)
              .firstOrNull;
          if (cand != null) {
            editor.refundOf = cand;
            if (editor.merchantController.text.trim().isEmpty) {
              editor.merchantController.text = cand.merchant ?? '';
            }
            editor.selectedCategoryId =
                cand.categoryId ?? editor.selectedCategoryId;
            editor.selectedCardId = cand.userCardId ?? editor.selectedCardId;
            editor.instrument = cand.instrument;
          }
        }
      case FollowUpSlot.moneyInType:
        editor.moneyInType = c.id;
        if (editor.merchantController.text.trim().isEmpty) {
          if (c.id == 'salary') editor.merchantController.text = 'Salary';
          if (c.id == 'interest') editor.merchantController.text = 'Interest';
        }
      case FollowUpSlot.moneyInHow:
        editor.instrument = switch (c.id) {
          'bank' => TxnInstrument.upiBank,
          'cash' => TxnInstrument.cash,
          _ => TxnInstrument.other,
        };
        editor.moneyInHowChosen = true;
      case FollowUpSlot.card:
        editor.selectedCardId = c.id;
      case FollowUpSlot.rupeeAmount:
      case FollowUpSlot.amount:
        break;
    }
    editor.asked.add(f.slot);
    setState(() {});
  }

  void _applyNumber(int i, FollowUp f, double value) {
    final editor = _editors[i];
    editor.amountController.text = value.toStringAsFixed(2);
    editor.asked.add(f.slot);
    setState(() {});
  }

  void _skipFollowUp(int i, FollowUp f) {
    _editors[i].asked.add(f.slot);
    setState(() {});
  }

  /// A short, one-shot listen for the answer to a follow-up question.
  Future<void> _listenForAnswer(int i, FollowUp f) async {
    if (_answerListening || _listening) return;
    setState(() {
      _answerListening = true;
      _error = null;
    });
    try {
      if (!await _ensureSpeech()) {
        if (mounted) {
          setState(() {
            _answerListening = false;
            _error = 'Speech isn’t available. Tap an option or type it.';
          });
        }
        return;
      }
      await _resolveLocale();
      await _speech.listen(
        onResult: (result) {
          if (!result.finalResult || !mounted) return;
          final text = result.recognizedWords.trim();
          setState(() => _answerListening = false);
          if (text.isEmpty || i >= _editors.length) return;
          if (f.numeric) {
            final v = FollowUpAnswers.number(text, pack: _pack);
            if (v != null) {
              _applyNumber(i, f, v);
            } else {
              setState(() => _error = 'I couldn’t hear an amount in “$text”.');
            }
          } else {
            final c = FollowUpAnswers.choice(text, f.choices, pack: _pack);
            if (c != null) {
              _applyChoice(i, f, c);
            } else {
              setState(() => _error = 'I didn’t catch which one. Tap an option.');
            }
          }
        },
        listenOptions: stt.SpeechListenOptions(
          partialResults: false,
          listenFor: const Duration(seconds: 8),
          pauseFor: const Duration(seconds: 3),
          listenMode: stt.ListenMode.confirmation,
          onDevice: true,
          localeId: _localeId,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _answerListening = false;
          _error = _onDeviceMessage();
        });
      }
    }
  }

  // ---- saving ---------------------------------------------------------------------

  Future<void> _save() async {
    final loggable = [
      for (var i = 0; i < _drafts.length; i++)
        if (_drafts[i].type != VoiceActionType.unsupported) i,
    ];
    if (loggable.isEmpty) return;
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) {
      setState(() => _error = 'Sign in before saving a voice entry.');
      return;
    }
    final cards = ref.read(userCardsProvider).valueOrNull ?? const <UserCard>[];
    for (final i in loggable) {
      final issues = _editors[i].currentIssues(cards);
      if (issues.isNotEmpty) {
        setState(() => _error = 'Entry ${i + 1}: ${issues.first}');
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final clock = ref.read(clockProvider).now();
      for (final i in loggable) {
        final editor = _editors[i];
        final draft = _drafts[i];
        final merchant = editor.merchantController.text.trim();
        if (editor.type == VoiceActionType.pointsRedemption) {
          final card = cards
              .where((item) => item.id == editor.selectedCardId)
              .firstOrNull!;
          final points = editor.points!;
          final ledger = await repo.fetchPointsLedger(card.id);
          final current =
              (card.pointsBalance ?? 0) +
              ledger.fold<double>(0, (sum, row) => sum + row.deltaPoints);
          if (points > current) {
            throw StateError(
              'This card has ${current.toStringAsFixed(0)} points available, so the entry was not saved.',
            );
          }
          await repo.adjustPointsBalance(
            card.id,
            newBalance: current - points,
            reason:
                'Voice points redemption${merchant.isEmpty ? '' : ': $merchant'}',
          );
          continue;
        }
        final isMoneyIn = editor.type == VoiceActionType.moneyIn;
        final kind = switch (editor.type) {
          VoiceActionType.moneyIn => TxnEntryKind.income,
          VoiceActionType.refund => TxnEntryKind.refund,
          _ => TxnEntryKind.spend,
        };
        final notes = <String>[
          if (editor.noteController.text.trim().isNotEmpty)
            editor.noteController.text.trim(),
          if (draft.isForeign)
            'Foreign amount: ${draft.foreignCurrency} ${_plain(draft.foreignAmount)}',
          if (editor.refundOf != null)
            'Refund for ${editor.refundOf!.label(clock)}',
        ];
        final transactionId = await repo.logTransaction(
          userCardId:
              !isMoneyIn && editor.instrument == TxnInstrument.creditCard
              ? editor.selectedCardId
              : null,
          amount: Money.fromRupees(editor.amount!),
          categoryId: isMoneyIn ? null : editor.selectedCategoryId,
          merchantName: merchant.isEmpty ? null : merchant,
          note: notes.isEmpty ? null : notes.join('\n'),
          occurredAt: editor.occurredAt ?? clock,
          instrument: editor.instrument,
          entryKind: kind,
          clientMutationId: const Uuid().v4(),
        );
        if (!isMoneyIn && editor.selectedTagIds.isNotEmpty) {
          // Tag links are local-first: they queue in the outbox even when
          // offline, so a failure here can never lose the saved spend.
          await ref.read(transactionTagsProvider)?.assign([
            transactionId,
          ], editor.selectedTagIds.toList());
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
              loggable.length == 1
                  ? switch (_editors[loggable.single].type) {
                      VoiceActionType.pointsRedemption => 'Points entry saved.',
                      VoiceActionType.moneyIn => 'Money in saved.',
                      VoiceActionType.refund => 'Refund saved.',
                      _ => 'Spend saved.',
                    }
                  : '${loggable.length} entries saved.',
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

  static String _plain(double? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
  }

  // ---- views ---------------------------------------------------------------------

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
          child: _answer != null
              ? _answerView()
              : _thinking
              ? _thinkingView()
              : _drafts.isEmpty
              ? _recordView()
              : _reviewView(cards, categories),
        ),
      ),
    );
  }

  Widget _thinkingView() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(strokeWidth: 2),
        const SizedBox(height: 16),
        Text(
          'Working it out on your phone…',
          style: BambooFonts.ui(13, color: BambooInk.ink500),
        ),
      ],
    ),
  );

  Widget _answerView() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _quote(_transcriptBuffer.text),
      const SizedBox(height: 16),
      VoiceAnswerCard(
        answer: _answer!,
        onAction: _openAction,
        onAskAnother: _resetToRecord,
        spoken: _answer!.status == AnswerStatus.ok ? (_speaking ?? false) : null,
        onToggleSpeech: _answer!.status == AnswerStatus.ok ? _toggleSpeech : null,
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: BambooFonts.ui(13, color: BambooInk.clay)),
      ],
    ],
  );

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
        'Say a spend, money in, a refund or a points redemption, or ask about your spending, bills, caps, points or best card. Nothing is saved until you confirm it.',
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
        )
      else
        Text(
          'Your voice is understood on this phone',
          style: BambooFonts.ui(12, color: BambooInk.ink500),
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
      const SizedBox(height: 16),
      TextField(
        controller: _typed,
        textInputAction: TextInputAction.send,
        onSubmitted: _understandTyped,
        decoration: InputDecoration(
          hintText: _onDeviceProblem
              ? 'Type it here, like “spent 250 on lunch”'
              : 'Or type it, like “spent 250 on lunch”',
          suffixIcon: IconButton(
            tooltip: 'Understand',
            icon: const Icon(Icons.arrow_upward_rounded),
            onPressed: () => _understandTyped(_typed.text),
          ),
        ),
      ),
      const SizedBox(height: 8),
    ],
  );

  Widget _reviewView(List<UserCard> cards, List<SpendCategory> categories) {
    final loggable = _drafts
        .where((d) => d.type != VoiceActionType.unsupported)
        .length;
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
        _quote(_transcriptBuffer.text),
        const SizedBox(height: 16),
        for (var index = 0; index < _drafts.length; index++) ...[
          _entryEditor(_drafts[index], _editors[index], cards, categories, index),
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
                child: Text(loggable == 0 ? 'Try again' : 'Cancel'),
              ),
            ),
            if (loggable > 0) ...[
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
                      : Text(
                          loggable == _drafts.length
                              ? 'Confirm & save'
                              : 'Save $loggable',
                        ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _entryEditor(
    VoiceActionDraft draft,
    VoiceDraftEditor editor,
    List<UserCard> cards,
    List<SpendCategory> categories,
    int index,
  ) {
    if (draft.type == VoiceActionType.unsupported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _drafts.length == 1
                ? 'Nothing was added'
                : 'Entry ${index + 1} was not added',
            style: BambooFonts.heading(16, color: BambooInk.clay),
          ),
          const SizedBox(height: 6),
          if (draft.transcript.isNotEmpty) _quote(draft.transcript),
          const SizedBox(height: 8),
          Text(
            draft.issues.join('\n'),
            style: BambooFonts.ui(14, color: BambooInk.clay),
          ),
        ],
      );
    }
    return VoiceEntryReview(
      draft: draft,
      editor: editor,
      cards: cards,
      categories: categories,
      index: index,
      total: _drafts.length,
      now: _now,
      onChanged: () => setState(() {}),
      followUp: _followUpFor(index, cards),
      onFollowUpChoice: (f, c) => _applyChoice(index, f, c),
      onFollowUpNumber: (f, v) => _applyNumber(index, f, v),
      onFollowUpSkip: (f) => _skipFollowUp(index, f),
      onFollowUpListen: (f) => _listenForAnswer(index, f),
      listeningForAnswer: _answerListening,
    );
  }

  void _resetToRecord() {
    for (final editor in _editors) {
      editor.dispose();
    }
    _editors.clear();
    _refundCache.clear();
    unawaited(_speaker.stop());
    setState(() {
      _drafts = const [];
      _answer = null;
      _speaking = null;
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

extension on Iterable<UserCard> {
  UserCard? get firstOrNull => isEmpty ? null : first;
}

extension on Iterable<RefundCandidate> {
  RefundCandidate? get firstOrNull => isEmpty ? null : first;
}
