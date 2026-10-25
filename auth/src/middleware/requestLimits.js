'use strict';

const express = require('express');

// Keep the prior Express default explicit. This module is local to the auth
// Docker build context; API parity is covered by the request-limit tests.
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
