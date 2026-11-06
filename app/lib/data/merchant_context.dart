import 'package:pandapay_domain/pandapay_domain.dart';

/// Card Rewards Phase 1 (WP9) — builds a [RecommendationContext] for a spend
/// whose merchant is known only by name or VPA.
///
/// The merchant is resolved through the C5 directory and the context carries
/// its slug. When the caller has no MCC (most SMS and search paths), the
/// context takes the resolved merchant's **first** listed MCC (C8 D19c, D24f:
/// the directory orders the list most-specific first, so this is
/// deterministic). That lets an MCC-only exclusion on a v2 rule (a narrow
/// token such as fast food within dining) apply, rather than a missing MCC
/// proving nothing.
///
/// The platform is never guessed (C3.1): the context carries none.
RecommendationContext buildRecommendationContext({
  required MerchantDirectory directory,
  required Money amount,
  required TxnRail rail,
  String? categoryId,
  String? categorySlug,
  String? mcc,
  String? vpa,
  String? merchantName,
  bool isP2P = false,
  bool travelMode = false,
  DateTime? now,
}) {
  String? merchantSlug;
  var resolvedMcc = mcc;
  final hasName = merchantName != null && merchantName.trim().isNotEmpty;
  final hasVpa = vpa != null && vpa.trim().isNotEmpty;
  if (hasName || hasVpa) {
    final match = directory.resolve(
      merchantName: hasName ? merchantName : null,
      vpa: hasVpa ? vpa : null,
    );
    if (match != null) {
      merchantSlug = match.slug;
      if (resolvedMcc == null || resolvedMcc.isEmpty) {
        final listed = directory.merchant(match.slug)?.mcc ?? const <String>[];
        resolvedMcc = listed.isEmpty ? null : listed.first;
      }
    }
  }
  return RecommendationContext(
    amount: amount,
    categoryId: categoryId,
    categorySlug: categorySlug,
    mcc: resolvedMcc,
    vpa: vpa,
    rail: rail,
    isP2P: isP2P,
    travelMode: travelMode,
    merchantName: merchantName,
    merchantSlug: merchantSlug,
    now: now,
  );
}
