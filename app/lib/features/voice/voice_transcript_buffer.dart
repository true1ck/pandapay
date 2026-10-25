/// Accumulates recognition results by native session. Android may deliver a
/// session's final result after the next session has already started; keeping
/// each session's text separate lets that final result replace its interim
/// text without dropping later speech.
class VoiceTranscriptBuffer {
  final Map<int, _VoiceTranscriptSession> _sessions =
      <int, _VoiceTranscriptSession>{};
  int _nextSessionId = 0;

  String get text => _sessions.values
      .map((session) => session.text.trim())
      .where((part) => part.isNotEmpty)
      .join(' ');

  String get finalized => _sessions.values
      .map((session) => session.finalized.trim())
      .where((part) => part.isNotEmpty)
      .join(' ');

  String get provisional => _sessions.values
      .map((session) => session.provisional.trim())
      .where((part) => part.isNotEmpty)
      .join(' ');

  void clear() {
    _sessions.clear();
    _nextSessionId = 0;
  }

  /// Starts a recognition session and returns the ID its callbacks must use.
  int beginSession() {
    final id = ++_nextSessionId;
    _sessions[id] = _VoiceTranscriptSession(baseText: text);
    return id;
  }

  void update(int sessionId, String words, {required bool isFinal}) {
    final session = _sessions[sessionId];
    if (session == null) return;
    final normalized = _withoutSessionBase(words.trim(), session.knownBases);
    if (normalized.isEmpty) {
      if (isFinal) {
        session.finalized = '';
        session.provisional = '';
      } else if (session.finalized.isEmpty) {
        session.provisional = '';
      }
      _refreshLaterBaselines();
      return;
    }
    if (isFinal) {
      // Final results may improve or correct the interim phrase for this
      // specific session, even if a later recognition session has started.
      session.finalized = normalized;
      session.provisional = '';
    } else if (session.finalized.isEmpty) {
      // Interim results are revisions of the current utterance, not chunks.
      session.provisional = normalized;
    }
    _refreshLaterBaselines();
  }

  /// Commits visible interim words at a session boundary. A later final result
  /// from this session can still replace them through [update].
  void commitProvisional([int? sessionId]) {
    if (sessionId != null) {
      _sessions[sessionId]?.commitProvisional();
      _refreshLaterBaselines();
      return;
    }
    for (final session in _sessions.values) {
      session.commitProvisional();
    }
    _refreshLaterBaselines();
  }

  void _refreshLaterBaselines() {
    var prefix = '';
    for (final session in _sessions.values) {
      session.baseText = prefix;
      session.knownBases.add(prefix);
      final value = session.text.trim();
      if (value.isNotEmpty) prefix = prefix.isEmpty ? value : '$prefix $value';
    }
  }

  String _withoutSessionBase(String words, Set<String> knownBases) {
    final lowerWords = words.toLowerCase();
    final bases = knownBases.where((base) => base.isNotEmpty).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final base in bases) {
      final lowerBase = base.toLowerCase();
      if (lowerWords == lowerBase) return '';
      if (lowerWords.startsWith('$lowerBase ')) {
        return words.substring(base.length).trim();
      }
    }
    return words;
  }
}

class _VoiceTranscriptSession {
  String baseText;
  final Set<String> knownBases;
  String finalized = '';
  String provisional = '';

  _VoiceTranscriptSession({required this.baseText}) : knownBases = {baseText};

  String get text => finalized.isNotEmpty ? finalized : provisional;

  void commitProvisional() {
    if (provisional.isEmpty) return;
    finalized = provisional;
    provisional = '';
  }
}
