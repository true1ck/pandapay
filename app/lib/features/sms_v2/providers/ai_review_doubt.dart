import 'package:pandapay_domain/sms_v2.dart';

import '../pipeline/ai_doubt.dart';
import 'data_providers.dart';

/// Of the open Needs review questions that already carry an AI reading, which
/// the AI was sure about and which the person has to look at.
class AiOpenReadings {
  const AiOpenReadings({this.confident = const {}, this.doubtful = const {}});

  /// Messages read with confidence: not a question, they are AI auto-resolved.
  final Set<String> confident;

  /// Messages the person has to look at, and why. They stay on Needs review with
  /// the "AI suggested" badge.
  final Map<String, AiDoubt> doubtful;
}

/// One definition shared by the Needs review screen and the outside count, so
/// the badge can never disagree with the list. Pure: in-memory facts, the
/// message text the item already holds, no SQLite.
///
/// A question qualifies when it is a template question that has a reading
/// ([LocalReviewItem.payload] `hasReading`) and an AI rule made that reading
/// ([aiRead]). Questions raised by the old rule (every unverified AI reading
/// became one) are judged here the same way, so they leave Needs review
/// without anyone rewriting a row; the pipeline closes them for real the next
/// time the message is read.
AiOpenReadings classifyOpenAiReadings({
  required Iterable<LocalReviewItem> items,
  required Set<String> aiRead,
  required Map<String, List<Fact>> factsBySource,
}) {
  final confident = <String>{};
  final doubtful = <String, AiDoubt>{};
  for (final item in items) {
    final source = item.payload['sourceKey'];
    if (item.kind != 'template' ||
        item.payload['hasReading'] != true ||
        source is! String ||
        !aiRead.contains(source)) {
      continue;
    }
    // The person put it back themselves: it stays, whatever the AI's confidence.
    if (item.payload['reason'] == 'reopened') {
      doubtful[source] = AiDoubt.reopened;
      confident.remove(source);
      continue;
    }
    if (doubtful.containsKey(source)) continue;
    final facts = factsBySource[source] ?? const <Fact>[];
    final machine = [
      for (final fact in facts)
        if (fact.provenance.engine != Engine.user) fact,
    ];
    // Facts we cannot see are not judged: the question stays where it is.
    if (machine.isEmpty) continue;
    final ai = [
      for (final fact in machine)
        if (fact.provenance.ruleId.startsWith('AI-')) fact,
    ];
    final doubt = aiDoubtOf(
      ai.isNotEmpty ? ai : machine,
      body: item.message?.message.body,
    );
    if (doubt == null) {
      confident.add(source);
    } else {
      doubtful[source] = doubt;
      confident.remove(source);
    }
  }
  return AiOpenReadings(confident: confident, doubtful: doubtful);
}
