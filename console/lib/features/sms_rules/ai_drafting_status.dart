import 'settings_tab.dart' show aiSpendThisMonth;

/// What is stopping AI drafting right now, in plain words; empty when nothing is.
/// [settings] are the rows from GET settings, [metrics] the console metrics
/// payload, [jobs] the system status jobs (null when this admin cannot read them).
List<String> aiDraftingProblems({
  required List<Map<String, dynamic>> settings,
  required Map<String, dynamic>? metrics,
  required List<Map<String, dynamic>>? jobs,
  required DateTime now,
}) {
  Object? valueOf(String key) =>
      settings.where((row) => row['key'] == key).firstOrNull?['value'];
  final budget = (valueOf('ai_monthly_budget_usd') as num?)?.toDouble();
  return [
    if (valueOf('ai_enabled') == false) 'AI drafting is switched off',
    if (valueOf('ai_enabled') != false &&
        budget != null &&
        aiSpendThisMonth(metrics, now) >= budget)
      'This month\u2019s AI budget is used up',
    for (final job in jobs ?? const <Map<String, dynamic>>[])
      if (job['name'] == 'SMS AI drafts' &&
          (job['state'] == 'failed' || job['state'] == 'overdue'))
        'The AI drafts job is ${job['state']}',
  ];
}
