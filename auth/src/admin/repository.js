'use strict';

// Private-console persistence. The caller owns the small bounded pool and
// supplies HMAC digests; this module never keeps process-local authority.
const crypto = require('node:crypto');
const digest = value => crypto.createHash('sha256').update(String(value)).digest('hex');

function createAdminRepository({ pool, environment = 'local', sessionEpoch } = {}) {
  if (!pool || typeof pool.query !== 'function' || typeof pool.connect !== 'function') throw new TypeError('A PostgreSQL pool is required');
  if(typeof sessionEpoch!=='string'||sessionEpoch.length<32||sessionEpoch.length>128)throw new TypeError('External admin session epoch is required');
  const principal = row => row && ({ userId: row.user_id, email: row.email, principalStatus: row.state,
    principalVersion: Number(row.version), accountActive: row.account_active === true, emailVerified: row.email_verified === true });
  async function transaction(fn) {
    const c = await pool.connect();
    try { await c.query('BEGIN'); const out = await fn(c); await c.query('COMMIT'); return out; }
    catch (e) { await c.query('ROLLBACK').catch(() => {}); throw e; } finally { c.release(); }
  }
  return {
    async readiness() { await pool.query('SELECT 1 FROM admin_private.sessions LIMIT 0'); },
    async findVerifiedPrincipalByEmail(email) {
      const r = await pool.query(`SELECT p.user_id,p.state,p.version,u.email,u.is_active account_active,u.is_email_verified email_verified
        FROM admin_private.principals p JOIN public.users u ON u.id=p.user_id
        WHERE lower(u.email)=lower($1) AND u.is_active AND NOT u.deleted AND u.is_email_verified LIMIT 1`, [email]);
      return principal(r.rows[0]);
    },
    async createLoginChallenge({ loginId, email, codeDigest, preauthCookieDigest, expiresAt, sourceKey, origin='https://localhost:8443', rpId='localhost', now=new Date() }) {
      const p = await this.findVerifiedPrincipalByEmail(email);
      await transaction(async c => {
        await c.query(`UPDATE admin_private.challenges SET consumed_at=$2 WHERE login_id=$1 AND consumed_at IS NULL`, [loginId, now]);
        await c.query(`INSERT INTO admin_private.challenges(login_id,preauth_cookie_digest,user_id,purpose,challenge_digest,origin,rp_id,expires_at)
          VALUES($1,$2,$3,'email',$4,$5,$6,$7)`, [loginId,preauthCookieDigest,p?.userId || null,codeDigest,origin,rpId,expiresAt]);
        if (sourceKey) {
          const limit=await this.rateLimit({ key: `login:${sourceKey}`, now, limit: 20, windowMs: 600000 }, c);
          if(!limit.allowed) throw Object.assign(new Error('rate limit exceeded'),{code:'ADMIN_RATE_LIMIT'});
        }
      });
      return { loginId, principal: p };
    },
    async consumeEmailChallenge({ loginId, codeDigest, preauthCookieDigest, now=new Date() }) {
      return transaction(async c => {
        const r=await c.query(`SELECT id,user_id,challenge_digest FROM admin_private.challenges WHERE login_id=$1 AND preauth_cookie_digest=$3 AND purpose='email'
          AND consumed_at IS NULL AND expires_at>$2 AND attempts<5 FOR UPDATE`,[loginId,now,preauthCookieDigest]);
        if(!r.rowCount) return {ok:false};
        const x=r.rows[0];
        await c.query(`UPDATE admin_private.challenges SET attempts=attempts+1,consumed_at=CASE WHEN challenge_digest=$2 THEN $3 ELSE consumed_at END WHERE id=$1`,[x.id,codeDigest,now]);
        const a=Buffer.from(x.challenge_digest,'hex'),b=Buffer.from(codeDigest,'hex');
        if(a.length!==b.length||!crypto.timingSafeEqual(a,b)||!x.user_id) return {ok:false};
        const q = await c.query(`SELECT p.user_id,p.state,p.version,u.email,u.is_active account_active,u.is_email_verified email_verified
          FROM admin_private.principals p JOIN public.users u ON u.id=p.user_id WHERE p.user_id=$1 AND u.is_active AND NOT u.deleted AND u.is_email_verified`, [x.user_id]);
        if (!q.rowCount) return { ok:false };
        await c.query(`INSERT INTO admin_private.email_proofs(login_id,user_id,preauth_cookie_digest,expires_at) VALUES($1,$2,$3,$4)
          ON CONFLICT(login_id) DO UPDATE SET user_id=EXCLUDED.user_id,preauth_cookie_digest=EXCLUDED.preauth_cookie_digest,expires_at=EXCLUDED.expires_at,consumed_at=NULL`,[loginId,x.user_id,preauthCookieDigest,new Date(now.getTime()+120000)]);
        return { ok:true, loginId, principal:principal(q.rows[0]) };
      });
    },
    async createWebAuthnChallenge({ userId,loginId,preauthCookieDigest,sessionId,purpose,challengeDigest,challengeValue,grantDigest=null,origin,rpId,credentialIds=[],expiresAt }) {
      const id = crypto.randomUUID();
      await transaction(async c => {
        if(purpose==='enrollment') {
          const proof=await c.query(`SELECT 1 FROM admin_private.email_proofs ep JOIN admin_private.principals p ON p.user_id=ep.user_id
            WHERE ep.login_id=$1 AND ep.user_id=$2 AND ep.consumed_at IS NULL AND ep.expires_at>now() AND p.state='pending'`,[loginId,userId]);
          if(!proof.rowCount) throw new Error('Enrollment requires current verified email proof');
        }
        await c.query(`UPDATE admin_private.challenges SET consumed_at=now() WHERE login_id=$1 AND purpose=$2 AND consumed_at IS NULL`,[loginId,purpose]);
        await c.query(`INSERT INTO admin_private.challenges(id,login_id,preauth_cookie_digest,user_id,purpose,challenge_digest,challenge_value,grant_digest,origin,rp_id,credential_ids,expires_at)
          VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,[id,loginId,preauthCookieDigest,userId,purpose,challengeDigest,challengeValue,grantDigest,origin,rpId,credentialIds,expiresAt]);
      });
      return { id };
    },
    async consumeWebAuthnChallenge({ loginId,purpose,challengeDigest,preauthCookieDigest,now=new Date(),userId }) {
      const r = await pool.query(`UPDATE admin_private.challenges SET consumed_at=$4
        WHERE id=(SELECT id FROM admin_private.challenges WHERE login_id=$1 AND purpose=$2 AND challenge_digest=$3
          AND preauth_cookie_digest=$5 AND consumed_at IS NULL AND expires_at>$4 AND ($6::uuid IS NULL OR user_id=$6) LIMIT 1 FOR UPDATE SKIP LOCKED)
        RETURNING user_id,challenge_value,purpose,origin,rp_id,credential_ids,expires_at`,[loginId,purpose,challengeDigest,now,preauthCookieDigest,userId||null]);
      const x=r.rows[0]; return x && { userId:x.user_id, challenge:x.challenge_value, purpose:x.purpose, origin:x.origin,rpId:x.rp_id,credentialIds:x.credential_ids,expiresAt:x.expires_at };
    },
    async getWebAuthnChallenge({loginId,purpose,challengeDigest,preauthCookieDigest,now=new Date(),userId}) {
      const r=await pool.query(`SELECT ch.user_id,ch.challenge_value,ch.purpose,ch.origin,ch.rp_id,ch.credential_ids,ch.grant_digest,ch.expires_at,g.slot
        FROM admin_private.challenges ch LEFT JOIN admin_private.enrollment_grants g ON g.grant_digest=ch.grant_digest
        WHERE ch.login_id=$1 AND ch.purpose=$2 AND ch.challenge_digest=$3 AND ch.preauth_cookie_digest=$5 AND ch.consumed_at IS NULL AND ch.expires_at>$4
          AND ($6::uuid IS NULL OR ch.user_id=$6)`,[loginId,purpose,challengeDigest,now,preauthCookieDigest,userId||null]);
      const x=r.rows[0];return x&&{userId:x.user_id,challenge:x.challenge_value,purpose:x.purpose,origin:x.origin,rpId:x.rp_id,credentialIds:x.credential_ids,grantDigest:x.grant_digest,slot:x.slot,expiresAt:x.expires_at};
    },
    async listCredentials(userId) {
      const r=await pool.query(`SELECT credential_id,public_key,counter,transports,device_type,backed_up,slot FROM admin_private.credentials WHERE user_id=$1 AND revoked_at IS NULL`,[userId]);
      return r.rows.map(x=>({credentialId:x.credential_id,publicKey:x.public_key,counter:Number(x.counter),transports:x.transports,deviceType:x.device_type,backedUp:x.backed_up,slot:x.slot}));
    },
    async createEnrollmentGrant({ grantDigest,userId,environment:env=environment,origin,rpId,slot,expiresAt }) {
      await pool.query(`INSERT INTO admin_private.enrollment_grants(grant_digest,user_id,environment,origin,rp_id,slot,expires_at)
        SELECT $1,$2,$3,$4,$5,$6,$7 WHERE EXISTS(SELECT 1 FROM admin_private.principals WHERE user_id=$2 AND state='pending')`,[grantDigest,userId,env,origin,rpId,slot,expiresAt]);
    },
    async getEnrollmentGrant({grantDigest,loginId,preauthCookieDigest,environment:env=environment,origin,rpId,now=new Date()}) {
      const r=await pool.query(`SELECT g.user_id,g.slot FROM admin_private.enrollment_grants g JOIN admin_private.email_proofs ep
        ON ep.user_id=g.user_id AND ep.login_id=$2 WHERE g.grant_digest=$1 AND ep.preauth_cookie_digest=$6 AND g.environment=$3 AND g.origin=$4 AND g.rp_id=$5
        AND g.consumed_at IS NULL AND g.expires_at>$7 AND ep.consumed_at IS NULL AND ep.expires_at>$7`,[grantDigest,loginId,env,origin,rpId,preauthCookieDigest,now]);
      return r.rows[0]?{userId:r.rows[0].user_id,slot:r.rows[0].slot,grantDigest}:null;
    },
    async consumeEnrollmentGrant({ grantDigest,loginId,preauthCookieDigest,userId,environment:env=environment,origin,rpId,slot,now=new Date() }, client=pool) {
      const r=await client.query(`UPDATE admin_private.enrollment_grants g SET consumed_at=$7 FROM admin_private.email_proofs ep
        WHERE g.grant_digest=$1 AND g.user_id=coalesce($2::uuid,ep.user_id) AND ep.login_id=$8 AND ep.user_id=g.user_id AND ep.preauth_cookie_digest=$9
          AND ep.consumed_at IS NULL AND ep.expires_at>$7 AND g.environment=$3 AND g.origin=$4 AND g.rp_id=$5 AND g.slot=$6
          AND g.consumed_at IS NULL AND g.expires_at>$7 RETURNING g.user_id`,[grantDigest,userId||null,env,origin,rpId,slot,now,loginId,preauthCookieDigest]);
      return r.rowCount===1;
    },
    async addCredential({ loginId,preauthCookieDigest,challengeDigest,credentialId,publicKey,counter=0,transports=[],deviceType,backedUp=false,origin,rpId,now=new Date(),environment:env=environment }) {
      const result = await pool.query('SELECT * FROM admin_private.register_credential($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)',
        [loginId,preauthCookieDigest,challengeDigest,credentialId,publicKey,counter,transports,deviceType,backedUp,env]);
      return result.rows[0] || null;
    },
    async updateCredentialCounter({credentialId,userId,oldCounter,newCounter}) {
      const r=await pool.query('UPDATE admin_private.credentials SET counter=$4 WHERE credential_id=$1 AND user_id=$2 AND counter=$3 AND revoked_at IS NULL RETURNING credential_id',[credentialId,userId,oldCounter,newCounter]);
      if(r.rowCount!==1)throw new Error('Credential changed concurrently');
    },
    async createAdminSession({ userId,credentialId,verifiedAt,cookieDigest,accessTokenDigest,csrfDigest,encryptedUpstreamToken,accessTokenExpiresAt,absoluteExpiresAt,idleExpiresAt,now=new Date() }) {
      return transaction(async c=>{
        const p=await c.query(`SELECT p.version FROM admin_private.principals p JOIN public.users u ON u.id=p.user_id
          WHERE p.user_id=$1 AND p.state='enabled' AND u.is_active AND NOT u.deleted AND u.is_email_verified
          AND (SELECT count(*) FROM admin_private.credentials cr WHERE cr.user_id=p.user_id AND cr.revoked_at IS NULL)>=2`,[userId]);
        if(!p.rowCount) return null;
        const s=await c.query(`INSERT INTO admin_private.sessions(user_id,principal_version,session_epoch,cookie_digest,csrf_digest,verified_at,idle_expires_at,absolute_expires_at,encrypted_upstream_token,created_at)
          VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id,idle_expires_at`,[userId,p.rows[0].version,sessionEpoch,cookieDigest,csrfDigest,verifiedAt,idleExpiresAt,absoluteExpiresAt,encryptedUpstreamToken,now]);
        await c.query(`INSERT INTO admin_private.access_tokens(token_digest,session_id,expires_at) VALUES($1,$2,least($3::timestamptz,$4::timestamptz))`,[accessTokenDigest,s.rows[0].id,accessTokenExpiresAt||new Date(now.getTime()+300000),absoluteExpiresAt]);
        return {sessionId:s.rows[0].id,expiresAt:s.rows[0].idle_expires_at};
      });
    },
    async resolveAdminSessionByToken(tokenDigest,now=new Date()) {
      const r=await pool.query(`SELECT s.id session_id,s.user_id actor_id,s.verified_at,s.absolute_expires_at,s.idle_expires_at,p.version
        FROM admin_private.access_tokens t JOIN admin_private.sessions s ON s.id=t.session_id
        JOIN admin_private.principals p ON p.user_id=s.user_id JOIN public.users u ON u.id=s.user_id
        WHERE t.token_digest=$1 AND t.revoked_at IS NULL AND t.expires_at>$2 AND s.revoked_at IS NULL AND s.idle_expires_at>$2
          AND s.absolute_expires_at>$2 AND s.principal_version=p.version AND s.session_epoch=$3 AND p.state='enabled' AND u.is_active AND NOT u.deleted AND u.is_email_verified`,[tokenDigest,now,sessionEpoch]);
      const x=r.rows[0];return x?{active:true,actorId:x.actor_id,sessionId:x.session_id,assurance:'webauthn_uv',verifiedAt:x.verified_at,expiresAt:x.idle_expires_at,principalVersion:Number(x.version)}:{active:false};
    },
    async loadSession(cookieDigest,now=new Date()) { const r=await pool.query(`SELECT s.id,s.user_id,s.csrf_digest,s.verified_at,s.idle_expires_at,s.absolute_expires_at,s.encrypted_upstream_token,
      (SELECT max(t.expires_at) FROM admin_private.access_tokens t WHERE t.session_id=s.id AND t.revoked_at IS NULL) access_token_expires_at
      FROM admin_private.sessions s JOIN admin_private.principals p ON p.user_id=s.user_id JOIN public.users u ON u.id=s.user_id
      WHERE s.cookie_digest=$1 AND s.revoked_at IS NULL AND s.idle_expires_at>$2 AND s.absolute_expires_at>$2
        AND s.principal_version=p.version AND s.session_epoch=$3 AND p.state='enabled' AND u.is_active AND NOT u.deleted AND u.is_email_verified`,[cookieDigest,now,sessionEpoch]);return r.rows[0]||null; },
    async rotateAccessToken({sessionId,oldTokenDigest,newTokenDigest,newEncryptedUpstreamToken,expiresAt,now=new Date(),overlapUntil=null}) {
      return transaction(async c=>{
        const current=await c.query(`SELECT s.absolute_expires_at FROM admin_private.sessions s JOIN admin_private.access_tokens t ON t.session_id=s.id
          WHERE s.id=$1 AND s.revoked_at IS NULL AND s.idle_expires_at>$3 AND s.absolute_expires_at>$3
            AND t.token_digest=$2 AND t.revoked_at IS NULL FOR UPDATE OF s,t`,[sessionId,oldTokenDigest,now]);
        if(!current.rowCount)return false;
        const until=overlapUntil && new Date(overlapUntil)>now ? new Date(Math.min(new Date(overlapUntil).getTime(),now.getTime()+30000)) : now;
        await c.query(`UPDATE admin_private.access_tokens SET expires_at=least(expires_at,$3),revoked_at=CASE WHEN $3<=$4 THEN coalesce(revoked_at,$4) ELSE revoked_at END WHERE session_id=$1 AND token_digest=$2`,[sessionId,oldTokenDigest,until,now]);
        await c.query(`INSERT INTO admin_private.access_tokens(token_digest,session_id,expires_at) VALUES($1,$2,least($3::timestamptz,$4::timestamptz))`,[newTokenDigest,sessionId,expiresAt,current.rows[0].absolute_expires_at]);
        await c.query(`UPDATE admin_private.sessions SET encrypted_upstream_token=$2 WHERE id=$1`,[sessionId,newEncryptedUpstreamToken]);return true;
      });
    },
    async touchAdminSession({sessionId,cookieDigest,csrfDigest,now=new Date(),idleExpiresAt}) { const r=await pool.query(`UPDATE admin_private.sessions SET idle_expires_at=least($4,absolute_expires_at),csrf_digest=coalesce($5,csrf_digest) WHERE id=$1 AND cookie_digest=$2 AND revoked_at IS NULL AND idle_expires_at>$3 AND absolute_expires_at>$3 RETURNING id`,[sessionId,cookieDigest,now,idleExpiresAt,csrfDigest||null]);return r.rowCount===1; },
    async updateAdminSessionVerification({sessionId,userId,verifiedAt}) { const r=await pool.query(`UPDATE admin_private.sessions SET verified_at=$3 WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL AND absolute_expires_at>$3 RETURNING id`,[sessionId,userId,verifiedAt]);return r.rowCount===1; },
    async revokeAdminSession({sessionId,reason='logout',now=new Date()}) { await transaction(async c=>{await c.query(`UPDATE admin_private.sessions SET revoked_at=coalesce(revoked_at,$2),revocation_version=revocation_version+1 WHERE id=$1`,[sessionId,now]);await c.query(`UPDATE admin_private.access_tokens SET revoked_at=coalesce(revoked_at,$2) WHERE session_id=$1`,[sessionId,now]);await c.query(`INSERT INTO admin_private.audit(operation_id,actor,action,reason) VALUES($1,$2,'session.revoke',$3)`,[crypto.randomUUID(),'gateway',String(reason).slice(0,1000)||'logout']);}); },
    async revokeAllAdminSessions(userId,now=new Date()) { await pool.query(`UPDATE admin_private.sessions SET revoked_at=coalesce(revoked_at,$2),revocation_version=revocation_version+1 WHERE user_id=$1`,[userId,now]);await pool.query(`UPDATE admin_private.access_tokens t SET revoked_at=coalesce(t.revoked_at,$2) FROM admin_private.sessions s WHERE t.session_id=s.id AND s.user_id=$1`,[userId,now]); },
    async rateLimit({key,now=new Date(),limit,windowMs},client=pool) { const expires=new Date(now.getTime()+windowMs);const r=await client.query(`INSERT INTO admin_private.rate_buckets(bucket_key,window_started_at,count,expires_at) VALUES($1,$2,1,$3)
      ON CONFLICT(bucket_key) DO UPDATE SET window_started_at=CASE WHEN admin_private.rate_buckets.expires_at<=$2 THEN $2 ELSE admin_private.rate_buckets.window_started_at END,
      count=CASE WHEN admin_private.rate_buckets.expires_at<=$2 THEN 1 ELSE admin_private.rate_buckets.count+1 END,expires_at=CASE WHEN admin_private.rate_buckets.expires_at<=$2 THEN $3 ELSE admin_private.rate_buckets.expires_at END RETURNING count,window_started_at,expires_at`,[key,now,expires]);const x=r.rows[0],allowed=Number(x.count)<=limit;return {allowed,retryAfterSeconds:allowed?0:Math.max(1,Math.ceil((new Date(x.expires_at)-now)/1000))}; },
  };
}
module.exports={createAdminRepository,digest};
