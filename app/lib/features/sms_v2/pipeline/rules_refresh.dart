/// What one "Refresh rules and re-sort" pass did, in numbers the person can
/// read. Every step reports on its own: a step that fails says why in words and
/// never stops the ones after it.
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
    this.keptYours = 0,
    this.waitingToSend = 0,
    this.resortProblem,
    this.finishedAt,
  });

  /// The rule set the phone had when it started, and the one it has now.
  final int versionBefore, versionAfter;
  final int ruleCount;

  /// In words, null when the step worked.
  final String? rulesProblem, sendProblem, rereadProblem, resortProblem;

  /// Messages marked "unknown" that were read again, and how many are still unknown after.
  final int rereadMessages, stillUnrecognised;

  /// Spends whose category the rules changed, spends left as the person set
  /// them, and spends not looked at yet because they are still waiting to be sent.
  final int resorted, keptYours, waitingToSend;
  final DateTime? finishedAt;

  bool get gotNewRules => versionAfter != versionBefore;
  bool get hasProblem =>
      rulesProblem != null ||
      sendProblem != null ||
      rereadProblem != null ||
      resortProblem != null;

  /// One line for each thing that happened, plain words.
  List<String> get lines => [
    if (rulesProblem != null)
      rulesProblem!
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
    else
      resorted == 0
          ? 'No spends needed a new category.'
          : 'Moved $resorted ${resorted == 1 ? 'spend' : 'spends'} to a better category.',
    if (keptYours > 0)
      '$keptYours you set yourself ${keptYours == 1 ? 'was' : 'were'} left as you chose.',
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
}
