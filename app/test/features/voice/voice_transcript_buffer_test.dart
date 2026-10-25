import 'package:flutter_test/flutter_test.dart';

import '../../../lib/features/voice/voice_transcript_buffer.dart';

void main() {
  test('keeps finalized speech when a later recognizer session starts', () {
    final buffer = VoiceTranscriptBuffer();
    final first = buffer.beginSession();
    buffer.update(first, 'I spent 500 rupees', isFinal: true);
    final second = buffer.beginSession();
    buffer.update(second, 'and paid 100', isFinal: false);

    expect(buffer.text, 'I spent 500 rupees and paid 100');
    expect(buffer.finalized, 'I spent 500 rupees');
    expect(buffer.provisional, 'and paid 100');
  });

  test(
    'commits visible interim speech when recognition ends without final',
    () {
      final buffer = VoiceTranscriptBuffer();
      final session = buffer.beginSession();
      buffer.update(session, 'I spent 500 rupees', isFinal: false);

      buffer.commitProvisional(session);

      expect(buffer.text, 'I spent 500 rupees');
      expect(buffer.provisional, '');
    },
  );

  test('late final result revises its session after a restart', () {
    final buffer = VoiceTranscriptBuffer();
    final first = buffer.beginSession();
    buffer.update(first, 'I spent 500 rupees', isFinal: true);
    final paused = buffer.beginSession();
    buffer.update(paused, 'and paid one', isFinal: false);
    buffer.commitProvisional(paused);
    buffer.beginSession();

    buffer.update(paused, 'and paid 100', isFinal: true);

    expect(buffer.text, 'I spent 500 rupees and paid 100');
  });

  test('replaces cumulative interim revisions instead of duplicating them', () {
    final buffer = VoiceTranscriptBuffer();
    final session = buffer.beginSession();
    buffer.update(session, 'spent one', isFinal: false);
    buffer.update(session, 'spent one hundred rupees', isFinal: false);

    expect(buffer.text, 'spent one hundred rupees');
    buffer.commitProvisional(session);
    expect(buffer.text, 'spent one hundred rupees');
  });

  test('deduplicates a repeated final callback', () {
    final buffer = VoiceTranscriptBuffer();
    final session = buffer.beginSession();
    buffer.update(session, 'I spent 500 rupees', isFinal: true);
    buffer.update(session, 'I spent 500 rupees', isFinal: true);

    expect(buffer.text, 'I spent 500 rupees');
  });

  test('appends a distinct phrase after an earlier final result', () {
    final buffer = VoiceTranscriptBuffer();
    final first = buffer.beginSession();
    buffer.update(first, 'I spent 500 rupees', isFinal: true);
    final second = buffer.beginSession();
    buffer.update(second, 'and paid 100', isFinal: true);

    expect(buffer.text, 'I spent 500 rupees and paid 100');
  });

  test('removes an earlier finalized prefix repeated in a new session', () {
    final buffer = VoiceTranscriptBuffer();
    final first = buffer.beginSession();
    buffer.update(first, 'I spent 500 rupees', isFinal: true);
    final second = buffer.beginSession();
    buffer.update(second, 'I spent 500 rupees and paid 100', isFinal: false);

    expect(buffer.text, 'I spent 500 rupees and paid 100');
    buffer.commitProvisional(second);
    expect(buffer.text, 'I spent 500 rupees and paid 100');
  });

  test('revising an earlier session refreshes later cumulative baselines', () {
    final buffer = VoiceTranscriptBuffer();
    final first = buffer.beginSession();
    buffer.update(first, 'paid of 100', isFinal: false);
    buffer.commitProvisional(first);
    final second = buffer.beginSession();

    buffer.update(first, 'paid 100', isFinal: true);
    buffer.update(second, 'paid 100 and coffee', isFinal: false);

    expect(buffer.text, 'paid 100 and coffee');
  });

  test(
    'a final containing only the previous transcript clears interim words',
    () {
      final buffer = VoiceTranscriptBuffer();
      final first = buffer.beginSession();
      buffer.update(first, 'paid 100', isFinal: true);
      final second = buffer.beginSession();
      buffer.update(second, 'paid 100 and coffee', isFinal: false);

      buffer.update(second, 'paid 100', isFinal: true);

      expect(buffer.text, 'paid 100');
      expect(buffer.provisional, '');
    },
  );

  test('a late correction still accepts a later old-prefix revision', () {
    final buffer = VoiceTranscriptBuffer();
    final first = buffer.beginSession();
    buffer.update(first, 'paid of 100', isFinal: false);
    buffer.commitProvisional(first);
    final second = buffer.beginSession();
    buffer.update(second, 'paid of 100 and coffee', isFinal: false);

    buffer.update(first, 'paid 100', isFinal: true);
    buffer.update(second, 'paid of 100 and coffee today', isFinal: true);

    expect(buffer.text, 'paid 100 and coffee today');
  });
}
