'use strict';

// Persistence for the rule service (WP-09): a Postgres store and an in-memory
// store with the same interface. Services call `store.tx(userId, async (s) => ...)`;
// everything in the callback commits or rolls back together. The in-memory store
// is for tests and mirrors the SQL semantics of the migration.

const { readSettings, mergeSettings } = require('./settings');

const utcDay = (d) => d.toISOString().slice(0, 10);

// ---------- Postgres ----------

const ruleRow = (r) => ({ ruleId: r.rule_id, version: r.version, status: r.status, family: r.family, senders: r.senders, body: r.body, createdBy: r.created_by, createdAt: r.created_at });
const cohortRow = (r) => ({ ruleId: r.rule_id, version: r.version, cohort: r.cohort, startedAt: r.started_at, pausedAt: r.paused_at, pauseReason: r.pause_reason });
const bundleRow = (r) => ({
  bundleVersion: r.bundle_version, manifest: r.manifest, sha256: r.sha256, signature: r.signature, keyId: r.key_id,
  cohort: r.cohort, goldenReport: r.golden_report, status: r.status, publishedBy: r.published_by, createdAt: r.created_at, body: r.body,
  servedBody: r.served_body || null,
});

class PgTx {
  constructor(client) { this.c = client; }
  async lock() { await this.c.query("SELECT pg_advisory_xact_lock(hashtext('sms_v2_rules'))"); }
  async allRules() { return (await this.c.query('SELECT * FROM sms_v2_rules ORDER BY rule_id, version')).rows.map(ruleRow); }
  async ruleVersions(ruleId) { return (await this.c.query('SELECT * FROM sms_v2_rules WHERE rule_id = $1 ORDER BY version', [ruleId])).rows.map(ruleRow); }
  async getRule(ruleId, version) {
    const r = await this.c.query('SELECT * FROM sms_v2_rules WHERE rule_id = $1 AND version = $2', [ruleId, version]);
    return r.rows[0] ? ruleRow(r.rows[0]) : null;
  }
  async insertRule(r) {
    await this.c.query(
      'INSERT INTO sms_v2_rules (rule_id, version, status, family, senders, body, created_by) VALUES ($1,$2,$3,$4,$5,$6,$7)',
      [r.ruleId, r.version, r.status, r.family, r.senders, JSON.stringify(r.body), r.createdBy],
    );
  }
  // Only status, family, senders and body may change (draft replacement, activation, pause).
  async updateRule(r) {
    await this.c.query(
      'UPDATE sms_v2_rules SET status = $3, family = $4, senders = $5, body = $6 WHERE rule_id = $1 AND version = $2',
      [r.ruleId, r.version, r.status, r.family, r.senders, JSON.stringify(r.body)],
    );
  }
  async allCohorts() { return (await this.c.query('SELECT * FROM sms_v2_rule_cohorts')).rows.map(cohortRow); }
  async addCohort(c) {
    await this.c.query(
      'INSERT INTO sms_v2_rule_cohorts (rule_id, version, cohort, started_at) VALUES ($1,$2,$3,$4) ON CONFLICT (rule_id, version, cohort) DO NOTHING',
      [c.ruleId, c.version, c.cohort, c.startedAt],
    );
  }
  async pauseVersion(ruleId, version, reason, at) {
    await this.c.query(
      'UPDATE sms_v2_rule_cohorts SET paused_at = $4, pause_reason = $3 WHERE rule_id = $1 AND version = $2 AND paused_at IS NULL',
      [ruleId, version, reason, at],
    );
  }
  async getParts() {
    const out = {};
    for (const r of (await this.c.query('SELECT part, body FROM sms_v2_bundle_parts')).rows) out[r.part] = r.body;
    return out;
  }
  async setParts(parts) {
    for (const [k, v] of Object.entries(parts)) {
      await this.c.query(
        'INSERT INTO sms_v2_bundle_parts (part, body) VALUES ($1,$2) ON CONFLICT (part) DO UPDATE SET body = EXCLUDED.body, updated_at = now()',
        [k, JSON.stringify(v)],
      );
    }
  }
  // Draft tables for the shared bundle parts: category rules and shop-name aliases.
  async _draft(table,id,revision) {
    const result=await this.c.query(`SELECT draft_id AS id,revision,status,body,created_by AS "createdBy",created_at AS "createdAt" FROM ${table} WHERE draft_id=$1 AND ($2::int IS NULL OR revision=$2) ORDER BY revision DESC LIMIT 1`,[id,revision ?? null]);
    return result.rows[0] || null;
  }
  async _previousPublished(table,id,revision) {
    const result=await this.c.query(`SELECT draft_id AS id,revision,body FROM ${table} WHERE draft_id=$1 AND revision<$2 AND status='published' ORDER BY revision DESC LIMIT 1`,[id,revision]);
    return result.rows[0] || null;
  }
  async _listDrafts(table) { return (await this.c.query(`SELECT DISTINCT ON (draft_id) draft_id AS id,revision,status,body,created_by AS "createdBy",created_at AS "createdAt" FROM ${table} ORDER BY draft_id,revision DESC LIMIT 500`)).rows; }
  async _insertDraft(table,row) { await this.c.query(`INSERT INTO ${table}(draft_id,revision,status,body,created_by,created_at) VALUES($1,$2,$3,$4,$5,$6)`,[row.id,row.revision,row.status,JSON.stringify(row.body),row.createdBy,row.createdAt]); }
  async _publishDraft(table,id,revision) { await this.c.query(`UPDATE ${table} SET status='published' WHERE draft_id=$1 AND revision=$2`,[id,revision]); }
  categoryDraft(id,revision) { return this._draft('sms_v2_category_drafts',id,revision); }
  previousPublishedCategoryDraft(id,revision) { return this._previousPublished('sms_v2_category_drafts',id,revision); }
  listCategoryDrafts() { return this._listDrafts('sms_v2_category_drafts'); }
  insertCategoryDraft(row) { return this._insertDraft('sms_v2_category_drafts',row); }
  publishCategoryDraft(id,revision) { return this._publishDraft('sms_v2_category_drafts',id,revision); }
  aliasDraft(id,revision) { return this._draft('sms_v2_alias_drafts',id,revision); }
  previousPublishedAliasDraft(id,revision) { return this._previousPublished('sms_v2_alias_drafts',id,revision); }
  listAliasDrafts() { return this._listDrafts('sms_v2_alias_drafts'); }
  insertAliasDraft(row) { return this._insertDraft('sms_v2_alias_drafts',row); }
  publishAliasDraft(id,revision) { return this._publishDraft('sms_v2_alias_drafts',id,revision); }
  async maxBundleVersion() { return (await this.c.query('SELECT COALESCE(MAX(bundle_version), 0) AS v FROM sms_v2_bundles')).rows[0].v; }
  async latestBundle(cohort) {
    const r = await this.c.query("SELECT * FROM sms_v2_bundles WHERE cohort = $1 AND status = 'active' ORDER BY bundle_version DESC LIMIT 1", [cohort]);
    return r.rows[0] ? bundleRow(r.rows[0]) : null;
  }
  async setBundleStatus(version, status) { await this.c.query('UPDATE sms_v2_bundles SET status = $2 WHERE bundle_version = $1', [version, status]); }
  async insertBundle(b) {
    await this.c.query(
      `INSERT INTO sms_v2_bundles (bundle_version, manifest, sha256, signature, key_id, cohort, golden_report, status, published_by, created_at, body, served_body, served_expires_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
      [b.bundleVersion, JSON.stringify(b.manifest), b.sha256, b.signature, b.keyId, b.cohort,
        b.goldenReport ? JSON.stringify(b.goldenReport) : null, b.status, b.publishedBy, b.createdAt, JSON.stringify(b.body),
        b.servedBody ? JSON.stringify(b.servedBody) : null, b.servedBody ? b.servedBody.expiresAt : null],
    );
  }
  // Maintenance job only: replace the pre-signed copy the public API serves (LO-09).
  async setServedBundle(version, signed) {
    await this.c.query('UPDATE sms_v2_bundles SET served_body = $2, served_expires_at = $3 WHERE bundle_version = $1',
      [version, JSON.stringify(signed), signed.expiresAt]);
  }
  async listBundles(limit = 100) {
    // Summary columns only. `body` and `served_body` are whole rule sets (about 2.8 MB each, two per bundle), so reading
    // them here made the list take over 5 s and fail once there were a few bundles. The list never returns them.
    return (await this.c.query(
      'SELECT bundle_version, manifest, sha256, signature, key_id, cohort, golden_report, status, published_by, created_at FROM sms_v2_bundles ORDER BY bundle_version DESC LIMIT $1',
      [limit],
    )).rows.map(bundleRow);
  }
  async audit(a) {
    await this.c.query(
      'INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason) VALUES ($1,$2,$3,NULL,$4,$5,$6)',
      [a.adminId || null, a.action, a.entity || 'sms_v2_rule', a.before == null ? null : JSON.stringify(a.before), a.after == null ? null : JSON.stringify(a.after), a.reason || null],
    );
  }
  async isTester() { return (await this.c.query('SELECT pandapay.sms_v2_is_tester() AS t')).rows[0].t === true; }
  // Console settings (settings.js); the hourly job wants current values, not a cached read.
  async settings() { return readSettings(this.c, { force: true }); }
  // Learning signals older than the retention setting (days) are deleted by the hourly job.
  async pruneSignals(days) {
    const r = await this.c.query('DELETE FROM sms_v2_learning_signals WHERE last_at < now() - make_interval(days => $1::int)', [days]);
    return r.rowCount;
  }
  async phoneBundle(cohort) {
    // The pre-signed copy (`body` is null until the maintenance job has signed it).
    const r = await this.c.query('SELECT * FROM pandapay.sms_v2_latest_served_bundle($1)', [cohort]);
    return r.rows[0] ? { bundleVersion: r.rows[0].bundle_version, body: r.rows[0].body, sha256: r.rows[0].sha256 } : null;
  }
  async recordRuleStats(_profileId, day, appVersion, stats) {
    const rows = stats.map((x) => ({ rule_id: x.ruleId, rule_version: x.ruleVersion, hits: x.hits, to_review: x.toReview, corrected: x.corrected }));
    await this.c.query('SELECT pandapay.sms_v2_record_rule_stats($1::date, $2, $3::jsonb)', [day, appVersion, JSON.stringify(rows)]);
  }
  async rollupRuleStats() { return (await this.c.query('SELECT pandapay.sms_v2_rollup_rule_stats() AS n')).rows[0].n; }
  async statsByDay(day) {
    const result = await this.c.query(
      `SELECT day,rule_id,rule_version,SUM(hits)::bigint AS hits,
        SUM(to_review)::bigint AS to_review,SUM(corrected)::bigint AS corrected
       FROM sms_v2_rule_stats_daily WHERE day >= $1::date
       GROUP BY day,rule_id,rule_version ORDER BY day,rule_id,rule_version`, [day]);
    return result.rows.map(row => ({day:row.day instanceof Date ? utcDay(row.day) : String(row.day),
      ruleId:row.rule_id,version:row.rule_version,hits:Number(row.hits),
      toReview:Number(row.to_review),corrected:Number(row.corrected)}));
  }
  async statsSince(day) {
    const r = await this.c.query(
      `SELECT rule_id, rule_version, SUM(hits)::bigint AS hits, SUM(to_review)::bigint AS to_review,
              SUM(corrected)::bigint AS corrected, MAX(devices) AS devices
         FROM sms_v2_rule_stats_daily WHERE day >= $1::date GROUP BY rule_id, rule_version`, [day],
    );
    return r.rows.map((x) => ({ ruleId: x.rule_id, version: x.rule_version, hits: Number(x.hits), toReview: Number(x.to_review), corrected: Number(x.corrected), devices: x.devices }));
  }
}

function createPgStore({ withUserClient }) {
  return { tx: (userId, fn) => withUserClient(userId, (client) => fn(new PgTx(client))) };
}

// ---------- in-memory ----------

class MemoryStore {
  constructor() {
    this.state = { rules: [], cohorts: [], bundles: [], parts: {}, audit: [], testers: new Set(), profileStats: [], daily: [], categoryDrafts: [], aliasDrafts: [], settings: [] };
    this.today = () => utcDay(new Date());
  }
  async tx(_userId, fn) {
    const snapshot = structuredClone({ ...this.state, testers: [...this.state.testers] });
    try {
      return await fn(this.view());
    } catch (e) {
      this.state = { ...snapshot, testers: new Set(snapshot.testers) };
      throw e;
    }
  }
  view() {
    const st = () => this.state;
    const self = this;
    const drafts = (name) => ({
      latest(id,revision) { const rows=st()[name].filter(row=>row.id===id && (revision===undefined || row.revision===revision)).sort((a,b)=>b.revision-a.revision); return structuredClone(rows[0] || null); },
      previousPublished(id,revision) { return structuredClone(st()[name].filter(row=>row.id===id&&row.revision<revision&&row.status==='published').sort((a,b)=>b.revision-a.revision)[0] || null); },
      list() { return structuredClone(st()[name].filter(row=>!st()[name].some(other=>other.id===row.id && other.revision>row.revision))); },
      insert(row) { st()[name].push(structuredClone(row)); },
      publish(id,revision) { st()[name].find(row=>row.id===id && row.revision===revision).status='published'; },
    });
    return {
      async lock() {},
      async allRules() { return structuredClone(st().rules); },
      async ruleVersions(id) { return structuredClone(st().rules.filter((r) => r.ruleId === id).sort((a, b) => a.version - b.version)); },
      async getRule(id, v) { const r = st().rules.find((x) => x.ruleId === id && x.version === v); return r ? structuredClone(r) : null; },
      async insertRule(r) {
        if (st().rules.some((x) => x.ruleId === r.ruleId && x.version === r.version)) throw Object.assign(new Error('duplicate rule version'), { code: '23505' });
        st().rules.push({ ...structuredClone(r), createdAt: r.createdAt || new Date().toISOString() });
      },
      async updateRule(r) {
        const i = st().rules.findIndex((x) => x.ruleId === r.ruleId && x.version === r.version);
        if (i < 0) throw new Error('missing rule');
        st().rules[i] = { ...st().rules[i], status: r.status, family: r.family, senders: r.senders, body: structuredClone(r.body) };
      },
      async allCohorts() { return structuredClone(st().cohorts); },
      async addCohort(c) {
        if (!st().cohorts.some((x) => x.ruleId === c.ruleId && x.version === c.version && x.cohort === c.cohort)) {
          st().cohorts.push({ ruleId: c.ruleId, version: c.version, cohort: c.cohort, startedAt: c.startedAt, pausedAt: null, pauseReason: null });
        }
      },
      async pauseVersion(id, v, reason, at) {
        for (const c of st().cohorts) if (c.ruleId === id && c.version === v && !c.pausedAt) { c.pausedAt = at; c.pauseReason = reason; }
      },
      async getParts() { return structuredClone(st().parts); },
      async setParts(parts) { Object.assign(st().parts, structuredClone(parts)); },
      async categoryDraft(id,revision) { return drafts('categoryDrafts').latest(id,revision); },
      async previousPublishedCategoryDraft(id,revision) { return drafts('categoryDrafts').previousPublished(id,revision); },
      async listCategoryDrafts() { return drafts('categoryDrafts').list(); },
      async insertCategoryDraft(row) { drafts('categoryDrafts').insert(row); },
      async publishCategoryDraft(id,revision) { drafts('categoryDrafts').publish(id,revision); },
      async aliasDraft(id,revision) { return drafts('aliasDrafts').latest(id,revision); },
      async previousPublishedAliasDraft(id,revision) { return drafts('aliasDrafts').previousPublished(id,revision); },
      async listAliasDrafts() { return drafts('aliasDrafts').list(); },
      async insertAliasDraft(row) { drafts('aliasDrafts').insert(row); },
      async publishAliasDraft(id,revision) { drafts('aliasDrafts').publish(id,revision); },
      async maxBundleVersion() { return st().bundles.reduce((m, b) => Math.max(m, b.bundleVersion), 0); },
      async latestBundle(cohort) {
        const rows = st().bundles.filter((b) => b.cohort === cohort && b.status === 'active').sort((a, b) => b.bundleVersion - a.bundleVersion);
        return rows[0] ? structuredClone(rows[0]) : null;
      },
      async setBundleStatus(v, status) { st().bundles.find((b) => b.bundleVersion === v).status = status; },
      async insertBundle(b) { st().bundles.push(structuredClone(b)); },
      async setServedBundle(v, signed) { st().bundles.find((b) => b.bundleVersion === v).servedBody = structuredClone(signed); },
      async listBundles(limit = 100) { return structuredClone([...st().bundles].sort((a, b) => b.bundleVersion - a.bundleVersion).slice(0, limit)); },
      async audit(a) { st().audit.push(structuredClone({ ...a, at: new Date().toISOString() })); },
      async isTester(profileId) { return st().testers.has(profileId); },
      async settings() { return mergeSettings(st().settings); },
      async pruneSignals() { return 0; },
      async phoneBundle(cohort) {
        const b = await this.latestBundle(cohort);
        return b ? { bundleVersion: b.bundleVersion, body: b.servedBody || null, sha256: b.sha256 } : null;
      },
      async recordRuleStats(profileId, day, appVersion, stats) {
        const keep = utcDay(new Date(Date.parse(`${self.today()}T00:00:00Z`) - 2 * 86400000));
        if (day < keep) return;
        for (const x of stats) {
          const i = st().profileStats.findIndex((p) => p.day === day && p.profileId === profileId && p.ruleId === x.ruleId && p.version === x.ruleVersion && p.appVersion === appVersion);
          const row = { day, profileId, ruleId: x.ruleId, version: x.ruleVersion, appVersion, hits: x.hits, toReview: x.toReview, corrected: x.corrected };
          if (i >= 0) st().profileStats[i] = row; else st().profileStats.push(row);
        }
      },
      async rollupRuleStats() {
        const groups = new Map();
        for (const p of st().profileStats) {
          const k = [p.day, p.ruleId, p.version, p.appVersion].join('|');
          const g = groups.get(k) || { day: p.day, ruleId: p.ruleId, version: p.version, appVersion: p.appVersion, hits: 0, toReview: 0, corrected: 0, profiles: new Set() };
          g.hits += p.hits; g.toReview += p.toReview; g.corrected += p.corrected; g.profiles.add(p.profileId);
          groups.set(k, g);
        }
        for (const g of groups.values()) {
          const row = { day: g.day, ruleId: g.ruleId, version: g.version, appVersion: g.appVersion, hits: g.hits, toReview: g.toReview, corrected: g.corrected, devices: g.profiles.size };
          const i = st().daily.findIndex((d) => d.day === g.day && d.ruleId === g.ruleId && d.version === g.version && d.appVersion === g.appVersion);
          if (i >= 0) st().daily[i] = row; else st().daily.push(row);
        }
        const keep = utcDay(new Date(Date.parse(`${self.today()}T00:00:00Z`) - 2 * 86400000));
        st().profileStats = st().profileStats.filter((p) => p.day >= keep);
        return groups.size;
      },
      async statsByDay(day) {
        const rows = new Map();
        for (const item of st().daily.filter(row => row.day >= day)) {
          const key = [item.day,item.ruleId,item.version].join('|');
          const row = rows.get(key) || {day:item.day,ruleId:item.ruleId,version:item.version,hits:0,toReview:0,corrected:0};
          row.hits += item.hits;row.toReview += item.toReview;row.corrected += item.corrected;
          rows.set(key,row);
        }
        return [...rows.values()].sort((a,b) => a.day.localeCompare(b.day));
      },
      async statsSince(day) {
        const out = new Map();
        for (const d of st().daily) {
          if (d.day < day) continue;
          const k = `${d.ruleId}|${d.version}`;
          const o = out.get(k) || { ruleId: d.ruleId, version: d.version, hits: 0, toReview: 0, corrected: 0, devices: 0 };
          o.hits += d.hits; o.toReview += d.toReview; o.corrected += d.corrected; o.devices = Math.max(o.devices, d.devices);
          out.set(k, o);
        }
        return [...out.values()];
      },
    };
  }
}

module.exports = { createPgStore, MemoryStore, utcDay };
