'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {execFileSync,spawnSync}=require('node:child_process');
const {audit,scanArchive,scanText}=require('../scripts/release_secret_audit');
function repo(){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-secret-audit-'));execFileSync('git',['init','-q'],{cwd:dir});return dir;}
function commit(dir,msg){execFileSync('git',['add','-A'],{cwd:dir});execFileSync('git',['-c','user.name=Fixture','-c','user.email=fixture@example.test','commit','-qm',msg],{cwd:dir});}
function zip(dir,name,entries){const archive=path.join(dir,name);const py=`import sys,zipfile,stat\np=sys.argv[1]\nwith zipfile.ZipFile(p,'w') as z:\n${entries.map(e=>` z.writestr(${JSON.stringify(e.name)},${e.bodyExpr||JSON.stringify(e.body)},compress_type=${e.compress||'zipfile.ZIP_DEFLATED'})`).join('\n')}\n`;const r=spawnSync('python3',['-c',py,archive],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);return archive;}

test('source and bounded history report locations/counts only and exclude env/key paths',()=>{
 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});
  const marker='ghp_'+'a'.repeat(36);
  fs.writeFileSync(path.join(dir,'api/src/provider.js'),`const key = "${marker}";\n`);
  fs.writeFileSync(path.join(dir,'.env.prod'),'AWS_ACCESS_KEY_ID=AKIA'+'A'.repeat(16)+'\n');
  commit(dir,'fixture');
  const result=audit({root:dir});const json=JSON.stringify(result);
  assert.equal(result.incomplete,false);
  assert.ok(result.findings.some(f=>f.rule==='github-token'&&f.file==='api/src/provider.js'&&f.line===1&&f.count===1));
  assert.equal(result.findings.some(f=>f.file.includes('.env')),false);
  assert.equal(result.findings.some(f=>f.scope==='git-history'),true);
  assert.equal(json.includes(marker),false);assert.equal(json.includes('AKIA'),false);assert.equal(json.includes('raw_values_emitted":false'),true);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('symlinked eligible source fails closed without serializing file contents',()=>{
 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});const secret=path.join(dir,'outside.txt');fs.writeFileSync(secret,'ghp_'+'b'.repeat(36));
  fs.symlinkSync(secret,path.join(dir,'api/src/link.js'));
  assert.throws(()=>audit({root:dir}));
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('ZIP scan redacts matches, validates bounds, and rejects unsafe/truncated archives',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-secret-zip-'));try{
  const marker='sk_live_'+'c'.repeat(24);
  const good=zip(dir,'candidate.zip',[{name:'app/lib/config.dart',body:`const value = '${marker}';\n`}]);
  const result=scanArchive(good),json=JSON.stringify(result);
  assert.equal(result.incomplete,false);assert.ok(result.findings.some(f=>f.rule==='stripe-live-secret'&&f.line===1));assert.equal(json.includes(marker),false);
  const traversal=zip(dir,'traversal.zip',[{name:'../escape.js',body:'safe'}]);assert.equal(scanArchive(traversal).incomplete,true);
  const symlink=path.join(dir,'symlink.zip');const symlinkPy=`import sys,zipfile,stat\nz=zipfile.ZipFile(sys.argv[1],'w')\ni=zipfile.ZipInfo('app/link.js');i.create_system=3;i.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(i,'target');z.close()`;
  assert.equal(spawnSync('python3',['-c',symlinkPy,symlink]).status,0);assert.equal(scanArchive(symlink).incomplete,true);
  const bomb=zip(dir,'oversize-entry.zip',[{name:'app/large.js',bodyExpr:'"x"*(2*1024*1024)',compress:'zipfile.ZIP_DEFLATED'}]);assert.equal(scanArchive(bomb).incomplete,true);
  const broken=path.join(dir,'truncated.zip');fs.writeFileSync(broken,Buffer.from('PK\x03\x04partial'));assert.equal(scanArchive(broken).incomplete,true);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('audit output contains no matches or source context, only rule/file/line/count fields',()=>{
 const dir=repo();try{fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});fs.writeFileSync(path.join(dir,'api/src/a.js'),'password = "'+'x'.repeat(24)+'"');commit(dir,'fixture');
  const result=audit({root:dir});for(const f of result.findings)assert.deepEqual(Object.keys(f).sort(),['count','file','line','rule','scope']);
  assert.equal(JSON.stringify(result).includes('x'.repeat(24)),false);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('full-retained history scans root, merge, branch, deleted, and renamed source blobs',()=>{
 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});
  const rootSecret='ghp_'+'d'.repeat(36),branchSecret='sk_live_'+'e'.repeat(24),deletedSecret='AIza'+'f'.repeat(32);
  fs.writeFileSync(path.join(dir,'api/src/root.js'),`const root = "${rootSecret}";\n`);
  fs.writeFileSync(path.join(dir,'api/src/deleted.js'),`const gone = "${deletedSecret}";\n`);commit(dir,'root history');
  const defaultBranch=execFileSync('git',['symbolic-ref','--short','HEAD'],{cwd:dir,encoding:'utf8'}).trim();
  execFileSync('git',['checkout','-qb','retained-branch'],{cwd:dir});
  fs.writeFileSync(path.join(dir,'api/src/branch.js'),`const branch = "${branchSecret}";\n`);commit(dir,'branch history');
  execFileSync('git',['checkout','-q',defaultBranch],{cwd:dir});
  fs.renameSync(path.join(dir,'api/src/root.js'),path.join(dir,'api/src/renamed.js'));
  fs.rmSync(path.join(dir,'api/src/deleted.js'));commit(dir,'rename and delete');
  execFileSync('git',['merge','--no-ff','-qm','merge retained branch','retained-branch'],{cwd:dir});
  const result=audit({root:dir,historyMode:'full-retained'}),historyFindings=result.findings.filter(f=>f.scope==='git-history'),json=JSON.stringify(result);
  assert.equal(result.history.mode,'full-retained');assert.equal(result.history.incomplete,false);assert.equal(result.history.retained_history_complete,true);
  for(const file of ['api/src/root.js','api/src/deleted.js','api/src/branch.js','api/src/renamed.js'])assert.ok(historyFindings.some(f=>f.file===file),`missing retained path ${file}`);
  assert.ok(result.history.commits_examined>=4);
  for(const secret of [rootSecret,branchSecret,deletedSecret])assert.equal(json.includes(secret),false);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('history object read failures are incomplete and never emit blob contents',()=>{
 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});const secret='ghp_'+'g'.repeat(36);
  fs.writeFileSync(path.join(dir,'api/src/object.js'),`const token = "${secret}";\n`);commit(dir,'object fixture');
  const objectId=execFileSync('git',['rev-parse','HEAD:api/src/object.js'],{cwd:dir,encoding:'utf8'}).trim();
  fs.rmSync(path.join(dir,'.git','objects',objectId.slice(0,2),objectId.slice(2)));
  const result=audit({root:dir,historyMode:'full-retained',historyProvenance:true}),json=JSON.stringify(result);
  assert.equal(result.incomplete,true);assert.equal(result.history.incomplete,true);assert.equal(result.history.retained_history_complete,false);
  assert.equal(result.history.blobs_attempted,1);assert.equal(result.history.blobs_read,0);assert.equal(result.history.blobs_examined,0);assert.equal(result.history.blobs_failed,1);
  assert.equal(result.history_provenance.incomplete,true);assert.equal(result.history_provenance.records.length,0);
  assert.equal(json.includes(secret),false);assert.ok(result.findings.every(f=>!Object.hasOwn(f,'value')&&!Object.hasOwn(f,'context')));
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('sampled defaults stay bounded and full-retained rejects unsupported modes',()=>{
 const dir=repo();try{fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});fs.writeFileSync(path.join(dir,'api/src/a.js'),'safe');commit(dir,'fixture');
  const result=audit({root:dir});assert.equal(result.history.mode,'sampled');assert.equal(result.history.retained_history_complete,true);
  assert.throws(()=>audit({root:dir,historyMode:'unbounded'}));
  assert.throws(()=>audit({root:dir,historyLimits:{maxFiles:5001}}));
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('invalid retained path bytes fail closed and sampled commit limit is explicit',()=>{
 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});fs.writeFileSync(path.join(dir,'api/src/anchor.js'),'safe');commit(dir,'path fixture');
  const secret='ghp_'+'h'.repeat(36),blob=execFileSync('git',['hash-object','-w','--stdin'],{cwd:dir,input:secret,encoding:'utf8'}).trim();
  const writeTree=bytes=>execFileSync('git',['-c','fsck.fullPathname=ignore','hash-object','-t','tree','-w','--stdin'],{cwd:dir,input:bytes,encoding:'utf8'}).trim();
  const srcTree=writeTree(Buffer.concat([Buffer.from('100644 '),Buffer.from([0xff]),Buffer.from('.js\0'),Buffer.from(blob,'hex')]));
  const apiTree=writeTree(Buffer.concat([Buffer.from('40000 src\0'),Buffer.from(srcTree,'hex')]));
  const treeId=writeTree(Buffer.concat([Buffer.from('40000 api\0'),Buffer.from(apiTree,'hex')]));
  const commitId=execFileSync('git',['commit-tree',treeId,'-p','HEAD','-m','malformed path'],{cwd:dir,encoding:'utf8',env:{...process.env,GIT_AUTHOR_NAME:'Fixture',GIT_AUTHOR_EMAIL:'fixture@example.test',GIT_COMMITTER_NAME:'Fixture',GIT_COMMITTER_EMAIL:'fixture@example.test'}}).trim();
  execFileSync('git',['update-ref','refs/heads/malformed-path',commitId],{cwd:dir});
  let result=audit({root:dir,historyMode:'full-retained',historyProvenance:true});
  assert.equal(result.incomplete,true);assert.equal(result.history.retained_history_complete,false);
  assert.equal(result.history_provenance.incomplete,true);
  assert.equal(JSON.stringify(result).includes(secret),false);

  const limited=repo();try{
   fs.mkdirSync(path.join(limited,'api/src'),{recursive:true});const file=path.join(limited,'api/src/changing.js');
   for(let i=0;i<41;i++){fs.writeFileSync(file,`const revision = ${i};\n`);commit(limited,`bounded history ${i}`);}
   result=audit({root:limited});assert.equal(result.history.mode,'sampled');assert.equal(result.history.commits_listed,41);assert.equal(result.history.commits_selected,40);assert.equal(result.history.commits_examined,40);assert.equal(result.history.incomplete,true);assert.equal(result.incomplete,true);
  }finally{fs.rmSync(limited,{recursive:true,force:true});}
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('full-retained deduplicates unchanged blob paths across long history',()=>{
 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});fs.writeFileSync(path.join(dir,'api/src/stable.js'),'const stable = "ghp_'+'j'.repeat(36)+'";\n');
  fs.writeFileSync(path.join(dir,'notes.md'),'0');commit(dir,'initial');
  for(let i=1;i<45;i++){fs.writeFileSync(path.join(dir,'notes.md'),String(i));commit(dir,`unrelated revision ${i}`);}
  const result=audit({root:dir,historyMode:'full-retained'});
  assert.equal(result.history.incomplete,false);assert.equal(result.history.commits_examined,45);assert.equal(result.history.retained_history_complete,true);
  assert.equal(result.history.blobs_examined,1);assert.equal(result.history.scan_scope,'retained-git-refs/release-source/recognized-text');
  assert.equal(result.findings.filter(f=>f.scope==='git-history'&&f.file==='api/src/stable.js').length,1);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('history file, byte, and time budgets stop early without claiming completion',()=>{
 const makeRepo=()=>{const dir=repo();fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});return dir;};
 const fileLimited=makeRepo();try{
  fs.writeFileSync(path.join(fileLimited,'api/src/a.js'),'const a = 1;');commit(fileLimited,'one');
  fs.writeFileSync(path.join(fileLimited,'api/src/b.js'),'const b = 2;');commit(fileLimited,'two');
  let result=audit({root:fileLimited,historyMode:'full-retained',historyLimits:{maxFiles:1}});
  assert.equal(result.history.incomplete,true);assert.equal(result.history.retained_history_complete,false);assert.equal(result.history.blobs_examined,1);assert.ok(result.history.commits_examined<result.history.commits_selected);
 }finally{fs.rmSync(fileLimited,{recursive:true,force:true});}

 const byteLimited=makeRepo();try{
  fs.writeFileSync(path.join(byteLimited,'api/src/a.js'),'const token = "ghp_'+'k'.repeat(36)+'";');commit(byteLimited,'byte limited');
  const result=audit({root:byteLimited,historyMode:'full-retained',historyLimits:{maxBytes:1}});
  assert.equal(result.history.incomplete,true);assert.equal(result.history.retained_history_complete,false);assert.equal(result.history.bytes_examined,0);assert.equal(result.history.blobs_attempted,1);assert.equal(result.history.blobs_read,1);assert.equal(result.history.blobs_examined,0);assert.equal(result.history.blobs_limit_rejected,1);assert.equal(JSON.stringify(result).includes('k'.repeat(36)),false);
 }finally{fs.rmSync(byteLimited,{recursive:true,force:true});}

 const exact=makeRepo();try{
  fs.writeFileSync(path.join(exact,'api/src/a.js'),'safe');commit(exact,'exact file limit');
  let result=audit({root:exact,historyMode:'full-retained',historyLimits:{maxFiles:1,maxBytes:4}});
  assert.equal(result.history.blobs_examined,1);assert.equal(result.history.bytes_examined,4);assert.equal(result.history.incomplete,false);assert.equal(result.history.retained_history_complete,true);
 }finally{fs.rmSync(exact,{recursive:true,force:true});}

 const timed=makeRepo();try{
  fs.writeFileSync(path.join(timed,'api/src/a.js'),'safe');commit(timed,'time 1');fs.writeFileSync(path.join(timed,'api/src/a.js'),'safe 2');commit(timed,'time 2');
  const result=audit({root:timed,historyMode:'full-retained',historyLimits:{maxMs:1}});
  assert.equal(result.history.incomplete,true);assert.equal(result.history.retained_history_complete,false);assert.ok(result.history.commits_examined<result.history.commits_selected);
 }finally{fs.rmSync(timed,{recursive:true,force:true});}
});

test('credential assignments in current, history, and archive paths are redacted',()=>{
 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});const secret='pathsecret'.repeat(3),name=`password="${secret}".js`;
  fs.writeFileSync(path.join(dir,'api/src',name),`const token = "ghp_${'m'.repeat(36)}";\n`);commit(dir,'credential path');
  const fakeKeyBody='FAKE-KEY-BODY-'.repeat(3),privatePath=`-----BEGIN PRIVATE KEY----- ${fakeKeyBody}.js`;
  fs.writeFileSync(path.join(dir,'api/src',privatePath),`password = "${'z'.repeat(24)}";\n`);commit(dir,'private marker path');
  const result=audit({root:dir,historyMode:'full-retained'}),json=JSON.stringify(result);
  assert.equal(json.includes(secret),false);assert.equal(json.includes(fakeKeyBody),false);
  assert.ok(result.findings.some(f=>f.scope==='working-tree'&&f.file.startsWith('[redacted-path:')));assert.ok(result.findings.some(f=>f.scope==='git-history'&&f.file.startsWith('[redacted-path:')));
  const archive=zip(dir,'credential-path.zip',[{name:`pkg/password="${secret}".js`,body:`const token = 'ghp_${'n'.repeat(36)}';`}]);
  const archiveResult=scanArchive(archive),archiveJson=JSON.stringify(archiveResult);
  assert.equal(archiveJson.includes(secret),false);assert.ok(archiveResult.findings.some(f=>f.file.startsWith('[redacted-path:')));
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('finding count and output budgets truncate during accumulation and mark incomplete',()=>{
 const textFindings=[];scanText('fixture.js',`ghp_${'o'.repeat(36)}\nAKIA${'P'.repeat(16)}\n` ,textFindings,'test',{maxFindings:1});
 assert.equal(textFindings.length,1);

 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});fs.writeFileSync(path.join(dir,'api/src/matches.js'),`ghp_${'q'.repeat(36)}\nAKIA${'R'.repeat(16)}\n`);commit(dir,'repetitive matches');
  const result=audit({root:dir,outputLimits:{maxFindings:1}});
  assert.equal(result.incomplete,true);assert.ok(result.findings.length<=1);assert.equal(JSON.stringify(result).includes('q'.repeat(36)),false);
  const byteBound=audit({root:dir,outputLimits:{maxFindingBytes:1}});
  assert.equal(byteBound.incomplete,true);assert.equal(byteBound.findings.length,0);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}

 const archiveDir=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-secret-output-'));try{
  const archive=zip(archiveDir,'many.zip',[{name:'a.js',body:`ghp_${'s'.repeat(36)}\n`},{name:'b.js',body:`AKIA${'T'.repeat(16)}\n`}]);
  const report=scanArchive(archive,{maxFindings:1});
  assert.equal(report.incomplete,true);assert.ok(report.findings.length<=1);assert.equal(JSON.stringify(report).includes('s'.repeat(36)),false);
  const pathArchive=zip(archiveDir,'long-path.zip',[{name:'pkg/'.padEnd(80,'x')+'.js',body:`ghp_${'u'.repeat(36)}`}]);
  const short=scanArchive(pathArchive,{maxPathBytes:32});
  assert.equal(short.incomplete,true);assert.ok(Buffer.byteLength(short.findings[0].file)<=32);assert.match(short.findings[0].file,/\[sha256:/);
 }finally{fs.rmSync(archiveDir,{recursive:true,force:true});}

 const pathRepo=repo();try{
  fs.mkdirSync(path.join(pathRepo,'api/src'),{recursive:true});const longName='x'.repeat(80)+'.js';fs.writeFileSync(path.join(pathRepo,'api/src',longName),`ghp_${'v'.repeat(36)}`);commit(pathRepo,'long path');
  const result=audit({root:pathRepo,outputLimits:{maxPathBytes:32}}),finding=result.findings.find(f=>f.scope==='working-tree');
  assert.equal(result.incomplete,true);assert.ok(Buffer.byteLength(finding.file)<=32);assert.match(finding.file,/\[sha256:/);
 }finally{fs.rmSync(pathRepo,{recursive:true,force:true});}
});

test('full-retained mode reports shallow clone ancestry as incomplete',()=>{
 const source=repo(),clone=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-shallow-'));fs.rmSync(clone,{recursive:true,force:true});try{
  fs.mkdirSync(path.join(source,'api/src'),{recursive:true});fs.writeFileSync(path.join(source,'api/src/a.js'),'safe');commit(source,'one');fs.writeFileSync(path.join(source,'api/src/a.js'),'safe two');commit(source,'two');
  execFileSync('git',['clone','-q','--depth','1','--no-local',source,clone]);
  const result=audit({root:clone,historyMode:'full-retained'});
  assert.equal(result.history.shallow_repository,true);assert.equal(result.history.incomplete,true);assert.equal(result.history.retained_history_complete,false);assert.equal(result.incomplete,true);
 }finally{fs.rmSync(source,{recursive:true,force:true});fs.rmSync(clone,{recursive:true,force:true});}
});

test('history provenance is opt-in and maps sorted findings to distinct historical blobs and commits',()=>{
 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});const file=path.join(dir,'api/src/version.js');
  const first='ghp_'+'a'.repeat(36),branchToken='sk_live_'+'b'.repeat(24),headToken='AIza'+'c'.repeat(32);
  fs.writeFileSync(file,`const token = "${first}";\n`);commit(dir,'initial version');
  const initialCommit=execFileSync('git',['rev-parse','HEAD'],{cwd:dir,encoding:'utf8'}).trim();
  const defaultBranch=execFileSync('git',['symbolic-ref','--short','HEAD'],{cwd:dir,encoding:'utf8'}).trim();
  execFileSync('git',['checkout','-qb','history-branch'],{cwd:dir});
  fs.writeFileSync(file,`const token = "${branchToken}";\n`);commit(dir,'branch version');
  const branchCommit=execFileSync('git',['rev-parse','HEAD'],{cwd:dir,encoding:'utf8'}).trim();
  execFileSync('git',['checkout','-q',defaultBranch],{cwd:dir});
  fs.writeFileSync(file,`const token = "${headToken}";\n`);commit(dir,'head version');
  const headCommit=execFileSync('git',['rev-parse','HEAD'],{cwd:dir,encoding:'utf8'}).trim();

  const defaultResult=audit({root:dir,historyMode:'full-retained'});
  assert.equal(Object.hasOwn(defaultResult,'history_provenance'),false);
  const result=audit({root:dir,historyMode:'full-retained',historyProvenance:true}),json=JSON.stringify(result);
  const records=result.history_provenance.records;
  assert.equal(result.history_provenance.enabled,true);assert.equal(result.history_provenance.incomplete,false);
  assert.equal(result.incomplete,false);assert.ok(records.length>=3);
  for(const [token,commitId] of [[first,initialCommit],[branchToken,branchCommit],[headToken,headCommit]]){
   const blobId=execFileSync('git',['rev-parse',`${commitId}:api/src/version.js`],{cwd:dir,encoding:'utf8'}).trim();
   const record=records.find(r=>r.blob_id===blobId);
   assert.ok(record,`missing provenance for ${commitId}`);assert.equal(record.observed_commit_id,commitId);
   assert.equal(Object.hasOwn(record,'first_commit_id'),false);
   const expectedRule=token.startsWith('ghp_')?'github-token':token.startsWith('sk_live_')?'stripe-live-secret':'google-api-key';
   assert.equal(record.file,'api/src/version.js');assert.equal(record.line,1);assert.equal(record.rule,expectedRule);assert.equal(record.count,1);
   const finding=result.findings[record.finding_index];assert.deepEqual({scope:finding.scope,file:finding.file,line:finding.line,rule:finding.rule,count:finding.count},{scope:'git-history',file:record.file,line:record.line,rule:record.rule,count:record.count});
  }
  for(const token of [first,branchToken,headToken])assert.equal(json.includes(token),false);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('history provenance follows renamed and deleted versions, redacts paths, and truncates within bounds',()=>{
 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});const original=path.join(dir,'api/src/old.js'),secretPath=`ghp_${'r'.repeat(36)}.js`;
  const secret='AKIA'+'D'.repeat(16);fs.writeFileSync(original,`const token = "${secret}";\n`);commit(dir,'old retained path');
  const oldCommit=execFileSync('git',['rev-parse','HEAD'],{cwd:dir,encoding:'utf8'}).trim(),oldBlob=execFileSync('git',['rev-parse','HEAD:api/src/old.js'],{cwd:dir,encoding:'utf8'}).trim();
  fs.renameSync(original,path.join(dir,'api/src/new.js'));fs.writeFileSync(path.join(dir,'api/src',secretPath),`const token = "ghp_${'s'.repeat(36)}";\n`);commit(dir,'rename and sensitive path');
  const result=audit({root:dir,historyMode:'full-retained',historyProvenance:true}),json=JSON.stringify(result),records=result.history_provenance.records;
  assert.ok(records.some(r=>r.blob_id===oldBlob&&r.observed_commit_id===oldCommit&&r.file==='api/src/old.js'));
  assert.ok(records.some(r=>r.file.startsWith('[redacted-path:')));assert.equal(json.includes(secretPath),false);
  const limited=audit({root:dir,historyMode:'full-retained',historyProvenance:true,historyProvenanceLimits:{maxRecords:1}});
  assert.equal(limited.history_provenance.records.length,1);assert.equal(limited.history_provenance.incomplete,true);assert.equal(limited.incomplete,true);
  assert.equal(limited.history.retained_history_complete,true);
  assert.throws(()=>audit({root:dir,historyMode:'sampled',historyProvenance:true}));
  assert.throws(()=>audit({root:dir,historyMode:'full-retained',historyProvenanceLimits:{maxBytes:2*1024*1024+1}}));
  const invalidCli=spawnSync(process.execPath,[path.resolve(__dirname,'../scripts/release_secret_audit.js'),'--history-provenance'],{encoding:'utf8'});
  assert.equal(invalidCli.status,2);assert.equal(invalidCli.stdout,'');assert.match(invalidCli.stderr,/no raw findings emitted/i);
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('unchanged blob provenance names an observed containing commit without claiming origin',()=>{
 const dir=repo();try{
  fs.mkdirSync(path.join(dir,'api/src'),{recursive:true});
  fs.writeFileSync(path.join(dir,'api/src/stable.js'),`const token = "ghp_${'w'.repeat(36)}";\n`);commit(dir,'introduce stable finding');
  const blobId=execFileSync('git',['rev-parse','HEAD:api/src/stable.js'],{cwd:dir,encoding:'utf8'}).trim();
  fs.writeFileSync(path.join(dir,'notes.md'),'one');commit(dir,'unrelated one');
  fs.writeFileSync(path.join(dir,'notes.md'),'two');commit(dir,'unrelated two');

  const result=audit({root:dir,historyMode:'full-retained',historyProvenance:true});
  const records=result.history_provenance.records.filter(r=>r.blob_id===blobId&&r.file==='api/src/stable.js');
  assert.equal(records.length,1);
  const record=records[0],observedPath=`${record.observed_commit_id}:api/src/stable.js`;
  assert.equal(execFileSync('git',['rev-parse',observedPath],{cwd:dir,encoding:'utf8'}).trim(),blobId);
  assert.equal(Object.hasOwn(record,'first_commit_id'),false);
  assert.equal(Object.hasOwn(record,'earliest_commit_id'),false);
  const finding=result.findings[record.finding_index];
  assert.deepEqual({scope:finding.scope,file:finding.file,line:finding.line,rule:finding.rule,count:finding.count},{scope:'git-history',file:record.file,line:record.line,rule:record.rule,count:record.count});
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
