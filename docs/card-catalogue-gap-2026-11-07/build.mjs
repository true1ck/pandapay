// Builds validated universal-format drafts from the hand-sourced overlays in cards/*.mjs.
//   node docs/card-catalogue-gap-2026-11-07/build.mjs
// Output: drafts/<slug>.json, drafts-all.json (array, importer input), build-report.json.
// Nothing here touches a database. Every record stays status=draft.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { deepMerge } from './lib.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const PIPELINE = process.env.CARD_PIPELINE || path.resolve(here, '../../../CardPipeline');
const { validateUniversalRecord, UNIVERSAL_TEMPLATE } = await import(pathToFileURL(path.join(PIPELINE, 'src/schema.js')).href);

const readJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const bases = new Map();
const novDrafts = readJson(path.join(PIPELINE, 'data/catalogue-gaps/2026-11-05/new-cards-universal.json'));
for (const r of novDrafts) bases.set(r.card_product.slug, r);
const octDrafts = readJson(path.join(PIPELINE, 'data/catalogue-gaps/2026-10-17/normalized-drafts.json'));
for (const d of octDrafts) { const r = d.final || d; if (r?.card_product?.slug) bases.set(r.card_product.slug, r); }

const emptyFrom = (t) => Array.isArray(t) ? [] : (t && typeof t === 'object') ? Object.fromEntries(Object.entries(t).map(([k, v]) => [k, emptyFrom(v)])) : null;
const blank = () => { const r = emptyFrom(UNIVERSAL_TEMPLATE); r.$schema = UNIVERSAL_TEMPLATE.$schema; r.schema_version = UNIVERSAL_TEMPLATE.schema_version; r._notes = UNIVERSAL_TEMPLATE._notes; return r; };

const only = process.argv.slice(2);
const files = fs.readdirSync(path.join(here, 'cards')).filter((f) => f.endsWith('.mjs'));
fs.mkdirSync(path.join(here, 'drafts'), { recursive: true });

const report = []; const all = [];
for (const f of files) {
  const { cards } = await import(pathToFileURL(path.join(here, 'cards', f)).href);
  for (const [slug, overlay] of Object.entries(cards)) {
    if (only.length && !only.includes(slug)) continue;
    const base = bases.get(slug) ? JSON.parse(JSON.stringify(bases.get(slug))) : blank();
    if (!bases.get(slug)) { base.card_product.slug = slug; }
    const merged = deepMerge(base, overlay);
    merged.card_product.slug = slug;
    merged.card_product.status = 'draft';
    merged.card_product.verified_at = null;
    const v = validateUniversalRecord(merged);
    const row = {
      slug, name: merged.card_product.name, file: f, valid: v.valid, issues: v.issues.slice(0, 12),
      rules: merged.reward_rules.length, earn_rules: merged.reward_rules.filter((r) => r.evaluation_type !== 'exclusion').length,
      exclusions: merged.reward_rules.filter((r) => r.evaluation_type === 'exclusion').length,
      caps: merged.cap_rules.length, milestones: merged.fee_waiver_and_milestones.spend_milestones.length,
      benefits: merged.lifestyle_and_network_benefits.length,
      joining: merged.card_product.joining_fee_inr, annual: merged.card_product.annual_fee_inr, network: merged.card_product.network,
      open_questions: (merged.additional_data.items.find((i) => i.key === 'research_provenance')?.value.open_questions || []).length,
    };
    report.push(row);
    if (v.valid) { fs.writeFileSync(path.join(here, 'drafts', `${slug}.json`), JSON.stringify(merged, null, 2) + '\n'); all.push(merged); }
  }
}
// Re-read every draft on disk so drafts-all.json is always the full set, not just this run.
const onDisk = fs.readdirSync(path.join(here, 'drafts')).filter((f) => f.endsWith('.json')).sort().map((f) => readJson(path.join(here, 'drafts', f)));
fs.writeFileSync(path.join(here, 'drafts-all.json'), JSON.stringify(onDisk, null, 2) + '\n');
fs.writeFileSync(path.join(here, 'build-report.json'), JSON.stringify({ built_at: new Date().toISOString(), cards: report }, null, 2) + '\n');
for (const r of report) console.log(`${r.valid ? 'OK ' : 'BAD'} ${r.slug.padEnd(34)} rules=${r.earn_rules}+${r.exclusions}excl caps=${r.caps} ms=${r.milestones} ben=${r.benefits} fee=${r.joining}/${r.annual} net=${r.network} open=${r.open_questions}${r.valid ? '' : '\n    ' + r.issues.join('\n    ')}`);
console.log(`drafts on disk: ${onDisk.length}`);
