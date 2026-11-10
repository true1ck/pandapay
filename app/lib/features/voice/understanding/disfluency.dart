import 'language_pack.dart';
import 'tokens.dart';

/// Takes out the stumbles of speech before anything is read: fillers ("um",
/// "like") and words said twice ("2 days days ago", "paid paid me"). A filler
/// can sit in the middle of a number ("eight um hundred") or a phrase
/// ("google uh pay"), which would otherwise break it. Repeated number words
/// are left alone because "four four" can be real (card digits), but a
/// repeated "hundred" or "thousand" never is.
List<Token> cleanTokens(List<Token> tokens, LanguagePack pack) {
  final out = <Token>[];
  for (final t in tokens) {
    if (t.isWord && pack.fillers.contains(t.text)) continue;
    if (t.isWord && out.isNotEmpty) {
      final prev = out.last;
      final isUnit =
          pack.numberUnits.containsKey(t.text) ||
          pack.numberTens.containsKey(t.text);
      if (prev.isWord && prev.text == t.text && !isUnit) continue;
    }
    out.add(t);
  }
  return out;
}
