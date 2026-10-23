import 'package:flutter_test/flutter_test.dart';

import '../../../lib/features/voice/voice_transcript_buffer.dart';

void main() {
  test('keeps finalized speech when a later recognizer session starts', () {
    final buffer = VoiceTranscriptBuffer()
      ..update('I spent 500 rupees', isFinal: true)
      ..update('and paid 100', isFinal: false);

    expect(buffer.text, 'I spent 500 rupees and paid 100');
    expect(buffer.finalized, 'I spent 500 rupees');
    expect(buffer.provisional, 'and paid 100');
  });

  test(
    'commits visible interim speech when recognition ends without final',
    () {
      final buffer = VoiceTranscriptBuffer()
        ..update('I spent 500 rupees', isFinal: true)
        ..update('and paid 100', isFinal: false);

      buffer.commitProvisional();

      expect(buffer.text, 'I spent 500 rupees and paid 100');
      expect(buffer.provisional, '');
    },
  );

  test('replaces cumulative interim revisions instead of duplicating them', () {
    final buffer = VoiceTranscriptBuffer()
      ..update('spent one', isFinal: false)
      ..update('spent one hundred rupees', isFinal: false);

    expect(buffer.text, 'spent one hundred rupees');
    buffer.commitProvisional();
    expect(buffer.text, 'spent one hundred rupees');
  });

  test('deduplicates a repeated final callback', () {
    final buffer = VoiceTranscriptBuffer()
      ..update('I spent 500 rupees', isFinal: true)
      ..update('I spent 500 rupees', isFinal: true);

    expect(buffer.text, 'I spent 500 rupees');
  });

  test('appends a distinct phrase after an earlier final result', () {
    final buffer = VoiceTranscriptBuffer()
      ..update('I spent 500 rupees', isFinal: true)
      ..update('and paid 100', isFinal: true);

    expect(buffer.text, 'I spent 500 rupees and paid 100');
  });

  test('removes a previously finalized prefix repeated by a new session', () {
    final buffer = VoiceTranscriptBuffer()
      ..update('I spent 500 rupees', isFinal: true)
      ..beginSession()
      ..update('I spent 500 rupees and paid 100', isFinal: false);

    expect(buffer.text, 'I spent 500 rupees and paid 100');
    buffer.commitProvisional();
    expect(buffer.text, 'I spent 500 rupees and paid 100');
  });
}
