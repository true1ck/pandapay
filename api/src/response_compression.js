'use strict';

// Gzip for every compressible answer (JSON above all) when the client asks with Accept-Encoding: gzip.
//
// Every phone build talks to this API through dart:io, which always sends Accept-Encoding: gzip and inflates the
// answer itself, so this needs no app change. Before this, nothing was compressed: nginx's `gzip on` covers only
// text/html, and a first SMS sync page went out as 1.7 MB of JSON (350 KB gzipped) on a slow, busy host.
//
// Left alone: answers under 1 KB (the gzip header would eat the saving), answers a route already compressed
// (rules bundle, catalogue: they set Content-Encoding themselves), `Cache-Control: no-transform`, and clients that
// do not ask. Level 6 is zlib's default: most of the size win for a few milliseconds of CPU per large page.
const compression = require('compression');

const THRESHOLD_BYTES = 1024;

const compressResponses = compression({ threshold: THRESHOLD_BYTES, level: 6 });

module.exports = { compressResponses, THRESHOLD_BYTES };
