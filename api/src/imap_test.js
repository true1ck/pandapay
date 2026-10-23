const tls = require('tls');
const {
  createPinnedTlsOptions,
  hasImapControlChars,
  imapHostFailureReason,
  isValidImapHost,
  resolvePublicImapHost,
} = require('./imap_network');

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
 * { ok: false, reason } on expected failures. Reasons are fixed user-facing
 * descriptions and never include server responses or socket exception text.
 * Never throws for expected failure modes — only programmer errors (bad
 * arguments).
 */
function testImapLogin({
  host,
  port,
  email,
  password,
  timeoutMs = 10000,
  tlsConnect = tls.connect,
  resolveHost = resolvePublicImapHost,
}) {
  if (!host || typeof host !== 'string') throw new Error('host is required');
  if (!email || typeof email !== 'string') throw new Error('email is required');
  if (!password || typeof password !== 'string') throw new Error('password is required');
  if ([email, password].some(hasImapControlChars)) {
    return Promise.resolve({ ok: false, reason: 'IMAP settings contain unsupported control characters.' });
  }
  if (!isValidImapHost(host)) return Promise.resolve({ ok: false, reason: 'IMAP server host is invalid.' });

  return new Promise((resolve) => {
    let settled = false;
    let socket;
    let bytesRead = 0;
    const done = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        if (result.ok) socket?.end();
        else socket?.destroy?.();
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

    const escapeQuoted = (s) => {
      if (hasImapControlChars(s)) throw new Error('invalid_imap_argument');
      return `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
    };

    const connect = async () => {
      let resolution;
      try {
        resolution = await resolveHost(host);
      } catch (error) {
        done({ ok: false, reason: hostFailureMessage(error) });
        return;
      }
      if (settled) return;

      try {
        socket = tlsConnect({ ...createPinnedTlsOptions(resolution, port || 993), timeout: timeoutMs });
      } catch (error) {
        done({ ok: false, reason: isTlsFailure(error)
          ? 'Secure IMAP connection failed; check the server certificate and hostname.'
          : 'Could not connect to the IMAP server.' });
        return;
      }

      socket.on('error', (error) => {
        done({ ok: false, reason: isTlsFailure(error)
          ? 'Secure IMAP connection failed; check the server certificate and hostname.'
          : 'Could not connect to the IMAP server.' });
      });
      socket.on('timeout', () => done({ ok: false, reason: 'Connection timed out.' }));
      socket.on('secureConnect', () => {
        // Wait for the untagged greeting (* OK ...) before sending LOGIN.
      });
      socket.on('data', (chunk) => {
        bytesRead += Buffer.byteLength(chunk, 'utf8');
        if (bytesRead > 64 * 1024) {
          done({ ok: false, reason: 'IMAP server response was too large.' });
          return;
        }
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
              done({ ok: false, reason: 'IMAP server could not complete the login request.' });
            }
          }
        }
      });
      socket.on('close', () => done({ ok: false, reason: 'Connection closed before completing login.' }));
    };
    connect().catch(() => done({ ok: false, reason: 'Could not connect to the IMAP server.' }));
  });
}

function isTlsFailure(error) {
  const code = typeof error?.code === 'string' ? error.code : '';
  return /^(?:ERR_TLS|CERT_|UNABLE_TO_VERIFY|SELF_SIGNED|DEPTH_ZERO)/.test(code);
}

function hostFailureMessage(error) {
  const reason = imapHostFailureReason(error);
  if (reason === 'imap_host_invalid') return 'IMAP server host is invalid.';
  if (reason === 'imap_host_not_public') return 'IMAP server must resolve to a public internet address.';
  if (reason === 'imap_dns_failed') return 'Could not resolve the IMAP server.';
  return 'Could not connect to the IMAP server.';
}

module.exports = { testImapLogin };
