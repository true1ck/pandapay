/// Keeps finalized speech and the current recognizer's provisional speech
/// separate, so a recognizer session ending cannot discard visible words.
class VoiceTranscriptBuffer {
  String _finalized = '';
  String _provisional = '';
  String _sessionBase = '';

  String get finalized => _finalized;
  String get provisional => _provisional;

  String get text => [
    _finalized.trim(),
    _provisional.trim(),
  ].where((part) => part.isNotEmpty).join(' ');

  void clear() {
    _finalized = '';
    _provisional = '';
    _sessionBase = '';
  }

  /// Marks the transcript already committed before opening a new native
  /// recognition session. Results from that session may repeat this prefix.
  void beginSession() {
    _sessionBase = _finalized;
    _provisional = '';
  }

  void update(String words, {required bool isFinal}) {
    final normalized = words.trim();
    if (normalized.isEmpty) return;
    final sessionWords = _withoutSessionBase(normalized);
    if (sessionWords.isEmpty) {
      if (!isFinal) {
        _provisional = '';
      }
      return;
    }
    if (!isFinal) {
      _provisional = sessionWords;
      return;
    }

    _appendFinal(sessionWords);
    _provisional = '';
  }

  String _withoutSessionBase(String words) {
    if (_sessionBase.isEmpty) return words;
    final base = _sessionBase.trim();
    if (words.toLowerCase() == base.toLowerCase()) return '';
    if (words.toLowerCase().startsWith('${base.toLowerCase()} ')) {
      return words.substring(base.length).trim();
    }
    return words;
  }

  /// Commits the last visible partial when a platform ends a session without
  /// delivering a final result. Duplicate final/partial callbacks are folded.
  void commitProvisional() {
    if (_provisional.isEmpty) return;
    _appendFinal(_provisional);
    _provisional = '';
  }

  void _appendFinal(String words) {
    final current = _finalized.toLowerCase();
    final next = words.toLowerCase();
    if (_finalized.isEmpty) {
      _finalized = words;
    } else if (current == next || current.endsWith(next)) {
      return;
    } else if (next.startsWith(current)) {
      // Some recognizers revise the same utterance cumulatively ("spent 1"
      // then "spent 100"). Replace that prefix instead of duplicating it.
      _finalized = words;
    } else if (current.startsWith(next)) {
      // A recognizer may emit a shortened final revision of the previous
      // utterance. Keep the richer already committed transcript.
      return;
    } else {
      _finalized = '$_finalized $words';
    }
  }
}
