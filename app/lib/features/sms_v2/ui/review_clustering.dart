import 'package:intl/intl.dart';
import 'package:pandapay_domain/sms_v2_template.dart';

import '../providers/data_providers.dart';

/// Groups Needs review items into bundles of "the same thing", sorts them
/// into content types for the filter chips, and works out what a bundle may
/// honestly say about money.
///
/// Display-only: it never changes what is stored or what the pipeline does.
/// An action on a bundle is applied to each member by the existing review
/// controller, so a bundle is only ever made of items for which one answer is
/// safe:
///  * receipts and "same payment?" links are never merged (each one is a
///    question about one specific payment);
///  * everything else merges only on an exact match of review kind plus
///    message format (sender brand + message skeleton);
///  * messages from one Pay Later provider merge across formats, because they
///    are all drawdowns on the same credit line. Format-specific actions are
///    then withheld ([ReviewBundle.uniformFormat] is false).

/// What a message says it is, read from its wording. A hint for labels,
/// filters and totals, never a decision about the money.
enum ReviewContent {
  declined('Declined or failed'),
  security('Security or OTP notice'),
  promotion('Promotion'),
  mandate('Mandate or AutoPay'),
  bill('Bill or due date'),
  balance('Balance update'),
  credit('Money in'),
  debit('Money out'),
  other('Other');

  const ReviewContent(this.label);
  final String label;

  /// Only real movements have an amount worth adding up. A declined payment,
  /// an upcoming mandate or a balance never moved the money it mentions.
  bool get summable => this == credit || this == debit;
}

final _declined = RegExp(
  r'\b(declined|failed|failure|unsuccessful|not successful|rejected|could not be processed|insufficient (?:balance|funds))\b',
  caseSensitive: false,
);
final _security = RegExp(
  r'\botp\b|verification code|one[- ]?time password|do not share|never share|\bcvv\b|login (?:alert|attempt)|password',
  caseSensitive: false,
);
final _promotion = RegExp(
  r'pre-?approved|\boffer\b|apply now|limited time|t&c|terms apply|click here|congratulations|\bwin\b|\bcoupon\b',
  caseSensitive: false,
);
final _mandate = RegExp(
  r'\bmandate\b|auto-?pay|auto[- ]?debit|standing instruction|\bnach\b|e-?mandate',
  caseSensitive: false,
);
final _bill = RegExp(
  r'\bbill\b|statement|minimum (?:amount )?due|total (?:amount )?due|due date|payment due|outstanding',
  caseSensitive: false,
);
final _credit = RegExp(
  r'\b(credited|received|refund(?:ed)?|cashback|deposited|reversed|reversal)\b',
  caseSensitive: false,
);
final _debit = RegExp(
  r'\b(debited|spent|purchase|paid|withdrawn|deducted|charged|txn of|transaction of|used for|sent to|transferred|payment of)\b|\bsent\s+(?:rs\.?|inr|₹)',
  caseSensitive: false,
);
final _balance = RegExp(
  r'\b(?:avl|available|a/c|account) ?(?:bal|balance)\b|\bbalance\b',
  caseSensitive: false,
);

/// The content type of a message body. Order matters: a declined payment that
/// also says "Not you? Call" is declined, not a security notice.
ReviewContent classifyReviewContent(String body) {
  if (_declined.hasMatch(body)) return ReviewContent.declined;
  if (_security.hasMatch(body)) return ReviewContent.security;
  if (_mandate.hasMatch(body)) return ReviewContent.mandate;
  if (_bill.hasMatch(body)) return ReviewContent.bill;
  if (_promotion.hasMatch(body) &&
      !_debit.hasMatch(body) &&
      !_credit.hasMatch(body)) {
    return ReviewContent.promotion;
  }
  final isCredit = _credit.hasMatch(body);
  final isDebit = _debit.hasMatch(body);
  if (isDebit && !isCredit) return ReviewContent.debit;
  if (isCredit && !isDebit) return ReviewContent.credit;
  // Both verbs ("debited ... will be credited"): the first one is the event.
  if (isDebit && isCredit) {
    final d = _debit.firstMatch(body)!.start;
    final c = _credit.firstMatch(body)!.start;
    return d < c ? ReviewContent.debit : ReviewContent.credit;
  }
  // A balance notice only mentions a balance. A message with an amount before
  // its "Avl Bal" is describing something that happened to the money in a
  // wording we do not know, so it must not be filed as a harmless balance
  // update (where it would sit under the alerts that can be dismissed in
  // bulk).
  final balance = _balance.firstMatch(body);
  if (balance != null) {
    final amount = _amount.firstMatch(body);
    if (amount == null || amount.start > balance.start) {
      return ReviewContent.balance;
    }
  }
  return ReviewContent.other;
}

class ReviewBundle {
  const ReviewBundle({
    required this.key,
    required this.kind,
    required this.items,
    required this.payLaterProvider,
    required this.uniformFormat,
    required this.content,
    required this.totalMinor,
    required this.earliest,
    required this.latest,
  });

  final String key;
  final String kind;

  /// Newest first.
  final List<LocalReviewItem> items;
  final String? payLaterProvider;

  /// True when every member shares one message format, so "Fix" and "Correct"
  /// (which teach or confirm a format) mean the same thing for all of them.
  final bool uniformFormat;

  /// What the messages say they are; null for a bundle that mixes formats.
  final ReviewContent? content;

  /// Sum of the printed amounts. Null unless every member has an amount, all
  /// share one format, and the messages describe money that actually moved:
  /// mixed formats (a Pay Later bill beside its drawdowns) would count the
  /// same money twice, and a declined payment or an upcoming mandate never
  /// moved it.
  final int? totalMinor;
  final DateTime? earliest;
  final DateTime? latest;

  bool get isPayLater => payLaterProvider != null;
  bool get isSingle => items.length == 1;
}

/// Removes the carrier prefix and route suffix from an SMS sender id
/// (`AX-HDFCBK-S` becomes `HDFCBK`).
String cleanReviewSender(String sender) {
  var s = sender.trim();
  s = s.replaceFirst(RegExp(r'^[A-Za-z]{2}-'), '');
  s = s.replaceFirst(RegExp(r'-[A-Za-z]$'), '');
  return s.trim();
}

final _providers = <({String name, RegExp sender, RegExp body})>[
  (
    name: 'Amazon Pay Later (Axio)',
    sender: RegExp(r'axio', caseSensitive: false),
    body: RegExp(r'\baxio\b|amazon\s+pay\s+later', caseSensitive: false),
  ),
  (
    name: 'LazyPay',
    sender: RegExp(r'lazyp', caseSensitive: false),
    body: RegExp(r'\blazypay\b', caseSensitive: false),
  ),
  (
    name: 'Simpl',
    sender: RegExp(r'^simpl[a-z]?$', caseSensitive: false),
    body: RegExp(r'\bsimpl\b', caseSensitive: false),
  ),
  (
    name: 'Flipkart Pay Later',
    sender: RegExp(r'^(fkrt|flipkt|flipkart)', caseSensitive: false),
    body: RegExp(r'flipkart\s+pay\s+later', caseSensitive: false),
  ),
  (
    name: 'PostPe',
    sender: RegExp(r'postpe', caseSensitive: false),
    body: RegExp(r'\bpostpe\b', caseSensitive: false),
  ),
  (
    name: 'ZestMoney',
    sender: RegExp(r'zestm', caseSensitive: false),
    body: RegExp(r'\bzestmoney\b', caseSensitive: false),
  ),
];

const _bodyHeadChars = 60;

/// The Pay Later provider a message belongs to, or null. Word boundaries keep
/// "simple" or "axiom" from matching. A provider named deep inside another
/// sender's text ("pay later with LazyPay" in a bank offer) must not pull that
/// message into the bundle, so the body only counts when the provider opens
/// the message.
String? payLaterProviderOf(String sender, String body) {
  final clean = cleanReviewSender(sender);
  final head = body.length > _bodyHeadChars
      ? body.substring(0, _bodyHeadChars)
      : body;
  for (final p in _providers) {
    if (p.sender.hasMatch(clean) || p.body.hasMatch(head)) return p.name;
  }
  return null;
}

final _amount = RegExp(
  r'(?:₹|\brs\.?|\binr)\s*([\d,]+(?:\.\d{1,2})?)(?!\d)',
  caseSensitive: false,
);

/// The printed amount of a review item in paise, if it has one.
int? reviewItemAmountMinor(LocalReviewItem item) {
  final stored = item.payload['amountMinor'];
  if (stored is num && stored > 0) return stored.toInt();
  final body = item.message?.message.body;
  if (body == null) return null;
  final match = _amount.firstMatch(body);
  final raw = match?.group(1)?.replaceAll(',', '');
  final m = raw == null
      ? null
      : RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(raw);
  if (m == null) return null;
  final paise =
      int.parse(m[1]!) * 100 + int.parse((m[2] ?? '').padRight(2, '0'));
  return paise > 0 ? paise : null;
}

/// When the item's message arrived, if known.
DateTime? reviewItemDate(LocalReviewItem item) =>
    item.message?.message.receivedAt ??
    DateTime.tryParse(item.payload['receiptAt'] as String? ?? '');

/// Hashing a message is regex-heavy and a long inbox is regrouped on every
/// filter change, so each item's format is worked out once.
final Expando<String> _formatCache = Expando<String>('review format');

String _formatOf(LocalReviewItem item) =>
    _formatCache[item] ??= _computeFormat(item);

String _computeFormat(LocalReviewItem item) {
  final hash = item.payload['templateHash'];
  if (hash is String && hash.isNotEmpty) return hash;
  final m = item.message?.message;
  if (m == null) return item.id;
  return smsTemplateHash(smsTemplateBrand(m.sender), smsSkeleton(m.body));
}

final Expando<ReviewContent> _contentCache = Expando<ReviewContent>(
  'review content',
);

/// The content type of one item (other when its message is gone).
ReviewContent reviewContentOf(LocalReviewItem item) =>
    _contentCache[item] ??= item.message == null
    ? ReviewContent.other
    : classifyReviewContent(item.message!.message.body);

/// Kinds whose items are each a question about one specific payment.
const _neverMerged = {'receipt', 'link'};

/// Provider detection runs a dozen regexes, and the list is regrouped on every
/// chip tap, so it is worked out once per item (and kind, which never changes
/// for an item).
final Expando<String> _providerCache = Expando<String>('review provider');

String _providerOf(LocalReviewItem item, String kind) {
  if (kind == 'category' || _neverMerged.contains(kind)) return '';
  return _providerCache[item] ??= () {
    final m = item.message?.message;
    if (m == null) return '';
    return payLaterProviderOf(m.sender, m.body) ?? '';
  }();
}

/// The type chips on the Needs review screen. A Pay Later message belongs to
/// [payLater] whatever its review kind, matching how it is bundled.
enum ReviewFilter {
  all('All'),
  spends('Money out'),
  credits('Money in'),
  bills('Bills & mandates'),
  alerts('Declined & alerts'),
  other('Other'),
  payLater('Pay Later'),
  receipt('Receipts'),
  link('Same payment?'),
  category('Merchants'),
  account('Accounts');

  const ReviewFilter(this.label);
  final String label;
}

ReviewFilter reviewFilterOf(
  LocalReviewItem item,
  String Function(LocalReviewItem) kindOf,
) {
  final kind = kindOf(item);
  if (_providerOf(item, kind).isNotEmpty) return ReviewFilter.payLater;
  switch (kind) {
    case 'receipt':
      return ReviewFilter.receipt;
    case 'link':
      return ReviewFilter.link;
    case 'category':
      return ReviewFilter.category;
    case 'template':
      return switch (reviewContentOf(item)) {
        ReviewContent.debit => ReviewFilter.spends,
        ReviewContent.credit => ReviewFilter.credits,
        ReviewContent.bill || ReviewContent.mandate => ReviewFilter.bills,
        ReviewContent.declined ||
        ReviewContent.security ||
        ReviewContent.promotion ||
        ReviewContent.balance => ReviewFilter.alerts,
        ReviewContent.other => ReviewFilter.other,
      };
    default:
      return ReviewFilter.account;
  }
}

/// `2026-11` in the phone's time zone, or null when the date is unknown.
String? reviewMonthKey(LocalReviewItem item) {
  final d = reviewItemDate(item)?.toLocal();
  if (d == null) return null;
  return '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

/// "Nov 2026" for a key from [reviewMonthKey].
String reviewMonthLabel(String key) {
  final parts = key.split('-');
  return DateFormat(
    'MMM yyyy',
  ).format(DateTime(int.parse(parts[0]), int.parse(parts[1])));
}

/// Builds the bundles for one review list. [kindOf] is the screen's
/// `reviewKindOf`. The result is ordered newest bundle first, ties broken by
/// key so the order is stable between refreshes.
List<ReviewBundle> bundleReviewItems(
  List<LocalReviewItem> items,
  String Function(LocalReviewItem) kindOf,
) {
  final byKey = <String, List<LocalReviewItem>>{};
  final kinds = <String, String>{};
  final providers = <String, String?>{};
  for (final item in items) {
    final kind = kindOf(item);
    final provider = _providerOf(item, kind);
    final key = _neverMerged.contains(kind)
        ? '$kind:${item.id}'
        : provider.isNotEmpty
        ? '$kind:paylater:$provider'
        : '$kind:${_formatOf(item)}';
    (byKey[key] ??= []).add(item);
    kinds[key] = kind;
    providers[key] = provider.isEmpty ? null : provider;
  }
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final bundles = <ReviewBundle>[];
  for (final entry in byKey.entries) {
    final members = [...entry.value]
      ..sort((a, b) {
        final byDate = (reviewItemDate(b) ?? epoch).compareTo(
          reviewItemDate(a) ?? epoch,
        );
        return byDate != 0 ? byDate : a.id.compareTo(b.id);
      });
    final uniform = members.map(_formatOf).toSet().length == 1;
    final content = uniform ? reviewContentOf(members.first) : null;
    final amounts = members.map(reviewItemAmountMinor).toList();
    final dates = members.map(reviewItemDate).whereType<DateTime>().toList()
      ..sort();
    final canSum =
        uniform &&
        kinds[entry.key] == 'template' &&
        (content?.summable ?? false) &&
        members.length > 1 &&
        amounts.every((a) => a != null);
    bundles.add(
      ReviewBundle(
        key: entry.key,
        kind: kinds[entry.key]!,
        items: members,
        payLaterProvider: providers[entry.key],
        uniformFormat: uniform,
        content: content,
        totalMinor: canSum ? amounts.fold<int>(0, (sum, a) => sum + a!) : null,
        earliest: dates.firstOrNull,
        latest: dates.lastOrNull,
      ),
    );
  }
  bundles.sort((a, b) {
    final byDate = (b.latest ?? epoch).compareTo(a.latest ?? epoch);
    return byDate != 0 ? byDate : a.key.compareTo(b.key);
  });
  return bundles;
}

/// "Oct 2026", "Aug – Oct 2026" or "Dec 2025 – Feb 2026".
String formatBundleSpan(DateTime earliest, DateTime latest) {
  final e = earliest.toLocal();
  final l = latest.toLocal();
  if (e.year == l.year && e.month == l.month) {
    return DateFormat('MMM yyyy').format(l);
  }
  if (e.year == l.year) {
    return '${DateFormat('MMM').format(e)} – ${DateFormat('MMM yyyy').format(l)}';
  }
  return '${DateFormat('MMM yyyy').format(e)} – ${DateFormat('MMM yyyy').format(l)}';
}

/// ₹1,234 or ₹1,234.50 from paise.
String formatRupeesMinor(int minor) {
  final whole = minor ~/ 100;
  final paise = minor % 100;
  final text = NumberFormat.decimalPattern('en_IN').format(whole);
  return paise == 0 ? '₹$text' : '₹$text.${paise.toString().padLeft(2, '0')}';
}
