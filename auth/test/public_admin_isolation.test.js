'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const fs = require('node:fs');
const path = require('node:path');
const {denyPublicAdmin} = require('../src/publicAdminBoundary');
test('customer auth rejects public and encoded admin route variants', async t => {
  const app=express();app.use(denyPublicAdmin);app.use((_req,res)=>res.json({customer:true}));
  const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
  t.after(()=>{server.closeAllConnections();server.close();});
  const base=`http://127.0.0.1:${server.address().port}`;
  for(const route of ['/admin','/ADMIN/me','//browser/login/start','/%62rowser/session','/internal/%61dmin/session/introspect']) {
    for(const method of ['GET','POST','OPTIONS','HEAD']) assert.equal((await fetch(base+route,{method})).status,404,method+' '+route);
  }
  assert.equal((await fetch(base+'/auth/request-email-otp')).status,200);
});
test('customer auth entrypoint never initializes or mounts legacy admin runtimes',()=>{
  const source=fs.readFileSync(path.join(__dirname,'../src/index.js'),'utf8');
  assert.doesNotMatch(source,/createConsoleBrowserRuntime|app\.use\(['"]\/browser|app\.use\(['"]\/admin|sendFile\('security-dashboard/);
});
