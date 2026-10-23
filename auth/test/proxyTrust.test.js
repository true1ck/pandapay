'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { parseTrustProxyHops, resolveTrustProxyHops, rejectMalformedClientIp } = require('../src/utils/proxyTrust');

function requestWith(hops, forwardedFor) {
  const app = express();
  const trust = typeof hops === 'string' ? parseTrustProxyHops(hops) : resolveTrustProxyHops(hops);
  app.set('trust proxy', trust);
  const req = Object.create(express.request);
  req.app = app;
  req.headers = forwardedFor === undefined ? {} : { 'x-forwarded-for': forwardedFor };
  req.connection = { remoteAddress: '127.0.0.1' };
  req.socket = req.connection;
  const result = { status: 200, body: null };
  const res = {
    status(code) { result.status = code; return this; },
    json(body) { result.body = body; return this; },
  };
  rejectMalformedClientIp(req, res, () => {
    result.body = { ip: req.ip, ips: req.ips };
  });
  return result;
}

test('proxy hops accept only explicit small non-negative integer configuration', () => {
  assert.equal(parseTrustProxyHops(), 0);
  assert.equal(parseTrustProxyHops('1'), 1);
  assert.equal(parseTrustProxyHops('5'), 5);
  for (const value of ['true', 'false', '-1', '1.5', '06', '6', '']) {
    assert.throws(() => parseTrustProxyHops(value), /TRUST_PROXY_HOPS/);
  }
});

test('legacy TRUST_PROXY values map to bounded hop counts and explicit hops take precedence', () => {
  assert.equal(resolveTrustProxyHops({}), 0);
  assert.equal(resolveTrustProxyHops({ TRUST_PROXY: 'true' }), 1);
  assert.equal(resolveTrustProxyHops({ TRUST_PROXY: '1' }), 1);
  assert.equal(resolveTrustProxyHops({ TRUST_PROXY: 'false' }), 0);
  assert.equal(resolveTrustProxyHops({ TRUST_PROXY: '0' }), 0);
  assert.equal(resolveTrustProxyHops({ TRUST_PROXY: 'true', TRUST_PROXY_HOPS: '2' }), 2);
  assert.throws(() => resolveTrustProxyHops({ TRUST_PROXY: 'yes' }), /TRUST_PROXY/);
  assert.throws(() => resolveTrustProxyHops({ TRUST_PROXY_HOPS: 'true' }), /TRUST_PROXY_HOPS/);
});

test('local mode ignores a caller-supplied forwarded address', () => {
  const response = requestWith('0', '198.51.100.7');
  assert.equal(response.status, 200);
  assert.equal(response.body.ip, '127.0.0.1');
});

test('one-hop mode uses Express nearest-hop resolution, not a manual XFF parser', () => {
  const response = requestWith('1', '198.51.100.7, 192.0.2.9');
  assert.equal(response.status, 200);
  assert.equal(response.body.ip, '192.0.2.9');
});

test('malformed address selected through configured trust is rejected', () => {
  const response = requestWith('1', 'not-an-ip');
  assert.equal(response.status, 400);
  assert.deepEqual(response.body, { error: 'invalid_forwarded_ip' });
});

test('legacy true is bounded to one hop and ignores a spoofed farther XFF entry', () => {
  const response = requestWith({ TRUST_PROXY: 'true' }, '198.51.100.77, 192.0.2.45');
  assert.equal(response.status, 200);
  assert.equal(response.body.ip, '192.0.2.45');
});

test('legacy false leaves the socket peer as the limiter IP', () => {
  const response = requestWith({ TRUST_PROXY: 'false' }, '198.51.100.77');
  assert.equal(response.status, 200);
  assert.equal(response.body.ip, '127.0.0.1');
});
