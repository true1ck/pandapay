'use strict';

const express = require('express');

// Express's previous default was 100 KiB. State the same bound explicitly
// so library/config changes cannot silently remove or shrink it.
const JSON_BODY_LIMIT_BYTES = 100 * 1024;
const jsonBodyParser = express.json({ limit: JSON_BODY_LIMIT_BYTES, strict: true });

function jsonBodyErrorHandler(error, _req, res, next) {
  if (error?.type === 'entity.too.large') return res.status(413).json({ error: 'payload_too_large' });
  if (['entity.parse.failed', 'request.size.invalid', 'request.aborted'].includes(error?.type)) {
    return res.status(400).json({ error: 'invalid_json' });
  }
  if (['charset.unsupported', 'encoding.unsupported'].includes(error?.type)) {
    return res.status(415).json({ error: 'unsupported_encoding' });
  }
  return next(error);
}

module.exports = { JSON_BODY_LIMIT_BYTES, jsonBodyParser, jsonBodyErrorHandler };
