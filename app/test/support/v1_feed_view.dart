import 'dart:convert';
import 'dart:io';

/// The real catalogue fixtures (db/fixtures/catalogue_v2_cards, WP7) and the
/// v1 feed they would be served as.
const _snapshotDir = '../db/fixtures/catalogue_v2_cards';

/// A fixture card as the v2 feed serves it (`GET /catalogue?schema=2`).
Map<String, dynamic> fixtureCard(String slug) =>
    (jsonDecode(File('$_snapshotDir/$slug.json').readAsStringSync())
            as Map<String, dynamic>)['card']
        as Map<String, dynamic>;

/// What `v_card_catalogue_export` (the v1 feed, migration 20261105120000)
/// serves for [card]: rules with `min_engine_version = 1` and not `info`,
/// caps with `min_engine_version = 1` whose rule(s) are visible (and no
/// `cap_rule_targets` column), milestones without `window_days`, and none of
/// the card-level v2 columns. Rows keep EVERY column (`to_jsonb`), including
/// the v2 ones (`rule_role`, `max_engine_version`, `cap_kind`, ...).
Map<String, dynamic> v1FeedView(Map<String, dynamic> card) {
  final rules = (card['reward_rules'] as List).cast<Map<String, dynamic>>();
  final hidden = {
    for (final r in rules)
      if ((r['min_engine_version'] ?? 1) != 1 || r['rule_role'] == 'info')
        r['id'],
  };
  final out = Map<String, dynamic>.of(card);
  for (final key in [
    'accrual_block_inr',
    'accrual_rounding',
    'cashback_rounding',
    'points_expiry_months',
    'model_status',
    'model_coverage',
    'unlock_rules',
    'redemption_options',
  ]) {
    out.remove(key);
  }
  out['reward_rules'] = [
    for (final r in rules)
      if (!hidden.contains(r['id'])) r,
  ];
  out['cap_rules'] = [
    for (final k in (card['cap_rules'] as List).cast<Map<String, dynamic>>())
      if ((k['min_engine_version'] ?? 1) == 1 &&
          !hidden.contains(k['reward_rule_id']) &&
          !((k['targets'] as List?) ?? const []).any(hidden.contains))
        Map<String, dynamic>.of(k)..remove('targets'),
  ];
  out['milestone_rules'] = [
    for (final m in ((card['milestone_rules'] as List?) ?? const []))
      if ((m as Map)['window_days'] == null) m,
  ];
  return out;
}

/// `{"cards": [...]}`: the v1 feed body.
Map<String, dynamic> v1FeedBody(List<String> slugs) => {
  'cards': [for (final slug in slugs) v1FeedView(fixtureCard(slug))],
};
