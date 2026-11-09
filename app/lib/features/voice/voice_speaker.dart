import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_tts/flutter_tts.dart';

/// Reads a short answer aloud with the phone's own voice. It speaks only when
/// the phone can do it without a server: on Android it checks that an English
/// voice is installed (an uninstalled one makes Google fetch speech online),
/// and on iPhone the system voices are always on the device. When it cannot,
/// it stays silent and the answer card is all the user gets.
class VoiceSpeaker {
  VoiceSpeaker({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  bool _checked = false;
  bool _usable = false;

  Future<bool> _ready() async {
    if (_checked) return _usable;
    _checked = true;
    try {
      String? chosen;
      for (final lang in const ['en-IN', 'en-US', 'en-GB']) {
        final dynamic ok = Platform.isAndroid
            ? await _tts.isLanguageInstalled(lang)
            : await _tts.isLanguageAvailable(lang);
        if (ok == true) {
          chosen = lang;
          break;
        }
      }
      if (chosen == null) return _usable = false;
      await _tts.setLanguage(chosen);
      await _tts.setSpeechRate(0.5);
      await _tts.setPitch(1.0);
      return _usable = true;
    } catch (_) {
      return _usable = false;
    }
  }

  /// Calls [done] when speech finishes, is stopped, or fails.
  void setOnEnd(void Function() done) {
    _tts.setCompletionHandler(done);
    _tts.setCancelHandler(done);
    _tts.setErrorHandler((_) => done());
  }

  /// True when the text was handed to the on-device voice.
  Future<bool> speak(String text) async {
    if (text.trim().isEmpty || !await _ready()) return false;
    try {
      await _tts.stop();
      await _tts.speak(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing to stop.
    }
  }

  void dispose() => unawaited(stop());
}
