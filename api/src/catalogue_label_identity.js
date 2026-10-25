'use strict';

// Versioned, locale-independent label identity. Preserve the displayed value.
// Fold ASCII A-Z and collapse/trim ASCII whitespace (space, TAB, LF, VT, FF,
// CR). Other Unicode bytes, accents and every non-label rule field stay exact.
// Null and empty string remain different; no SQL/JS locale-dependent lower().
const FORMAT = 'pandapay-catalogue-label-identity-v1';
const SQL_TEMPLATE = "pg_catalog.translate(pg_catalog.btrim(pg_catalog.regexp_replace(%s, E'[\\011-\\015 ]+', ' ', 'g')), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')";
function normalizeCatalogueLabel(value) {
  if (value === null) return null;
  if (typeof value !== 'string') throw new TypeError('Catalogue label must be text or null');
  return value.replace(/[\u0009-\u000d ]+/g, ' ').replace(/^ | $/g, '')
    .replace(/[A-Z]/g, c => String.fromCharCode(c.charCodeAt(0) + 32));
}
function labelIdentitySql(alias = 't') {
  if (typeof alias !== 'string' || !/^[a-z_][a-z0-9_]{0,62}$/.test(alias)) throw Error('Invalid catalogue alias');
  return SQL_TEMPLATE.replace('%s', `"${alias}"."label"`);
}
const RULE_KEYS = Object.freeze({
  cap_rules: Object.freeze(['card_product_id','reward_rule_id','category_id','benefit_kind','label','measure','period','cap_value','post_cap_unit','post_cap_rate','resets_on_day']),
  card_benefits: Object.freeze(['card_product_id','kind','label','description','quota_count','quota_period','network_program','value_estimate_inr','conditions']),
});
module.exports={FORMAT,normalizeCatalogueLabel,labelIdentitySql,RULE_KEYS,SQL_TEMPLATE};
