import '../../../data/cached_regexp.dart';
import '../understanding/en_pack.dart';
import '../understanding/language_pack.dart';
import '../understanding/number_grammar.dart';
import '../understanding/tokens.dart';
import '../voice_action_parser.dart';

/// What Panda may ask about one entry.
enum FollowUpSlot {
  kind,
  rupeeAmount,
  amount,
  refundPurchase,
  moneyInType,
  moneyInHow,
  card,
}

class FollowUpChoice {
  const FollowUpChoice(this.id, this.label);

  /// Stable id, e.g. `salary`, `none`, or a transaction or card id.
  final String id;
  final String label;
}

class FollowUp {
  const FollowUp({
    required this.slot,
    required this.question,
    this.choices = const [],
    this.numeric = false,
    this.hint,
  });

  final FollowUpSlot slot;
  final String question;
  final List<FollowUpChoice> choices;

  /// The answer is a number typed or spoken.
  final bool numeric;
  final String? hint;
}

/// What the planner needs to know about an entry as it stands now, after any
/// earlier answers and edits.
class FollowUpState {
  const FollowUpState({
    required this.type,
    this.amount,
    this.foreignCurrency,
    this.foreignAmount,
    this.cardNeeded = false,
    this.hasCard = false,
    this.kindAlternative,
    this.refundCandidates = const [],
    this.moneyInTypeChosen = false,
    this.moneyInHowChosen = false,
    this.cards = const [],
    this.asked = const {},
  });

  final VoiceActionType type;
  final double? amount;
  final String? foreignCurrency;
  final double? foreignAmount;
  final bool cardNeeded;
  final bool hasCard;

  /// The other reading of an unclear kind, if any.
  final VoiceActionType? kindAlternative;

  /// Choices for "which purchase": id, label.
  final List<FollowUpChoice> refundCandidates;
  final bool moneyInTypeChosen;
  final bool moneyInHowChosen;
  final List<FollowUpChoice> cards;
  final Set<FollowUpSlot> asked;
}

/// Decides the next question for an entry. At most [maxPerEntry] are asked;
/// after that the editable form is the place to finish.
class FollowUpPlanner {
  const FollowUpPlanner._();

  static const maxPerEntry = 2;

  static String kindLabel(VoiceActionType t) => switch (t) {
    VoiceActionType.moneyIn => 'Money in',
    VoiceActionType.refund => 'Refund',
    _ => 'A spend',
  };

  static FollowUp? next(FollowUpState s) {
    if (s.asked.length >= maxPerEntry) return null;
    bool todo(FollowUpSlot slot) => !s.asked.contains(slot);

    if (s.kindAlternative != null && todo(FollowUpSlot.kind)) {
      return FollowUp(
        slot: FollowUpSlot.kind,
        question: s.type == VoiceActionType.moneyIn ||
                s.kindAlternative == VoiceActionType.moneyIn
            ? 'Is this money you received, or a refund?'
            : 'What kind of entry is this?',
        choices: [
          FollowUpChoice(s.type.name, kindLabel(s.type)),
          FollowUpChoice(s.kindAlternative!.name, kindLabel(s.kindAlternative!)),
        ],
      );
    }
    if (s.foreignCurrency != null &&
        s.amount == null &&
        todo(FollowUpSlot.rupeeAmount)) {
      final spoken =
          '${s.foreignCurrency} ${_plain(s.foreignAmount)}'.trim();
      return FollowUp(
        slot: FollowUpSlot.rupeeAmount,
        question: 'How much was that in rupees?',
        numeric: true,
        hint:
            'You said $spoken. Enter what your bank charged. It is saved as a rupee entry with $spoken in the note.',
      );
    }
    if (s.foreignCurrency == null &&
        s.amount == null &&
        todo(FollowUpSlot.amount)) {
      return const FollowUp(
        slot: FollowUpSlot.amount,
        question: 'How much was it?',
        numeric: true,
      );
    }
    if (s.type == VoiceActionType.refund &&
        s.refundCandidates.isNotEmpty &&
        todo(FollowUpSlot.refundPurchase)) {
      return FollowUp(
        slot: FollowUpSlot.refundPurchase,
        question: 'Which purchase was this refund for?',
        choices: [
          ...s.refundCandidates,
          const FollowUpChoice('none', 'None of these'),
        ],
      );
    }
    if (s.type == VoiceActionType.moneyIn &&
        !s.moneyInTypeChosen &&
        todo(FollowUpSlot.moneyInType)) {
      return const FollowUp(
        slot: FollowUpSlot.moneyInType,
        question: 'What was it?',
        choices: [
          FollowUpChoice('salary', 'Salary'),
          FollowUpChoice('person', 'From a person'),
          FollowUpChoice('interest', 'Interest'),
          FollowUpChoice('other', 'Something else'),
        ],
      );
    }
    if (s.type == VoiceActionType.moneyIn &&
        !s.moneyInHowChosen &&
        todo(FollowUpSlot.moneyInHow)) {
      return const FollowUp(
        slot: FollowUpSlot.moneyInHow,
        question: 'How did it reach you?',
        choices: [
          FollowUpChoice('bank', 'Bank or UPI'),
          FollowUpChoice('cash', 'Cash'),
          FollowUpChoice('other', 'Other'),
        ],
      );
    }
    if (s.cardNeeded && !s.hasCard && todo(FollowUpSlot.card)) {
      if (s.cards.isEmpty) return null;
      return FollowUp(
        slot: FollowUpSlot.card,
        question: 'Which card?',
        choices: s.cards.take(6).toList(),
      );
    }
    return null;
  }

  static String _plain(double? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
  }
}

/// Reads a spoken or typed answer to a follow-up question.
class FollowUpAnswers {
  const FollowUpAnswers._();

  /// The first number in [text]: "about 4,200 rupees", "forty two hundred".
  static double? number(String text, {LanguagePack pack = enPack}) {
    final tokens = tokenize(text);
    final spans = findNumbers(tokens, pack);
    for (final s in spans) {
      if (s.value > 0) return s.value;
    }
    return null;
  }

  /// The choice that [text] points at: its words, "the second one", "none".
  /// Returns null when nothing matches or two choices match equally well.
  static FollowUpChoice? choice(
    String text,
    List<FollowUpChoice> choices, {
    LanguagePack pack = enPack,
  }) {
    final words = _words(text);
    if (words.isEmpty || choices.isEmpty) return null;
    const none = {'none', 'neither', 'skip', 'nothing', 'no'};
    if (words.length <= 4 && words.any(none.contains)) {
      for (final c in choices) {
        if (c.id == 'none') return c;
      }
    }
    const ordinals = {
      'first': 0,
      '1st': 0,
      'second': 1,
      '2nd': 1,
      'third': 2,
      '3rd': 2,
      'fourth': 3,
      '4th': 3,
      'fifth': 4,
      '5th': 4,
      'last': -1,
    };
    for (final w in words) {
      final i = ordinals[w];
      if (i == null) continue;
      final index = i == -1 ? choices.length - 1 : i;
      if (index >= 0 && index < choices.length) return choices[index];
    }
    FollowUpChoice? best;
    var bestScore = 0;
    var tie = false;
    for (final c in choices) {
      final label = _words(c.label).where((w) => w.length > 2).toSet();
      final score = label.where(words.contains).length;
      if (score > bestScore) {
        best = c;
        bestScore = score;
        tie = false;
      } else if (score == bestScore && score > 0) {
        tie = true;
      }
    }
    return tie ? null : best;
  }

  static List<String> _words(String text) => text
      .toLowerCase()
      .split(cachedRegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toList();
}
