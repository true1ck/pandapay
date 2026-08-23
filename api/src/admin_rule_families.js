/**
 * AD-1.1.2 tabbed rule-family editor — the backend half.
 *
 * catalogue_screen.dart's own doc-comment flagged this as missing: only
 * reward_rules had a typed writer (PUT /admin/reward-rules/:id), leaving
 * cap/milestone/fee-waiver/benefits/forex/fuel/cycle/redemption as
 * read-only data baked into v_admin_card_catalogue_export. Each of those
 * eight families is a real Postgres table with its own column set — this
 * module is a small, declarative factory (not a generic "raw JSON
 * passthrough" writer, which this codebase deliberately avoids
 * everywhere else — see PUT /admin/reward-rules/:id's doc-comment) that
 * mounts the same typed-writer + admin_audit_log shape used by the
 * existing reward_rules/parser_patterns routes, once per family, driven
 * by an explicit field spec so every accepted value is still individually
 * validated by type/enum, never trusted as-is.
 *
 * Two shapes, matching the schema:
 *  - "list" families (cap_rules, milestone_rules, fee_waiver_rules,
 *    card_benefits, redemption_options): many rows per card ->
 *    POST create / PUT update / DELETE remove.
 *  - "singlePerCard" families (forex_rules, fuel_surcharge_rules,
 *    billing_cycle_rules): at most one row per card (schema-enforced via
 *    a UNIQUE card_product_id) -> PUT upserts by cardProductId, no
 *    separate create/delete route needed.
 */

function validateField(spec, value) {
  if (value === undefined || value === null) {
    if (spec.required) return `${spec.name} is required`;
    return null;
  }
  switch (spec.type) {
    case 'string':
      if (typeof value !== 'string') return `${spec.name} must be a string`;
      if (spec.required && !value.trim()) return `${spec.name} must not be empty`;
      return null;
    case 'number':
      if (typeof value !== 'number' || !Number.isFinite(value)) return `${spec.name} must be a number`;
      if (spec.min !== undefined && value < spec.min) return `${spec.name} must be >= ${spec.min}`;
      if (spec.max !== undefined && value > spec.max) return `${spec.name} must be <= ${spec.max}`;
      return null;
    case 'integer':
      if (!Number.isInteger(value)) return `${spec.name} must be an integer`;
      if (spec.min !== undefined && value < spec.min) return `${spec.name} must be >= ${spec.min}`;
      if (spec.max !== undefined && value > spec.max) return `${spec.name} must be <= ${spec.max}`;
      return null;
    case 'boolean':
      if (typeof value !== 'boolean') return `${spec.name} must be a boolean`;
      return null;
    case 'enum':
      if (!spec.values.includes(value)) return `${spec.name} must be one of ${spec.values.join('/')}`;
      return null;
    case 'jsonb':
      if (typeof value !== 'object' || Array.isArray(value)) return `${spec.name} must be an object`;
      return null;
    case 'stringArray':
      if (!Array.isArray(value) || value.some((v) => typeof v !== 'string' || !v.trim())) {
        return `${spec.name} must be an array of non-empty strings`;
      }
      return null;
    default:
      return null;
  }
}

/**
 * Mounts POST/PUT/DELETE (list) or PUT-upsert (singlePerCard) routes for
 * one rule family onto `app`. `withUserClient`/`requireAdmin` are passed
 * in rather than required here so this module has no circular dependency
 * on index.js.
 */
function registerRuleFamilyRoutes(app, { withUserClient, requireAdmin }, spec) {
  const { urlSegment, tableName, fields, auditEntity, singlePerCard } = spec;

  function validateBody(body, { partial }) {
    const errors = [];
    const values = {};
    for (const field of fields) {
      const present = Object.prototype.hasOwnProperty.call(body, field.name);
      if (!present) {
        if (!partial && field.required) errors.push(`${field.name} is required`);
        continue;
      }
      const err = validateField(field, body[field.name]);
      if (err) errors.push(err);
      else values[field.column] = field.type === 'jsonb' ? JSON.stringify(body[field.name]) : body[field.name];
    }
    return { errors, values };
  }

  if (singlePerCard) {
    // PUT /admin/<urlSegment>/by-card/:cardProductId — upsert (create if
    // absent, update if present). Schema's UNIQUE(card_product_id) makes
    // "exactly one row" a DB-enforced invariant, not just app convention.
    app.put(`/admin/${urlSegment}/by-card/:cardProductId`, requireAdmin, async (req, res) => {
      const { errors, values } = validateBody(req.body || {}, { partial: false });
      if (errors.length) return res.status(400).json({ error: errors.join('; ') });
      try {
        const result = await withUserClient(req.userId, async (client) => {
          const before = await client.query(
            `SELECT * FROM ${tableName} WHERE card_product_id = $1`,
            [req.params.cardProductId]
          );
          const insertCols = ['card_product_id', ...Object.keys(values)];
          const insertVals = [req.params.cardProductId, ...Object.values(values)];
          const placeholders = insertVals.map((_, i) => `$${i + 1}`);
          const updateSet = Object.keys(values).map((c) => `${c} = EXCLUDED.${c}`).join(', ');
          const upserted = await client.query(
            `INSERT INTO ${tableName} (${insertCols.join(', ')})
             VALUES (${placeholders.join(', ')})
             ON CONFLICT (card_product_id) DO UPDATE SET ${updateSet}
             RETURNING *`,
            insertVals
          );
          await client.query(
            `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
             VALUES ($1, $2, $3, $4, $5, $6, $7)`,
            [
              req.userId,
              `upsert_${auditEntity}`,
              tableName,
              upserted.rows[0].id,
              JSON.stringify(before.rows[0] || null),
              JSON.stringify(upserted.rows[0]),
              req.body.reason || null,
            ]
          );
          return upserted.rows[0];
        });
        res.json({ [auditEntity]: result });
      } catch (err) {
        console.error(`PUT /admin/${urlSegment}/by-card/:cardProductId error`, err);
        res.status(500).json({ error: 'internal_error' });
      }
    });
    return;
  }

  // POST /admin/<urlSegment> — create a new row for a card.
  app.post(`/admin/${urlSegment}`, requireAdmin, async (req, res) => {
    const { cardProductId, reason } = req.body || {};
    if (!cardProductId || typeof cardProductId !== 'string') {
      return res.status(400).json({ error: 'cardProductId is required' });
    }
    const { errors, values } = validateBody(req.body || {}, { partial: false });
    if (errors.length) return res.status(400).json({ error: errors.join('; ') });
    try {
      const result = await withUserClient(req.userId, async (client) => {
        const insertCols = ['card_product_id', ...Object.keys(values)];
        const insertVals = [cardProductId, ...Object.values(values)];
        const placeholders = insertVals.map((_, i) => `$${i + 1}`);
        const inserted = await client.query(
          `INSERT INTO ${tableName} (${insertCols.join(', ')}) VALUES (${placeholders.join(', ')}) RETURNING *`,
          insertVals
        );
        await client.query(
          `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
           VALUES ($1, $2, $3, $4, $5, $6)`,
          [req.userId, `create_${auditEntity}`, tableName, inserted.rows[0].id, JSON.stringify(inserted.rows[0]), reason || null]
        );
        return inserted.rows[0];
      });
      res.status(201).json({ [auditEntity]: result });
    } catch (err) {
      console.error(`POST /admin/${urlSegment} error`, err);
      res.status(500).json({ error: 'internal_error' });
    }
  });

  // PUT /admin/<urlSegment>/:id — partial update of an existing row.
  app.put(`/admin/${urlSegment}/:id`, requireAdmin, async (req, res) => {
    const { errors, values } = validateBody(req.body || {}, { partial: true });
    if (errors.length) return res.status(400).json({ error: errors.join('; ') });
    if (Object.keys(values).length === 0) return res.status(400).json({ error: 'no fields to update' });
    try {
      const result = await withUserClient(req.userId, async (client) => {
        const before = await client.query(`SELECT * FROM ${tableName} WHERE id = $1`, [req.params.id]);
        if (before.rows.length === 0) return null;

        const setCols = Object.keys(values);
        const setClause = setCols.map((c, i) => `${c} = $${i + 2}`).join(', ');
        const updated = await client.query(
          `UPDATE ${tableName} SET ${setClause} WHERE id = $1 RETURNING *`,
          [req.params.id, ...setCols.map((c) => values[c])]
        );

        await client.query(
          `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
           VALUES ($1, $2, $3, $4, $5, $6, $7)`,
          [
            req.userId,
            `update_${auditEntity}`,
            tableName,
            req.params.id,
            JSON.stringify(before.rows[0]),
            JSON.stringify(updated.rows[0]),
            req.body.reason || null,
          ]
        );
        return updated.rows[0];
      });
      if (!result) return res.status(404).json({ error: `${auditEntity} not found` });
      res.json({ [auditEntity]: result });
    } catch (err) {
      console.error(`PUT /admin/${urlSegment}/:id error`, err);
      res.status(500).json({ error: 'internal_error' });
    }
  });

  // DELETE /admin/<urlSegment>/:id
  app.delete(`/admin/${urlSegment}/:id`, requireAdmin, async (req, res) => {
    try {
      const result = await withUserClient(req.userId, async (client) => {
        const before = await client.query(`SELECT * FROM ${tableName} WHERE id = $1`, [req.params.id]);
        if (before.rows.length === 0) return null;
        await client.query(`DELETE FROM ${tableName} WHERE id = $1`, [req.params.id]);
        await client.query(
          `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, reason)
           VALUES ($1, $2, $3, $4, $5, $6)`,
          [req.userId, `delete_${auditEntity}`, tableName, req.params.id, JSON.stringify(before.rows[0]), (req.body || {}).reason || null]
        );
        return true;
      });
      if (!result) return res.status(404).json({ error: `${auditEntity} not found` });
      res.status(204).send();
    } catch (err) {
      console.error(`DELETE /admin/${urlSegment}/:id error`, err);
      res.status(500).json({ error: 'internal_error' });
    }
  });
}

module.exports = { registerRuleFamilyRoutes, validateField };
