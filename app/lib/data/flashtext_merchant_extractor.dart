import 'dart:core';

/// Match result returned by [FlashTextMerchantExtractor].
class ExtractedMerchantResult {
  final String canonicalName;
  final String category;
  final String matchedTerm;
  final int startOffset;
  final int endOffset;

  const ExtractedMerchantResult({
    required this.canonicalName,
    required this.category,
    required this.matchedTerm,
    required this.startOffset,
    required this.endOffset,
  });

  @override
  String toString() =>
      'ExtractedMerchantResult($canonicalName, category: $category, matched: "$matchedTerm")';
}

/// Internal Trie Node for FlashText keyword matching.
class _TrieNode {
  final Map<int, _TrieNode> children = {};
  String? canonicalName;
  String? category;
  bool isEndOfWord = false;
}

/// Pure-Dart high-performance FlashText (Trie KeywordProcessor) algorithm.
///
/// Features:
/// 1. $O(N)$ single-pass time complexity where $N$ is text length.
/// 2. Strict word boundary checks (prevents substring false-positives).
/// 3. Longest-match preference (e.g., "SWIGGY INSTAMART" matches groceries rather than dining "SWIGGY").
/// 4. Built-in curated catalog of 150+ top Indian merchants, corporate aliases, and category mappings.
class FlashTextMerchantExtractor {
  final _TrieNode _root = _TrieNode();

  FlashTextMerchantExtractor({bool includeBuiltinCatalog = true}) {
    if (includeBuiltinCatalog) {
      _loadDefaultCatalog();
    }
  }

  static FlashTextMerchantExtractor? _shared;
  static FlashTextMerchantExtractor get defaultExtractor =>
      _shared ??= FlashTextMerchantExtractor();

  /// Adds a merchant keyword pattern to the Trie.
  void addKeyword(String keyword, {required String canonicalName, required String category}) {
    final lower = keyword.trim().toLowerCase();
    if (lower.isEmpty) return;

    var current = _root;
    for (var i = 0; i < lower.length; i++) {
      final code = lower.codeUnitAt(i);
      current = current.children.putIfAbsent(code, () => _TrieNode());
    }
    current.isEndOfWord = true;
    current.canonicalName = canonicalName;
    current.category = category;
  }

  /// Extracts the highest-priority, longest matching merchant from [text].
  /// Returns null if no known merchant keyword is found.
  ExtractedMerchantResult? extractFirst(String text) {
    final results = extractAll(text);
    return results.isEmpty ? null : results.first;
  }

  /// Extracts all matching merchants from [text] in single-pass $O(N)$ time.
  List<ExtractedMerchantResult> extractAll(String text) {
    if (text.isEmpty) return const [];

    final results = <ExtractedMerchantResult>[];
    final lower = text.toLowerCase();
    final len = lower.length;
    var i = 0;

    while (i < len) {
      // Must start on a word boundary
      if (i > 0 && _isWordChar(lower.codeUnitAt(i - 1))) {
        i++;
        continue;
      }

      var current = _root;
      var matchEnd = -1;
      String? matchedCanonical;
      String? matchedCategory;

      for (var j = i; j < len; j++) {
        final code = lower.codeUnitAt(j);
        final nextNode = current.children[code];
        if (nextNode == null) break;

        current = nextNode;
        if (current.isEndOfWord) {
          // Check if this position is a word boundary
          final nextCharIsWord = (j + 1 < len) && _isWordChar(lower.codeUnitAt(j + 1));
          if (!nextCharIsWord) {
            matchEnd = j + 1;
            matchedCanonical = current.canonicalName;
            matchedCategory = current.category;
          }
        }
      }

      if (matchEnd != -1 && matchedCanonical != null && matchedCategory != null) {
        results.add(
          ExtractedMerchantResult(
            canonicalName: matchedCanonical,
            category: matchedCategory,
            matchedTerm: text.substring(i, matchEnd),
            startOffset: i,
            endOffset: matchEnd,
          ),
        );
        i = matchEnd;
      } else {
        i++;
      }
    }

    return results;
  }

  bool _isWordChar(int code) {
    // 0-9: 48-57, A-Z: 65-90, a-z: 97-122, _: 95
    return (code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) ||
        code == 95;
  }

  void _loadDefaultCatalog() {
    // 1. Groceries & Quick Commerce (Longer phrases first for priority)
    const groceries = [
      ['swiggy instamart', 'Swiggy Instamart'],
      ['instamart', 'Swiggy Instamart'],
      ['blinkit', 'Blinkit'],
      ['blink commerce', 'Blinkit'],
      ['grofers', 'Blinkit'],
      ['zepto', 'Zepto'],
      ['kiranakart', 'Zepto'],
      ['bigbasket', 'BigBasket'],
      ['innovative retail', 'BigBasket'],
      ['bbdaily', 'BigBasket Daily'],
      ['dmart', 'DMart'],
      ['avenue supermarts', 'DMart'],
      ['jiomart', 'JioMart'],
      ['reliance fresh', 'Reliance Fresh'],
      ['reliance smart', 'Reliance Smart'],
      ['more retail', 'More Retail'],
      ['nature basket', "Nature's Basket"],
      ['licious', 'Licious'],
      ['country delight', 'Country Delight'],
      ['freshtohome', 'FreshToHome'],
    ];
    for (final pair in groceries) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'groceries');
    }

    // 2. Food & Dining
    const dining = [
      ['swiggy', 'Swiggy'],
      ['bundl technologies', 'Swiggy'],
      ['zomato', 'Zomato'],
      ['eternal limited', 'Zomato'],
      ['mcdonalds', "McDonald's"],
      ["mcdonald's", "McDonald's"],
      ['hardcastle restaurants', "McDonald's"],
      ['dominos', "Domino's Pizza"],
      ["domino's", "Domino's Pizza"],
      ['jubilant foodworks', "Domino's Pizza"],
      ['starbucks', 'Starbucks'],
      ['tata starbucks', 'Starbucks'],
      ['kfc', 'KFC'],
      ['pizza hut', 'Pizza Hut'],
      ['burger king', 'Burger King'],
      ['subway', 'Subway'],
      ['haldirams', "Haldiram's"],
      ['haldiram', "Haldiram's"],
      ['eazydiner', 'EazyDiner'],
      ['barbeque nation', 'Barbeque Nation'],
      ['chaayos', 'Chaayos'],
      ['chai point', 'Chai Point'],
      ['blue tokai', 'Blue Tokai'],
      ['third wave coffee', 'Third Wave Coffee'],
    ];
    for (final pair in dining) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'dining');
    }

    // 3. E-Commerce & Shopping
    const online = [
      ['amazon', 'Amazon'],
      ['amazon seller', 'Amazon'],
      ['amazon pay', 'Amazon'],
      ['flipkart', 'Flipkart'],
      ['myntra', 'Myntra'],
      ['ajio', 'Ajio'],
      ['nykaa', 'Nykaa'],
      ['fsn e-commerce', 'Nykaa'],
      ['meesho', 'Meesho'],
      ['tata cliq', 'Tata CLiQ'],
      ['croma', 'Croma'],
      ['infiniti retail', 'Croma'],
      ['reliance digital', 'Reliance Digital'],
      ['ikea', 'IKEA'],
      ['decathlon', 'Decathlon'],
      ['zara', 'Zara'],
      ['h&m', 'H&M'],
      ['uniqlo', 'Uniqlo'],
    ];
    for (final pair in online) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'online');
    }

    // 4. Fuel & Mobility
    const fuel = [
      ['indianoil', 'Indian Oil'],
      ['indian oil', 'Indian Oil'],
      ['iocl', 'Indian Oil'],
      ['bharat petroleum', 'Bharat Petroleum'],
      ['bpcl', 'Bharat Petroleum'],
      ['hindustan petroleum', 'Hindustan Petroleum'],
      ['hpcl', 'Hindustan Petroleum'],
      ['shell', 'Shell'],
      ['jio-bp', 'Jio-bp'],
      ['jio bp', 'Jio-bp'],
      ['nayara', 'Nayara Energy'],
      ['hpcl coco', 'Hindustan Petroleum'],
      ['bpcl coco', 'Bharat Petroleum'],
      ['iocl coco', 'Indian Oil'],
      ['coco outlet', 'Fuel Station'],
      ['auto fuels', 'Fuel Station'],
      ['autocare', 'Fuel Station'],
      ['petro products', 'Fuel Station'],
      ['petrol bunk', 'Fuel Station'],
      ['filling station', 'Fuel Station'],
      ['cng station', 'CNG Station'],
      ['igl cng', 'IGL CNG'],
      ['mgl cng', 'MGL CNG'],
      ['tata power ev', 'Tata Power EV'],
      ['zeon charging', 'Zeon Charging'],
      ['statiq', 'Statiq EV'],
      ['chargezone', 'ChargeZone'],
      ['ather grid', 'Ather Grid'],
    ];
    for (final pair in fuel) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'fuel');
    }

    // 5. Travel & Commute
    const travel = [
      ['uber', 'Uber'],
      ['uber india', 'Uber'],
      ['ola', 'Ola'],
      ['ola cabs', 'Ola'],
      ['ani technologies', 'Ola'],
      ['rapido', 'Rapido'],
      ['roppen transportation', 'Rapido'],
      ['irctc', 'IRCTC'],
      ['makemytrip', 'MakeMyTrip'],
      ['goibibo', 'Goibibo'],
      ['cleartrip', 'Cleartrip'],
      ['easemytrip', 'EaseMyTrip'],
      ['redbus', 'RedBus'],
      ['abhibus', 'AbhiBus'],
      ['zingbus', 'Zingbus'],
      ['namma yatri', 'Namma Yatri'],
      ['moving tech', 'Namma Yatri'],
      ['dmrc', 'Delhi Metro'],
      ['bmrcl', 'Namma Metro'],
      ['namma metro', 'Namma Metro'],
      ['fastag', 'FASTag Toll'],
      ['netc fastag', 'FASTag Toll'],
      ['ihmcl', 'FASTag Toll'],
      ['toll plaza', 'Toll Plaza'],
      ['ksrtc', 'KSRTC'],
      ['msrtc', 'MSRTC'],
      ['apsrtc', 'APSRTC'],
      ['tsrtc', 'TSRTC'],
      ['air india', 'Air India'],
      ['indigo', 'IndiGo'],
      ['interglobe aviation', 'IndiGo'],
      ['vistara', 'Vistara'],
      ['akasa air', 'Akasa Air'],
      ['spicejet', 'SpiceJet'],
      ['oyo', 'OYO Rooms'],
      ['booking.com', 'Booking.com'],
      ['agoda', 'Agoda'],
    ];
    for (final pair in travel) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'travel');
    }

    // 6. Entertainment & Subscriptions
    const entertainment = [
      ['netflix', 'Netflix'],
      ['spotify', 'Spotify'],
      ['hotstar', 'Disney+ Hotstar'],
      ['disney plus', 'Disney+ Hotstar'],
      ['disney+', 'Disney+ Hotstar'],
      ['prime video', 'Prime Video'],
      ['bookmyshow', 'BookMyShow'],
      ['bigtree entertainment', 'BookMyShow'],
      ['youtube premium', 'YouTube'],
      ['youtube', 'YouTube'],
      ['google play', 'Google Play'],
      ['apple.com/bill', 'Apple'],
      ['apple', 'Apple'],
      ['sonyliv', 'SonyLIV'],
      ['zee5', 'Zee5'],
      ['jiocinema', 'JioCinema'],
      ['chatgpt', 'OpenAI'],
      ['openai', 'OpenAI'],
    ];
    for (final pair in entertainment) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'entertainment');
    }

    // 7. Bills, Telecom & Utilities
    const bills = [
      ['airtel', 'Airtel'],
      ['bharti airtel', 'Airtel'],
      ['jio', 'Jio'],
      ['reliance jio', 'Jio'],
      ['vodafone', 'Vi'],
      ['vodafone idea', 'Vi'],
      ['vi', 'Vi'],
      ['tata power', 'Tata Power'],
      ['bescom', 'BESCOM'],
      ['adani electricity', 'Adani Electricity'],
      ['bses', 'BSES'],
      ['mahadiscom', 'Mahadiscom'],
      ['tsspdcl', 'TSSPDCL'],
      ['tsnpdcl', 'TSNPDCL'],
      ['tangedco', 'TANGEDCO'],
      ['uppcl', 'UPPCL'],
      ['wbsedcl', 'WBSEDCL'],
      ['dhbvn', 'DHBVN'],
      ['pspcl', 'PSPCL'],
      ['kseb', 'KSEB'],
      ['jvvnl', 'JVVNL'],
      ['torrent power', 'Torrent Power'],
      ['cesc', 'CESC'],
      ['ndmc', 'NDMC Electricity'],
      ['mahanagar gas', 'Mahanagar Gas'],
      ['mgl', 'Mahanagar Gas'],
      ['indraprastha gas', 'IGL'],
      ['igl', 'IGL'],
      ['adani gas', 'Adani Gas'],
      ['gujarat gas', 'Gujarat Gas'],
      ['hp gas', 'HP Gas'],
      ['bharat gas', 'Bharat Gas'],
      ['indane', 'Indane Gas'],
      ['act fibernet', 'ACT Fibernet'],
      ['act corp', 'ACT Fibernet'],
      ['tata play', 'Tata Play'],
      ['tata sky', 'Tata Play'],
      ['dish tv', 'Dish TV'],
      ['sun direct', 'Sun Direct'],
      ['hathway', 'Hathway'],
      ['excitel', 'Excitel'],
    ];
    for (final pair in bills) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'bills');
    }

    // 8. Health & Pharmacy
    const health = [
      ['apollopharmacy', 'Apollo Pharmacy'],
      ['apollo pharmacy', 'Apollo Pharmacy'],
      ['apollo', 'Apollo Hospitals'],
      ['pharmeasy', 'PharmEasy'],
      ['tata 1mg', 'Tata 1mg'],
      ['1mg', 'Tata 1mg'],
      ['netmeds', 'Netmeds'],
      ['practo', 'Practo'],
      ['medplus', 'MedPlus'],
      ['cult.fit', 'Cult.fit'],
      ['curefit', 'Cult.fit'],
    ];
    for (final pair in health) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'health');
    }

    // 9. Rent & Housing
    const rent = [
      ['nobroker', 'NoBroker'],
      ['redgirraffe', 'RedGirraffe'],
      ['red giraffe', 'RedGirraffe'],
      ['magicbricks', 'MagicBricks'],
    ];
    for (final pair in rent) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'rent');
    }

    // 10. Investments & Brokerages
    const investments = [
      ['zerodha', 'Zerodha'],
      ['groww', 'Groww'],
      ['nextbillion technology', 'Groww'],
      ['angel one', 'Angel One'],
      ['upstox', 'Upstox'],
      ['rksv securities', 'Upstox'],
      ['indmoney', 'INDmoney'],
      ['kuvera', 'Kuvera'],
      ['coin', 'Zerodha Coin'],
    ];
    for (final pair in investments) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'investment');
    }

    // 11. Wallets & Payment Platforms
    const wallets = [
      ['paytm', 'Paytm'],
      ['one97 communications', 'Paytm'],
      ['phonepe', 'PhonePe'],
      ['cred', 'CRED'],
      ['dreamplug technologies', 'CRED'],
      ['mobikwik', 'MobiKwik'],
      ['amazon pay', 'Amazon Pay'],
    ];
    for (final pair in wallets) {
      addKeyword(pair[0], canonicalName: pair[1], category: 'wallet');
    }
  }
}
