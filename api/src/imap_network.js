'use strict';

const dns = require('node:dns').promises;
const net = require('node:net');
const tls = require('node:tls');
const { domainToASCII } = require('node:url');

const IPV4_NON_PUBLIC = [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  // Azure platform virtual IP used for DNS, DHCP, and host services.
  ['168.63.129.16', 32],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.0.2.0', 24],
  ['192.31.196.0', 24],
  ['192.52.193.0', 24],
  ['192.88.99.0', 24],
  ['192.168.0.0', 16],
  ['192.175.48.0', 24],
  ['198.18.0.0', 15],
  ['198.51.100.0', 24],
  ['203.0.113.0', 24],
  ['224.0.0.0', 4],
  ['240.0.0.0', 4],
];

function errorWithCode(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function hasImapControlChars(value) {
  return typeof value === 'string' && /[\u0000-\u001f\u007f]/.test(value);
}

function canonicalHost(host) {
  if (typeof host !== 'string' || host.length === 0 || host !== host.trim() || hasImapControlChars(host)) {
    throw errorWithCode('imap_host_invalid');
  }

  const ipFamily = net.isIP(host);
  if (ipFamily) return { host, ipFamily };

  const asciiHost = domainToASCII(host.replace(/\.$/, '')).toLowerCase();
  if (!asciiHost || asciiHost.length > 253 || !asciiHost.includes('.')) {
    throw errorWithCode('imap_host_invalid');
  }
  const labels = asciiHost.split('.');
  if (labels.some((label) => label.length < 1 || label.length > 63 ||
      !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label)) ||
      !/[a-z]/.test(labels[labels.length - 1])) {
    throw errorWithCode('imap_host_invalid');
  }
  return { host: asciiHost, ipFamily: 0 };
}

function ipv4BigInt(address) {
  if (net.isIP(address) !== 4) return null;
  return address.split('.').reduce((value, octet) => (value << 8n) | BigInt(Number(octet)), 0n);
}

function inIpv4Cidr(address, network, prefix) {
  const value = ipv4BigInt(address);
  const base = ipv4BigInt(network);
  if (value === null || base === null) return false;
  const shift = BigInt(32 - prefix);
  return (value >> shift) === (base >> shift);
}

function isPublicIpv4(address) {
  return net.isIP(address) === 4 &&
    !IPV4_NON_PUBLIC.some(([network, prefix]) => inIpv4Cidr(address, network, prefix));
}

function ipv6BigInt(address) {
  if (net.isIP(address) !== 6 || address.includes('%')) return null;
  let source = address.toLowerCase();
  if (source.includes('.')) {
    const lastColon = source.lastIndexOf(':');
    const embeddedV4 = source.slice(lastColon + 1);
    const v4 = ipv4BigInt(embeddedV4);
    if (v4 === null) return null;
    const high = Number((v4 >> 16n) & 0xffffn).toString(16);
    const low = Number(v4 & 0xffffn).toString(16);
    source = `${source.slice(0, lastColon + 1)}${high}:${low}`;
  }

  const halves = source.split('::');
  if (halves.length > 2) return null;
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const gap = halves.length === 2 ? 8 - left.length - right.length : 0;
  if ((halves.length === 1 && left.length !== 8) || (halves.length === 2 && gap < 1)) return null;
  const groups = [...left, ...Array(gap).fill('0'), ...right];
  if (groups.length !== 8 || groups.some((group) => !/^[0-9a-f]{1,4}$/.test(group))) return null;
  return groups.reduce((value, group) => (value << 16n) | BigInt(`0x${group}`), 0n);
}

function inIpv6Cidr(value, networkHex, prefix) {
  const network = ipv6BigInt(networkHex);
  if (network === null) return false;
  return (value >> BigInt(128 - prefix)) === (network >> BigInt(128 - prefix));
}

function isPublicIpv6(address) {
  const value = ipv6BigInt(address);
  if (value === null) return false;

  // Public IPv6 unicast is currently allocated from 2000::/3. Exclude
  // transition, protocol-assignment, and documentation blocks within it.
  return inIpv6Cidr(value, '2000::', 3) &&
    !inIpv6Cidr(value, '2001::', 23) &&
    !inIpv6Cidr(value, '2001:db8::', 32) &&
    !inIpv6Cidr(value, '2002::', 16) &&
    // Returned 6bone space; it sits inside the broad 2000::/3 range.
    !inIpv6Cidr(value, '3ffe::', 16) &&
    !inIpv6Cidr(value, '3fff::', 20);
}

function isPublicAddress(address, family) {
  const actualFamily = net.isIP(address);
  if (!actualFamily || (family !== 0 && family !== actualFamily)) return false;
  return actualFamily === 4 ? isPublicIpv4(address) : isPublicIpv6(address);
}

function createPinnedLookup(host, addresses) {
  const expectedHost = host.toLowerCase().replace(/\.$/, '');
  const pinned = addresses.map(({ address, family }) => ({ address, family }));
  return function pinnedLookup(requestedHost, options, callback) {
    if (typeof options === 'function') {
      callback = options;
      options = {};
    }
    if (typeof callback !== 'function') throw new TypeError('lookup callback is required');
    if (typeof requestedHost !== 'string' ||
        requestedHost.toLowerCase().replace(/\.$/, '') !== expectedHost) {
      callback(errorWithCode('imap_dns_name_mismatch'));
      return;
    }

    const requestedFamily = options === 4 || options === 6 ? options
      : options?.family === 'IPv4' ? 4
      : options?.family === 'IPv6' ? 6
        : Number(options?.family || 0);
    const matches = pinned.filter((item) => requestedFamily === 0 || item.family === requestedFamily);
    if (matches.length === 0) {
      callback(errorWithCode('imap_dns_family_unavailable'));
      return;
    }
    if (typeof options === 'object' && options?.all) callback(null, matches.map((item) => ({ ...item })));
    else callback(null, matches[0].address, matches[0].family);
  };
}

function createPinnedImapResolution(host, addresses) {
  const canonical = canonicalHost(host);
  if (!Array.isArray(addresses) || addresses.length === 0 ||
      addresses.some((item) => !item || !isPublicAddress(item.address, item.family))) {
    throw errorWithCode('imap_host_not_public');
  }
  const unique = [...new Map(addresses.map((item) => [`${item.family}:${item.address}`, {
    address: item.address,
    family: item.family,
  }])).values()];
  return {
    host: canonical.host,
    addresses: unique,
    lookup: createPinnedLookup(canonical.host, unique),
    servername: canonical.ipFamily ? undefined : canonical.host,
    checkServerIdentity: (_servername, cert) => tls.checkServerIdentity(canonical.host, cert),
  };
}

async function resolvePublicImapHost(host, { lookupAll = dns.lookup } = {}) {
  const canonical = canonicalHost(host);
  if (canonical.ipFamily) {
    if (!isPublicAddress(canonical.host, canonical.ipFamily)) throw errorWithCode('imap_host_not_public');
    return createPinnedImapResolution(canonical.host, [{ address: canonical.host, family: canonical.ipFamily }]);
  }

  let addresses;
  try {
    addresses = await lookupAll(canonical.host, { all: true, order: 'verbatim' });
  } catch (_) {
    throw errorWithCode('imap_dns_failed');
  }
  return createPinnedImapResolution(canonical.host, addresses);
}

function createPinnedTlsOptions(resolution, port) {
  return {
    host: resolution.host,
    port,
    lookup: resolution.lookup,
    rejectUnauthorized: true,
    ...(resolution.servername ? { servername: resolution.servername } : {}),
    checkServerIdentity: resolution.checkServerIdentity,
  };
}

function imapHostFailureReason(error) {
  if (error?.code === 'imap_host_invalid') return 'imap_host_invalid';
  if (error?.code === 'imap_host_not_public') return 'imap_host_not_public';
  if (error?.code === 'imap_dns_failed') return 'imap_dns_failed';
  return 'socket_error';
}

function isValidImapHost(host) {
  try {
    canonicalHost(host);
    return true;
  } catch (_) {
    return false;
  }
}

module.exports = {
  createPinnedImapResolution,
  createPinnedLookup,
  createPinnedTlsOptions,
  hasImapControlChars,
  imapHostFailureReason,
  isPublicAddress,
  isValidImapHost,
  resolvePublicImapHost,
};
