'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeCatalogueLabel, labelIdentitySql } = require('../src/catalogue_label_identity');
const { registerRuleFamilyRoutes } = require('../src/admin_rule_families');

test('label identity folds only ASCII case/whitespace and preserves null, Unicode and punctuation', () => {
  for (const [input, expected] of [[null,null],['',''],[' \t\n\r\v\f ',''],
    ['  Dining\t\nCAP  ','dining cap'],['Ä A\u00a0B','Ä a\u00a0b'],['İ É é','İ É é'],['A-B','a-b']]) {
    assert.equal(normalizeCatalogueLabel(input), expected);
  }
  for (const bad of [undefined, 42, {}, []]) assert.throws(() => normalizeCatalogueLabel(bad));
  for (const bad of ['x;DROP', '', 'x.y', 'UPPER', null]) assert.throws(() => labelIdentitySql(bad));
  assert.match(labelIdentitySql(), /"t"\."label"/);
});

function setup({failure, method, constraint, label = ' Dining\tCAP '}) {
  const routes = new Map(), calls = [];
  const app = Object.fromEntries(['post','put','delete'].map(verb => [verb, (url, admin, handler) => routes.set(`${verb} ${url}`, handler)]));
  let rolledBack = false;
  registerRuleFamilyRoutes(app, {
    requireAdmin() {},
    async withUserClient(user, callback) {
      try { return await callback({ async query(sql, params) {
        calls.push({sql, params});
        if (sql.startsWith('SELECT')) return {rows:[{id:'fixture-row', label:'before'}]};
        if (failure && !sql.includes('admin_audit_log')) throw Object.assign(new Error('private label and SQL detail'), {code:'23505',constraint,detail:'sensitive'});
        return {rows:[{id:'fixture-row', label}]};
      }}); } catch (error) { rolledBack = true; throw error; }
    },
  }, {urlSegment:'fixture-rules',tableName:'cap_rules',auditEntity:'cap_rule',
    fields:[{name:'label',column:'label',type:'string',required:true}]});
  return { calls, handler:routes.get(`${method} /admin/fixture-rules${method === 'put' ? '/:id' : ''}`),
    req:{userId:'fixture-admin',params:{id:'fixture-row'},body:{cardProductId:'fixture-card',label}},
    res:{statusCode:200,status(code){this.statusCode=code;return this;},json(body){this.body=body;return this;}},
    rolledBack:() => rolledBack};
}
for (const method of ['post','put']) {
  for (const constraint of ['uq_cap_rules_label_identity_v1','uq_card_benefits_label_identity_v1',
    'uq_cap_rules_semantic_identity','uq_card_benefits_semantic_identity']) {
    test(`${method}: ${constraint} is safe 409 and never writes an audit success`, async () => {
      const f=setup({method,constraint,failure:true});await f.handler(f.req,f.res);
      assert.equal(f.res.statusCode,409);assert.deepEqual(f.res.body,{error:'rule_definition_conflict'});
      assert.equal(f.rolledBack(),true);assert.equal(f.calls.some(c=>c.sql.includes('admin_audit_log')),false);
    });
  }
  test(`${method}: unrelated constraint keeps safe internal-error handling`, async (t) => {
    const logs=[];t.mock.method(console,'error',(...args)=>logs.push(args));
    const f=setup({method,constraint:'some_other_constraint',failure:true});await f.handler(f.req,f.res);
    assert.equal(f.res.statusCode,500);assert.deepEqual(f.res.body,{error:'internal_error'});
    assert.equal(f.rolledBack(),true);assert.ok(!JSON.stringify(logs).includes('private label'));
  });
  test(`${method}: successful write preserves display label and audit contract`, async () => {
    const f=setup({method});await f.handler(f.req,f.res);
    assert.equal(f.res.statusCode,method==='post'?201:200);
    assert.equal(f.res.body.cap_rule.label,f.req.body.label);
    assert.ok(f.calls.some(c=>c.sql.includes('admin_audit_log')));
    const write=f.calls.find(c=>/^(INSERT INTO cap_rules|UPDATE cap_rules)/.test(c.sql));
    assert.ok(write.params.includes(f.req.body.label));assert.ok(!write.sql.includes(f.req.body.label));
  });
}
