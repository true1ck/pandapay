import 'package:flutter/material.dart';

import '../../../app/design/app_theme.dart';
import 'voice_answer.dart';

/// A computed answer: the number first, then what it is compared with, how
/// it was worked out, any gap in the data, and buttons to the matching
/// screens. Everything on it came from the phone's own data.
class VoiceAnswerCard extends StatelessWidget {
  const VoiceAnswerCard({
    super.key,
    required this.answer,
    required this.onAction,
    required this.onAskAnother,
    this.spoken,
    this.onToggleSpeech,
  });

  final VoiceAnswer answer;
  final ValueChanged<AnswerAction> onAction;
  final VoidCallback onAskAnother;

  /// Whether the answer is being read aloud right now; null when it cannot be.
  final bool? spoken;
  final VoidCallback? onToggleSpeech;

  @override
  Widget build(BuildContext context) {
    final isMessage = answer.headline.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isMessage ? Icons.info_outline_rounded : Icons.insights_rounded,
              color: BambooInk.jade,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isMessage ? 'Panda' : answer.title,
                style: BambooFonts.heading(17, color: BambooInk.ink900),
              ),
            ),
            if (onToggleSpeech != null)
              IconButton(
                tooltip: spoken == true ? 'Stop' : 'Read aloud',
                visualDensity: VisualDensity.compact,
                onPressed: onToggleSpeech,
                icon: Icon(
                  spoken == true
                      ? Icons.stop_circle_outlined
                      : Icons.volume_up_rounded,
                  color: BambooInk.jade,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (isMessage)
          Text(
            answer.evidence,
            style: BambooFonts.ui(15, color: BambooInk.ink900),
          )
        else ...[
          Text(
            answer.headline,
            style: BambooFonts.heading(34, color: BambooInk.ink900),
          ),
          if (answer.comparison != null) ...[
            const SizedBox(height: 4),
            Text(
              answer.comparison!,
              style: BambooFonts.ui(14, color: BambooInk.ink500),
            ),
          ],
          if (answer.rows.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final r in answer.rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.label,
                            style: BambooFonts.ui(14, color: BambooInk.ink900),
                          ),
                          if (r.detail != null && r.detail!.isNotEmpty)
                            Text(
                              r.detail!,
                              style: BambooFonts.ui(12, color: BambooInk.ink500),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      r.value,
                      style: BambooFonts.heading(14, color: BambooInk.ink900),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 10),
          Text(
            answer.evidence,
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
          if (answer.coverageNote != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: BambooInk.clay.withValues(alpha: .4)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: BambooInk.clay,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      answer.coverageNote!,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink900),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
        if (answer.actions.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < answer.actions.length; i++)
                i == 0
                    ? FilledButton(
                        onPressed: () => onAction(answer.actions[i]),
                        child: Text(answer.actions[i].label),
                      )
                    : OutlinedButton(
                        onPressed: () => onAction(answer.actions[i]),
                        child: Text(answer.actions[i].label),
                      ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onAskAnother,
            icon: const Icon(Icons.mic_none_rounded, size: 18),
            label: const Text('Ask or add something else'),
          ),
        ),
      ],
    );
  }
}
