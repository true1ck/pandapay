"use strict";

// The AI providers, run inside the worker (option B, 22 Nov 2026) instead of through the separate PandaPay AI service.
//
// The code, not the request, decides everything: which providers exist (a key in the environment turns one on, no key
// leaves it out, nothing is asked of a provider that has no key), the order (Gemini, then Groq, Cloudflare, OpenRouter,
// NVIDIA, then OpenAI only when it is switched on by name), how long a provider rests after a 429 or an outage, and
// which provider answered a layout the last time (a layout asked again goes to the next one). A slow provider is given
// time: the only limits are the job's own deadline and a generous one per provider. Same contract as
// `createAiServiceProvider`, so the worker does not know which one it has.
//
// ai_chain/ holds the provider code ported from the PandaPay AI service (its prompt, Gemini, Groq, the OpenAI-style
// providers, the ordered router with its rest times, and the rejection reasons).

const { createHash, randomUUID } = require("node:crypto");
const { LayoutError } = require("./layout_matcher");
const { ProviderBusyError } = require("./template_worker");
const { assertLayout } = require("./ai_service_provider");
const { buildPrompt, PROMPT_VERSION } = require("./ai_chain/prompt");
const { createGeminiProvider, parseApiKeys, ProviderError } = require("./ai_chain/gemini");
const { createGroqProvider } = require("./ai_chain/groq");
const { createAdditionalProviders } = require("./ai_chain/chat_providers");
const { createOrderedRouter, ORDER } = require("./ai_chain/ordered_router");
const { conformAnswer } = require("./ai_chain/conform");
const { isReason } = require("./ai_chain/rejection");

const DEFAULT_GEMINI_MODEL = "gemini-3.1-flash-lite";
// Pinned, tested on synthetic layouts (22 Nov 2026): both answered 3 of 3 cases in 0.6 to 5 s.
const DEFAULT_GROQ_MODEL_NOTE = "openai/gpt-oss-20b (pinned inside groq.js)";
const DEFAULT_CLOUDFLARE_MODEL = "@cf/openai/gpt-oss-20b";
// A free OpenRouter model and an NVIDIA one; both are used only when their key exists. NVIDIA's are slow (16 to 20 s a
// layout in a test), which is why it is last.
const DEFAULT_OPENROUTER_MODEL = "google/gemma-4-31b-it:free";
const DEFAULT_NVIDIA_MODEL = "nvidia/nemotron-3.5-lightning-30b-a3b";
// How long one provider may take, and how long a whole walk over the providers may take. Slow answers are normal.
const PROVIDER_TIMEOUT_MS = 180000;
const WALK_TIMEOUT_MS = 290000;
// What is remembered about a layout this long (which providers already answered it).
const MEMORY_MS = 30 * 60 * 1000;
const MEMORY_MAX = 2000;

const has = (value) => typeof value === "string" && value.trim() !== "";

// The providers the environment has the keys for, in the router's order. A key is all that is needed for the free ones.
function buildRoutes(env, { fetchImpl = fetch, now = Date.now } = {}) {
  const maxOutputTokens = Number(env.SMS_V2_AI_MAX_OUTPUT_TOKENS) > 0 ? Number(env.SMS_V2_AI_MAX_OUTPUT_TOKENS) : 4096;
  const routes = {};
  const keys = parseApiKeys(env);
  if (keys.length) {
    routes.gemini = createGeminiProvider({
      apiKeys: keys,
      model: env.SMS_V2_AI_MODEL || env.PANDAPAY_AI_GEMINI_MODEL || DEFAULT_GEMINI_MODEL,
      maxOutputTokens,
      timeoutMs: PROVIDER_TIMEOUT_MS,
      fetchImpl,
      now,
    });
  }
  if (has(env.GROQ_API_KEY)) routes.groq = createGroqProvider({ apiKey: env.GROQ_API_KEY, maxOutputTokens, fetchImpl, now });
  const extra = { ...env };
  if (has(env.CLOUDFLARE_API_TOKEN) && has(env.CLOUDFLARE_ACCOUNT_ID)) {
    extra.PANDAPAY_AI_CLOUDFLARE_FALLBACK = "true";
    extra.PANDAPAY_AI_CLOUDFLARE_MODEL ||= DEFAULT_CLOUDFLARE_MODEL;
  }
  if (has(env.OPENROUTER_API_KEY)) {
    extra.PANDAPAY_AI_OPENROUTER_FALLBACK = "true";
    extra.PANDAPAY_AI_OPENROUTER_MODEL ||= DEFAULT_OPENROUTER_MODEL;
  }
  if (has(env.NVIDIA_API_KEY)) {
    extra.PANDAPAY_AI_NVIDIA_FALLBACK = "true";
    extra.PANDAPAY_AI_NVIDIA_MODEL ||= DEFAULT_NVIDIA_MODEL;
  }
  // The paid provider stays off unless its own switch AND model are set (createAdditionalProviders requires both).
  const more = createAdditionalProviders({ env: extra, maxOutputTokens, fetchImpl, now });
  for (const [name, route] of Object.entries(more)) routes[name] = route;
  return routes;
}

// Which providers the environment turns on, by name (for the log and the tests); no secrets.
function configuredRoutes(env) {
  try {
    return ORDER.filter((name) => typeof buildRoutes(env)[name] === "function");
  } catch {
    return [];
  }
}

function createLocalChainProvider({ env = process.env, routes = null, logger = null, now = Date.now, fetchImpl = fetch } = {}) {
  const available = routes ?? buildRoutes(env, { fetchImpl, now });
  const names = ORDER.filter((name) => typeof available[name] === "function");
  if (!names.length) return null;
  const router = createOrderedRouter(available, { clock: now, providerTimeoutMs: PROVIDER_TIMEOUT_MS, log: logger ? (event) => logger(event) : () => {} });
  // layout key -> { routes: providers that answered it, at, rerun: providers asked again with the checker's reasons }
  const memory = new Map();
  const keyOf = (brand, body) => createHash("sha256").update(`${brand}\n${body}`).digest("hex");
  const recall = (key) => {
    const entry = memory.get(key);
    if (!entry) return null;
    if (now() - entry.at > MEMORY_MS) {
      memory.delete(key);
      return null;
    }
    return entry;
  };
  const remember = (key, route) => {
    const entry = recall(key) ?? { routes: [], at: now(), rerun: new Set() };
    entry.at = now();
    if (!entry.routes.includes(route)) entry.routes.push(route);
    if (memory.size >= MEMORY_MAX) memory.delete(memory.keys().next().value);
    memory.set(key, entry);
    return entry;
  };

  return {
    assertLayout,
    configured: names,
    get promptVersion() {
      return PROMPT_VERSION;
    },
    // The chain has no health page of its own: asking is cheap and the router rests a failing provider itself.
    async isUp() {
      return true;
    },
    async generateLayout({ senderBrand, redactedBody, signal, routing, fix }) {
      assertLayout({ senderBrand, redactedBody });
      const requestId = randomUUID();
      const started = performance.now();
      const key = keyOf(senderBrand, redactedBody);
      const entry = recall(key);
      const reasons = Array.isArray(fix) ? fix.filter((code) => typeof code === "string").slice(0, 8) : [];
      // What a repeat of the same layout means: the worker's checker refused the last answer. With the checker's reasons the
      // provider that answered is asked once more; otherwise (and after that) the later ones follow. All asked: start over.
      let skip = new Set([...(routing?.skipProviders ?? []), ...(entry?.routes ?? [])].filter((name) => names.includes(name)));
      let rerunOf = null;
      if (entry && reasons.length) {
        const last = entry.routes.at(-1);
        if (last && !entry.rerun.has(last)) {
          skip.delete(last);
          rerunOf = last;
        }
      }
      if (names.every((name) => skip.has(name))) {
        skip = new Set();
        memory.delete(key);
      }
      let outcome = "ok";
      let provider;
      try {
        const prompt = buildPrompt({ senderBrand, redactedBody, ...(reasons.length ? { fix: reasons } : {}) });
        const result = await router({
          ...prompt,
          signal,
          requestId,
          timeoutMs: Math.min(WALK_TIMEOUT_MS, routing?.timeoutMs ?? WALK_TIMEOUT_MS),
          skipProviders: [...skip],
          allowed: names.filter((name) => name !== "gemini"),
        });
        provider = result.provider;
        const conformed = conformAnswer(result.answer);
        const stored = remember(key, provider);
        if (rerunOf && provider === rerunOf) stored.rerun.add(rerunOf);
        return {
          answer: conformed.changes ? conformed.answer : result.answer,
          model: result.model,
          inputTokens: result.inputTokens,
          outputTokens: result.outputTokens,
          totalTokens: result.totalTokens,
          routeProvider: provider,
          routeHadInfrastructureFailure: result.routeHadInfrastructureFailure === true,
        };
      } catch (error) {
        if (error instanceof LayoutError || error instanceof ProviderBusyError) {
          outcome = error.message;
          throw error;
        }
        if (error instanceof ProviderError && error.code === "invalid_provider_output") {
          outcome = "invalid_provider_output";
          const serviceReason = isReason(error.reason) ? error.reason : null;
          throw Object.assign(new SyntaxError("ai_chain_invalid_provider_output"), {
            serviceReason,
            noRouteLeft: serviceReason === "no_route_left",
            usage: error.usage && /^[@A-Za-z0-9][@A-Za-z0-9_.:+/-]{0,127}$/.test(error.model ?? "") ? { ...error.usage, model: error.model } : null,
          });
        }
        if (error instanceof ProviderError) {
          // 429 and 503: every provider was resting, rate limited or failed. The router already rests each one by what it
          // was told; the layout goes back in the queue and nothing counts against it.
          outcome = error.code;
          throw new ProviderBusyError("ai_chain_unavailable", {
            status: error.status,
            retryAfterMs: Math.max(1000, (Number(error.retryAfter) || 15) * 1000),
            systemic: true,
          });
        }
        if (error?.name === "TimeoutError" || error?.name === "AbortError") {
          outcome = "timeout";
          throw new ProviderBusyError("ai_chain_timeout", { retryAfterMs: 30000, systemic: true });
        }
        outcome = "ai_chain_error";
        throw new ProviderBusyError("ai_chain_error", { retryAfterMs: 15000, systemic: true });
      } finally {
        logger?.({
          event: "sms_v2_ai_chain_request",
          entryPoint: "template_worker",
          requestId,
          outcome,
          ...(provider ? { provider } : {}),
          latencyMs: Math.round(performance.now() - started),
        });
      }
    },
  };
}

module.exports = { createLocalChainProvider, configuredRoutes, buildRoutes, DEFAULT_GROQ_MODEL_NOTE };
