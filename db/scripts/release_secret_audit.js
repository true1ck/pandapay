#!/usr/bin/env node
'use strict';

// Bounded, local-only secret audit for the release source scope, retained Git
// history and optional ZIP release archives. Output contains locations and
// counts only. This is a heuristic scanner, not proof that secrets are absent.
const fs=require('node:fs'),path=require('node:path'),{spawnSync,execFileSync}=require('node:child_process');
const {TextDecoder}=require('node:util');
const {sourcePathAllowed,sourceSnapshot,readBounded}=require('./release_security_check');
const RULES=[
  ['private-key-marker',/-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/g],
  ['aws-access-key',/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g],
  ['github-token',/\bgh[pousr]_[A-Za-z0-9_]{30,}\b/g],
  ['stripe-live-secret',/\bsk_live_[A-Za-z0-9]{16,}\b/g],
  ['google-api-key',/\bAIza[0-9A-Za-z_-]{30,}\b/g],
  ['twilio-api-key',/\bSK[0-9a-fA-F]{32}\b/g],
  ['credential-assignment',/\b(?:password|passwd|secret|access[_-]?token|api[_-]?key)\b\s*[:=]\s*["'][A-Za-z0-9/+_=-]{20,}["']/gi]
];
const MAX_COMMITS=40,MAX_FULL_COMMITS=20000,MAX_HISTORY_FILES=5000,MAX_HISTORY_BYTES=128*1024*1024,MAX_HISTORY_TREE_BYTES=16*1024*1024,MAX_HISTORY_TREE_TOTAL_BYTES=512*1024*1024,MAX_HISTORY_TREE_ENTRIES=20000000,MAX_HISTORY_MS=120000,MAX_ARCHIVE=512*1024*1024,MAX_ARCHIVES=32,MAX_FINDINGS=5000,MAX_FINDING_BYTES=2*1024*1024,MAX_LOCATION_BYTES=512;
const MAX_PROVENANCE_RECORDS=5000,MAX_PROVENANCE_BYTES=2*1024*1024;
const TEXT_EXT=new Set(['.js','.cjs','.mjs','.ts','.dart','.kt','.java','.swift','.gradle','.kts','.xml','.json','.yaml','.yml','.properties','.txt','.html','.css','.sh','.py','.m','.h','.plist','.entitlements','.toml']);
const findingStates=new WeakMap();
function outputLimits(requested={}){
 const hard={maxFindings:MAX_FINDINGS,maxFindingBytes:MAX_FINDING_BYTES,maxPathBytes:MAX_LOCATION_BYTES};
 if(!requested||typeof requested!=='object'||Array.isArray(requested))throw Error('invalid output limits');
 for(const [key,value] of Object.entries(requested))if(!(key in hard)||!Number.isSafeInteger(value)||value<(key==='maxPathBytes'?32:1)||value>hard[key])throw Error('invalid output limits');
 return {...hard,...requested};
}
function findingState(findings,limits){let state=findingStates.get(findings);if(!state){state={incomplete:false,count:0,bytes:0,limits:outputLimits(limits)};findingStates.set(findings,state);}return state;}
function cleanPathDetailed(value,maxBytes=MAX_LOCATION_BYTES){
 const original=String(value);let sensitive=/(?:https?:\/\/)[^\s/]+@/i.test(original);
 for(const [,re] of RULES){re.lastIndex=0;if(re.test(original))sensitive=true;re.lastIndex=0;}
 if(sensitive){const digest=require('node:crypto').createHash('sha256').update(original).digest('hex').slice(0,16);return {path:`[redacted-path:${digest}]`,truncated:false};}
 const cleaned=original;
 const bytes=Buffer.byteLength(cleaned);if(bytes<=maxBytes)return {path:cleaned,truncated:false};
 const digest=require('node:crypto').createHash('sha256').update(cleaned).digest('hex').slice(0,16),suffix=`...[sha256:${digest}]`,budget=Math.max(0,maxBytes-Buffer.byteLength(suffix));let prefix='',used=0;
 for(const char of cleaned){const size=Buffer.byteLength(char);if(used+size>budget)break;prefix+=char;used+=size;}
 return {path:prefix+suffix,truncated:true};
}
function cleanPath(value,maxBytes=MAX_LOCATION_BYTES){return cleanPathDetailed(value,maxBytes).path;}
function addFinding(findings,item,limits,onAdded){
 const state=findingState(findings,limits);if(state.incomplete)return false;
 const location=cleanPathDetailed(item.file,state.limits.maxPathBytes);item={...item,file:location.path};
 const bytes=Buffer.byteLength(JSON.stringify(item));
 if(state.count>=state.limits.maxFindings||state.bytes+bytes>state.limits.maxFindingBytes){state.incomplete=true;return false;}
 findings.push(item);state.count++;state.bytes+=bytes;if(onAdded)onAdded(item);if(location.truncated){state.incomplete=true;return false;}return true;
}
function scanText(label,text,findings,scope,limits,onAdded){
 const state=findingState(findings,limits);let start=0,lineNumber=1;
 while(start<=text.length){if(state.incomplete)return;let end=text.indexOf('\n',start);if(end<0)end=text.length;let line=text.slice(start,end);if(line.endsWith('\r'))line=line.slice(0,-1);
  for(const [rule,re] of RULES){re.lastIndex=0;let count=0;while(re.exec(line)){count++;if(!re.lastIndex)re.lastIndex++;}if(count&&!addFinding(findings,{scope,file:label,line:lineNumber,rule,count},undefined,onAdded))return;}
  if(end===text.length)break;start=end+1;lineNumber++;
 }
}
function eligibleCurrent(root,findings){
 const snap=sourceSnapshot(root),base=fs.realpathSync(root);let bytes=0;
 for(const name of Object.keys(snap.file_sha256)){
  if(snap.file_sha256[name]==='deleted')continue;
  const absolute=path.resolve(base,name);if(!absolute.startsWith(base+path.sep)||!fs.realpathSync(absolute).startsWith(base+path.sep))throw Error('source path escapes audit root');
  const data=readBounded(absolute,16*1024*1024);bytes+=data.length;if(bytes>256*1024*1024)throw Error('source byte limit exceeded');
  if(TEXT_EXT.has(path.extname(name).toLowerCase()))scanText(name,data.toString('utf8'),findings,'working-tree');
 }
 return snap;
}
function historyLimits(mode,requested={}){
 const hard={maxCommits:mode==='full-retained'?MAX_FULL_COMMITS:MAX_COMMITS,maxFiles:MAX_HISTORY_FILES,maxBytes:MAX_HISTORY_BYTES,maxTreeBytes:MAX_HISTORY_TREE_BYTES,maxTreeTotalBytes:MAX_HISTORY_TREE_TOTAL_BYTES,maxTreeEntries:MAX_HISTORY_TREE_ENTRIES,maxMs:MAX_HISTORY_MS};
 if(!requested||typeof requested!=='object'||Array.isArray(requested))throw Error('invalid history limits');
 for(const [key,value] of Object.entries(requested))if(!(key in hard)||!Number.isSafeInteger(value)||value<1||value>hard[key])throw Error('invalid history limits');
 return {...hard,...requested};
}
function history(root,findings,mode='sampled',requestedLimits={},provenanceState=null){
 const limits=historyLimits(mode,requestedLimits),commitLimit=limits.maxCommits;
 let incomplete=false,commitList=[],shallowRepository=null;
 const emptyReport={mode,scan_scope:'retained-git-refs/release-source/recognized-text',incomplete:true,shallow_repository:null,commits_listed:0,commits_selected:0,commits_attempted:0,commits_examined:0,blobs_attempted:0,blobs_read:0,blobs_examined:0,blobs_failed:0,blobs_limit_rejected:0,bytes_examined:0,tree_entries_examined:0,tree_bytes_examined:0,limits,retained_history_complete:false};
 if(mode==='full-retained'){
  try{shallowRepository=execFileSync('git',['rev-parse','--is-shallow-repository'],{cwd:root,encoding:'utf8',timeout:5000,maxBuffer:1024,stdio:['ignore','pipe','ignore']}).trim()==='true';if(shallowRepository)incomplete=true;}
  catch(_){incomplete=true;}
 }
 try{commitList=execFileSync('git',['rev-list','--all',`--max-count=${commitLimit+1}`],{cwd:root,encoding:'utf8',timeout:30000,maxBuffer:2*1024*1024,stdio:['ignore','pipe','ignore']}).trim().split('\n').filter(Boolean);}catch(_){return {...emptyReport,shallow_repository:shallowRepository};}
 const commitsListed=commitList.length;
 if(commitsListed>commitLimit){commitList=commitList.slice(0,commitLimit);incomplete=true;}
 let blobsAttempted=0,blobsRead=0,blobsExamined=0,blobsFailed=0,blobsLimitRejected=0,total=0,treeEntries=0,treeBytes=0,commitsAttempted=0,commitsExamined=0;const seenPairs=new Set(),started=Date.now();
 // Inspect each retained commit's tree, rather than relying on path-limited git
 // log output. This naturally includes merge parents, branches, deleted files,
 // and both old/new names of renamed files while reading blobs without pathshells.
 commitLoop:for(const commit of commitList){
  if(findingState(findings).incomplete){incomplete=true;break;}
  if(Date.now()-started>=limits.maxMs){incomplete=true;break;}
  commitsAttempted++;
  let listing;
  try{listing=execFileSync('git',['ls-tree','-r','-z','--full-tree',commit],{cwd:root,encoding:'buffer',timeout:10000,maxBuffer:limits.maxTreeBytes,stdio:['ignore','pipe','ignore']});}
  catch(_){incomplete=true;continue;}
  treeBytes+=listing.length;if(treeBytes>limits.maxTreeTotalBytes){incomplete=true;break;}
  let commitComplete=true;
  for(const rawRecord of listing.toString('latin1').split('\0')){
   if(Date.now()-started>=limits.maxMs){incomplete=true;commitComplete=false;break commitLoop;}
   if(!rawRecord)continue;
   treeEntries++;if(treeEntries>limits.maxTreeEntries){incomplete=true;commitComplete=false;break commitLoop;}
   const record=Buffer.from(rawRecord,'latin1'),tab=record.indexOf(9);
   const match=tab<0?null:/^(\d{6}) (blob|commit) ([a-f0-9]{40,64})$/.exec(record.subarray(0,tab).toString('ascii'));
   if(!match){incomplete=true;commitComplete=false;continue;}
   const [,fileMode,objectType,objectId]=match;let name;
   try{name=new TextDecoder('utf-8',{fatal:true}).decode(record.subarray(tab+1));}catch(_){incomplete=true;commitComplete=false;continue;}
   if(objectType!=='blob'||!sourcePathAllowed(name)||!TEXT_EXT.has(path.extname(name).toLowerCase()))continue;
   const pairKey=objectId+'\0'+name;if(seenPairs.has(pairKey))continue;
   if(blobsAttempted>=limits.maxFiles){incomplete=true;commitComplete=false;blobsLimitRejected++;break commitLoop;}
   seenPairs.add(pairKey);blobsAttempted++;
   let data;try{data=execFileSync('git',['cat-file','blob',objectId],{cwd:root,encoding:'buffer',timeout:5000,maxBuffer:16*1024*1024,stdio:['ignore','pipe','ignore']});}
   catch(_){incomplete=true;commitComplete=false;blobsFailed++;continue;}
   blobsRead++;
   if(total+data.length>limits.maxBytes){incomplete=true;commitComplete=false;blobsLimitRejected++;break commitLoop;}
   total+=data.length;
   // Git symlinks are blobs too; scan their stored target text without following.
   if(fileMode==='120000'||fileMode==='100644'||fileMode==='100755'){
    blobsExamined++;scanText(name,data.toString('utf8'),findings,'git-history',undefined,item=>{
     if(!provenanceState)return;
     // rev-list traversal is descendant-first and branches have no unique
     // historical origin. This is the first containing commit observed here,
     // not a claim about when the blob or finding was introduced.
     const record={finding:item,blob_id:objectId,observed_commit_id:commit,file:item.file,line:item.line,rule:item.rule,count:item.count};
     // Reserve the widest possible finding index and JSON array separators so
     // the serialized record array stays within its byte budget as it grows.
     const bytes=Buffer.byteLength(JSON.stringify({finding_index:MAX_FINDINGS-1,blob_id:record.blob_id,observed_commit_id:record.observed_commit_id,file:record.file,line:record.line,rule:record.rule,count:record.count}))+(provenanceState.records.length?1:0);
     if(provenanceState.records.length>=provenanceState.limits.maxRecords||provenanceState.bytes+bytes>provenanceState.limits.maxBytes){provenanceState.incomplete=true;return;}
     provenanceState.records.push(record);provenanceState.bytes+=bytes;
    });
    if(findingState(findings).incomplete){incomplete=true;commitComplete=false;break commitLoop;}
   }
  }
  if(commitComplete)commitsExamined++;
 }
 incomplete ||= findingState(findings).incomplete;
 return {mode,scan_scope:'retained-git-refs/release-source/recognized-text',incomplete,shallow_repository:shallowRepository,commits_listed:commitsListed,commits_selected:commitList.length,commits_attempted:commitsAttempted,commits_examined:commitsExamined,blobs_attempted:blobsAttempted,blobs_read:blobsRead,blobs_examined:blobsExamined,blobs_failed:blobsFailed,blobs_limit_rejected:blobsLimitRejected,bytes_examined:total,tree_entries_examined:treeEntries,tree_bytes_examined:treeBytes,limits,retained_history_complete:!incomplete};
}
const ZIP_PY=String.raw`
import json,os,re,stat,sys,zipfile,posixpath,hashlib,io
p=sys.argv[1]; MAX_ENTRY=32*1024*1024; MAX_TOTAL=512*1024*1024; MAX_FILES=5000; MAX_RATIO=100
MAX_FINDINGS=min(int(sys.argv[2]),5000); MAX_FINDING_BYTES=min(int(sys.argv[3]),2*1024*1024); MAX_PATH_BYTES=min(int(sys.argv[4]),512)
rules=[('private-key-marker',re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----')),
('aws-access-key',re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
('github-token',re.compile(r'\bgh[pousr]_[A-Za-z0-9_]{30,}\b')),
('stripe-live-secret',re.compile(r'\bsk_live_[A-Za-z0-9]{16,}\b')),
('google-api-key',re.compile(r'\bAIza[0-9A-Za-z_-]{30,}\b')),
('twilio-api-key',re.compile(r'\bSK[0-9a-fA-F]{32}\b')),
('credential-assignment',re.compile(r'\b(?:password|passwd|secret|access[_-]?token|api[_-]?key)\b\s*[:=]\s*[\"\'][A-Za-z0-9/+_=-]{20,}[\"\']',re.I))]
ext={'.js','.cjs','.mjs','.ts','.dart','.kt','.java','.swift','.gradle','.kts','.xml','.json','.yaml','.yml','.properties','.txt','.html','.css','.sh','.py','.m','.h','.plist','.entitlements','.toml'}
def clean(s):
 original=s
 if re.search(r'https?://[^\s/@]+@',original,re.I) or any(r.search(original) for _,r in rules):
  return '[redacted-path:'+hashlib.sha256(original.encode('utf-8')).hexdigest()[:16]+']'
 raw=s.encode('utf-8')
 if len(raw)>MAX_PATH_BYTES:
  suffix=('...[sha256:'+hashlib.sha256(raw).hexdigest()[:16]+']').encode(); budget=max(0,MAX_PATH_BYTES-len(suffix))
  s=raw[:budget].decode('utf-8','ignore')+suffix.decode(); state['incomplete']=True
 return s
find=[]; state={'incomplete':False,'finding_bytes':0}; total=0; examined=0; scanned=0; skipped=0
def add_finding(item):
 encoded=json.dumps(item,separators=(',',':')).encode('utf-8')
 if len(find)>=MAX_FINDINGS or state['finding_bytes']+len(encoded)>MAX_FINDING_BYTES:
  state['incomplete']=True; return False
 find.append(item); state['finding_bytes']+=len(encoded); return True
try:
 fd=os.open(p,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0)); st=os.fstat(fd)
 if not stat.S_ISREG(st.st_mode) or st.st_size>512*1024*1024: raise ValueError('archive size/type bound')
 with os.fdopen(fd,'rb') as archive, zipfile.ZipFile(archive) as z:
  infos=z.infolist()
  if len(infos)>MAX_FILES:raise ValueError('archive file count bound')
  names=set()
  for info in infos:
   name=info.filename
   if info.flag_bits & 1: raise ValueError('encrypted archive entry')
   if info.compress_type not in (zipfile.ZIP_STORED,zipfile.ZIP_DEFLATED,zipfile.ZIP_BZIP2,zipfile.ZIP_LZMA):raise ValueError('unknown compression')
   norm=posixpath.normpath(name)
   if name.startswith('/') or '\\' in name or norm in ('.','..') or norm.startswith('../') or re.match(r'^[A-Za-z]:',name):raise ValueError('unsafe archive path')
   if norm in names:raise ValueError('duplicate archive path')
   names.add(norm)
   mode=(info.external_attr>>16)&0xffff
   if stat.S_ISLNK(mode):raise ValueError('archive symlink')
   if info.file_size>MAX_ENTRY or (info.compress_size==0 and info.file_size>0) or (info.compress_size and info.file_size/info.compress_size>MAX_RATIO):raise ValueError('archive expansion bound')
   total+=info.file_size
   if total>MAX_TOTAL:raise ValueError('archive total expansion bound')
   examined+=1
   if info.is_dir():continue
   if os.path.splitext(name)[1].lower() not in ext:skipped+=1;continue
   scanned+=1
   data=z.read(info) # verifies CRC; bounded by checked declared sizes
   text=data.decode('utf-8','replace')
   for ln,line in enumerate(io.StringIO(text),1):
    for rule,rx in rules:
     n=sum(1 for _ in rx.finditer(line))
     if n and not add_finding({'scope':'release-archive','file':clean(name),'line':ln,'rule':rule,'count':n}):break
    if state['incomplete']:break
   if state['incomplete']:break
 result={'findings':find,'incomplete':state['incomplete'],'entries_examined':examined,'text_entries_scanned':scanned,'non_text_entries_skipped':skipped,'bytes_examined':total}
except Exception: result={'findings':find,'incomplete':True,'entries_examined':examined,'text_entries_scanned':scanned,'non_text_entries_skipped':skipped,'bytes_examined':total,'failure_rule':'archive-input-incomplete'}
print(json.dumps(result,separators=(',',':')))
`;
function scanArchive(filename,requestedOutputLimits={}){
 const limits=outputLimits(requestedOutputLimits);
 let before;
 try{before=archiveDigest(filename);}catch(_){return {findings:[],incomplete:true,failure_rule:'archive-input-incomplete'};}
 const r=spawnSync('python3',['-c',ZIP_PY,filename,String(limits.maxFindings),String(limits.maxFindingBytes),String(limits.maxPathBytes)],{encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});
 if(r.error||r.status!==0) return {findings:[],incomplete:true,entries_examined:0,text_entries_scanned:0,non_text_entries_skipped:0,bytes_examined:0,failure_rule:'archive-input-incomplete'};
 try{const result=JSON.parse(r.stdout);if(before!==archiveDigest(filename))throw Error('changed');return {...result,sha256:before};}catch(_){return {findings:[],incomplete:true,entries_examined:0,text_entries_scanned:0,non_text_entries_skipped:0,bytes_examined:0,failure_rule:'archive-input-incomplete'};}
}
function archiveDigest(filename){const fd=fs.openSync(filename,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);try{const before=fs.fstatSync(fd);if(!before.isFile()||before.size>MAX_ARCHIVE)throw Error('archive bound');const hash=require('node:crypto').createHash('sha256'),buffer=Buffer.alloc(65536);let total=0,n;while((n=fs.readSync(fd,buffer,0,buffer.length,null))>0){total+=n;if(total>MAX_ARCHIVE)throw Error('archive changed');hash.update(buffer.subarray(0,n));}const after=fs.fstatSync(fd);if(total!==before.size||before.size!==after.size||before.mtimeMs!==after.mtimeMs||before.ctimeMs!==after.ctimeMs)throw Error('archive changed');return hash.digest('hex');}finally{fs.closeSync(fd);}}
function audit({root=process.cwd(),archives=[],historyMode='sampled',historyLimits:requestedHistoryLimits={},outputLimits:requestedOutputLimits={},historyProvenance=false,historyProvenanceLimits:requestedProvenanceLimits={}}={}){
 if(!['sampled','full-retained'].includes(historyMode))throw Error('unsupported history mode');
 if(typeof historyProvenance!=='boolean'||(historyProvenance&&historyMode!=='full-retained'))throw Error('history provenance requires full-retained mode');
 const provenanceLimits={maxRecords:MAX_PROVENANCE_RECORDS,maxBytes:MAX_PROVENANCE_BYTES};
 if(!requestedProvenanceLimits||typeof requestedProvenanceLimits!=='object'||Array.isArray(requestedProvenanceLimits))throw Error('invalid history provenance limits');
 for(const [key,value] of Object.entries(requestedProvenanceLimits))if(!(key in provenanceLimits)||!Number.isSafeInteger(value)||value<(key==='maxBytes'?2:1)||value>provenanceLimits[key])throw Error('invalid history provenance limits');
 Object.assign(provenanceLimits,requestedProvenanceLimits);
 const output=outputLimits(requestedOutputLimits),findings=[];findingState(findings,output);let incomplete=false;
 const source=eligibleCurrent(root,findings);
 const provenanceState=historyProvenance?{records:[],bytes:2,incomplete:false,limits:provenanceLimits}:null;
 const hist=history(root,findings,historyMode,requestedHistoryLimits,provenanceState);incomplete ||= hist.incomplete;if(provenanceState&&hist.incomplete)provenanceState.incomplete=true;
 const archiveReports=[];
 if(!Array.isArray(archives))throw Error('invalid archive list');
 if(archives.length>MAX_ARCHIVES)incomplete=true;
 for(const archive of archives.slice(0,MAX_ARCHIVES)){
  const report=scanArchive(archive,output);
  const archiveName=cleanPathDetailed(path.basename(archive),output.maxPathBytes);
  archiveReports.push({file:archiveName.path,sha256:report.sha256??null,entries_examined:report.entries_examined??0,text_entries_scanned:report.text_entries_scanned??0,non_text_entries_skipped:report.non_text_entries_skipped??0,bytes_examined:report.bytes_examined??0,incomplete:report.incomplete||archiveName.truncated,...(report.failure_rule?{failure_rule:report.failure_rule}:{})});
  for(const finding of report.findings||[])if(!addFinding(findings,finding,output))break;
  if(archiveName.truncated)findingState(findings).incomplete=true;
  incomplete ||= report.incomplete||archiveName.truncated||findingState(findings).incomplete;
 }
 incomplete ||= findingState(findings).incomplete;
 incomplete ||= source.candidate_sha256!==sourceSnapshot(root).candidate_sha256;
 findings.sort((a,b)=>a.scope.localeCompare(b.scope)||a.file.localeCompare(b.file)||a.line-b.line||a.rule.localeCompare(b.rule));
 const result={format:'pandapay-release-secret-audit-v1',source_sha256:source.candidate_sha256,network:'none',raw_values_emitted:false,heuristic:true,incomplete:incomplete||Boolean(provenanceState?.incomplete),history:hist,archives:archiveReports,findings};
 if(provenanceState){
  const indexes=new Map(findings.map((finding,index)=>[finding,index]));
  const records=provenanceState.records.map(({finding,...record})=>({finding_index:indexes.get(finding),...record}));
  result.history_provenance={enabled:true,incomplete:provenanceState.incomplete,records,limits:provenanceState.limits,records_bytes:Buffer.byteLength(JSON.stringify(records))};
 }
 return result;
}
function main(argv=process.argv.slice(2)){
 const archives=[];let root=process.cwd(),historyMode='sampled',historyProvenance=false;for(let i=0;i<argv.length;i++){if(argv[i]==='--root'&&argv[i+1])root=path.resolve(argv[++i]);else if(argv[i]==='--archive'&&argv[i+1])archives.push(path.resolve(argv[++i]));else if(argv[i]==='--history-full-retained')historyMode='full-retained';else if(argv[i]==='--history-provenance')historyProvenance=true;else throw Error('unsupported arguments');}
 const result=audit({root,archives,historyMode,historyProvenance});process.stdout.write(JSON.stringify(result,null,2)+'\n');if(result.incomplete)process.exitCode=2;
}
if(require.main===module)try{main();}catch(_){process.stderr.write('Secret audit incomplete; no raw findings emitted.\n');process.exitCode=2;}
module.exports={audit,scanArchive,scanText,sourcePathAllowed,RULES};
