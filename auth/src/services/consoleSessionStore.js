'use strict';
const { randomBytes, createHash, createCipheriv, createDecipheriv } = require('node:crypto');
const TOKEN = /^[A-Za-z0-9_-]{43}$/;
const digest = value => createHash('sha256').update(value).digest('hex');

function createConsoleSessionStore({ pool, encryptionKey }) {
  const key = Buffer.from(encryptionKey || '', 'base64');
  if (!pool || key.length !== 32 || key.toString('base64') !== encryptionKey) throw new Error('Console session configuration invalid');
  let active=0;
  function encrypt(hash, value) {
    const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, iv);
    cipher.setAAD(Buffer.from(hash));
    const body = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), body]).toString('base64');
  }
  function decrypt(hash, value) {
    const bytes = Buffer.from(value, 'base64');
    const cipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
    cipher.setAAD(Buffer.from(hash)); cipher.setAuthTag(bytes.subarray(12, 28));
    return JSON.parse(Buffer.concat([cipher.update(bytes.subarray(28)), cipher.final()]).toString('utf8'));
  }
  async function create(tokens) {
    const id = randomBytes(32).toString('base64url'), hash = digest(id);
    const state = { ...tokens, csrf: randomBytes(32).toString('base64url') };
    await pool.query(`INSERT INTO console_private.sessions(session_hash,encrypted_tokens,expires_at)
      VALUES ($1,$2,now()+interval '12 hours')`, [hash, encrypt(hash, state)]);
    return { id, csrf: state.csrf };
  }
  async function withSession(id, work) {
    if (!TOKEN.test(id || '')) return null;
    if(active>=2)throw new Error('Console session capacity unavailable');
    active++;
    let client, broken, began=false;
    try {
      client=await pool.connect();
      await client.query('BEGIN');
      began=true;
      await client.query("SET LOCAL lock_timeout='3s'");
      await client.query("SET LOCAL statement_timeout='5s'");
      const hash = digest(id);
      const row = (await client.query(`SELECT encrypted_tokens FROM console_private.sessions
        WHERE session_hash=$1 AND expires_at>now() AND last_used_at>now()-interval '30 minutes' FOR UPDATE`, [hash])).rows[0];
      if (!row) { await client.query('COMMIT'); began=false; return null; }
      const state = decrypt(hash, row.encrypted_tokens);
      let result, workError;
      try { result=await work(state); } catch(error) { workError=error; }
      // A confirmed upstream refresh already rotated its credential. Preserve
      // it even if the subsequent admin request fails, so a transient outage
      // cannot make the next request replay the old refresh token.
      if (result?.destroy) await client.query('DELETE FROM console_private.sessions WHERE session_hash=$1', [hash]);
      else if(!result?.denied) await client.query(`UPDATE console_private.sessions SET encrypted_tokens=$2,last_used_at=now() WHERE session_hash=$1`, [hash, encrypt(hash, state)]);
      await client.query('COMMIT'); began=false;
      if(workError)throw workError;
      return result;
    } catch (error) {
      if(began)try { await client.query('ROLLBACK'); } catch (failure) { broken = failure; }
      throw error;
    } finally { active--; if(client)client.release(broken); }
  }
  async function cleanup() {
    return pool.query(`DELETE FROM console_private.sessions WHERE session_hash IN
      (SELECT session_hash FROM console_private.sessions WHERE expires_at<=now()
       OR last_used_at<=now()-interval '30 minutes' ORDER BY expires_at LIMIT 100)`);
  }
  async function destroy(id){
    if(!TOKEN.test(id||''))return;
    await pool.query('DELETE FROM console_private.sessions WHERE session_hash=$1',[digest(id)]);
  }
  return { create, withSession, cleanup,destroy };
}
module.exports = { createConsoleSessionStore, digest };
