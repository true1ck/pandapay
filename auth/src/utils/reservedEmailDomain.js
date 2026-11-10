'use strict';

// Domains that can never receive mail: RFC 2606 / RFC 6761 reserve them for documentation and tests.
// A message sent to one can only bounce, and the bounce goes to our own sending mailbox.
const RESERVED_DOMAINS = Object.freeze(['example.com', 'example.org', 'example.net']);
const RESERVED_TOP_LEVEL = Object.freeze(['test', 'example', 'invalid', 'localhost']);

/**
 * True when [email] belongs to a reserved test domain (example.com/.org/.net and anything under them,
 * or a .test, .example, .invalid or .localhost address). Only the domain after the last "@" is read.
 * Never throws; anything that is not an address with a domain is simply "not reserved".
 */
function isReservedTestEmail(email) {
  if (typeof email !== 'string') return false;
  const at = email.lastIndexOf('@');
  if (at < 1) return false;
  const domain = email.slice(at + 1).trim().toLowerCase().replace(/\.+$/, '');
  if (!domain) return false;
  if (RESERVED_DOMAINS.some(reserved => domain === reserved || domain.endsWith(`.${reserved}`))) return true;
  const topLevel = domain.slice(domain.lastIndexOf('.') + 1);
  return RESERVED_TOP_LEVEL.includes(topLevel);
}

module.exports = { isReservedTestEmail, RESERVED_DOMAINS, RESERVED_TOP_LEVEL };
