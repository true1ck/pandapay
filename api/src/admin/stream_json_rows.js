'use strict';

// Writes `{"<key>":[row,row,...]}` to an Express response, reading the rows through a database cursor a batch at a
// time and sending each batch as it comes. GET /admin/cards used to hold the whole 14 MB catalogue in memory (every row
// as objects, then one string) on a 1 GB host (21 Nov 2026).
//
// The bytes are exactly what res.json({ [key]: rows }) sent: each row goes through the same JSON.stringify, joined the
// same way, with the same content type. Must run inside the caller's transaction (a cursor lives in one).
//
// Errors: anything that fails before the first batch is written (the query itself, its timeout) is thrown with nothing
// sent, so the route answers its usual 500. A failure later is thrown with headers sent; the route must then end the
// connection, so a client never sees a complete-looking short list.

let cursorSeq = 0;

function drained(res) {
  return new Promise((resolve) => {
    const done = () => { res.off('drain', done); res.off('close', done); resolve(); };
    res.on('drain', done); res.on('close', done);
  });
}

async function streamJsonRows(client, res, { key, text, values, batch = 25, queryTimeoutMs } = {}) {
  const cursor = `stream_rows_${process.pid}_${++cursorSeq}`;
  const run = (sql, params) => client.query(queryTimeoutMs ? { text: sql, values: params, query_timeout: queryTimeoutMs } : { text: sql, values: params });
  // A cursor is planned for its first rows by default; plan for the whole result, as the plain query was.
  await run('SET LOCAL cursor_tuple_fraction = 1.0');
  await run(`DECLARE ${cursor} NO SCROLL CURSOR FOR ${text}`, values);
  const fetch = async () => (await run(`FETCH ${batch} FROM ${cursor}`)).rows;
  let rows = await fetch();
  res.status(200).type('application/json');
  let written = 0;
  let piece = `{${JSON.stringify(key)}:[`;
  for (;;) {
    for (const row of rows) { piece += (written ? ',' : '') + JSON.stringify(row); written += 1; }
    if (rows.length < batch) break;
    if (!res.write(piece)) await drained(res);
    if (res.destroyed) throw new Error('client closed the connection');
    piece = '';
    rows = await fetch();
  }
  res.end(`${piece}]}`);
  await run(`CLOSE ${cursor}`);
  return written;
}

module.exports = { streamJsonRows };
