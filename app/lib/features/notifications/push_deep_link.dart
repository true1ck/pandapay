/// A tapped push may only open a known in-app destination. The link comes from
/// the notification payload, so it is validated against an allow-list rather
/// than handed to the router as-is.
///
/// Currently allowed: a split group or friend, `/insights/splits/<uuid>`.
String? pushDeepLink(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  return _splitContext.hasMatch(value) ? value.toLowerCase() : null;
}

final _splitContext = RegExp(
  r'^/insights/splits/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
