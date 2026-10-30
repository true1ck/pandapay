'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { routeManifest } = require('../api/src/admin/route_manifest');
const root = path.join(__dirname, '..');
const body = JSON.stringify(routeManifest, null, 2) + '\n';
for (const name of ['auth/src/admin_route_manifest.json', 'docs/admin-console-contracts/v1/routes.json']) {
  const target = path.join(root, name);
  fs.mkdirSync(path.dirname(target), {recursive:true});
  if (process.argv.includes('--check')) {
    if (!fs.existsSync(target) || fs.readFileSync(target,'utf8') !== body) {
      console.error('Private admin route contracts are out of sync'); process.exitCode=1;
    }
  } else fs.writeFileSync(target, body);
}
