/// What one "Refresh rules and re-sort" pass did, in numbers the person can
/// read. Every step reports on its own: a step that fails says why in words and
/// never stops the ones after it.
///
/// The re-sort is shown before it is done: [resortWouldMove] spends would move
/// to a better category, and nothing on the phone changes until the person
/// taps Apply (the report that comes back has [applied] set).
class RulesRefreshReport {
  const RulesRefreshReport({
    required this.versionBefore,
    required this.versionAfter,
    required this.ruleCount,
    this.rulesProblem,
    this.sendProblem,
    this.rereadMessages = 0,
    this.stillUnrecognised = 0,
    this.rereadProblem,
    this.resorted = 0,
    this.resortWouldMove = 0,
    this.resortSkipped = 0,
    this.resortSkippedWhy = const {},
    this.keptYours = 0,
    this.waitingToSend = 0,
    this.refusedForGood = 0,
    this.refusedWhy = const {},
    this.resortProblem,
    this.applied = false,
    this.finishedAt,
  });

  /// The rule set the phone had when it started, and the one it has now.
  final int versionBefore, versionAfter;
  final int ruleCount;

  /// In words, null when the step worked.
  final String? rulesProblem, sendProblem, rereadProblem, resortProblem;

  /// Messages marked "unknown" that were read again, and how many are still unknown after.
  final int rereadMessages, stillUnrecognised;

  /// Spends whose category the rules changed (after Apply), spends that would
  /// change (before it), spends left as the person set them, and spends not
  /// looked at yet because they are still waiting to be sent.
  final int resorted, resortWouldMove, keptYours, waitingToSend;

  /// Spends the re-sort could not look at, and why (reason word -> how many).
  /// One of these never stops the others.
  final int resortSkipped;
  final Map<String, int> resortSkippedWhy;

  /// Records the server would not take; they stay as they are on this phone and
  /// are no longer sent. [refusedWhy] counts them by reason.
  final int refusedForGood;
  final Map<String, int> refusedWhy;

  /// True for the report of a tap on Apply, false for the preview.
  final bool applied;
  final DateTime? finishedAt;

  bool get gotNewRules => versionAfter != versionBefore;
  bool get hasProblem =>
      rulesProblem != null ||
      sendProblem != null ||
      rereadProblem != null ||
      resortProblem != null;

  /// There is a change to show and ask about.
  bool get canApply => !applied && resortProblem == null && resortWouldMove > 0;

  static const sendProblemText =
      'Some of your spends could not be sent to your account just now. They are kept on this phone and sent later.';

  /// One line for each thing that happened, plain words.
  List<String> get lines => [
    if (rulesProblem != null)
      rulesProblem!
    else if (applied)
      'Your rules are version $versionAfter, $ruleCount rules.'
    else if (gotNewRules)
      'Got new rules: version $versionAfter, $ruleCount rules.'
    else
      'Your rules are already the latest: version $versionAfter, $ruleCount rules.',
    ?sendProblem,
    if (rereadProblem != null)
      rereadProblem!
    else if (rereadMessages > 0)
      'Read $rereadMessages earlier ${rereadMessages == 1 ? 'message' : 'messages'} again'
          '${stillUnrecognised == 0 ? '.' : ', $stillUnrecognised still not recognised.'}',
    if (resortProblem != null)
      resortProblem!
    else if (applied)
      resorted == 0
          ? 'No spends needed a new category.'
          : 'Moved $resorted ${resorted == 1 ? 'spend' : 'spends'} to a better category.'
    else
      resortWouldMove == 0
          ? 'No spends need a new category.'
          : '$resortWouldMove ${resortWouldMove == 1 ? 'spend would' : 'spends would'} move to a better category. Nothing has changed yet.',
    if (resortSkipped > 0)
      '$resortSkipped ${resortSkipped == 1 ? 'spend' : 'spends'} could not be looked at (${_words(resortSkippedWhy, _skipWords)}). '
          '${resortSkipped == 1 ? 'It is' : 'They are'} unchanged.',
    if (keptYours > 0)
      '$keptYours you set yourself ${applied ? (keptYours == 1 ? 'was' : 'were') : (keptYours == 1 ? 'stays' : 'stay')} as you chose.',
    if (refusedForGood > 0)
      'The server would not take $refusedForGood ${refusedForGood == 1 ? 'record' : 'records'}'
          '${refusedWhy.isEmpty ? '' : ' (${_words(refusedWhy, _refusedWords)})'}. '
          '${refusedForGood == 1 ? 'It stays' : 'They stay'} as it is on this phone and is no longer sent.',
    if (waitingToSend > 0)
      '$waitingToSend ${waitingToSend == 1 ? 'spend is' : 'spends are'} still waiting to be sent to your account, so '
          '${waitingToSend == 1 ? 'it was' : 'they were'} skipped. Try again with a connection.',
  ];

  /// The words for a rules download that did not work.
  static String rulesProblemFor(String? stale) => switch (stale) {
    'entitlement_or_attestation' =>
      'The server did not give this phone the new rules (it could not confirm the app). Nothing else is wrong with your data.',
    'download_failed' =>
      'The server could not send the rules just now. Try again in a minute.',
    _ =>
      'Could not reach the PandaPay server for the rules. Check the connection and try again.',
  };

  /// The words for a re-sort that stopped, from the fixed reason word the
  /// check recorded (never from an error message, which could hold a value).
  static String resortProblemFor(String reason) => switch (reason) {
    'waiting_to_send' =>
      'Some spends are still waiting to be sent, so the re-sort stopped. Nothing was changed. Try again once they are sent.',
    'money_would_change' =>
      'The re-sort would have changed an amount, so it stopped. Nothing was changed, and your spends are as they were.',
    _ =>
      'Could not work out the new categories just now. Nothing was changed. (reason: $reason)',
  };

  static const _skipWords = {
    'waiting_to_send': 'still waiting to be sent',
    'money_would_change': 'the check found an amount would change',
    'inconsistent_data': 'their saved data did not agree',
    'unexpected_value': 'a saved value was unexpected',
    'error': 'an unexpected problem',
  };

  static const _refusedWords = {
    'event_leg_role_conflict': 'it already holds this spend read differently',
    'event_id_conflict': 'it already holds a different version',
    'ledger_id_conflict': 'it already holds a different version',
    'fact_id_conflict': 'it already holds a different version',
    'instrument_key_conflict': 'it already holds this account under another name',
    'event_status_locked': 'you had confirmed it on another device',
    'event_status_transition_invalid': 'it already holds a later state',
    'event_leg_fact_unknown': 'a message it depends on was not accepted',
    'ledger_event_unknown': 'the spend it belongs to was not accepted',
    'http_400': 'it found the record invalid',
    'http_413': 'it was too large',
    'http_422': 'it found the record invalid',
    'http_500': 'it could not store the record',
  };

  static String _words(Map<String, int> why, Map<String, String> table) {
    final entries = why.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final entry in entries.take(3))
        '${table[entry.key] ?? entry.key}: ${entry.value}',
    ].join('; ');
  }
}
