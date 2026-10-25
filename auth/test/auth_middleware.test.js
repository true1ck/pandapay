const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');

process.env.NODE_ENV = 'test';
process.env.DATABASE_URL = 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET = 'legacy-access-secret';
process.env.JWT_REFRESH_SECRET = 'synthetic-refresh-secret';
process.env.JWT_KEYS_JSON = JSON.stringify({
  current: 'current-access-secret',
  previous: 'previous-access-secret',
});
process.env.JWT_ACTIVE_KEY_ID = 'current';
process.env.JWT_ISSUER = 'pandapay-auth';
process.env.JWT_AUDIENCE = 'mobile-app';

const authMiddleware = require('../src/middleware/authMiddleware');

test('auth middleware rejects unknown key ids without trying configured keys', async () => {
  const token = jwt.sign(
    { sub: 'user-123' },
    'current-access-secret',
    {
      keyid: 'not-configured',
      issuer: 'pandapay-auth',
      audience: 'mobile-app',
      expiresIn: '5m',
    },
  );
  const response = {
    statusCode: null,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };

  await authMiddleware({ headers: { authorization: `Bearer ${token}` } }, response, () => {
    assert.fail('middleware must reject an unknown key id');
  });

  assert.equal(response.statusCode, 401);
  assert.deepEqual(response.body, { error: 'Invalid or expired token' });
});


test('auth middleware exposes only the signed device claim after checking its active device row', async t => {
  const db=require('../src/db'),original=db.query;let calls=0;
  db.query=async(sql,args)=>{calls++;if(sql.includes('FROM user_devices')){assert.deepEqual(args,['user-123','signed-device']);return{rows:[{id:'device-row'}]};}return{rows:[{token_version:1,is_active:true,deleted:false}]};};
  t.after(()=>{db.query=original;});
  const token=jwt.sign({sub:'user-123',device_id:'signed-device'},'current-access-secret',{keyid:'current',issuer:'pandapay-auth',audience:'mobile-app',expiresIn:'5m'});
  const req={headers:{authorization:`Bearer ${token}`},body:{device_id:'client-forgery'}};
  await authMiddleware(req,{status(){assert.fail('Valid session should pass');}},()=>{});
  assert.equal(req.user.device_id,'signed-device');assert.equal(calls,2);
});
