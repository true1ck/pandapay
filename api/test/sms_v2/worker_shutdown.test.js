"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");

// Exercise the real job loop and signal handlers in a separate process. Replace
// database/provider boundaries so this cannot reach a database or model API.
const harness = String.raw`
const path = require("node:path");
const root = process.cwd();
const status = process.argv[1];
const once = process.argv[2] === "once";
function replace(relative, exports) {
  const filename = require.resolve(path.join(root, relative));
  require.cache[filename] = { id: filename, filename, loaded: true, exports };
}
const store = {};
let closed = false;
const pool = { end: async () => { closed = true; } };
replace("src/sms_v2/admin_store.js", {});
replace("src/admin/server.js", {});
replace("src/sms_v2/merchant_suggestions.js", {});
replace("src/sms_v2/ai_worker_store.js", {
  openAiWorkerStore: async () => ({ pool, transaction: () => {} }),
});
replace("src/sms_v2/ai_service_provider.js", {
  createAiServiceProvider: () => ({ generateLayout: () => {} }),
});
replace("src/sms_v2/template_worker.js", {
  workerConfig: () => ({}),
  createPgWorkerStore: () => store,
  runTemplateWorkerOnce: async () => {
    if (!once) setImmediate(() => process.emit("SIGTERM"));
    return { status, retryAfterMs: 3600000 };
  },
  busyWaitMs: () => 3600000,
});
process.env.SMS_AI_WORKER_DATABASE_URL = "synthetic";
if (once) process.argv.push("--once");
const before = process.listenerCount("SIGTERM");
require(path.join(root, "src/sms_v2/jobs/template_worker_main.js")).main().then(() => {
  if (!closed || process.listenerCount("SIGTERM") !== before) process.exitCode = 1;
  else console.log("pool_closed_and_handlers_removed");
}).catch((error) => { console.error(error); process.exitCode = 1; });
`;

for (const [status, mode] of [["budget", "signal"], ["provider_busy", "signal"], ["budget", "once"]]) {
  test(`worker closes its database during ${status} ${mode}`, () => {
    const result = spawnSync(process.execPath, ["-e", harness, status, mode], {
      cwd: path.resolve(__dirname, "../.."),
      encoding: "utf8",
      timeout: 4000,
    });
    assert.equal(result.error, undefined, result.error?.message);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /pool_closed_and_handlers_removed/);
  });
}
