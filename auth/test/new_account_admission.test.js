'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {newAccountsPaused,respondPaused}=require('../src/services/newAccountAdmission');
test('signup admission defaults open, accepts only explicit pause values and returns retryable private response',()=>{
 for(const env of [{},{NEW_ACCOUNT_REGISTRATIONS_PAUSED:''},{NEW_ACCOUNT_REGISTRATIONS_PAUSED:'false'}])assert.equal(newAccountsPaused(env),false);
 assert.equal(newAccountsPaused({NEW_ACCOUNT_REGISTRATIONS_PAUSED:'true'}),true);
 for(const value of ['1','TRUE','false ',1])assert.throws(()=>newAccountsPaused({NEW_ACCOUNT_REGISTRATIONS_PAUSED:value}));
 const res={headers:{},setHeader(k,v){this.headers[k]=v;},status(code){this.code=code;return this;},json(body){this.body=body;return this;}};
 respondPaused(res);assert.equal(res.code,503);assert.equal(res.headers['Retry-After'],'300');assert.equal(res.headers['Cache-Control'],'no-store');
});
