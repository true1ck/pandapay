import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/local_sms_parser.dart';
import '../../data/needs_review_repository.dart';

sealed class NeedsReviewEntryGroup {
  const NeedsReviewEntryGroup();
}

class SingleReviewGroup extends NeedsReviewEntryGroup {
  final NeedsReviewItem item;
  const SingleReviewGroup(this.item);
}

class BundleReviewGroup extends NeedsReviewEntryGroup {
  final String key;
  final String title;
  final String subtitle;
  final List<NeedsReviewItem> items;
  final Money? totalAmount;
  final DateTime earliest;
  final DateTime latest;
  final bool isPayLater;

  const BundleReviewGroup({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.items,
    required this.totalAmount,
    required this.earliest,
    required this.latest,
    this.isPayLater = false,
  });
}

/// Cleans an SMS sender string by removing carrier prefixes (e.g. `AX-`, `VM-`)
/// and route suffixes (e.g. `-S`, `-T`, `-P`).
String cleanReviewSender(String sender) {
  var s = sender.trim();
  s = s.replaceFirst(RegExp(r'^[a-zA-Z]{2}-'), '');
  s = s.replaceFirst(RegExp(r'-[a-zA-Z]$'), '');
  return s.trim();
}

/// Normalizes SMS body text into a template pattern by masking dynamic entities
/// (URLs, amounts, dates, times, accounts, standalone long numbers).
String normalizeBodyForClustering(String body) {
  var text = body;
  text = text.replaceAll(
    RegExp(
      r'https?://[^\s]+|www\.[^\s]+|\b(?:bit\.ly|tinyurl\.com|t\.co|amzn\.to|rb\.gy|goo\.gl)/[^\s]+',
      caseSensitive: false,
    ),
    '<URL>',
  );
  text = text.replaceAll(
    RegExp(
      r'(?:₹|\brs\.?|\binr|\$)\s*[\d,]+(?:\.\d+)?|\b[\d,]+(?:\.\d+)?\s*(?:₹|rs\.?|inr)\b',
      caseSensitive: false,
    ),
    '<AMT>',
  );
  text = text.replaceAll(
    RegExp(
      r'\b\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}\b|'
      r'\b\d{1,2}(?:st|nd|rd|th)?\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s*(?:\d{2,4})?\b|'
      r'\b\d{1,2}[-/.](?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[-/.]\d{2,4}\b|'
      r'\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s*\d{2,4})?\b',
      caseSensitive: false,
    ),
    '<DATE>',
  );
  text = text.replaceAll(
    RegExp(r'\b\d{1,2}:\d{2}(?::\d{2})?(?:\s*[ap]m|\s*hrs)?\b', caseSensitive: false),
    '<TIME>',
  );
  text = text.replaceAll(
    RegExp(
      r'\b(?:a/c|account|card|acct)\s*(?:no\.?|number)?\s*(?:ending\s+(?:in|with)?\s*)?[:#]?\s*(?:[xX*]*\d{3,4}|\d{3,4})\b|'
      r'\b[xX*]{2,}\d{3,4}\b|'
      r'\bending\s+(?:in\s+|with\s+)?\d{3,4}\b',
      caseSensitive: false,
    ),
    '<ACCT>',
  );
  text = text.replaceAll(RegExp(r'\b\d{4,}\b'), '<NUM>');
  return text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
}

/// Identifies whether the review item is a Pay Later (BNPL) drawdown.
bool isPayLaterReviewItem(NeedsReviewItem item) {
  if (item.kind == NeedsReviewKind.payLaterDrawdown) return true;
  return NeedsReviewRepository.isPayLaterDrawdown(item.body, sender: item.sender);
}

/// Identifies the human-friendly name of the Pay Later provider.
String detectPayLaterProvider(String body, String sender) {
  final text = body.toLowerCase();
  final s = sender.toLowerCase();
  if (s.contains('axio') || text.contains('axio') || text.contains('amazon pay later')) {
    return 'Amazon Pay Later (Axio)';
  }
  if (s.contains('lazypay') || s.contains('lazypy') || text.contains('lazypay')) {
    return 'LazyPay';
  }
  if (s.contains('simpl') || text.contains('simpl')) {
    return 'Simpl';
  }
  if (s.contains('flipkart') || text.contains('flipkart pay later')) {
    return 'Flipkart Pay Later';
  }
  if (s.contains('postpe') || text.contains('postpe')) {
    return 'PostPe';
  }
  final clean = cleanReviewSender(sender);
  if (clean.isNotEmpty) {
    return '$clean Pay Later';
  }
  return 'Pay Later';
}

/// Computes the grouping key for a review item.
String computeClusterKey(NeedsReviewItem item) {
  final clean = cleanReviewSender(item.sender);
  if (isPayLaterReviewItem(item)) {
    final provider = detectPayLaterProvider(item.body, item.sender);
    final keyPart = clean.isNotEmpty
        ? clean.toLowerCase()
        : provider.toLowerCase().replaceAll(RegExp(r'\s+'), '_');
    return 'paylater_$keyPart';
  }
  final template = normalizeBodyForClustering(item.body);
  return '${clean.toLowerCase()}_$template';
}

/// Extracts a monetary value from an SMS body, checking receipt amounts and standard patterns.
Money? extractItemAmount(String body) {
  final parsed = LocalSmsParser.extractReceiptAmount(body);
  if (parsed != null) return parsed;
  final match = RegExp(
    r'(?:₹|\brs\.?|\binr|\$)\s*([\d,]+(?:\.\d{1,2})?)|\b([\d,]+(?:\.\d{1,2})?)\s*(?:₹|rs\.?|inr)\b',
    caseSensitive: false,
  ).firstMatch(body);
  if (match == null) return null;
  final raw = (match.group(1) ?? match.group(2))?.replaceAll(',', '');
  if (raw == null) return null;
  final numMatch = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(raw);
  if (numMatch == null) return null;
  final paise =
      int.parse(numMatch[1]!) * 100 +
      int.parse((numMatch[2] ?? '').padRight(2, '0'));
  return paise > 0 ? Money.fromPaise(paise) : null;
}

/// Formats the date range of a review bundle for badge display.
String formatBundleDateSpan(DateTime earliest, DateTime latest) {
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

/// Clusters review items into single items and repeating bundles.
List<NeedsReviewEntryGroup> clusterReviewItems(List<NeedsReviewItem> items) {
  if (items.isEmpty) return const [];

  final groupsByKey = <String, List<NeedsReviewItem>>{};
  for (final item in items) {
    final key = computeClusterKey(item);
    (groupsByKey[key] ??= []).add(item);
  }

  final result = <NeedsReviewEntryGroup>[];

  for (final entry in groupsByKey.entries) {
    final groupItems = List<NeedsReviewItem>.from(entry.value)
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));

    if (groupItems.length == 1) {
      result.add(SingleReviewGroup(groupItems.first));
    } else {
      final firstItem = groupItems.first;
      final isPayLater = isPayLaterReviewItem(firstItem);
      final clean = cleanReviewSender(firstItem.sender);

      final String title;
      final String subtitle;
      if (isPayLater) {
        title = detectPayLaterProvider(firstItem.body, firstItem.sender);
        subtitle = 'Credit line drawdowns (billed in monthly AutoPay)';
      } else {
        title = clean.isNotEmpty ? '$clean messages' : 'Repeating messages';
        subtitle = 'Repeating message pattern';
      }

      int totalPaise = 0;
      bool hasAnyAmount = false;
      for (final item in groupItems) {
        final amt = extractItemAmount(item.body);
        if (amt != null) {
          totalPaise += amt.paise;
          hasAnyAmount = true;
        }
      }
      final totalAmount = hasAnyAmount ? Money.fromPaise(totalPaise) : null;

      final earliest = groupItems
          .map((i) => i.receivedAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final latest = groupItems
          .map((i) => i.receivedAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);

      result.add(
        BundleReviewGroup(
          key: entry.key,
          title: title,
          subtitle: subtitle,
          items: groupItems,
          totalAmount: totalAmount,
          earliest: earliest,
          latest: latest,
          isPayLater: isPayLater,
        ),
      );
    }
  }

  result.sort((a, b) {
    final aDate = switch (a) {
      SingleReviewGroup(:final item) => item.receivedAt,
      BundleReviewGroup(:final latest) => latest,
    };
    final bDate = switch (b) {
      SingleReviewGroup(:final item) => item.receivedAt,
      BundleReviewGroup(:final latest) => latest,
    };
    final byDate = bDate.compareTo(aDate);
    if (byDate != 0) return byDate;
    final aKey = switch (a) {
      SingleReviewGroup(:final item) => item.id,
      BundleReviewGroup(:final key) => key,
    };
    final bKey = switch (b) {
      SingleReviewGroup(:final item) => item.id,
      BundleReviewGroup(:final key) => key,
    };
    return aKey.compareTo(bKey);
  });

  return result;
}
