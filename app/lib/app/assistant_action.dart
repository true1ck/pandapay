/// Validated commands received from Android App Actions or a launcher
/// shortcut.  The assistant is only an entry point: it never receives
/// PandaPay's private spending data from this layer.
enum AssistantAction {
  spending,
  addSpend,
  dueDates,
  wallet,
  findCards,
  nearbyMerchants,
  scanUpi,
  bestCard,
}

final class AssistantRequest {
  final AssistantAction action;
  final String? period;
  final double? amount;
  final String? merchant;
  final String? category;

  const AssistantRequest({
    required this.action,
    this.period,
    this.amount,
    this.merchant,
    this.category,
  });
}

/// Parses only PandaPay's own assistant URI format.
///
/// App Actions use a custom scheme because fulfillment is an Android intent,
/// not a web request. Unknown paths and invalid values are ignored rather
/// than being passed to GoRouter as a raw location.
AssistantRequest? parseAssistantUri(Uri uri) {
  if (uri.scheme != 'pandapay' || uri.host != 'assistant') return null;
  final path = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;

  switch (path) {
    case 'spending':
      return AssistantRequest(
        action: AssistantAction.spending,
        period: _periodOrMonth(uri.queryParameters['period']),
      );
    case 'add-spend':
      final amount = _parseAmount(uri.queryParameters['amount']);
      if (amount != null && (amount <= 0 || amount > 100000000)) return null;
      return AssistantRequest(
        action: AssistantAction.addSpend,
        amount: amount,
        merchant: _cleanText(uri.queryParameters['merchant']),
        category: _cleanText(uri.queryParameters['category']),
      );
    case 'due-dates':
      return const AssistantRequest(action: AssistantAction.dueDates);
    case 'wallet':
      return const AssistantRequest(action: AssistantAction.wallet);
    case 'find-cards':
      return const AssistantRequest(action: AssistantAction.findCards);
    case 'nearby-merchants':
      return const AssistantRequest(action: AssistantAction.nearbyMerchants);
    case 'scan-upi':
      return const AssistantRequest(action: AssistantAction.scanUpi);
    case 'best-card':
      return const AssistantRequest(action: AssistantAction.bestCard);
    default:
      return null;
  }
}

String _periodOrMonth(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'week':
      return 'week';
    case 'quarter':
      return 'quarter';
    case 'year':
      return 'year';
    case 'month':
    default:
      return 'month';
  }
}

double? _parseAmount(String? raw) {
  if (raw == null) return null;
  final normalized = raw.replaceAll(',', '').replaceAll('₹', '').trim();
  return double.tryParse(normalized);
}

String? _cleanText(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty || value.length > 120) return null;
  return value;
}
