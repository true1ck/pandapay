'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { allowedOrigins, createCorsPolicy } = require('../src/cors_policy');
const { JSON_BODY_LIMIT_BYTES, jsonBodyParser, jsonBodyErrorHandler } = require('../src/request_limits');

test('hosted CORS requires explicit valid origins and normalizes configured URLs', () => {
  for (const NODE_ENV of ['production', 'staging']) {
    for (const CORS_ALLOWED_ORIGINS of ['', '*', 'null', 'https://*.example.test', 'https://console.example.test/path', 'https://u:p@example.test', 'javascript:example']) {
      assert.throws(() => allowedOrigins({ NODE_ENV, CORS_ALLOWED_ORIGINS }));
    }
  }
  assert.deepEqual([...allowedOrigins({ NODE_ENV: 'production', CORS_ALLOWED_ORIGINS: ' https://Console.example.test/,https://console.example.test ' })], ['https://console.example.test']);
});

async function server(t, env) {
  const app = express();
  app.use(...createCorsPolicy(env));
  app.use(jsonBodyParser, jsonBodyErrorHandler);
  app.all('/fixture', (req, res) => res.json({ ok: true, value: req.body?.value }));
  const http = await new Promise(resolve => { const value = app.listen(0, '127.0.0.1', () => resolve(value)); });
  t.after(() => new Promise(resolve => { http.close(resolve); http.closeAllConnections(); }));
  return `http://127.0.0.1:${http.address().port}/fixture`;
}

test('allowed console, preflight and native requests work; unrelated browser origins fail', async t => {
  const url = await server(t, { NODE_ENV: 'production', CORS_ALLOWED_ORIGINS: 'https://console.example.test' });
  const allowed = await fetch(url, { headers: { Origin: 'https://console.example.test' } });
  assert.equal(allowed.status, 200);
  assert.equal(allowed.headers.get('access-control-allow-origin'), 'https://console.example.test');
  assert.equal(allowed.headers.get('access-control-allow-credentials'), null);
  const preflight = await fetch(url, { method: 'OPTIONS', headers: {
    Origin: 'https://console.example.test', 'Access-Control-Request-Method': 'PATCH',
    'Access-Control-Request-Headers': 'authorization,content-type,x-request-id,if-match',
  } });
  assert.equal(preflight.status, 204);
  assert.match(preflight.headers.get('access-control-allow-methods'), /PATCH/);
  assert.match(preflight.headers.get('access-control-allow-headers'), /if-match/);
  assert.equal((await fetch(url)).status, 200);
  for (const Origin of ['https://evil.example.test', 'https://console.example.test.evil.test', 'null']) {
    const denied = await fetch(url, { headers: { Origin } });
    assert.equal(denied.status, 403);
    assert.equal(denied.headers.get('access-control-allow-origin'), null);
    assert.deepEqual(await denied.json(), { error: 'origin_not_allowed' });
  }
});

test('unconfigured local development retains browser access', async t => {
  const url = await server(t, { NODE_ENV: 'development' });
  const response = await fetch(url, { headers: { Origin: 'http://localhost:3000' } });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('access-control-allow-origin'), 'http://localhost:3000');
});

test('JSON keeps the previous 100 KiB boundary and safe parsing errors', async t => {
  const url = await server(t, { NODE_ENV: 'test' });
  const headers = { 'Content-Type': 'application/json' };
  const small = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ value: 'ok' }) });
  assert.deepEqual(await small.json(), { ok: true, value: 'ok' });
  const atLimit = JSON.stringify({ value: 'a'.repeat(JSON_BODY_LIMIT_BYTES - 12) });
  assert.equal(Buffer.byteLength(atLimit), JSON_BODY_LIMIT_BYTES);
  assert.equal((await fetch(url, { method: 'POST', headers, body: atLimit })).status, 200);
  const tooLarge = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ value: 'a'.repeat(JSON_BODY_LIMIT_BYTES) }) });
  assert.equal(tooLarge.status, 413);
  assert.deepEqual(await tooLarge.json(), { error: 'payload_too_large' });
  const invalid = await fetch(url, { method: 'POST', headers, body: '{"private":"contact@example.test",' });
  assert.equal(invalid.status, 400);
  assert.deepEqual(await invalid.json(), { error: 'invalid_json' });
});

test('compressed JSON with trailing bytes cannot crash the API parser process',async()=>{
  const execFile=require('node:util').promisify(require('node:child_process').execFile);
  const source=`
    const express=require('express'),http=require('node:http'),{gzipSync}=require('node:zlib');
    const {jsonBodyParser,jsonBodyErrorHandler}=require(${JSON.stringify(require.resolve('../src/request_limits'))});
    const app=express();app.use(jsonBodyParser);app.use(jsonBodyErrorHandler);
    app.post('/probe',(req,res)=>res.json({ok:true}));app.get('/health',(req,res)=>res.json({ok:true}));
    app.use((err,req,res,next)=>res.status(400).json({error:'invalid_json'}));
    const server=app.listen(0,'127.0.0.1',async()=>{
      try{const body=Buffer.concat([gzipSync(Buffer.from('{"ok":true}')),Buffer.from('trailing bytes')]);
        await new Promise((resolve,reject)=>{const req=http.request({hostname:'127.0.0.1',port:server.address().port,path:'/probe',method:'POST',headers:{'Content-Type':'application/json','Content-Encoding':'gzip','Content-Length':body.length}},res=>{res.resume();res.on('end',resolve);});req.on('error',reject);req.end(body);});
        await new Promise(r=>setTimeout(r,50));const health=await fetch('http://127.0.0.1:'+server.address().port+'/health');
        if(health.status!==200)throw Error('health failed');server.closeAllConnections();server.close();
      }catch(_){server.closeAllConnections();server.close();process.exitCode=1;}
    });`;
  await execFile(process.execPath,['-e',source],{timeout:10000,maxBuffer:65536});
});
