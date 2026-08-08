import '../money/money.dart';

/// B2/B3 — everything decoded from a scanned UPI QR (`upi://pay?...`).
/// [isLikelyP2P] mirrors ui-spec B3.4's "P2P QR detected (no mc, personal
/// VPA pattern)" edge case — this codebase has no merchant-vs-personal VPA
/// classifier, so the heuristic is deliberately just "no mc (merchant
/// category code) present", the one signal actually available from the QR
/// payload alone. Stated simplification, not a full VPA-pattern detector.
class ParsedUpiQr {
  final String pa; // payee VPA — the only required field for a usable payment target
  final String? pn; // payee name
  final String? mc; // merchant category code
  final Money? am; // amount, when the QR pre-fills one
  final String cu; // currency, defaults to INR when absent
  final bool isLikelyP2P;

  const ParsedUpiQr({
    required this.pa,
    this.pn,
    this.mc,
    this.am,
    this.cu = 'INR',
    required this.isLikelyP2P,
  });
}

/// Returns null for anything that isn't a `upi://pay` link, or that is one
/// but has no `pa` — B2's "That's not a UPI code" edge case and B3's "look
/// up VPA in crowdsource DB -> else ask user to pick a category" edge case
/// both start from this returning null/non-null.
ParsedUpiQr? parseUpiQrString(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'upi' || uri.host != 'pay') return null;

  final pa = uri.queryParameters['pa'];
  if (pa == null || pa.isEmpty) return null;

  // double.parse throws FormatException on malformed input, and this app
  // scans arbitrary (attacker-controlled) QR codes — an unparseable `am`
  // must not blow up the whole parse when every other field (pa, pn, mc)
  // is still perfectly usable. Treated the same as "no amount present"
  // (am: null) rather than rejecting the whole QR, since pa is the only
  // field this function's doc comment promises is required.
  final amRaw = uri.queryParameters['am'];
  final parsedAm = amRaw == null || amRaw.isEmpty ? null : double.tryParse(amRaw);
  final am = parsedAm == null ? null : Money.fromRupees(parsedAm);
  final mc = uri.queryParameters['mc'];

  return ParsedUpiQr(
    pa: pa,
    pn: uri.queryParameters['pn'],
    mc: (mc == null || mc.isEmpty) ? null : mc,
    am: am,
    cu: uri.queryParameters['cu'] ?? 'INR',
    isLikelyP2P: mc == null || mc.isEmpty,
  );
}

/// B3.6 — "Pay with [card]" builds this and hands it to url_launcher.
/// Query params are added in a fixed, stable order (pa, pn, am, cu) so the
/// output is deterministic and test-comparable, matching every UPI app's
/// documented query-string contract (order itself has no semantic meaning
/// to a UPI app, but a stable order makes this function's output
/// reproducible for tests and logs).
String buildUpiPayUri({required String pa, String? pn, Money? am, String cu = 'INR'}) {
  final params = <String>['pa=${Uri.encodeComponent(pa)}'];
  if (pn != null && pn.isNotEmpty) params.add('pn=${Uri.encodeComponent(pn)}');
  if (am != null) params.add('am=${am.rupees.toStringAsFixed(2)}');
  params.add('cu=${Uri.encodeComponent(cu)}');
  return 'upi://pay?${params.join('&')}';
}
