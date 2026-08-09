const tls = require('tls');

/**
 * testImapLogin — a genuinely live IMAP handshake: open a TLS socket to
 * host:port, read the server greeting, send `a1 LOGIN <email> <password>`,
 * and classify the response. No IMAP client library is added as a
 * dependency for this — the subset of the protocol needed (implicit-TLS
 * connect, greeting, one tagged LOGIN command, tagged OK/NO/BAD response,
 * LOGOUT) is a few dozen lines and doesn't warrant a new npm dependency in
 * a security-sensitive path that already touches decrypted credentials.
 *
 * Only implicit TLS (port 993 and friends) is supported, matching what the
 * F7 UI actually offers (`imapPort` defaults to 993). STARTTLS on plaintext
 * port 143 is intentionally not implemented — nothing in this app should
 * ever send an app password over an unencrypted socket, even briefly.
 *
 * Resolves to { ok: true } on a tagged OK LOGIN response, or
 * { ok: false, reason } on anything else (auth failure, timeout, TLS
 * failure, non-IMAP greeting). Never throws for expected failure modes —
 * only for programmer errors (bad arguments).
 */
function testImapLogin({ host, port, email, password, timeoutMs = 10000 }) {
  if (!host || typeof host !== 'string') throw new Error('host is required');
  if (!email || typeof email !== 'string') throw new Error('email is required');
  if (!password || typeof password !== 'string') throw new Error('password is required');

  return new Promise((resolve) => {
    let settled = false;
    const done = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        socket.end();
      } catch (_) {
        /* socket may already be closed */
      }
      resolve(result);
    };

    const timer = setTimeout(() => {
      done({ ok: false, reason: 'Connection timed out.' });
    }, timeoutMs);

    let buffer = '';
    let stage = 'greeting'; // 'greeting' -> 'login'
    const tag = 'a1';

    const escapeQuoted = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

    let socket;
    try {
      socket = tls.connect({ host, port: port || 993, servername: host, timeout: timeoutMs });
    } catch (err) {
      clearTimeout(timer);
      resolve({ ok: false, reason: `Could not open a TLS connection: ${err.message}` });
      return;
    }

    socket.on('error', (err) => {
      done({ ok: false, reason: `Connection error: ${err.message}` });
    });

    socket.on('timeout', () => {
      done({ ok: false, reason: 'Connection timed out.' });
    });

    socket.on('secureConnect', () => {
      // Wait for the untagged greeting (* OK ...) before sending LOGIN.
    });

    socket.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      const lines = buffer.split('\r\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        if (stage === 'greeting' && /^\*\s+(OK|PREAUTH)/i.test(line)) {
          stage = 'login';
          const cmd = `${tag} LOGIN ${escapeQuoted(email)} ${escapeQuoted(password)}\r\n`;
          socket.write(cmd);
        } else if (stage === 'greeting' && /^\*\s+BYE/i.test(line)) {
          done({ ok: false, reason: 'Server closed the connection immediately (BYE).' });
        } else if (stage === 'login' && line.startsWith(`${tag} `)) {
          if (/^a1\s+OK/i.test(line)) {
            done({ ok: true });
          } else if (/^a1\s+NO/i.test(line)) {
            done({ ok: false, reason: 'Server rejected the credentials (check email/app password).' });
          } else {
            done({ ok: false, reason: `Server returned an error: ${line.replace(/^a1\s+/i, '')}` });
          }
        }
      }
    });

    socket.on('close', () => {
      done({ ok: false, reason: 'Connection closed before completing login.' });
    });
  });
}

module.exports = { testImapLogin };
