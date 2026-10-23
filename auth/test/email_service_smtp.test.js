'use strict';

const assert = require('node:assert/strict');
const net = require('node:net');
const Module = require('node:module');
const { test } = require('node:test');

function startSmtpFixture({ recipientAccepted = true } = {}) {
  const commands = [];
  const server = net.createServer(socket => {
    socket.setTimeout(20000);
    socket.write('220 local.test ESMTP\r\n');
    let buffer = '';
    let dataMode = false;
    socket.on('data', chunk => {
      buffer += chunk.toString('utf8');
      while (buffer.length) {
        if (dataMode) {
          const end = buffer.indexOf('\r\n.\r\n');
          if (end === -1) return;
          buffer = buffer.slice(end + 5);
          dataMode = false;
          socket.write('250 2.0.0 queued as local-test\r\n');
          continue;
        }
        const newline = buffer.indexOf('\r\n');
        if (newline === -1) return;
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 2);
        commands.push(line);
        const command = line.split(/\s+/, 1)[0].toUpperCase();
        if (command === 'EHLO' || command === 'HELO') {
          socket.write('250-local.test\r\n250 SIZE 35882577\r\n');
        } else if (command === 'MAIL') {
          socket.write('250 2.1.0 sender ok\r\n');
        } else if (command === 'RCPT') {
          socket.write(recipientAccepted ? '250 2.1.5 recipient ok\r\n' : '550 5.1.1 recipient rejected\r\n');
        } else if (command === 'DATA') {
          socket.write('354 end with <CRLF>.<CRLF>\r\n');
          dataMode = true;
        } else if (command === 'RSET') {
          socket.write('250 2.0.0 reset\r\n');
        } else if (command === 'QUIT') {
          socket.write('221 2.0.0 bye\r\n');
          socket.end();
        } else if (command === 'AUTH') {
          socket.write('535 5.7.8 authentication not available\r\n');
        } else {
          socket.write('500 5.5.2 unsupported command\r\n');
        }
      }
    });
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      resolve({ server, commands, port: address.port });
    });
  });
}

function loadEmailService(config) {
  const configPath = require.resolve('../src/config');
  const servicePath = require.resolve('../src/services/emailService');
  const priorConfig = require.cache[configPath];
  const priorService = require.cache[servicePath];
  const mock = new Module(configPath);
  mock.filename = configPath;
  mock.loaded = true;
  mock.exports = config;
  require.cache[configPath] = mock;
  delete require.cache[servicePath];
  const service = require(servicePath);
  return {
    service,
    restore() {
      delete require.cache[servicePath];
      if (priorService) require.cache[servicePath] = priorService;
      if (priorConfig) require.cache[configPath] = priorConfig;
      else delete require.cache[configPath];
    },
  };
}

function configFor(port, isProduction) {
  return {
    emailHost: '127.0.0.1', emailPort: String(port), emailUser: 'synthetic-user',
    emailPass: 'synthetic-password', emailFrom: 'noreply@example.test', isProduction,
  };
}

test('hosted SMTP requires STARTTLS before auth or OTP content is sent', { timeout: 30000 }, async () => {
  const smtp = await startSmtpFixture();
  const loaded = loadEmailService(configFor(smtp.port, true));
  const originalError = console.error;
  console.error = () => {};
  try {
    const result = await loaded.service.sendOtpEmail('recipient@example.test', '123456');
    assert.deepEqual(result, { success: false, error: 'Email delivery failed' });
    assert.ok(smtp.commands.some(command => command.startsWith('EHLO ')));
    assert.equal(smtp.commands.some(command => command.startsWith('AUTH ')), false);
    assert.equal(smtp.commands.some(command => command.startsWith('MAIL ')), false);
    assert.equal(smtp.commands.includes('DATA'), false);
  } finally {
    console.error = originalError;
    loaded.restore();
    await new Promise(resolve => smtp.server.close(resolve));
  }
});

for (const recipientAccepted of [true, false]) {
  test(`real Nodemailer SMTP transport preserves recipient ${recipientAccepted ? 'acceptance' : 'rejection'} behavior`, { timeout: 30000 }, async () => {
    const smtp = await startSmtpFixture({ recipientAccepted });
    const loaded = loadEmailService(configFor(smtp.port, false));
    const originalError = console.error;
    console.error = () => {};
    try {
      const result = await loaded.service.sendOtpEmail('recipient@example.test', '123456');
      assert.equal(result.success, recipientAccepted);
      if (recipientAccepted) {
        assert.equal(result.messageId.startsWith('<'), true);
        assert.ok(smtp.commands.includes('DATA'));
      } else {
        assert.equal(result.error, 'Email delivery failed');
        assert.equal(smtp.commands.some(command => command.startsWith('RCPT ')), true);
        assert.equal(smtp.commands.includes('DATA'), false);
      }
    } finally {
      console.error = originalError;
      loaded.restore();
      await new Promise(resolve => smtp.server.close(resolve));
    }
  });
}
