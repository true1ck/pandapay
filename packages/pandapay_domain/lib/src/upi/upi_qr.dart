import '../money/money.dart';

/// B2/B3 — everything decoded from a scanned UPI QR (`upi://pay?...`).
/// [isLikelyP2P] is intentionally conservative: no MCC normally requires a
/// business confirmation, except for a small set of provider-managed merchant
/// VPA formats whose local part is a reliable QR signal.
class ParsedUpiQr {
  final String
  pa; // payee VPA — the only required field for a usable payment target
  final String? pn; // payee name
  final String? mc; // merchant category code
  final Money? am; // amount, when the QR pre-fills one
  final String cu; // currency, defaults to INR when absent
  final bool isLikelyP2P;

  /// NPCI UPI Linking Spec merchant fields, carried through verbatim from the
  /// scanned QR to the outgoing `upi://pay` intent so a verified-merchant QR
  /// keeps its signature/reference and doesn't degrade to an "unverified
  /// payee" prompt in the UPI app. Absent on a plain personal/static QR.
  final String? tr; // transaction reference id (merchant order id)
  final String? tn; // transaction note
  final String? mode; // e.g. "02" for a static QR
  final String? orgid; // acquiring org id
  final String? sign; // merchant QR signature (base64)

  /// Allowlisted UPI query parameters we do not interpret for ranking, but
  /// must not silently drop when the QR is handed to a UPI app.
  final Map<String, String> extraParams;

  const ParsedUpiQr({
    required this.pa,
    this.pn,
    this.mc,
    this.am,
    this.cu = 'INR',
    required this.isLikelyP2P,
    this.tr,
    this.tn,
    this.mode,
    this.orgid,
    this.sign,
    this.extraParams = const {},
  });
}

/// A provider label is not the merchant identity. A QR may contain `pn=Paytm`
/// while the PSP resolves the VPA to a real shop during its own preview.
bool isGenericUpiProviderLabel(String? value) {
  final normalized = (value ?? '').toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return {
    'paytm',
    'phonepe',
    'googlepay',
    'gpay',
    'bhim',
    'upi',
  }.contains(normalized);
}

/// Some provider-managed merchant QRs omit `mc`, but their VPA still carries
/// a narrow merchant signal. Ordinary handles continue through the
/// business-payment confirmation gate.
bool isProviderManagedMerchantVpa(String value) {
  final local = value.trim().toLowerCase().split('@').first;
  return local.startsWith('paytmqr') ||
      local.startsWith('phonepeq') ||
      local.startsWith('gpayq') ||
      local.startsWith('merchantqr') ||
      local.startsWith('qrcode');
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
  final parsedAm = amRaw == null || amRaw.isEmpty
      ? null
      : double.tryParse(amRaw);
  final am = parsedAm == null ? null : Money.fromRupees(parsedAm);
  final mc = uri.queryParameters['mc'];

  String? nonEmpty(String key) {
    final v = uri.queryParameters[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  const known = {
    'pa',
    'pn',
    'mc',
    'am',
    'cu',
    'tr',
    'tn',
    'mode',
    'orgid',
    'sign',
  };
  // Only forward documented UPI deep-link fields that this parser does not
  // otherwise interpret. Arbitrary QR query keys are not passed to a payment
  // app because a QR is attacker-controlled input.
  // Preserve standard NPCI fields that this model does not use for ranking.
  // A proxy scanner must not silently strip merchant identity, references,
  // minimum-amount, or acquiring metadata before handing the request to a
  // PSP app.
  const passThrough = {
    'ver',
    'purpose',
    'url',
    'category',
    'mam',
    'tid',
    'mid',
    'msid',
    'mtid',
    'refUrl',
    'invoiceNo',
    'invoiceDate',
    'gstIn',
    'gstBrkUp',
  };
  final extras = <String, String>{};
  for (final entry in uri.queryParameters.entries) {
    if (!known.contains(entry.key) &&
        passThrough.contains(entry.key) &&
        entry.value.isNotEmpty) {
      extras[entry.key] = entry.value;
    }
  }

  return ParsedUpiQr(
    pa: pa,
    pn: uri.queryParameters['pn'],
    mc: (mc == null || mc.isEmpty) ? null : mc,
    am: am,
    cu: uri.queryParameters['cu'] ?? 'INR',
    isLikelyP2P:
        (mc == null || mc.isEmpty) && !isProviderManagedMerchantVpa(pa),
    tr: nonEmpty('tr'),
    tn: nonEmpty('tn'),
    mode: nonEmpty('mode'),
    orgid: nonEmpty('orgid'),
    sign: nonEmpty('sign'),
    extraParams: extras,
  );
}

/// B3.6 — "Pay with [card]" builds this and hands it to url_launcher (or, on
/// Android, to a specific UPI app via the platform channel).
///
/// Query params are added in a fixed, stable order (pa, pn, am, cu, then the
/// optional merchant fields) so the output is deterministic and
/// test-comparable, matching every UPI app's documented query-string
/// contract (order itself has no semantic meaning to a UPI app, but a stable
/// order makes this function's output reproducible for tests and logs).
///
/// The merchant fields ([mc], [tr], [tn], [mode], [orgid], [sign]) are only
/// emitted when non-null/non-empty — a plain personal QR produces exactly
/// the same 4-param string it always did.
String buildUpiPayUri({
  required String pa,
  String? pn,
  Money? am,
  String cu = 'INR',
  String? mc,
  String? tr,
  String? tn,
  String? mode,
  String? orgid,
  String? sign,
  Map<String, String> extraParams = const {},
}) {
  final params = <String>['pa=${Uri.encodeComponent(pa)}'];
  if (pn != null && pn.isNotEmpty) params.add('pn=${Uri.encodeComponent(pn)}');
  if (am != null) params.add('am=${am.rupees.toStringAsFixed(2)}');
  params.add('cu=${Uri.encodeComponent(cu)}');
  void addIf(String key, String? value) {
    if (value != null && value.isNotEmpty) {
      params.add('$key=${Uri.encodeComponent(value)}');
    }
  }

  addIf('mc', mc);
  addIf('tr', tr);
  addIf('tn', tn);
  addIf('mode', mode);
  addIf('orgid', orgid);
  addIf('sign', sign);
  for (final entry in extraParams.entries) {
    if (entry.key.isNotEmpty && entry.value.isNotEmpty) {
      params.add(
        '${Uri.encodeComponent(entry.key)}=${Uri.encodeComponent(entry.value)}',
      );
    }
  }
  return 'upi://pay?${params.join('&')}';
}
