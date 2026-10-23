function testHarnessAllowed(env = process.env) {
  const environment = String(env.NODE_ENV || '').trim().toLowerCase();
  return environment !== 'production' && environment !== 'staging';
}

function mountTestHarness(app, express, env = process.env) {
  if (!testHarnessAllowed(env)) return false;

  app.use(express.static('public'));
  app.get('/test', (req, res) => {
    res.sendFile('test.html', { root: 'public' });
  });
  app.get('/testpage', (req, res) => {
    res.sendFile('test.html', { root: 'public' });
  });
  return true;
}

module.exports = { testHarnessAllowed, mountTestHarness };
