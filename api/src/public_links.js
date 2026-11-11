'use strict';
// The one public origin for every shareable link (split invites, referral
// invites, App Links verification). Must match the host in the Android manifest
// and the iOS associated-domains entitlement; override per environment.
const PUBLIC_LINK_BASE_URL = (process.env.INVITE_BASE_URL || 'https://pandapay.pandapath.live').replace(/\/+$/, '');
module.exports = { PUBLIC_LINK_BASE_URL };
