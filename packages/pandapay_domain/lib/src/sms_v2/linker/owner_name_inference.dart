/// Finding the account owner's name in their own messages.
///
/// Not everyone has typed their full name into the app, and the name on the
/// profile is often a username. But the services a person uses greet them by
/// name ("Dear Ishaan Dattatray Rangnekar, your order ..."), over and over,
/// from many unrelated senders. A name that shows up like that is the owner.
///
/// A greeting from one sender is weak evidence (an insurance site greets the
/// relatives it quotes for, an app greets a nickname), so a name is only
/// believed when it was seen several times AND from at least three different
/// senders. A relative who is greeted by one site never reaches that.
///
/// The greeting words, the honorifics and the stock words that are not names
/// come from the rulebook ([OwnerVocabulary]); nothing here knows a bank, a brand,
/// a language or a person.
library;

import 'owner_identity.dart';
import 'owner_vocabulary.dart';
import 'person_name.dart';

/// The person's name in a greeting, as upper-case words, or null.
///
/// Needs two to four words, each a plausible name part, none a stock word
/// ("Customer", "Sir").
String? greetingName(String body) {
  final vocabulary = OwnerVocabulary.current;
  final greeting = vocabulary.greetingPattern;
  if (greeting == null) return null;
  for (final m in greeting.allMatches(body)) {
    final words = personNameTokens(m.group(1));
    if (words.length < 2 || words.length > 4) continue;
    if (words.any(vocabulary.notNames.contains)) continue;
    if (words.first.length < 2) continue;
    return words.join(' ');
  }
  return null;
}

/// How often each greeting name was seen, and from how many different senders.
class OwnerNameSignals {
  OwnerNameSignals({Map<String, OwnerNameSignal>? seen}) : _seen = seen ?? {};

  final Map<String, OwnerNameSignal> _seen;

  /// Notes one greeting. [sender] is the sender's brand (so "AD-HDFCBK" and
  /// "VM-HDFCBK" are one sender).
  void add(String name, String sender) {
    final s = _seen.putIfAbsent(name, OwnerNameSignal.new);
    s.count++;
    if (sender.trim().isNotEmpty) s.senders.add(sender.trim().toUpperCase());
  }

  Map<String, OwnerNameSignal> get seen => Map.unmodifiable(_seen);

  /// The names believed to be the owner's, most seen first.
  ///
  /// A name needs [minCount] sightings from [minSenders] different senders (the
  /// rulebook's numbers unless given). Two forms of one person ("ISHAAN RANGNEKAR"
  /// and "ISHAAN DATTATRAY RANGNEKAR") are both kept; they match each other's
  /// prints anyway. At most [max] names.
  List<OwnerName> promoted({int? minCount, int? minSenders, int? max}) {
    final v = OwnerVocabulary.current;
    minCount ??= v.minSightings;
    minSenders ??= v.minSenders;
    max ??= v.maxLearned;
    final candidates = [
      for (final e in _seen.entries)
        if (e.value.count >= minCount && e.value.senders.length >= minSenders) e,
    ]..sort((a, b) => b.value.count.compareTo(a.value.count));
    final out = <OwnerName>[];
    for (final e in candidates) {
      final n = OwnerName.parse(e.key);
      if (n != null && !out.contains(n)) out.add(n);
      if (out.length == max) break;
    }
    return out;
  }

  Map<String, Object?> toJson() => {
    for (final e in _seen.entries) e.key: e.value.toJson(),
  };

  static OwnerNameSignals fromJson(Map<String, Object?> json) => OwnerNameSignals(
    seen: {
      for (final e in json.entries)
        e.key: OwnerNameSignal.fromJson((e.value as Map).cast<String, Object?>()),
    },
  );
}

class OwnerNameSignal {
  OwnerNameSignal({this.count = 0, Set<String>? senders}) : senders = senders ?? {};

  int count;
  final Set<String> senders;

  Map<String, Object?> toJson() => {'count': count, 'senders': senders.toList()..sort()};

  static OwnerNameSignal fromJson(Map<String, Object?> json) => OwnerNameSignal(
    count: (json['count'] as num?)?.toInt() ?? 0,
    senders: {for (final s in (json['senders'] as List? ?? const [])) s as String},
  );
}
