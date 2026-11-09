enum AnswerStatus { ok, noData, notReady, unsupported }

/// Where a button on an answer card leads. The sheet turns these into
/// routes; keeping them as data lets answers be built and tested without the
/// router.
enum AnswerActionKind {
  showTransactions,
  spendTrends,
  paymentsDue,
  caps,
  milestones,
  wallet,
  home,
  pointsExpiry,
}

class AnswerAction {
  const AnswerAction(
    this.kind,
    this.label, {
    this.from,
    this.to,
    this.categoryId,
    this.categoryLabel,
    this.query,
    this.spendOnly = true,
  });

  final AnswerActionKind kind;
  final String label;

  /// The same days the answer was about.
  final DateTime? from;
  final DateTime? to;
  final String? categoryId;
  final String? categoryLabel;

  /// A merchant or note search for Activity.
  final String? query;
  final bool spendOnly;
}

class AnswerRow {
  const AnswerRow(this.label, this.value, {this.detail});

  final String label;
  final String value;
  final String? detail;
}

/// A computed answer, ready to show and to read aloud. Every figure in it
/// came from the app's own data; the words around it are templates.
class VoiceAnswer {
  const VoiceAnswer({
    required this.title,
    required this.headline,
    required this.evidence,
    required this.spoken,
    this.comparison,
    this.rows = const [],
    this.coverageNote,
    this.actions = const [],
    this.status = AnswerStatus.ok,
  });

  /// "Dining · last month"
  final String title;

  /// "₹12,400"
  final String headline;

  /// "₹1,900 more than the month before"
  final String? comparison;
  final List<AnswerRow> rows;

  /// How the number was worked out and over which days.
  final String evidence;

  /// A gap in the data that could make the number misleading.
  final String? coverageNote;
  final List<AnswerAction> actions;

  /// One short sentence for text-to-speech.
  final String spoken;
  final AnswerStatus status;

  /// An answer that is a plain message with nothing to show.
  factory VoiceAnswer.message(
    String text, {
    AnswerStatus status = AnswerStatus.unsupported,
    List<AnswerAction> actions = const [],
  }) => VoiceAnswer(
    title: '',
    headline: '',
    evidence: text,
    spoken: text,
    status: status,
    actions: actions,
  );
}
