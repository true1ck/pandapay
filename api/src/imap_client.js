const tls = require('tls');

/**
 * A minimal IMAP reader: connect, LOGIN, SELECT INBOX, SEARCH, FETCH, done.
 *
 * WHY THIS EXISTS
 * ---------------
 * `imap_connections` has stored an encrypted app password and offered a
 * live "test connection" since migration 0018, and NOTHING EVER READ A
 * MAILBOX. The column comments said so ("populated once a real background
 * poller exists — not built this pass"), and index.js said so too. Storing
 * a decryptable credential for a feature that does nothing is the worst of
 * the available states: the user believes their mail is being read, and the
 * only thing the credential actually does is sit there as a liability.
 *
 * WHY NO IMAP LIBRARY
 * -------------------
 * Same reasoning `imap_test.js` already applies to LOGIN, extended to the
 * few commands a poller needs. The subset used here — implicit TLS connect,
 * greeting, LOGIN, SELECT, UID SEARCH, UID FETCH, LOGOUT — is a couple of
 * hundred lines, and this code path handles a decrypted credential. Adding
 * a transitive dependency tree to a place where a plaintext app password is
 * in memory is a bigger risk than writing the protocol subset.
 *
 * IMPLICIT TLS ONLY. STARTTLS on port 143 is deliberately not implemented:
 * nothing in this app should send an app password over an unencrypted
 * socket, even briefly.
 */

/** Hard ceiling on how much a single connection may read, ~8MB. */
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;

/** Messages fetched per poll, newest first. */
const MAX_MESSAGES_PER_POLL = 40;

/** IMAP wants dates as 25-Aug-2026. */
const IMAP_MONTHS = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

function imapDate(d) {
  return `${d.getDate()}-${IMAP_MONTHS[d.getMonth()]}-${d.getFullYear()}`;
}

/**
 * IMAP string literal quoting. A password or a sender filter containing a
 * quote or backslash would otherwise terminate the argument early and turn
 * the rest of the value into commands — the IMAP equivalent of an injection.
 */
function quoted(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/**
 * Drives one IMAP session as a small state machine over a TLS socket.
 *
 * Each command is tagged (`a1`, `a2`, …) and the reader accumulates until
 * it sees that tag's completion line — the only reliable framing in IMAP,
 * since untagged responses and literal blocks can contain anything,
 * newlines included.
 */
function runImapSession({ host, port = 993, email, password, timeoutMs = 20000, onReady }) {
  return new Promise((resolve) => {
    let settled = false;
    let buffer = '';
    let bytesRead = 0;
    let tagCounter = 0;
    let pending = null;

    const socket = tls.connect({ host, port, servername: host }, () => {});

    const done = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        socket.end();
      } catch (_) {
        /* already closed */
      }
      resolve(result);
    };

    const timer = setTimeout(() => done({ ok: false, reason: 'timeout' }), timeoutMs);

    /** Sends a tagged command and resolves with its full response text. */
    const send = (command) =>
      new Promise((resolveCmd, rejectCmd) => {
        tagCounter += 1;
        const tag = `a${tagCounter}`;
        pending = { tag, chunks: [], resolveCmd, rejectCmd };
        socket.write(`${tag} ${command}\r\n`);
      });

    socket.setEncoding('utf8');
    socket.on('data', (chunk) => {
      bytesRead += chunk.length;
      if (bytesRead > MAX_RESPONSE_BYTES) {
        done({ ok: false, reason: 'response_too_large' });
        return;
      }
      buffer += chunk;

      // Greeting: anything before the first command completes.
      if (!pending) {
        if (buffer.includes('\r\n')) buffer = '';
        return;
      }

      const lines = buffer.split('\r\n');
      // The last element is a partial line unless the buffer ended on CRLF.
      buffer = lines.pop() ?? '';

      for (const line of lines) {
        if (line.startsWith(`${pending.tag} `)) {
          const status = line.slice(pending.tag.length + 1).split(' ')[0];
          const { chunks, resolveCmd, rejectCmd } = pending;
          pending = null;
          if (status === 'OK') resolveCmd(chunks.join('\r\n'));
          else rejectCmd(new Error(line));
          return;
        }
        pending.chunks.push(line);
      }
    });

    socket.on('error', (err) => done({ ok: false, reason: `socket_error: ${err.message}` }));
    socket.on('end', () => done({ ok: false, reason: 'connection_closed' }));

    socket.once('secureConnect', async () => {
      try {
        // The greeting arrives unprompted; give it a moment to land before
        // the first command so it isn't mistaken for that command's reply.
        await new Promise((r) => setTimeout(r, 150));
        await send(`LOGIN ${quoted(email)} ${quoted(password)}`);
        const result = await onReady(send);
        try {
          await send('LOGOUT');
        } catch (_) {
          /* the server may close first; not a failure */
        }
        done({ ok: true, ...result });
      } catch (err) {
        // Auth failures arrive as a tagged NO and land here. Reported as a
        // reason rather than thrown: a wrong app password is an expected
        // outcome for this route, not a server error.
        done({ ok: false, reason: `imap_error: ${err.message}` });
      }
    });
  });
}

/**
 * Parses a `UID FETCH ... BODY[]` response into `{ uid, sender, subject, body }`.
 *
 * Deliberately shallow: it reads the few headers the parser needs and
 * treats the rest of the message as text. Full MIME handling (nested
 * multipart, base64 and quoted-printable transfer encodings, HTML-to-text)
 * is a real gap, and it is why [pollConnection] treats an unparseable
 * message as a normal miss rather than an error — the same posture the SMS
 * path already takes with `parser_failures`.
 */
function parseFetchResponse(text) {
  const messages = [];
  // Each message starts with an untagged line like:
  //   * 12 FETCH (UID 4242 BODY[] {1234}
  const parts = text.split(/^\* \d+ FETCH /m).slice(1);

  for (const part of parts) {
    const uidMatch = part.match(/UID (\d+)/);
    if (!uidMatch) continue;
    const uid = Number(uidMatch[1]);

    // Everything after the literal-size marker is the message itself.
    const literalStart = part.indexOf('}');
    if (literalStart === -1) continue;
    const raw = part.slice(literalStart + 1).replace(/^\r?\n/, '');

    // Headers end at the first blank line.
    const split = raw.search(/\r?\n\r?\n/);
    const headerBlock = split === -1 ? raw : raw.slice(0, split);
    const body = split === -1 ? '' : raw.slice(split).replace(/^\r?\n\r?\n/, '');

    // Unfold continuation lines before matching — long headers wrap.
    const headers = headerBlock.replace(/\r?\n[ \t]+/g, ' ');
    const from = headers.match(/^From:\s*(.+)$/im);
    const subject = headers.match(/^Subject:\s*(.+)$/im);

    messages.push({
      uid,
      sender: from ? from[1].trim() : null,
      subject: subject ? subject[1].trim() : null,
      body: body.trim(),
    });
  }
  return messages;
}

/**
 * Fetches recent messages from one mailbox.
 *
 * [since] bounds the SEARCH so a poll reads only what has arrived since the
 * last one — without it, every poll would re-read the whole inbox, which is
 * both slow and a good way to get rate-limited by the provider.
 *
 * [senderFilter], when set, is applied server-side via `FROM`, so bank mail
 * is the only thing that ever crosses the wire. That is a privacy property,
 * not just an optimisation: the poller should never pull a user's personal
 * correspondence into this process at all.
 */
async function fetchRecentMessages({ host, port, email, password, since, senderFilter, timeoutMs }) {
  return runImapSession({
    host,
    port,
    email,
    password,
    timeoutMs,
    onReady: async (send) => {
      // EXAMINE, not SELECT: read-only, so polling can never mark a user's
      // mail as read or otherwise alter their mailbox.
      await send('EXAMINE INBOX');

      const criteria = [`SINCE ${imapDate(since)}`];
      if (senderFilter) criteria.push(`FROM ${quoted(senderFilter)}`);
      const searchResult = await send(`UID SEARCH ${criteria.join(' ')}`);

      const line = searchResult.split('\r\n').find((l) => l.startsWith('* SEARCH'));
      const uids = line
        ? line
            .slice('* SEARCH'.length)
            .trim()
            .split(/\s+/)
            .filter((u) => /^\d+$/.test(u))
            .map(Number)
        : [];

      if (uids.length === 0) return { messages: [], highestUid: null };

      // Newest first, bounded — a mailbox with thousands of matching
      // messages must not turn one poll into an unbounded fetch.
      const selected = uids.sort((a, b) => b - a).slice(0, MAX_MESSAGES_PER_POLL);
      const fetchResult = await send(`UID FETCH ${selected.join(',')} (UID BODY.PEEK[])`);

      return {
        messages: parseFetchResponse(fetchResult),
        highestUid: Math.max(...uids),
      };
    },
  });
}

module.exports = {
  fetchRecentMessages,
  parseFetchResponse,
  quoted,
  imapDate,
  MAX_MESSAGES_PER_POLL,
};
