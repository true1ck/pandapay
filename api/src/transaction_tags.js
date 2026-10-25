const crypto = require('node:crypto');
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const normalizeName = (value) => value.trim().replace(/\s+/g, ' ').toLowerCase();
function bad(message, status = 400) { return Object.assign(new Error(message), { status }); }
function validId(value) { if (typeof value !== 'string' || !UUID.test(value)) throw bad('Invalid tag or transaction ID'); return value; }
function validateChange(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw bad('Invalid tag change');
  validId(body?.mutationId);
  if (!['upsert_tag', 'assign', 'unassign', 'merge_tags'].includes(body.operation)) throw bad('Invalid tag operation');
  const at = typeof body.updatedAt === 'string' ? new Date(body.updatedAt) : new Date(NaN);
  if (!body.updatedAt || !Number.isFinite(at.getTime()) || at.getTime() > Date.now() + 300000) throw bad('Invalid change timestamp');
  if (body.operation === 'upsert_tag') {
    if (!body.tag || typeof body.tag !== 'object' || Array.isArray(body.tag)) throw bad('Invalid tag definition');
    validId(body.tag?.id);
    if (typeof body.tag.name !== 'string' || !body.tag.name.trim() || body.tag.name.trim().length > 60) throw bad('Tag names must be 1–60 characters');
    if (body.tag.color != null && (typeof body.tag.color !== 'string' || !/^#[\da-f]{6}$/i.test(body.tag.color))) throw bad('Invalid tag color');
    if (body.tag.archivedAt != null && (typeof body.tag.archivedAt !== 'string' || !Number.isFinite(Date.parse(body.tag.archivedAt)))) throw bad('Invalid archive timestamp');
  } else {
    validId(body.tagId);
    if (body.operation === 'merge_tags') {
      validId(body.targetTagId);
      if (body.tagId === body.targetTagId) throw bad('Choose a different target tag');
    } else if (typeof body.transactionId !== 'string' || (!UUID.test(body.transactionId) && !/^local-outbox:[a-f0-9-]{36}$/i.test(body.transactionId))) throw bad('Invalid transaction ID');
  }
  return at.toISOString();
}

async function resolveTransaction(client, profileId, id) {
  let result;
  if (id.startsWith('local-outbox:')) {
    const mutation = validId(id.slice(13));
    const key = crypto.createHash('sha256').update(`${profileId}\0manual\0client-mutation\0${mutation}`).digest('hex');
    result = await client.query('SELECT id FROM transactions WHERE profile_id=$1 AND source_key=$2', [profileId, key]);
  } else {
    result = await client.query('SELECT id FROM transactions WHERE profile_id=$1 AND id=$2', [profileId, validId(id)]);
  }
  if (!result.rows.length) throw bad('Transaction is not synced yet', 409);
  let canonical = result.rows[0].id;
  const visited = new Set();
  while (!visited.has(canonical)) {
    visited.add(canonical);
    const alias = await client.query('SELECT transaction_id FROM transaction_tag_transaction_aliases WHERE profile_id=$1 AND old_id=$2', [profileId, canonical]);
    if (!alias.rows.length) break;
    canonical = alias.rows[0].transaction_id;
  }
  return canonical;
}

async function applyChange(client, profileId, body) {
  const at = validateChange(body);
  // Serialize tag changes for an account, so replay checks and merges are atomic.
  await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`tags:${profileId}`]);
  const seen = await client.query('SELECT 1 FROM transaction_tag_mutations WHERE profile_id=$1 AND mutation_id=$2', [profileId, body.mutationId]);
  if (seen.rows.length) return;
  if (body.operation === 'upsert_tag') {
    const tag = body.tag;
    await client.query(`INSERT INTO transaction_tags(id,profile_id,name,normalized_name,color,archived_at,updated_at)
      VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(id) DO UPDATE SET name=excluded.name,normalized_name=excluded.normalized_name,
        color=excluded.color,archived_at=excluded.archived_at,updated_at=excluded.updated_at
      WHERE transaction_tags.profile_id=$2 AND transaction_tags.updated_at<=excluded.updated_at RETURNING id`,
    [tag.id, profileId, tag.name.trim().replace(/\s+/g, ' '), normalizeName(tag.name), tag.color || null, tag.archivedAt || null, at]);
  } else {
    const ids = body.operation === 'merge_tags' ? [body.tagId, body.targetTagId] : [body.tagId];
    const owned = await client.query('SELECT id FROM transaction_tags WHERE profile_id=$1 AND id=ANY($2::uuid[])', [profileId, ids]);
    if (owned.rows.length !== ids.length) throw bad('Tag not found', 404);
    if (body.operation === 'merge_tags') {
      await client.query(`INSERT INTO transaction_tag_links(profile_id,transaction_id,tag_id,updated_at)
        SELECT profile_id,transaction_id,$3,GREATEST(updated_at,$4::timestamptz) FROM transaction_tag_links
        WHERE profile_id=$1 AND tag_id=$2 AND deleted_at IS NULL
        ON CONFLICT(profile_id,transaction_id,tag_id) DO UPDATE SET deleted_at=NULL,updated_at=excluded.updated_at
        WHERE transaction_tag_links.updated_at<=excluded.updated_at`, [profileId, body.tagId, body.targetTagId, at]);
      await client.query('UPDATE transaction_tag_links SET deleted_at=$3,updated_at=$3 WHERE profile_id=$1 AND tag_id=$2 AND updated_at<=$3', [profileId, body.tagId, at]);
      await client.query('UPDATE transaction_tags SET archived_at=$3,updated_at=$3 WHERE profile_id=$1 AND id=$2 AND updated_at<=$3', [profileId, body.tagId, at]);
    } else {
      const transactionId = await resolveTransaction(client, profileId, body.transactionId);
      await client.query(`INSERT INTO transaction_tag_links(profile_id,transaction_id,tag_id,updated_at,deleted_at)
        VALUES($1,$2,$3,$4,$5) ON CONFLICT(profile_id,transaction_id,tag_id) DO UPDATE
        SET updated_at=excluded.updated_at,deleted_at=excluded.deleted_at WHERE transaction_tag_links.updated_at<=excluded.updated_at`,
      [profileId, transactionId, body.tagId, at, body.operation === 'unassign' ? at : null]);
    }
  }
  await client.query('INSERT INTO transaction_tag_mutations(profile_id,mutation_id) VALUES($1,$2) ON CONFLICT DO NOTHING', [profileId, body.mutationId]);
}

async function attachTags(client, profileId, transactions) {
  if (!transactions.length) return transactions;
  const result = await client.query(`SELECT l.transaction_id,t.id,t.name,t.color,t.archived_at AS "archivedAt",t.updated_at AS "updatedAt"
    FROM transaction_tag_links l JOIN transaction_tags t ON t.id=l.tag_id AND t.profile_id=l.profile_id
    WHERE l.profile_id=$1 AND l.transaction_id=ANY($2::uuid[]) AND l.deleted_at IS NULL ORDER BY t.name`, [profileId, transactions.map((t) => t.id)]);
  const byTransaction = new Map();
  for (const { transaction_id, ...tag } of result.rows) {
    if (!byTransaction.has(transaction_id)) byTransaction.set(transaction_id, []);
    byTransaction.get(transaction_id).push(tag);
  }
  return transactions.map((row) => ({ ...row, tags: byTransaction.get(row.id) || [] }));
}

async function mergeTransactionTags(client, profileId, oldId, keptId) {
  await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`tags:${profileId}`]);
  await client.query(`INSERT INTO transaction_tag_links(profile_id,transaction_id,tag_id,updated_at)
    SELECT profile_id,$3,tag_id,updated_at FROM transaction_tag_links WHERE profile_id=$1 AND transaction_id=$2 AND deleted_at IS NULL
    ON CONFLICT(profile_id,transaction_id,tag_id) DO UPDATE SET deleted_at=NULL,updated_at=GREATEST(transaction_tag_links.updated_at,excluded.updated_at)
    WHERE transaction_tag_links.updated_at<=excluded.updated_at`, [profileId, oldId, keptId]);
  await client.query(`INSERT INTO transaction_tag_transaction_aliases(profile_id,old_id,transaction_id) VALUES($1,$2,$3)
    ON CONFLICT(profile_id,old_id) DO UPDATE SET transaction_id=excluded.transaction_id`, [profileId, oldId, keptId]);
}

async function importTagNames(client, profileId, transactionId, names) {
  if (!Array.isArray(names)) throw bad('Imported tags must be an array');
  if (names.length > 50) throw bad('At most 50 tags can be imported for one transaction');
  const uniqueNames = new Map();
  for (const name of names) {
    if (typeof name !== 'string' || !name.trim() || name.trim().length > 60) throw bad('Invalid imported tag');
    const normalized = normalizeName(name);
    if (!uniqueNames.has(normalized)) uniqueNames.set(normalized, name.trim());
  }
  await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`tags:${profileId}`]);
  for (const [normalizedName, name] of uniqueNames) {
    const found = await client.query('SELECT id FROM transaction_tags WHERE profile_id=$1 AND normalized_name=$2 AND archived_at IS NULL', [profileId, normalizedName]);
    const id = found.rows[0]?.id || crypto.randomUUID();
    if (!found.rows.length) {
      await client.query(`INSERT INTO transaction_tags(id,profile_id,name,normalized_name) VALUES($1,$2,$3,$4)
        ON CONFLICT(profile_id,normalized_name) WHERE archived_at IS NULL DO NOTHING`, [id, profileId, name, normalizedName]);
    }
    const tag = await client.query('SELECT id FROM transaction_tags WHERE profile_id=$1 AND normalized_name=$2 AND archived_at IS NULL', [profileId, normalizedName]);
    await client.query(`INSERT INTO transaction_tag_links(profile_id,transaction_id,tag_id) VALUES($1,$2,$3)
      ON CONFLICT DO NOTHING`, [profileId, transactionId, tag.rows[0].id]);
  }
}

function readTagFilter(query) {
  const ids = Array.isArray(query.tagIds) ? query.tagIds : typeof query.tagIds === 'string' ? query.tagIds.split(',').filter(Boolean) : [];
  if (ids.length > 50 || ids.some((id) => !UUID.test(id))) throw bad('Invalid tag filter');
  const untagged = query.untagged === 'true' || query.untagged === true;
  if (untagged && ids.length) throw bad('Choose tags or untagged, not both');
  return { tagIds: [...new Set(ids)], untagged };
}
// Scope the existing, tested report queries before aggregation. The CTE retains
// every transaction column and uses EXISTS, so multiple tags never multiply money.
function tagQueryClient(client, profileId, filter) {
  if (!filter.tagIds.length && !filter.untagged) return client;
  return { query(sql, values = []) {
    if (!/\btransactions\b/i.test(sql)) return client.query(sql, values);
    const params = [...values, profileId, filter.tagIds];
    const profile = `$${values.length + 1}`;
    const tags = `$${values.length + 2}`;
    const exists = `EXISTS(SELECT 1 FROM transaction_tag_links l WHERE l.profile_id=${profile} AND l.transaction_id=tx.id AND l.deleted_at IS NULL${filter.untagged ? '' : ` AND l.tag_id=ANY(${tags}::uuid[])`})`;
    // Always bind both parameters (including an empty uuid array).
    const predicate = `${filter.untagged ? 'NOT ' : ''}${exists} AND (${tags}::uuid[] IS NOT NULL)`;
    const cte = `__tagged_transactions AS (SELECT * FROM transactions tx WHERE tx.profile_id=${profile} AND ${predicate})`;
    const scoped = sql.replace(/\btransactions\b/g, '__tagged_transactions');
    return client.query(/^\s*WITH\b/i.test(scoped) ? scoped.replace(/^\s*WITH\b/i, `WITH ${cte},`) : `WITH ${cte} ${scoped}`, params);
  } };
}

function registerTagRoutes(app, { requireAuth, withUserClient }) {
  app.get('/transaction-tags', requireAuth, async (req, res) => {
    try {
      const payload = await withUserClient(req.userId, async (client) => {
        await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`tags:${req.userId}`]);
        const tags = await client.query('SELECT id,name,color,archived_at AS "archivedAt",updated_at AS "updatedAt" FROM transaction_tags WHERE profile_id=$1 ORDER BY name', [req.userId]);
        const links = await client.query(`SELECT l.transaction_id AS "transactionId",l.tag_id AS "tagId" FROM transaction_tag_links l
          WHERE l.profile_id=$1 AND l.deleted_at IS NULL AND NOT EXISTS(SELECT 1 FROM transaction_tag_transaction_aliases a WHERE a.profile_id=l.profile_id AND a.old_id=l.transaction_id)`, [req.userId]);
        const aliases = await client.query('SELECT old_id AS "localId",transaction_id AS "transactionId" FROM transaction_tag_transaction_aliases WHERE profile_id=$1', [req.userId]);
        return { tags: tags.rows, assignments: links.rows, aliases: aliases.rows };
      });
      res.json(payload);
    } catch (error) { res.status(error.status || 500).json({ error: error.status ? error.message : 'internal_error' }); }
  });
  app.post('/transaction-tags/changes', requireAuth, async (req, res) => {
    try {
      validateChange(req.body);
      await withUserClient(req.userId, (client) => applyChange(client, req.userId, req.body));
      res.json({ ok: true });
    } catch (error) {
      res.status(error.code === '23505' ? 409 : error.status || 500).json({ error: error.code === '23505' ? 'A tag with that name already exists. Rename the local tag and retry.' : error.status ? error.message : 'internal_error' });
    }
  });
}
module.exports = { registerTagRoutes, validateChange, attachTags, applyChange, mergeTransactionTags, importTagNames, readTagFilter, tagQueryClient, normalizeName };
