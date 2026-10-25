/* Offline DOM verification only. No browser, network, or database access. */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {JSDOM} = require(process.argv[2] || 'jsdom');
const root = path.resolve(__dirname, '../..');
const reportPath = path.join(root, 'docs/security-and-backend-audit-2026-10-20.html');
const dom = new JSDOM(fs.readFileSync(reportPath, 'utf8'), {
  url: 'https://offline-report.invalid/report.html', runScripts: 'outside-only',
});
const win = dom.window, doc = win.document;
const markdown = fs.readFileSync(reportPath.replace(/\.html$/, '.md'), 'utf8');
const sourceStatuses = [...markdown.matchAll(/^\| (S\d{2}) \| (Implemented in source|Partial|Open) \|/gm)];
assert.equal(sourceStatuses.length, 18, 'Markdown must declare all current security statuses');
const statusRows = [...doc.querySelectorAll('tbody tr')].filter(row => /^S\d{2}$/.test(row.cells[0]?.textContent.trim()));
assert.equal(statusRows.length, 18, 'HTML must contain the current security ledger once');
for (const [, id, status] of sourceStatuses) {
  assert.equal(statusRows.find(row => row.cells[0].textContent.trim() === id)?.cells[1].textContent.trim(), status, `Stale HTML status for ${id}`);
}
// The overview counts all 76 findings, not just S01–S18. Remaining source
// packages and release acceptance are separate units with overlapping mappings.
const remaining = JSON.parse(fs.readFileSync(path.join(__dirname, 'remaining-work-2026-10-25.json')));
assert.equal(remaining.total_findings, 76);
assert.equal(remaining.original_audit_findings + remaining.additional_system_design_findings, 76);
assert.deepEqual(remaining.status_counts, {'Implemented in source':26, Partial:43, Open:7});
assert.equal(remaining.finding_statuses.D03, 'Partial');
assert.equal(remaining.finding_statuses.D04, 'Partial');
assert.equal(remaining.finding_statuses.D05, 'Partial');
const focusedPlan = JSON.parse(fs.readFileSync(path.join(__dirname, 'data-dependency-mobile-documentation-plan-2026-10-25.json')));
const gapReview = JSON.parse(fs.readFileSync(path.join(root, 'artifacts/security-storage-2026-10-25/focused-gap-review.json')));
assert.equal(focusedPlan.unfinished_findings, 22);
assert.deepEqual(focusedPlan.status_counts, {'Implemented in source':4, Partial:19, Open:3});
assert.equal(gapReview.items.length, 22);
assert.equal(new Set(gapReview.items.map(item=>item.id)).size, 22);
assert.deepEqual(new Set(gapReview.items.map(item=>item.id)), new Set(focusedPlan.unfinished_ids));
for(const item of gapReview.items) {
  assert.equal(item.status, remaining.finding_statuses[item.id], `Stale gap review status for ${item.id}`);
  assert.ok(item.present && item.missing && item.next_action);
  assert.ok(fs.existsSync(path.join(root,item.evidence)), `Missing gap review evidence for ${item.id}`);
}
assert.equal(remaining.not_fully_closed, 50);
assert.equal(remaining.implementation_packages.length, 14);
assert.equal(remaining.release_gates.length, 6);
const launch = JSON.parse(fs.readFileSync(path.join(root,'artifacts/security-production-launch-2026-10-25/launch-priorities.json')));
assert.equal(launch.target.user_confirmed_completed_registrations_per_day,100000);
assert.equal(launch.target.hours,24);
assert.equal(launch.controls.length,10);
assert.deepEqual(launch.controls.map(x=>x.rank),[1,2,3,4,5,6,7,8,9,10]);
assert.equal(new Set(launch.controls.map(x=>x.id)).size,10);
assert.equal(launch.priority_rows_are_not_new_vulnerability_counts,true);
assert.equal(launch.load_test_run,false);
const knownWork=new Set([...remaining.implementation_packages,...remaining.release_gates].map(x=>x.id));
for(const item of launch.controls){
  assert.equal(item.status,'not_accepted');
  assert.ok(item.package_gate_ids.every(id=>knownWork.has(id)),'Unknown launch work mapping');
  assert.ok(item.finding_ids.every(id=>Object.hasOwn(remaining.finding_statuses,id)),'Unknown launch finding mapping');
}
for(const scenario of launch.scenarios){
  assert.equal(scenario.signups_per_second,scenario.users/scenario.seconds);
  assert.equal(scenario.modeled_http_rps,scenario.users*15/scenario.seconds);
}
const overviewCounts = {'implementation-packages':'14','release-gates':'6','source-implemented':'26/76',partial:'43/76',open:'7/76'};
function assertRemainingCounts(page) {
  for (const [name,value] of Object.entries(overviewCounts)) {
    assert.equal(page.querySelector(`[data-count="${name}"] strong`)?.textContent.trim(),value,`Stale overview ${name}`);
  }
  for (const group of ['implementation_packages','release_gates']) {
    const ids=remaining[group].map(item=>item.id);
    assert.equal(new Set(ids).size,ids.length);
    const actual=[...page.querySelectorAll('tbody tr')].map(row=>row.cells[0]?.textContent.trim().split(' — ')[0]).filter(id=>new RegExp(group==='implementation_packages'?'^I\\d{2}$':'^G\\d{2}$').test(id));
    assert.deepEqual(actual,ids,`Missing or repeated ${group}`);
  }
}
assertRemainingCounts(doc);
const mapped = new Set([...remaining.implementation_packages,...remaining.release_gates].flatMap(item=>item.finding_ids));
for(const [id,status] of Object.entries(remaining.finding_statuses))if(status!=='Implemented in source')assert.ok(mapped.has(id),`Unmapped unfinished finding ${id}`);
const focusedPath=path.join(root,'docs/security-remaining-work-2026-10-25.html');
const focusedDom=new JSDOM(fs.readFileSync(focusedPath,'utf8'));
const focused=focusedDom.window.document;
assertRemainingCounts(focused);
assert.equal(focused.querySelectorAll('script[src]').length,0);
const focusedIds=[...focused.querySelectorAll('[id]')].map(element=>element.id);
assert.equal(new Set(focusedIds).size,focusedIds.length);
for(const link of focused.querySelectorAll('a[href]')) {
  const href=link.getAttribute('href');
  if(href.startsWith('http'))continue;
  if(href.startsWith('#')) {assert.ok(focused.getElementById(href.slice(1)));continue;}
  const [file,anchor]=href.split('#');const target=path.resolve(path.dirname(focusedPath),decodeURIComponent(file));
  assert.ok(fs.existsSync(target),`Missing focused report link ${target}`);
  if(anchor&&target===reportPath)assert.ok(doc.getElementById(anchor),`Missing audit anchor ${anchor}`);
}
focusedDom.window.close();

win.HTMLElement.prototype.scrollIntoView = function () {};
win.HTMLElement.prototype.scrollTo = function () {};
for (const script of doc.querySelectorAll('script:not([type])')) win.eval(script.textContent);
assert.equal(doc.querySelector('main > h2')?.id,'production-launch-priorities');
assert.ok(doc.querySelector('header a[href="#production-launch-priorities"]'));
const launchSection=doc.getElementById('production-launch-priorities');
assert.ok(launchSection);
let launchText='';
for(let el=launchSection.nextElementSibling;el&&el.tagName!=='H2';el=el.nextElementSibling)launchText+=el.textContent+'\n';
let prior=-1;
for(const item of launch.controls){const position=launchText.indexOf(item.id);assert.ok(position>prior,'Launch priority order differs');prior=position;}
assert.ok(launchText.includes('100,000'));
assert.ok(launchText.includes('50 MiB'));
assert.ok(!doc.querySelector('.snapshot-note').textContent.includes('964 API'),'Stale headline test counts');
const tables = JSON.parse(doc.getElementById('schema-data').textContent);
assert.equal(tables.length, 96);
assert.equal(doc.querySelectorAll('.schema-table').length, 96);
assert.equal(doc.querySelectorAll('.erd-node').length, 96);
assert.equal(doc.querySelectorAll('.erd-edge').length, 139);
assert.equal(tables.reduce((a,t) => a+t.columns.length, 0), 934);
assert.ok(tables.every(t => t.domain !== 'Other'));
assert.equal(doc.getElementById('schema-diagram').getAttribute('role'),'group');
const budgetDetails=doc.getElementById('table-pandapay-public-budget_periods');
assert.ok(budgetDetails.textContent.includes('Composite UNIQUE member'));
const ids = [...doc.querySelectorAll('[id]')].map(el => el.id);
assert.equal(new Set(ids).size, ids.length, 'Unique DOM IDs required');
assert.equal(doc.querySelectorAll('.stack-strip>div').length, 4);
assert.ok(doc.getElementById('9-solutions-for-every-finding'));
assert.ok(doc.getElementById('10-database-optimization-and-table-usage-review'));
assert.ok(doc.getElementById('13-scalability-low-ram-servers-and-storage-plan'));
assert.ok(doc.querySelector('a[data-show-audit][href="#13-scalability-low-ram-servers-and-storage-plan"]'));
assert.ok(doc.getElementById('audit-panel').textContent.includes('No load test was run'));
assert.ok(doc.getElementById('14-cdn-redis-and-the-supporting-services-pandapay-needs'));
assert.ok(doc.querySelector('a[data-show-audit][href="#14-cdn-redis-and-the-supporting-services-pandapay-needs"]'));
const usageInventory=doc.getElementById('database-usage-inventory');
assert.ok(usageInventory);
assert.equal(usageInventory.querySelectorAll('tbody tr').length,96);
assert.equal(usageInventory.querySelectorAll('td').length,96*7);
assert.equal(usageInventory.querySelectorAll('a[data-table-link]').length,96);
assert.equal([...usageInventory.querySelectorAll('tbody tr')].filter(row=>row.cells[6].textContent.startsWith('Retirement candidate')).length,4);
const optimization=JSON.parse(fs.readFileSync(path.join(__dirname,'database-optimization-evidence.json')));
assert.equal(Object.values(optimization.databases).reduce((n,db)=>n+db.tables.length,0),96);
assert.ok(optimization.scope.includes('not production'));
assert.equal(optimization.databases.pandapay.equivalent_index_pairs.length,2);
const solutionsStart=doc.getElementById('9-solutions-for-every-finding');
const solutionRows=[];
for(let el=solutionsStart.nextElementSibling;el;el=el.nextElementSibling){
  if(el.matches('.table-wrap'))solutionRows.push(...el.querySelectorAll('tbody tr'));
}
const solutionIds=solutionRows.map(row=>row.cells[0].textContent.trim().split(/[ /—]/)[0]);
const expectedSolutionIds=[['S',18],['B',8],['A',9],['D',5],['C',7],['N',4],['M',10],['W',7]]
  .flatMap(([prefix,count])=>Array.from({length:count},(_,i)=>prefix+(prefix==='M'?String(i+1):String(i+1).padStart(2,'0'))));
for(const id of expectedSolutionIds)assert.ok(solutionIds.includes(id),`Missing solution ${id}`);
assert.equal(new Set(solutionIds.filter(id=>expectedSolutionIds.includes(id))).size,68);
assert.ok(solutionsStart.nextElementSibling.textContent.includes('proposed remediation'));
assert.equal(doc.getElementById('database-panel').hidden, true);
doc.getElementById('database-tab').click();
assert.equal(doc.getElementById('database-panel').hidden, false);
assert.equal(doc.getElementById('audit-panel').hidden, true);
assert.equal(doc.querySelectorAll('#database-boundaries tbody tr').length,3);
doc.querySelector('[data-database-scope="pandapay_auth"]').click();
assert.equal(doc.querySelectorAll('.erd-node').length,7);
doc.querySelector('[data-database-scope="pandapay"]').click();
assert.equal(doc.querySelectorAll('.erd-node').length,89);
doc.getElementById('schema-reset').click();
const filter = (id, value, event='change') => {const el=doc.getElementById(id);el.value=value;el.dispatchEvent(new win.Event(event));};
filter('schema-database', 'pandapay_auth');
assert.equal(doc.querySelectorAll('.erd-node').length,7);
assert.equal(doc.querySelectorAll('.erd-edge').length,5);
assert.equal(doc.querySelectorAll('.schema-table:not([hidden])').length,7);
doc.getElementById('schema-reset').click();
filter('schema-search', 'occurred_at', 'input');
assert.ok(doc.querySelectorAll('.erd-node').length>0);
assert.ok(doc.querySelectorAll('.erd-node').length<96);
filter('schema-search', 'no_table_matches_this_term', 'input');
assert.equal(doc.querySelectorAll('.erd-node').length,0);
assert.equal(doc.getElementById('schema-empty').hidden,false);
doc.getElementById('schema-reset').click();
assert.equal(doc.querySelectorAll('.erd-node').length,96);
doc.querySelector('.domain-card[data-domain="Authentication"]').click();
assert.equal(doc.querySelectorAll('.erd-node').length,7);
doc.getElementById('schema-reset').click();
doc.querySelector('.erd-node[aria-label^="pandapay.transactions,"]').dispatchEvent(new win.Event('click'));
assert.equal(doc.getElementById('table-pandapay-public-transactions').open,true);
assert.equal(doc.querySelectorAll('.erd-node.selected').length,1);
assert.ok(doc.querySelectorAll('.erd-edge.active').length>0);
const parentLink=doc.querySelector('#table-pandapay-public-transactions a[data-table-link]');
assert.ok(parentLink);parentLink.click();
assert.ok(doc.getElementById('table-'+parentLink.dataset.tableLink.replaceAll('.','-')).open);
const before=doc.getElementById('schema-diagram').style.width;
doc.getElementById('zoom-in').click();
assert.notEqual(doc.getElementById('schema-diagram').style.width,before);
assert.equal(doc.getElementById('zoom-label').textContent,'115%');
doc.getElementById('database-tab').dispatchEvent(new win.KeyboardEvent('keydown',{key:'ArrowLeft'}));
assert.equal(doc.getElementById('audit-tab').getAttribute('aria-selected'),'true');
assert.equal(doc.getElementById('audit-panel').hidden,false);
win.history.replaceState(null,'','#%invalid');
assert.doesNotThrow(()=>win.dispatchEvent(new win.HashChangeEvent('hashchange')));
assert.equal(doc.getElementById('audit-panel').hidden,false);
doc.getElementById('database-tab').click();
doc.querySelector('[data-show-audit]').click();
assert.equal(doc.getElementById('audit-panel').hidden,false);
doc.getElementById('database-tab').click();
doc.querySelector('a[data-show-audit][href="#13-scalability-low-ram-servers-and-storage-plan"]').click();
assert.equal(doc.getElementById('audit-panel').hidden,false);
assert.equal(doc.getElementById('database-panel').hidden,true);
doc.getElementById('database-tab').click();
doc.querySelector('a[data-show-audit][href="#14-cdn-redis-and-the-supporting-services-pandapay-needs"]').click();
assert.equal(doc.getElementById('audit-panel').hidden,false);
assert.equal(doc.getElementById('database-panel').hidden,true);
let localLinks=0;
for(const a of doc.querySelectorAll('a[href]')) {
  const href=a.getAttribute('href');
  if(href.startsWith('http')) continue;
  if(href.startsWith('#')) {assert.ok(doc.getElementById(href.slice(1)), `Missing anchor ${href}`);continue;}
  const target=path.resolve(path.dirname(reportPath),decodeURIComponent(href.split('#')[0]));
  assert.ok(fs.existsSync(target),`Missing local file ${target}`);localLinks++;
}
assert.equal(doc.querySelectorAll('script[src]').length,0);
const supplement=JSON.parse(fs.readFileSync(path.join(__dirname,'schema-source-supplement.json')));
assert.equal(supplement.flutter_sqlite.tables.length,19);
assert.equal(supplement.source_only_product_tables.length,2);
for (const t of supplement.flutter_sqlite.tables) assert.ok(doc.body.textContent.includes(t.table_name));
const fkCount=tables.reduce((sum,t)=>sum+t.constraints.filter(k=>k.kind==='f').length,0);
assert.equal(fkCount,139);
console.log(JSON.stringify({result:'passed',postgres_tables:tables.length,columns:934,foreign_keys:fkCount,sqlite_tables:19,source_only_tables:2,remediation_items:68,optimization_inventory_rows:96,table_retirement_candidates:4,local_links:localLinks,remaining_implementation_packages:14,remaining_release_gates:6,full_findings:76,unfinished_findings:remaining.not_fully_closed,focused_page_verified:true,checks:['remaining-work counts and complete finding mapping','focused remaining-work HTML','tab switching','keyboard tabs','database filter','domain filter','column search','empty state','reset','table inspection','relationship navigation','zoom','unique IDs','local links','offline scripts','remediation coverage and proposal status','optimization inventory completeness','scalability section and cross-tab shortcut']},null,2));
dom.window.close();
