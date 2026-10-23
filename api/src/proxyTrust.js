'use strict';

const net = require('node:net');

const MAX_TRUSTED_PROXY_HOPS = 5;

function parseTrustProxyHops(value = '0') {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error('TRUST_PROXY_HOPS must be an integer from 0 to 5');
  }
  const hops = Number(value);
  if (!Number.isSafeInteger(hops) || hops > MAX_TRUSTED_PROXY_HOPS) {
    throw new Error('TRUST_PROXY_HOPS must be an integer from 0 to 5');
  }
  return hops;
}

function resolveTrustProxyHops(env = process.env) {
  if (Object.prototype.hasOwnProperty.call(env, 'TRUST_PROXY_HOPS')) {
    return parseTrustProxyHops(env.TRUST_PROXY_HOPS);
  }
  const legacy = env.TRUST_PROXY;
  if (legacy === undefined) return 0;
  if (legacy === 'true' || legacy === '1') return 1;
  if (legacy === 'false' || legacy === '0') return 0;
  throw new Error('TRUST_PROXY must be true/false or TRUST_PROXY_HOPS must be an integer from 0 to 5');
}

function rejectMalformedClientIp(req, res, next) {
  const addresses = [req.ip, ...(Array.isArray(req.ips) ? req.ips : [])].filter(Boolean);
  if (addresses.some(address => net.isIP(address) === 0)) {
    return res.status(400).json({ error: 'invalid_forwarded_ip' });
  }
  return next();
}

module.exports = { parseTrustProxyHops, resolveTrustProxyHops, rejectMalformedClientIp };
