import 'date_grammar.dart';
import 'disfluency.dart';
import 'en_pack.dart';
import 'language_pack.dart';
import 'number_grammar.dart';
import 'tokens.dart';
import 'understanding.dart';

/// Turns one spoken or typed sentence into what it means, without asking
/// "which sentence pattern is this?". Every number and date is found by its
/// own small grammar, every number is given a role by how much evidence
/// supports it, and the sentence is cut into entries where the evidence says
/// a new one starts. Nothing that was heard is dropped silently: numbers
/// that are not used are reported as leftovers.
class UtteranceReader {
  const UtteranceReader([this.pack = enPack]);

  final LanguagePack pack;

  Understanding read(String text, DateTime now) =>
      _Run(pack, text.trim(), now).execute();
}

enum _Role { amount, quantity, points, percent, time, cardDigit, identifier }

class _Num {
  _Num(this.span);

  final NumberSpan span;
  _Role role = _Role.amount;
  double score = 0;
  String? foreignCode;

  /// Tokens of an attached currency word or symbol, [curStart, curEnd).
  int curStart = -1;
  int curEnd = -1;
  int get start => span.startToken;
  int get end => span.endToken;
}

class _Anchor {
  _Anchor(this.num, {required this.isPoints});

  final _Num num;
  final bool isPoints;
}

class _Group {
  _Group(this.anchor) : firstStart = anchor.num.start, lastEnd = anchor.num.end;

  _Anchor anchor;
  int firstStart;
  int lastEnd;
  double? correctedFrom;
  String? correctedFromSource;

  /// Tokens of replaced amounts and the correction words, to leave out of the
  /// clean text.
  final List<(int, int)> dropped = [];
}

class _Run {
  _Run(this.p, this.source, this.now)
    : tokens = cleanTokens(tokenize(source), p);

  final LanguagePack p;
  final String source;
  final DateTime now;
  final List<Token> tokens;

  List<TimeSpan> times = const [];
  Set<int> claimed = {};
  List<_Num> nums = [];
  List<bool> inNum = [];
  final List<({int start, int end, String digits})> cardRuns = [];

  String w(int k) =>
      k >= 0 && k < tokens.length && tokens[k].isWord ? tokens[k].text : '';
  bool isFiller(int k) => w(k).isNotEmpty && p.fillers.contains(w(k));

  Understanding execute() {
    if (source.isEmpty || tokens.isEmpty) {
      return Understanding(
        source: source,
        tokens: tokens,
        type: UtteranceType.empty,
      );
    }
    if (_isAddCard()) {
      return Understanding(
        source: source,
        tokens: tokens,
        type: UtteranceType.addCard,
        hasSignal: true,
      );
    }
    times = findTimeSpans(tokens, p, now);
    claimed = {
      for (final s in times)
        for (var k = s.startToken; k < s.endToken; k++) k,
    };
    final spans = findNumbers(tokens, p, claimed: claimed);
    nums = [for (final s in spans) _Num(s)];
    inNum = List<bool>.filled(tokens.length, false);
    for (final n in nums) {
      for (var k = n.start; k < n.end; k++) {
        inNum[k] = true;
      }
    }
    if (_isQuestion()) {
      return Understanding(
        source: source,
        tokens: tokens,
        type: UtteranceType.question,
        times: times,
        hasSignal: true,
      );
    }
    _findCardDigits();
    for (final n in nums) {
      if (n.role == _Role.amount) _classify(n);
    }
    final anchors = _chooseAnchors();
    final groups = _group(anchors);
    final entries = _entries(groups);
    final hasSignal =
        nums.isNotEmpty ||
        tokens.any(
          (t) =>
              t.isWord &&
              (p.amountLeadVerbs.contains(t.text) ||
                  p.currencyWords.contains(t.text)),
        );
    return Understanding(
      source: source,
      tokens: tokens,
      type: UtteranceType.entries,
      entries: entries,
      times: times,
      hasSignal: hasSignal,
    );
  }

  // ---- sentence level -----------------------------------------------------

  bool _isAddCard() {
    for (var i = 0; i < tokens.length; i++) {
      if (!p.addCardVerbs.contains(w(i))) continue;
      var k = i + 1;
      var steps = 0;
      while (k < tokens.length && steps < 5) {
        final x = w(k);
        if (x.isEmpty) break;
        if (p.cardWords.contains(x)) return true;
        if (p.addCardBlockers.contains(x)) break;
        if (p.addCardMiddle.contains(x)) {
          k++;
          steps++;
          continue;
        }
        if (p.amountLeadVerbs.contains(x) || p.objectPrepositions.contains(x)) {
          break;
        }
        // An unknown word here is usually a bank name ("my hdfc card").
        k++;
        steps++;
      }
    }
    return false;
  }

  bool _isQuestion() {
    var k = 0;
    while (k < tokens.length && (tokens[k].isPunct || isFiller(k))) {
      k++;
    }
    if (p.questionStarters.contains(w(k))) return true;
    if (source.trimRight().endsWith('?')) {
      final hasLead = tokens.any(
        (t) => t.isWord && p.amountLeadVerbs.contains(t.text),
      );
      return !(hasLead && nums.isNotEmpty);
    }
    return false;
  }

  // ---- numbers --------------------------------------------------------------

  void _findCardDigits() {
    final byStart = {for (var i = 0; i < nums.length; i++) nums[i].start: i};
    for (var i = 0; i < tokens.length; i++) {
      if (!p.cardEndingWords.contains(w(i))) continue;
      var k = i + 1;
      while (p.digitConnectors.contains(w(k))) {
        k++;
      }
      final picked = <int>[];
      final digits = StringBuffer();
      var runStart = -1;
      var runEnd = k;
      while (digits.length < 4 && byStart.containsKey(k)) {
        final idx = byStart[k]!;
        final n = nums[idx];
        final single = n.span.length == 1 && tokens[k].isNumber;
        final raw = single ? tokens[k].text : '';
        final v = n.span.value;
        if (single && digits.isEmpty && raw.length == 4 && !raw.contains('.')) {
          digits.write(raw);
          picked.add(idx);
          runStart = k;
          runEnd = n.end;
          break;
        }
        final isDigit =
            v == v.roundToDouble() &&
            v >= 0 &&
            v < 10 &&
            (!single || raw.length == 1);
        if (!isDigit) break;
        if (runStart < 0) runStart = k;
        digits.write(v.toInt());
        picked.add(idx);
        runEnd = n.end;
        k = n.end;
      }
      if (digits.length == 4) {
        for (final idx in picked) {
          nums[idx].role = _Role.cardDigit;
        }
        cardRuns.add((start: runStart, end: runEnd, digits: digits.toString()));
      }
    }
  }

  bool _looksPlural(String word) =>
      word.length > 3 &&
      !p.notPlural.contains(word) &&
      !word.endsWith('ss') &&
      p.pluralSuffixes.any(word.endsWith);

  /// The number at [a] is introduced like a quantity: it starts the sentence
  /// or follows a verb, preposition, conjunction or determiner, not a name.
  bool _introducesQuantity(int a) {
    var k = a - 1;
    while (k >= 0 && tokens[k].isSymbol) {
      k--;
    }
    if (k < 0) return true;
    final t = tokens[k];
    if (!t.isWord) return true;
    final x = t.text;
    return p.amountLeadVerbs.contains(x) ||
        p.amountLeadPrepositions.contains(x) ||
        p.objectPrepositions.contains(x) ||
        p.conjunctions.contains(x) ||
        p.determiners.contains(x) ||
        p.pronouns.contains(x) ||
        p.currencyWords.contains(x) ||
        const {'of', 'had', 'have', 'get', 'got', 'only', 'about'}.contains(x);
  }

  void _classify(_Num n) {
    final s = n.span;
    final a = s.startToken;
    final b = s.endToken;
    final nextW = w(b);
    final nextTok = b < tokens.length ? tokens[b] : null;
    if (p.pointsWords.contains(nextW)) {
      n.role = _Role.points;
      return;
    }
    if ((nextTok != null && nextTok.text == '%') ||
        p.percentWords.contains(nextW)) {
      n.role = _Role.percent;
      return;
    }
    if (p.timeSuffixes.contains(nextW)) {
      n.role = _Role.time;
      return;
    }

    var home = false;
    String? foreign;
    final prev = a > 0 ? tokens[a - 1] : null;
    if (prev != null) {
      if (prev.isSymbol && p.currencySymbols.contains(prev.text)) {
        home = true;
        n.curStart = a - 1;
        n.curEnd = a;
      } else if (prev.isSymbol && p.foreignCurrencies.containsKey(prev.text)) {
        foreign = p.foreignCurrencies[prev.text];
        n.curStart = a - 1;
        n.curEnd = a;
      } else if (prev.isWord && p.currencyWords.contains(prev.text)) {
        home = true;
        n.curStart = a - 1;
        n.curEnd = a;
      } else if (prev.isWord && p.foreignCurrencies.containsKey(prev.text)) {
        foreign = p.foreignCurrencies[prev.text];
        n.curStart = a - 1;
        n.curEnd = a;
      }
    }
    if (!home && foreign == null && nextTok != null && nextTok.isWord) {
      if (p.currencyWords.contains(nextTok.text)) {
        home = true;
        n.curStart = b;
        n.curEnd = b + 1;
      } else if (p.foreignCurrencies.containsKey(nextTok.text)) {
        foreign = p.foreignCurrencies[nextTok.text];
        n.curStart = b;
        n.curEnd = b + 1;
      }
    }
    final first = tokens[a];
    if (first.isNumber &&
        (first.rupeeSlash || p.currencySuffixes.contains(first.suffix))) {
      home = true;
    }
    n.foreignCode = foreign;
    final hasCurrency = home || foreign != null;

    var score = 1.0;
    if (hasCurrency) score += 4;

    // The nearest lead-in word before the number, not looking past another
    // number.
    var distance = 0;
    for (var k = a - 1; k >= 0 && distance <= 6; k--) {
      if (inNum[k]) break;
      final t = tokens[k];
      if (t.isSymbol) continue;
      if (!t.isWord) {
        distance++;
        continue;
      }
      if (p.currencyWords.contains(t.text)) continue;
      distance++;
      if (p.amountLeadVerbs.contains(t.text)) {
        score += 3.0 - 0.5 * (distance - 1);
        break;
      }
      if (p.amountLeadPrepositions.contains(t.text) && distance == 1) {
        score += 2;
        break;
      }
    }

    var quantityLike = false;
    if (nextW.isNotEmpty && !hasCurrency) {
      if (p.quantityUnits.contains(nextW)) {
        score -= 4;
        quantityLike = true;
      } else if (_looksPlural(nextW) &&
          !p.pointsWords.contains(nextW) &&
          !p.foreignCurrencies.containsKey(nextW) &&
          _introducesQuantity(a)) {
        // "2 coffees" is a quantity, but in "bread 45 eggs 80" the number
        // follows a name, so "eggs" belongs to the next item.
        score -= 3;
        quantityLike = true;
      }
    }
    if (p.objectPrepositions.contains(nextW)) score += 1;
    if (s.hasMagnitude) score += 1;
    final v = s.value;
    if (!hasCurrency && !s.hasMagnitude && v == v.roundToDouble() && v < 10) {
      // A lone digit is far more often a quantity, a star rating or a count
      // than an amount, so it needs real evidence to be one.
      score -= 3;
    }
    if (first.isNumber && !hasCurrency && !s.hasMagnitude) {
      final digits = first.text.replaceAll('.', '');
      final grouped = first.raw.contains(',');
      if (!grouped && !first.text.contains('.') && digits.length >= 8) {
        n.role = _Role.identifier;
        return;
      }
      if (!grouped && !first.text.contains('.') && digits.length >= 5) {
        score -= 1.5;
      }
    }
    n.score = score;
    if (quantityLike && score < 1.0) n.role = _Role.quantity;
  }

  // ---- anchors, corrections, entries -----------------------------------------

  /// An unlikely-looking number that sits in the same frame as a likely one
  /// is read as an amount too: in "6,950 for rent and 500000 for movie
  /// tickets" both numbers are followed by "for", so a plain six-digit number
  /// is still money. Only numbers of ten or more qualify, and quantities
  /// never do.
  void _boostParallelAmounts() {
    bool framed(_Num n) {
      var k = n.end;
      while (k < tokens.length && p.currencyWords.contains(w(k))) {
        k++;
      }
      return p.listFramePrepositions.contains(w(k));
    }

    final sure = nums.where((n) => n.role == _Role.amount && n.score >= 1.0);
    if (!sure.any(framed)) return;
    for (final n in nums) {
      if (n.role != _Role.amount || n.score >= 1.0 || n.score < -2.5) continue;
      if (n.span.value < 10 || !framed(n)) continue;
      n.score = 1.0;
    }
  }

  List<_Anchor> _chooseAnchors() {
    _boostParallelAmounts();
    final amounts = nums
        .where((n) => n.role == _Role.amount && n.score >= 1.0)
        .toList();
    final anchors = <_Anchor>[
      for (final n in amounts) _Anchor(n, isPoints: false),
    ];
    // Points count as an entry only with a redeeming word beside them.
    for (final n in nums.where((n) => n.role == _Role.points)) {
      final from = n.start - 6 < 0 ? 0 : n.start - 6;
      final to = n.end + 4 > tokens.length ? tokens.length : n.end + 4;
      var redeem = false;
      for (var k = from; k < to; k++) {
        if (p.pointsRedeemVerbs.contains(w(k))) redeem = true;
      }
      if (redeem) anchors.add(_Anchor(n, isPoints: true));
    }
    anchors.sort((x, y) => x.num.start.compareTo(y.num.start));
    if (anchors.isEmpty) {
      // No number scored well. Offer the best of the rest as a weak guess.
      final rest =
          nums.where((n) => n.role == _Role.amount && n.score >= -1.5).toList()
            ..sort((x, y) => y.score.compareTo(x.score));
      if (rest.isNotEmpty) return [_Anchor(rest.first, isPoints: false)];
    }
    return anchors;
  }

  ({int start, int end, bool weak})? _cueBefore(int amountStart, int lower) {
    for (var k = amountStart - 1; k >= lower && amountStart - k <= 8; k--) {
      for (final ph in p.correctionPhrases) {
        final s = k - ph.length + 1;
        if (s < lower) continue;
        var ok = true;
        for (var j = 0; j < ph.length; j++) {
          if (w(s + j) != ph[j]) {
            ok = false;
            break;
          }
        }
        if (ok) return (start: s, end: k + 1, weak: false);
      }
      final x = w(k);
      if (p.correctionStrong.contains(x)) {
        return (start: k, end: k + 1, weak: false);
      }
      if (p.correctionWeak.contains(x)) {
        return (start: k, end: k + 1, weak: true);
      }
      if (x == 'but') {
        // "not 200 but 250"; the caller checks for the "not".
        return (start: k, end: k + 1, weak: false);
      }
      final t = tokens[k];
      final skip =
          t.isSymbol ||
          (t.isPunct && (t.text == ',' || t.text == '.')) ||
          (t.isWord &&
              (isFiller(k) ||
                  p.correctionConnectors.contains(t.text) ||
                  p.currencyWords.contains(t.text)));
      if (!skip) break;
    }
    return null;
  }

  bool _notBefore(int start) {
    var k = start - 1;
    while (k >= 0 && (tokens[k].isSymbol || p.currencyWords.contains(w(k)))) {
      k--;
    }
    return w(k) == 'not';
  }

  List<_Group> _group(List<_Anchor> anchors) {
    final groups = <_Group>[];
    for (final a in anchors) {
      if (groups.isNotEmpty && !a.isPoints && !groups.last.anchor.isPoints) {
        final prev = groups.last;
        final cue = _cueBefore(a.num.start, prev.lastEnd);
        if (cue != null) {
          var valid = true;
          final x = w(cue.start);
          if (x == 'but') valid = _notBefore(prev.firstStart);
          if (cue.weak) {
            for (var k = prev.lastEnd; k < cue.start; k++) {
              if (p.conjunctions.contains(w(k))) valid = false;
            }
          }
          if (valid) {
            final old = prev.anchor.num;
            prev.correctedFrom = prev.correctedFromSource == null
                ? old.span.value
                : prev.correctedFrom;
            prev.correctedFromSource ??= old.span.text(source, tokens);
            prev.dropped
              ..add((old.start, old.end))
              ..add((cue.start, cue.end));
            if (old.curStart >= 0) prev.dropped.add((old.curStart, old.curEnd));
            prev.anchor = a;
            prev.lastEnd = a.num.end;
            continue;
          }
        }
      }
      groups.add(_Group(a));
    }
    return groups;
  }

  bool _skippable(int k) {
    final t = tokens[k];
    if (!t.isWord) return t.isPunct || t.isSymbol;
    return isFiller(k) ||
        p.pronouns.contains(t.text) ||
        p.amountLeadVerbs.contains(t.text) ||
        p.amountLeadPrepositions.contains(t.text) ||
        p.objectPrepositions.contains(t.text) ||
        p.conjunctions.contains(t.text) ||
        p.currencyWords.contains(t.text) ||
        p.articleWords.contains(t.text) ||
        p.theWords.contains(t.text) ||
        claimed.contains(k);
  }

  int _split(int gapStart, int gapEnd, bool nameFirst) {
    // After the last separator ("and", "then", a comma).
    for (var k = gapEnd - 1; k >= gapStart; k--) {
      final t = tokens[k];
      final sep =
          (t.isWord && p.conjunctions.contains(t.text)) ||
          (t.isPunct && const {',', ';', '.'}.contains(t.text));
      if (sep) return k + 1;
    }
    // Before the last verb.
    for (var k = gapEnd - 1; k >= gapStart; k--) {
      if (p.amountLeadVerbs.contains(w(k))) return k;
    }
    return nameFirst ? gapStart : gapEnd;
  }

  List<EntryReading> _entries(List<_Group> groups) {
    if (groups.isEmpty) {
      return [_entry(0, tokens.length, null, [], const [])];
    }
    var nameFirst = false;
    for (var k = 0; k < groups.first.firstStart; k++) {
      if (tokens[k].isWord && !_skippable(k)) {
        nameFirst = true;
        break;
      }
    }
    final cuts = <int>[0];
    for (var i = 0; i + 1 < groups.length; i++) {
      cuts.add(_split(groups[i].lastEnd, groups[i + 1].firstStart, nameFirst));
    }
    cuts.add(tokens.length);
    final entries = <EntryReading>[];
    for (var i = 0; i < groups.length; i++) {
      entries.add(
        _entry(
          cuts[i],
          cuts[i + 1],
          groups[i],
          [for (final g in groups) g],
          cuts,
          index: i,
        ),
      );
    }
    return _inheritKinds(_shareDates(entries, groups, cuts), groups);
  }

  // ---- one entry --------------------------------------------------------------

  EntryReading _entry(
    int rs,
    int re,
    _Group? g,
    List<_Group> all,
    List<int> cuts, {
    int index = 0,
  }) {
    final anchor = g?.anchor;
    AmountReading? amount;
    int? points;
    String? pointsSource;
    if (anchor != null) {
      final n = anchor.num;
      if (anchor.isPoints) {
        points = n.span.value.round();
        pointsSource = n.span.text(source, tokens);
      } else {
        final weak = n.score < 1.0;
        amount = AmountReading(
          value: n.span.value,
          source: n.span.text(source, tokens),
          tokenStart: n.start,
          tokenEnd: n.end,
          alternative: n.span.altValue,
          currencyCode: n.foreignCode,
          weak: weak,
          correctedFrom: g!.correctedFrom,
          correctedFromSource: g.correctedFromSource,
        );
      }
    }

    // Dates: a single day wins over a stretch of days.
    TimeSpan? date;
    var vague = false;
    for (final t in times) {
      if (t.startToken < rs || t.endToken > re) continue;
      if (t.isSingleDay) {
        date ??= t;
      }
    }
    if (date == null) {
      for (final t in times) {
        if (t.startToken < rs || t.endToken > re) continue;
        date = t;
        vague = true;
        break;
      }
    }

    // Kind from the words of this entry.
    final scores = <String, double>{'spend': 0.5};
    void add(String kind, double weight) =>
        scores[kind] = (scores[kind] ?? 0) + weight;
    // Cue words are matched over the words of the entry with the numbers and
    // currency words taken out, so "sent 5000 to" still reads as "sent to".
    final seq = <String>[
      for (var k = rs; k < re; k++)
        if (tokens[k].isWord &&
            !inNum[k] &&
            !p.currencyWords.contains(tokens[k].text))
          tokens[k].text,
    ];
    // Longest cue first: "paid me" uses up "paid", so it does not also count
    // as spending.
    final used = List<bool>.filled(seq.length, false);
    final cues = [...p.kindCues]
      ..sort((a, b) => b.words.length.compareTo(a.words.length));
    for (final cue in cues) {
      for (var k = 0; k + cue.words.length <= seq.length; k++) {
        var ok = true;
        for (var j = 0; j < cue.words.length; j++) {
          if (used[k + j] || seq[k + j] != cue.words[j]) {
            ok = false;
            break;
          }
        }
        if (!ok) continue;
        // Only a phrase uses up its words. A single word like "got" is
        // evidence for several kinds at once.
        if (cue.words.length > 1) {
          for (var j = 0; j < cue.words.length; j++) {
            used[k + j] = true;
          }
        }
        add(cue.kind, cue.weight);
      }
    }
    // "for 1800" says something was paid for; money received comes "from".
    if (anchor != null && !anchor.isPoints) {
      var k = anchor.num.start - 1;
      while (k >= rs &&
          (tokens[k].isSymbol ||
              p.currencyWords.contains(w(k)) ||
              p.hedgeWords.contains(w(k)))) {
        k--;
      }
      if (k >= rs && w(k) == 'for') add('spend', 1.5);
    }
    var billNear = false;
    for (var k = rs; k < re; k++) {
      if (p.cardWords.contains(w(k))) {
        for (var j = k - 3; j <= k + 3; j++) {
          if (j >= rs && j < re && p.billWords.contains(w(j))) billNear = true;
        }
      }
      if (p.statementWords.contains(w(k))) add('billPayment', 3);
    }
    if (billNear) add('billPayment', 5);
    final cueTotal = scores.entries
        .where((e) => e.key != 'spend')
        .fold<double>(0, (s, e) => s > e.value ? s : e.value);

    EntryKind kind;
    EntryKind? alt;
    if (points != null) {
      kind = EntryKind.pointsRedemption;
    } else {
      final ranked = scores.entries.toList()
        ..sort((x, y) => y.value.compareTo(x.value));
      kind = _kindOf(ranked.first.key);
      if (ranked.length > 1 &&
          ranked[1].value >= 1.0 &&
          ranked.first.value - ranked[1].value < 1.0) {
        final second = _kindOf(ranked[1].key);
        if (kind != EntryKind.spend || second == EntryKind.moneyIn) {
          alt = second;
        }
      }
    }
    _lastCueTotal[index] = cueTotal;

    // Quantities, leftovers, card digits.
    final quantities = <String>[];
    final leftovers = <Leftover>[];
    final drop = <int>{};
    for (final n in nums) {
      if (n.start < rs || n.end > re) continue;
      final isAnchor = anchor != null && identical(anchor.num, n);
      final replaced = g != null && g.dropped.any((d) => d.$1 == n.start);
      if (isAnchor || replaced) {
        for (var k = n.start; k < n.end; k++) {
          drop.add(k);
        }
        for (var k = n.curStart; k >= 0 && k < n.curEnd; k++) {
          drop.add(k);
        }
        continue;
      }
      switch (n.role) {
        case _Role.quantity:
          final noun = w(n.end);
          quantities.add(
            noun.isEmpty
                ? n.span.text(source, tokens)
                : '${n.span.text(source, tokens)} $noun',
          );
          for (var k = n.start; k < n.end; k++) {
            drop.add(k);
          }
        case _Role.identifier:
          leftovers.add(
            Leftover(
              text: n.span.text(source, tokens),
              reason: 'looks like a reference number',
              value: n.span.value,
            ),
          );
          for (var k = n.start; k < n.end; k++) {
            drop.add(k);
          }
        case _Role.amount:
          leftovers.add(
            Leftover(
              text: n.span.text(source, tokens),
              reason: 'not used as an amount',
              value: n.span.value,
            ),
          );
          for (var k = n.start; k < n.end; k++) {
            drop.add(k);
          }
        case _Role.points:
          if (anchor == null || !anchor.isPoints || !identical(anchor.num, n)) {
            for (var k = n.start; k < n.end; k++) {
              drop.add(k);
            }
          }
        case _Role.percent:
        case _Role.time:
        case _Role.cardDigit:
          for (var k = n.start; k < n.end; k++) {
            drop.add(k);
          }
      }
    }
    String? cardDigits;
    for (final run in cardRuns) {
      if (run.start >= rs && run.end <= re) {
        cardDigits = run.digits;
        for (var k = run.start; k < run.end; k++) {
          drop.add(k);
        }
        if (run.start > 0 && p.cardEndingWords.contains(w(run.start - 1))) {
          drop.add(run.start - 1);
        }
      }
    }
    if (g != null) {
      for (final d in g.dropped) {
        for (var k = d.$1; k < d.$2; k++) {
          drop.add(k);
        }
      }
    }
    for (final t in times) {
      if (t.startToken >= rs && t.endToken <= re) {
        for (var k = t.startToken; k < t.endToken; k++) {
          drop.add(k);
        }
      }
    }

    final dateSource = date?.text(source, tokens);
    return EntryReading(
      tokenStart: rs,
      tokenEnd: re,
      text: source.substring(tokens[rs].start, tokens[re - 1].end),
      cleanText: _clean(rs, re, drop),
      kind: kind,
      kindAlternative: alt,
      amount: amount,
      points: points,
      pointsSource: pointsSource,
      date: date,
      dateSource: dateSource,
      quantities: quantities,
      cardDigits: cardDigits,
      leftovers: leftovers,
      dateVague: vague,
      dateFuture: date != null && !vague && _isFuture(date),
    );
  }

  final Map<int, double> _lastCueTotal = {};

  bool _isFuture(TimeSpan d) =>
      d.isFuture(DateTime(now.year, now.month, now.day)) || d.yearInferredBack;

  EntryKind _kindOf(String key) => switch (key) {
    'income' => EntryKind.moneyIn,
    'refund' => EntryKind.refund,
    'transfer' => EntryKind.transfer,
    'billPayment' => EntryKind.billPayment,
    _ => EntryKind.spend,
  };

  String _clean(int rs, int re, Set<int> drop) {
    final parts = <String>[];
    for (var k = rs; k < re; k++) {
      if (drop.contains(k)) continue;
      final t = tokens[k];
      if (isFiller(k)) continue;
      if (t.isPunct) {
        if (parts.isNotEmpty) parts[parts.length - 1] += t.raw;
        continue;
      }
      parts.add(t.raw);
    }
    // Trim connecting words left at either end.
    bool edge(String s) {
      final x = s.toLowerCase().replaceAll(RegExp(r'[,.;]'), '');
      return p.conjunctions.contains(x) || x.isEmpty;
    }

    while (parts.isNotEmpty && edge(parts.first)) {
      parts.removeAt(0);
    }
    while (parts.isNotEmpty && edge(parts.last)) {
      parts.removeLast();
    }
    return parts.join(' ').trim();
  }

  // ---- shared dates and inherited kinds -----------------------------------------

  List<EntryReading> _shareDates(
    List<EntryReading> entries,
    List<_Group> groups,
    List<int> cuts,
  ) {
    if (entries.length < 2) return entries;
    TimeSpan? shared;
    String? sharedSource;
    final first = entries.first;
    final last = entries.last;
    // A date said first: "yesterday i spent 250 on lunch and 300 on fuel".
    if (first.date != null && !first.dateVague) {
      final d = first.date!;
      var leading = d.startToken < groups.first.firstStart;
      for (var k = 0; k < d.startToken && leading; k++) {
        if (!_skippable(k)) leading = false;
      }
      if (leading) {
        shared = d;
        sharedSource = first.dateSource;
      }
    }
    // A date said last: "... and 300 on fuel yesterday".
    if (shared == null && last.date != null && !last.dateVague) {
      final d = last.date!;
      var trailing = d.startToken >= groups.last.lastEnd;
      for (var k = d.endToken; k < tokens.length && trailing; k++) {
        if (!(tokens[k].isPunct || isFiller(k))) trailing = false;
      }
      if (trailing) {
        shared = d;
        sharedSource = last.dateSource;
      }
    }
    if (shared == null) return entries;
    return [
      for (final e in entries)
        e.date == null
            ? EntryReading(
                tokenStart: e.tokenStart,
                tokenEnd: e.tokenEnd,
                text: e.text,
                cleanText: e.cleanText,
                kind: e.kind,
                kindAlternative: e.kindAlternative,
                amount: e.amount,
                points: e.points,
                pointsSource: e.pointsSource,
                date: shared,
                dateSource: sharedSource,
                dateFuture: _isFuture(shared),
                quantities: e.quantities,
                cardDigits: e.cardDigits,
                leftovers: e.leftovers,
              )
            : e,
    ];
  }

  List<EntryReading> _inheritKinds(
    List<EntryReading> entries,
    List<_Group> groups,
  ) {
    if (entries.length < 2) return entries;
    final out = <EntryReading>[];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final cue = _lastCueTotal[i] ?? 0;
      if (i > 0 &&
          cue < 1.0 &&
          e.kind == EntryKind.spend &&
          e.points == null &&
          out.last.kind != EntryKind.pointsRedemption) {
        out.add(
          EntryReading(
            tokenStart: e.tokenStart,
            tokenEnd: e.tokenEnd,
            text: e.text,
            cleanText: e.cleanText,
            kind: out.last.kind,
            kindAlternative: out.last.kindAlternative,
            amount: e.amount,
            points: e.points,
            pointsSource: e.pointsSource,
            date: e.date,
            dateSource: e.dateSource,
            dateFuture: e.dateFuture,
            dateVague: e.dateVague,
            quantities: e.quantities,
            cardDigits: e.cardDigits,
            leftovers: e.leftovers,
          ),
        );
      } else {
        out.add(e);
      }
    }
    return out;
  }
}
