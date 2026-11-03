'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {exportCase}=require('../../scripts/export_sms_v2_case');
const id='00000000-0000-4000-8000-000000000001';
test('export creates one synthetic file and refuses overwriting or credential redirects',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'wp12-export-'));
 try{
  const destination=path.join(root,id+'.json');
  const options={destination,baseUrl:'https://admin.invalid',token:'x'.repeat(43),
   fetchCase:async(url,request)=>{
    assert.equal(request.redirect,'error');assert.equal(url.pathname,'/admin/sms/v2/corrections/'+id+'/export');
    return {ok:true,json:async()=>({id,source:'synthetic',messages:[{sender:'TEST',body:'synthetic',observedAt:'2026-11-01T00:00:00Z'}],expect:{facts:[]}})};
   }};
  assert.equal(await exportCase(id,options),destination);
  assert.equal(JSON.parse(fs.readFileSync(destination)).id,id);
  await assert.rejects(exportCase(id,options),{code:'EEXIST'});
  await assert.rejects(exportCase(id,{...options,baseUrl:'http://external.invalid'}),/HTTPS/);
 }finally{fs.rmSync(root,{recursive:true,force:true});}
});
test('sms-fix-case skill frontmatter names its exact trigger',()=>{
 const source=fs.readFileSync(path.resolve(__dirname,'../../../.claude/skills/sms-fix-case/SKILL.md'),'utf8');
 assert.match(source,/^---\nname: sms-fix-case\ndescription: Use when fixing an SMS classification correction case marked Code fix in the admin console\.\n---/);
});
