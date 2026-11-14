import 'package:pandapay_domain/pandapay_domain.dart'
    show normalizeMerchantText;

/// Display-only marks for merchants with bundled artwork. This never changes
/// the stored merchant, reporting group, category or payment method.
enum MerchantBrand {
  abhibus,
  adani,
  adobe,
  airbnb,
  airIndia,
  airIndiaExpress,
  airtel,
  ajio,
  akasaAir,
  amaStays,
  amazon,
  apollo,
  apple,
  appleMusic,
  asus,
  avis,
  aws,
  babyShop,
  bescom,
  bestPrice,
  bharatGas,
  bigBasket,
  bigBazaar,
  billdesk,
  blinkit,
  bookMyShow,
  bpcl,
  britishAirways,
  byjus,
  canva,
  caratlane,
  chennaiSuperKings,
  claude,
  clearTax,
  cleartrip,
  clubItc,
  coursera,
  credPay,
  croma,
  cultFit,
  decathlon,
  dell,
  district,
  dmart,
  dominos,
  dropbox,
  easemytrip,
  eazydiner,
  emirates,
  etihad,
  fabindia,
  fastrack,
  flipkart,
  fnp,
  freecharge,
  gap,
  gatewayHotels,
  github,
  giva,
  goibibo,
  google,
  googleGemini,
  googlePlay,
  grtJewellers,
  gyftr,
  hdfcLife,
  helios,
  homeCentre,
  hpcl,
  hpPay,
  hyatt,
  icloud,
  igp,
  ihclSeleqtions,
  indianoil,
  indigo,
  irctc,
  irth,
  ixigo,
  jio,
  jioBp,
  jioHotstar,
  jiomart,
  kfc,
  landmark,
  lenskart,
  lgElectronics,
  licIndia,
  lifestyleStores,
  lloyd,
  makemytrip,
  manchesterUnited,
  marksSpencer,
  marriott,
  maxFashion,
  mcdonalds,
  meesho,
  metroCashCarry,
  miaTitan,
  mobikwik,
  moreRetail,
  mumbaiMetro,
  myntra,
  naturesbasket,
  nayara,
  netflix,
  netmeds,
  nobroker,
  notion,
  nykaa,
  ola,
  openai,
  oyo,
  patanjali,
  paytm,
  pepperfry,
  pharmeasy,
  pizzaHut,
  policybazaar,
  postcardHotels,
  practo,
  primeVideo,
  pvr,
  qatarAirways,
  rapido,
  redbus,
  relianceDigital,
  relianceRetail,
  samsung,
  shellFuel,
  shoppersStop,
  singaporeAirlines,
  skinn,
  snapdeal,
  snitch,
  sonata,
  sonyIndia,
  sonyLiv,
  spar,
  spaceship,
  spicejet,
  spotify,
  starbucks,
  starHealth,
  steam,
  swiggy,
  taj,
  taneira,
  tanishq,
  tata1Mg,
  tataCliq,
  tataNeu,
  tataPlay,
  tataPower,
  tira,
  titanCompany,
  titanEye,
  tvs,
  uber,
  udemy,
  unacademy,
  urbanCompany,
  urbanLadder,
  vijaySales,
  vistara,
  vivanta,
  vivo,
  vodafoneIdea,
  yatra,
  youtube,
  zepto,
  zomato,
  zoya;

  String get asset => 'assets/merchant_brands/$name.png';

  static final _separators = RegExp(r"[\s.'’_-]+");

  /// Finds the most specific brand in a payment description, even when the
  /// bank adds text, joins words or clips the end of the merchant's name.
  static MerchantBrand? forName(String? name) {
    if (name == null || name.contains('@')) return null;
    final exact = _aliases[_key(name)];
    if (exact != null) return exact;

    final words = normalizeMerchantText(name).split(' ');
    final tokenMatches = [for (final word in words) _namesInText[word]];
    MerchantBrand? best;
    var bestScore = 0;
    void consider(MerchantBrand? brand, int score) {
      if (brand == null || score < bestScore) return;
      if (score > bestScore) {
        best = brand;
        bestScore = score;
      } else if (brand != best) {
        best = null;
      }
    }

    for (var start = 0; start < words.length; start++) {
      var phrase = '';
      for (var end = start; end < words.length; end++) {
        phrase += words[end];
        if (phrase.length > _maxMatchLength) break;
        // Short names still match on their own. Inside a descriptor they
        // have too little signal unless they are a known brand acronym.
        if (phrase.length >= 4 || _shortBrandWords.contains(phrase)) {
          consider(_namesInText[phrase], phrase.length * 2);
        }
        // If the last word already names a brand, don't let an abbreviation
        // of a different brand override it.
        if (tokenMatches[end] == null) {
          consider(_clippedNames[phrase], phrase.length * 2 - 1);
        }
      }
      final word = words[start];
      // Some banks remove the separator between a distinctive brand and the
      // rest of its description. The Jio mark also covers its joined names
      // like JioHome, unless a more specific mark such as JioMart wins.
      for (var end = 3; end < word.length && end <= _maxMatchLength; end++) {
        consider(_joinedBrandNames[word.substring(0, end)], end * 2 - 1);
      }
    }
    return best;
  }

  static String _key(String name) =>
      name.toLowerCase().replaceAll(_separators, '');

  static final _aliases = <String, MerchantBrand>{
    for (final entry in _names.entries)
      for (final name in entry.value) _key(name): entry.key,
  };

  static const _shortBrandWords = {'aws', 'jio', 'kfc', 'ola', 'oyo', 'pvr'};

  static final _namesInText = _uniqueNames(
    _names.entries.expand(
      (entry) => entry.value.map(
        (name) => (normalizeMerchantText(name).replaceAll(' ', ''), entry.key),
      ),
    ),
  );

  static final _maxMatchLength = _namesInText.keys.fold<int>(
    0,
    (longest, name) => name.length > longest ? name.length : longest,
  );

  static final _clippedNames = _uniqueNames([
    for (final entry in _namesInText.entries)
      for (var cut = 1; cut <= 3 && entry.key.length - cut >= 5; cut++)
        (entry.key.substring(0, entry.key.length - cut), entry.value),
  ]);

  static final _joinedBrandNames = {
    'jio': jio,
    for (final brand in values)
      if (brand.name.length >= 6 &&
          _namesInText[brand.name.toLowerCase()] == brand)
        brand.name.toLowerCase(): brand,
  };

  static Map<String, MerchantBrand> _uniqueNames(
    Iterable<(String, MerchantBrand)> names,
  ) {
    final matches = <String, MerchantBrand>{};
    final ambiguous = <String>{};
    for (final (name, brand) in names) {
      final existing = matches.putIfAbsent(name, () => brand);
      if (existing != brand) ambiguous.add(name);
    }
    return matches..removeWhere((name, _) => ambiguous.contains(name));
  }

  // Exact display names and aliases from the production merchant directory,
  // published businesses and known subscription descriptors.
  static const _names = <MerchantBrand, List<String>>{
    abhibus: ['AbhiBus'],
    adani: [
      'Adani Electricity',
      'Adani Electricity Mumbai',
      'AEML',
      'Adani One',
      'Adani Digital Labs',
    ],
    adobe: ['Adobe Creative Cloud', 'adobe'],
    airbnb: ['airbnb'],
    airIndia: ['Air India'],
    airIndiaExpress: ['Air India Express'],
    airtel: ['Airtel', 'bharti airtel', 'bharti airtel limited'],
    ajio: ['AJIO', 'ajio luxe'],
    akasaAir: ['Akasa Air', 'qp akasa', 'snv aviation'],
    amaStays: ['ama Stays & Trails', 'ama stays', 'ama stays and trails'],
    amazon: [
      'Amazon',
      'amazon seller services',
      'amazon in',
      'amazon retail india',
      'Amazon India',
      'Amazon Pay',
      'Amazon Pay IN',
      'Amazon Pay India',
      'Amazon Pay Later',
      'Amazon Retail',
      'AMZN MKTP',
      'AMZN MKTP IN',
    ],
    apollo: [
      'Apollo',
      'apollo pharmacy',
      'apollo hospitals',
      'apollo 247',
      'apollo 24x7',
      'apollo health and lifestyle',
    ],
    apple: [
      'Apple',
      'apple india',
      'apple store',
      'apple services',
      'apple retail india',
      'apple.com/bill',
      'iTunes',
    ],
    appleMusic: ['applemusic'],
    asus: ['ASUS', 'asus india', 'asus store'],
    avis: ['Avis India', 'avis car rental'],
    aws: ['Amazon Web Services', 'aws'],
    babyShop: ['Babyshop'],
    bescom: [
      'BESCOM',
      'Bangalore Electricity Supply Company',
      'Bengaluru Electricity Supply Company',
    ],
    bestPrice: [
      'Walmart Best Price',
      'walmart',
      'best price modern wholesale',
      'walmart india',
    ],
    bharatGas: ['Bharat Gas'],
    bigBasket: [
      'BigBasket',
      'supermarket grocery supplies',
      'innovative retail concepts',
    ],
    bigBazaar: ['Big Bazaar', 'Food Bazaar', 'Future Retail'],
    billdesk: ['BillDesk', 'indiaideas'],
    blinkit: [
      'Blinkit',
      'blink commerce',
      'blinkit commerce',
      'Blink Commerce Private Limited',
    ],
    bookMyShow: ['BookMyShow', 'bigtree entertainment'],
    bpcl: ['Bharat Petroleum', 'bpcl', 'bharat petroleum corporation'],
    britishAirways: ['British Airways'],
    byjus: ['BYJU’S'],
    canva: ['canva', 'canvapro'],
    caratlane: ['CaratLane'],
    chennaiSuperKings: ['Chennai Super Kings'],
    claude: ['Claude Pro', 'Claude Max', 'Anthropic', 'claude'],
    clearTax: ['ClearTax', 'Defmacro Software'],
    cleartrip: ['Cleartrip'],
    clubItc: ['ITC Hotels / Club ITC', 'itc hotels', 'club itc'],
    coursera: ['Coursera'],
    credPay: ['CRED', 'cred club', 'dreamplug', 'CRED Pay'],
    croma: ['Croma', 'infiniti retail'],
    cultFit: ['cult.fit', 'curefit healthcare'],
    decathlon: ['Decathlon', 'decathlon sports india'],
    dell: ['Dell', 'dell india', 'dell international'],
    district: ['District by Zomato', 'district app', 'district zomato'],
    dmart: ['DMart', 'avenue supermarts'],
    dominos: [
      'Domino\'s',
      'jubilant foodworks',
      'Domino’s Pizza',
      'Dominos Pizza India',
    ],
    dropbox: ['dropbox'],
    easemytrip: ['EaseMyTrip', 'easy trip planners'],
    eazydiner: ['EazyDiner', 'easydiner'],
    emirates: [
      'Emirates',
      'emirates skywards',
      'emirates airline',
      'emirates com',
    ],
    etihad: ['Etihad Airways', 'etihad'],
    fabindia: ['Fabindia', 'fabindia overseas'],
    fastrack: ['Fastrack'],
    flipkart: [
      'Flipkart',
      'flipkart internet',
      'flipkart india',
      'Flipkart Health+',
      'flipkart health',
      'flipkart health plus',
      'Flipkart Wholesale',
      'flipkart india wholesale',
      'Flipkart Internet Private Limited',
      'Flipkart Pay Later',
    ],
    fnp: ['Ferns N Petals', 'ferns and petals', 'fnp'],
    freecharge: ['Freecharge'],
    gap: ['GAP', 'gap india', 'gap stores'],
    gatewayHotels: ['Gateway Hotels', 'the gateway hotel'],
    github: ['GitHub Copilot', 'github'],
    giva: ['GIVA', 'giva jewellery', 'giva jewelry'],
    goibibo: ['Goibibo', 'ibibo group', 'ibibo'],
    google: ['Google One', 'google'],
    googleGemini: ['Gemini', 'Google Gemini'],
    googlePlay: ['googleplay'],
    grtJewellers: ['GRT Jewellers', 'grt jewels'],
    gyftr: ['GyFTR', 'vouchagram', 'vouchagram india'],
    hdfcLife: ['HDFC Life', 'HDFC Life Insurance'],
    helios: ['Helios Watches', 'helios lifestyle'],
    homeCentre: ['Home Centre'],
    hpcl: ['Hindustan Petroleum', 'hpcl', 'hindustan petroleum corporation'],
    hpPay: ['HP Pay'],
    hyatt: ['Hyatt', 'world of hyatt'],
    icloud: ['iCloud+', 'icloud'],
    igp: ['IGP', 'igp com', 'igp gifts', 'indian gifts portal'],
    ihclSeleqtions: ['SeleQtions'],
    indianoil: [
      'IndianOil',
      'iocl',
      'indian oil corporation',
      'IndianOil XTRAPOWER',
      'xtrapower',
    ],
    indigo: ['IndiGo', 'interglobe aviation', 'indigo airlines', 'goindigo'],
    irctc: [
      'IRCTC',
      'indian railway catering',
      'irctc co in',
      'Indian Railway Catering and Tourism Corporation',
    ],
    irth: ['Irth by Titan'],
    ixigo: ['ixigo'],
    jio: [
      'Jio',
      'reliance jio',
      'jio recharge',
      'reliance jio infocomm',
      'jio infocomm',
    ],
    jioBp: ['Jio-bp', 'reliance bp mobility'],
    jioHotstar: [
      'JioHotstar',
      'hotstar',
      'disney hotstar',
      'Disney+ Hotstar',
      'JioCinema',
    ],
    jiomart: ['JioMart'],
    kfc: ['KFC', 'kentucky fried chicken'],
    landmark: [
      'Landmark Group stores',
      'Landmark Group',
      'Landmark Rewards',
      'Landmark Stores',
    ],
    lenskart: ['Lenskart', 'lenskart solutions'],
    lgElectronics: ['LG Electronics', 'lg india'],
    licIndia: [
      'LIC of India',
      'life insurance corporation',
      'LIC India',
      'Life Insurance Corporation of India',
    ],
    lifestyleStores: [
      'Lifestyle',
      'Lifestyle Stores',
      'Lifestyle International',
    ],
    lloyd: ['Lloyd', 'lloyd electric'],
    makemytrip: ['MakeMyTrip', 'makemytrip india'],
    manchesterUnited: ['Manchester United'],
    marksSpencer: ['Marks & Spencer', 'marks spencer', 'marks and spencer'],
    marriott: ['Marriott', 'marriott bonvoy'],
    maxFashion: ['Max Fashion'],
    mcdonalds: [
      'McDonald\'s',
      'hardcastle restaurants',
      'connaught plaza restaurants',
    ],
    meesho: ['Meesho', 'fashnear technologies'],
    metroCashCarry: [
      'Metro Cash & Carry',
      'Metro Cash Carry',
      'Metro Cash and Carry',
      'Metro Cash n Carry',
      'Metro Wholesale',
    ],
    miaTitan: ['Mia by Tanishq'],
    mobikwik: ['MobiKwik', 'one mobikwik systems'],
    moreRetail: ['More Retail', 'More Supermarket'],
    mumbaiMetro: ['Mumbai Metro', 'Mumbai Metro One', 'MMOPL'],
    myntra: ['Myntra', 'myntra designs'],
    naturesbasket: ['Nature\'s Basket'],
    nayara: ['Nayara Energy', 'nayara'],
    netflix: ['Netflix', 'netflix entertainment services india', 'Netflix.com'],
    netmeds: ['Netmeds'],
    nobroker: ['NoBroker', 'nobroker technologies'],
    notion: ['notion'],
    nykaa: ['Nykaa', 'fsn e commerce'],
    ola: ['Ola', 'ola cabs', 'ani technologies'],
    openai: ['OpenAI LLC', 'ChatGPT', 'ChatGPT Plus', 'ChatGPT Pro', 'openai'],
    oyo: ['OYO', 'oyo rooms', 'oyo hotels', 'oravel stays'],
    patanjali: ['Patanjali', 'patanjali ayurved', 'patanjali mega store'],
    paytm: [
      'Paytm Mall',
      'Paytm Movies',
      'paytm insider',
      'paytm movie',
      'Paytm',
      'One97 Communications',
    ],
    pepperfry: ['Pepperfry'],
    pharmeasy: ['PharmEasy', 'api holdings'],
    pizzaHut: ['Pizza Hut'],
    policybazaar: ['PolicyBazaar', 'pb fintech'],
    postcardHotels: [
      'The Postcard Hotels',
      'postcard hotels',
      'the postcard hotel',
      'postcard hotels and resorts',
    ],
    practo: ['Practo', 'practo technologies'],
    primeVideo: ['Amazon Prime', 'Amazon Prime Video', 'primevideo'],
    pvr: ['PVR INOX', 'pvr', 'pvr cinemas', 'inox leisure'],
    qatarAirways: ['Qatar Airways'],
    rapido: ['Rapido', 'roppen transportation'],
    redbus: ['redBus'],
    relianceDigital: ['Reliance Digital'],
    relianceRetail: [
      'Reliance Market',
      'Reliance Retail',
      'reliance retail ltd',
      'reliance retail limited',
      'Reliance Smart',
      'reliance smart bazaar',
      'reliance smart superstore',
      'reliance fresh',
      'Reliance Trends',
    ],
    samsung: [
      'Samsung',
      'samsung india',
      'samsung india electronics',
      'samsung shop',
      'samsung electronics',
    ],
    shellFuel: ['Shell', 'shell india', 'shell fuel'],
    shoppersStop: ['Shoppers Stop', 'shoppers stop limited'],
    singaporeAirlines: ['Singapore Airlines', 'krisflyer'],
    skinn: ['Skinn by Titan'],
    snapdeal: ['Snapdeal'],
    snitch: ['SNITCH', 'snitch lifestyle'],
    sonata: ['Sonata Watches'],
    sonyIndia: ['Sony India', 'sony center', 'sony centre'],
    sonyLiv: ['Sony LIV'],
    spar: ['SPAR Hypermarket'],
    spaceship: ['Spaceship'],
    spicejet: ['SpiceJet'],
    spotify: ['Spotify', 'spotify india', 'Spotify Premium'],
    starbucks: ['Starbucks', 'tata starbucks'],
    starHealth: ['Star Health', 'Star Health Insurance'],
    steam: ['steam', 'steampowered'],
    swiggy: [
      'Swiggy Instamart',
      'instamart',
      'Swiggy',
      'bundl technologies',
      'swiggy limited',
      'Swiggy Dineout',
      'dineout',
      'Bundl Technologies Private Limited',
      'Bundl Technologies Pvt. Ltd.',
      'Swiggy One',
    ],
    taj: [
      'Taj Hotels (IHCL)',
      'taj hotels',
      'ihcl',
      'indian hotels',
      'taj hotels resorts',
      'indian hotels company limited',
    ],
    taneira: ['Taneira'],
    tanishq: ['Tanishq'],
    tata1Mg: ['Tata 1mg', '1mg technologies'],
    tataCliq: [
      'Tata CLiQ',
      'tata unistore',
      'tata cliq luxury',
      'tata cliq fashion',
    ],
    tataNeu: ['Tata Neu', 'tata digital'],
    tataPlay: ['Tata Play', 'tata sky'],
    tataPower: [
      'Tata Power',
      'Tata Power Delhi Distribution',
      'Tata Power Mumbai',
    ],
    tira: ['Tira Beauty'],
    titanCompany: ['Titan Company', 'world of titan'],
    titanEye: ['Titan Eye+', 'titan eye', 'titan eyeplus'],
    tvs: ['TVS Motor'],
    uber: [
      'Uber',
      'uber india',
      'uber india systems',
      'Uber Trip',
      'Uber Eats',
    ],
    udemy: ['Udemy'],
    unacademy: ['Unacademy'],
    urbanCompany: ['Urban Company', 'urbanclap'],
    urbanLadder: ['Urban Ladder'],
    vijaySales: ['Vijay Sales'],
    vistara: ['Vistara', 'Tata SIA Airlines'],
    vivanta: ['Vivanta'],
    vivo: ['Vivo', 'vivo india', 'vivo mobile', 'vivo e shop'],
    vodafoneIdea: [
      'Vi (Vodafone Idea)',
      'vodafone idea',
      'vodafone',
      'Vi',
      'Vodafone Idea Limited',
    ],
    yatra: ['Yatra', 'yatra online'],
    youtube: ['YouTube Premium', 'YouTube', 'YouTube Music'],
    zepto: ['Zepto', 'kiranakart technologies'],
    zomato: [
      'Zomato',
      'zomato limited',
      'zomato media',
      'Zomato Dining',
      'Zomato Gold',
    ],
    zoya: ['Zoya', 'zoya by titan'],
  };
}
