import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';

const _speakAnswersKey = 'voice_speak_answers_v1';

/// Whether Panda also says an answer out loud when a question was asked by
/// voice. A device preference, on by default; it is never synced because it
/// is about this phone's speaker, not the account.
class VoiceSpeakController extends StateNotifier<bool> {
  VoiceSpeakController() : super(true) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) state = prefs.getBool(_speakAnswersKey) ?? true;
    } catch (_) {
      // The default stays.
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_speakAnswersKey, value);
    } catch (_) {
      // The choice still applies for this session.
    }
  }
}

final voiceSpeakAnswersProvider =
    StateNotifierProvider<VoiceSpeakController, bool>(
      (ref) => VoiceSpeakController(),
    );

class VoiceSettingsScreen extends ConsumerWidget {
  const VoiceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speak = ref.watch(voiceSpeakAnswersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Voice')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Speak answers',
              style: BambooFonts.heading(16, color: BambooInk.ink900),
            ),
            subtitle: Text(
              'When you ask Panda a question by voice, it also says a short answer. Questions you type are answered on screen only.',
              style: BambooFonts.ui(13, color: BambooInk.ink500),
            ),
            value: speak,
            onChanged: (v) =>
                ref.read(voiceSpeakAnswersProvider.notifier).set(v),
          ),
          const SizedBox(height: 16),
          Text(
            'Your voice stays on this phone',
            style: BambooFonts.heading(15, color: BambooInk.ink900),
          ),
          const SizedBox(height: 6),
          Text(
            'Speech is recognized on the phone, questions are answered from the data on the phone, and spoken answers use the phone’s own voice. Nothing you say is sent to a server. If the phone doesn’t have an English speech pack installed, Panda stays silent and shows the answer instead.',
            style: BambooFonts.ui(13, color: BambooInk.ink500),
          ),
        ],
      ),
    );
  }
}
