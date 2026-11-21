"use strict";

const { ProviderError } = require("./gemini");
const { isReason } = require("./rejection");

const ORDER = Object.freeze(["gemini", "experiential", "groq", "cloudflare", "openrouter", "nvidia", "openai"]);
const ROUTING_VERSION = "ordered-v1";
const DEFAULT_REQUEST_MS = 300000;
const MAX_REQUEST_MS = 900000;
const MAX_PROVIDER_DELAY_SECONDS = 86400;

// A provider that stalls past its own time limit rests longer each time it happens again in a row (seconds),
// and starts over from the first step after one good answer.
const TIMEOUT_COOLDOWN_SECONDS = Object.freeze([15, 30, 60, 120, 300]);

// Tokens that rejected answers were billed for: the caller records them even when no route gave a usable draft.
function addUsage(total, error) {
  const usage = error?.usage;
  if (!usage) return total;
  const sum = (key) => (total?.usage?.[key] ?? 0) + (Number.isSafeInteger(usage[key]) ? usage[key] : 0);
  return {
    usage: { inputTokens: sum("inputTokens"), outputTokens: sum("outputTokens"), totalTokens: sum("totalTokens") },
    model: error.model ?? total?.model,
  };
}

function createOrderedRouter(routes, { clock = Date.now, providerTimeoutMs = 12000, log = () => {} } = {}) {
  const availableAt = new Map();
  const timeoutStreak = new Map();
  return async ({
    signal: callerSignal, timeoutMs = DEFAULT_REQUEST_MS, allowed = [], skipProviders = [],
    afterProvider, priorUnavailable, requestId, rerun = false, ...request
  }) => {
    const deadline = AbortSignal.timeout(Math.min(timeoutMs, MAX_REQUEST_MS));
    const signal = callerSignal ? AbortSignal.any([callerSignal, deadline]) : deadline;
    // The cursor means "a LATER route". With `rerun` (a caller that sends the reasons its last draft was refused) the
    // route that answered is asked again first, now knowing what was wrong; if it fails the later ones follow.
    const eligible = ORDER.slice(ORDER.indexOf(afterProvider) + (rerun && afterProvider ? 0 : 1))
      .filter(name => !skipProviders.includes(name) &&
        (name === "gemini" || allowed.includes(name)) && typeof routes[name] === "function");
    let rejected = !!afterProvider;
    let unavailable = !!priorUnavailable;
    let nextWait = Infinity;
    let billed;
    let lastReason;
    for (const name of eligible) {
      const delay = (availableAt.get(name) ?? 0) - clock();
      if (delay > 0) {
        unavailable = true;
        nextWait = Math.min(nextWait, Math.ceil(delay / 1000));
        continue;
      }
      if (signal.aborted) {
        unavailable = true;
        break;
      }
      const startedAt = clock();
      let status = "skipped";
      let reason;
      try {
        const result = await attemptRoute(routes[name], request, signal, providerTimeoutMs);
        if (result === null) continue;
        status = "ok";
        timeoutStreak.delete(name);
        return { ...result, provider: name, routeHadInfrastructureFailure: unavailable };
      } catch (error) {
        if (error instanceof ProviderError && error.code === "invalid_provider_output" && error.status === 502) {
          rejected = true;
          status = "invalid_output";
          billed = addUsage(billed, error);
          lastReason = isReason(error.reason) ? error.reason : undefined;
          reason = lastReason;
          continue;
        }
        status = "unavailable";
        unavailable = true;
        // The caller left or this request's own time ran out: that says nothing about the provider, so it
        // must not rest for everyone else.
        if (signal.aborted) break;
        let seconds;
        if (error?.reason === "provider_timeout") {
          const streak = (timeoutStreak.get(name) ?? 0) + 1;
          timeoutStreak.set(name, streak);
          seconds = TIMEOUT_COOLDOWN_SECONDS[Math.min(streak, TIMEOUT_COOLDOWN_SECONDS.length) - 1];
        } else {
          seconds = Number.isFinite(error?.retryAfter)
            ? Math.max(1, Math.min(MAX_PROVIDER_DELAY_SECONDS, Math.ceil(error.retryAfter)))
            : 15;
        }
        nextWait = Math.min(nextWait, seconds);
        availableAt.set(name, Math.max(availableAt.get(name) ?? 0, clock() + seconds * 1000));
      } finally {
        log({ event: "sms_rule_provider_attempt", requestId, provider: name, status, ...(reason ? { reason } : {}), durationMs: Math.max(0, clock() - startedAt) });
      }
    }
    // Nothing was asked (the cursor was already past the last route, or every route is skipped): say so, so it is not
    // taken for a model that wrote something bad.
    if (rejected && !unavailable) throw new ProviderError("invalid_provider_output", 502, { ...(billed ?? {}), reason: lastReason ?? (billed ? undefined : "no_route_left") });
    throw new ProviderError("provider_unavailable", 503, { retryAfter: Number.isFinite(nextWait) ? nextWait : 15 });
  };
}

async function attemptRoute(generate, request, deadlineSignal, providerTimeoutMs) {
  const timeout = new AbortController();
  const timer = setTimeout(() => timeout.abort(), providerTimeoutMs);
  const signal = AbortSignal.any([deadlineSignal, timeout.signal]);
  let onAbort;
  try {
    signal.throwIfAborted();
    const aborted = new Promise((_, reject) => {
      onAbort = () => reject(Object.assign(new ProviderError("provider_unavailable", 503), {
        reason: deadlineSignal.aborted ? "deadline" : "provider_timeout",
      }));
      signal.addEventListener("abort", onAbort, { once: true });
    });
    return await Promise.race([Promise.resolve().then(() => {
      signal.throwIfAborted();
      return generate({ ...request, signal });
    }), aborted]);
  } finally {
    clearTimeout(timer);
    if (onAbort) signal.removeEventListener("abort", onAbort);
  }
}

// What a request with no routing header gets. The caller (the PandaPay worker) sends no model and no opt-in
// headers and leaves the choice to this service, so every FREE fallback that is configured here (key and model
// set on this service) is tried in order after Gemini. The paid route stays opt-in per request. With no
// fallback configured there is nothing to route to, so the single-provider path is kept unchanged.
const DEFAULT_ORDERED_BUDGET_MS = 60000;
const PAID_ROUTES = Object.freeze(["openai"]);

function defaultRoutingFor(routes, { legacy = false, fallbackModel, budgetMs = DEFAULT_ORDERED_BUDGET_MS } = {}) {
  if (legacy) return undefined;
  const allowed = ORDER.filter((name) => name !== "gemini" && !PAID_ROUTES.includes(name) && typeof routes[name] === "function");
  if (!allowed.length) return undefined;
  return { allowed, fallbackModel, timeoutMs: Math.min(budgetMs, MAX_REQUEST_MS) };
}

module.exports = {
  createOrderedRouter, defaultRoutingFor, ORDER, ROUTING_VERSION, DEFAULT_REQUEST_MS, DEFAULT_ORDERED_BUDGET_MS, MAX_REQUEST_MS,
};
