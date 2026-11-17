"use strict";

const { createHash, randomUUID } = require("node:crypto");
const { redactionError } = require("./ai_templates");
const { LayoutError } = require("./layout_matcher");
const { ProviderBusyError, providerDelayMs } = require("./template_worker");

const DEFAULT_PROMPT_VERSION = "sms-rule-draft-v1.0.0";
const MAX_RESPONSE_BYTES = 256 * 1024;
// The service may fall back across several AIs, so a call can take a while. The worker is a background process and the
// layout lease is 3 minutes: wait up to 100 s by default, never more than 170 s.
const DEFAULT_TIMEOUT_MS = 100000;
// Provider model ids: "openai/gpt-oss-20b", "clef:free", Cloudflare's "@cf/meta/llama-3.1-8b-instruct".
const MODEL_ID = /^[@A-Za-z0-9][@A-Za-z0-9_.:+\/-]{0,127}$/;
const POSTGRES_INTEGER_MAX = 2147483647;
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);
const SERVICE_LAYOUT_UNSAFE = /[\x00-\x1f\x7f\p{Nd}@]/u;

function assertLayout({ senderBrand, redactedBody }) {
  if (typeof senderBrand !== "string" || !/^[A-Z0-9]{1,32}$/.test(senderBrand) || /\d{6,}/.test(senderBrand) ||
    redactionError(redactedBody) || !redactedBody.trim() || SERVICE_LAYOUT_UNSAFE.test(redactedBody))
    throw new LayoutError("ai_service_invalid_layout");
}

function serviceEndpoint(rawUrl) {
  let origin;
  try {
    origin = new URL(rawUrl);
  } catch {
    throw new Error("SMS_V2_AI_SERVICE_URL_invalid");
  }
  const allowedProtocol = origin.protocol === "https:" ||
    (origin.protocol === "http:" && LOOPBACK_HOSTS.has(origin.hostname));
  if (!allowedProtocol || origin.username || origin.password || origin.pathname !== "/" || origin.search || origin.hash)
    throw new Error("SMS_V2_AI_SERVICE_URL_invalid");
  return new URL("/v1/sms-rule-drafts", origin);
}

async function readJson(response) {
  let bytes = 0;
  const chunks = [];
  for await (const chunk of response.body ?? []) {
    bytes += chunk.length;
    if (bytes > MAX_RESPONSE_BYTES) return null;
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return null;
  }
}

function readUsage(body) {
  const { inputTokens, outputTokens, totalTokens } = body ?? {};
  const validCount = (count) => Number.isInteger(count) && count >= 0 && count <= POSTGRES_INTEGER_MAX;
  if (![inputTokens, outputTokens, totalTokens].every(validCount) || inputTokens + outputTokens > POSTGRES_INTEGER_MAX)
    return null;
  return { inputTokens, outputTokens, totalTokens };
}

function createAiServiceProvider({ env = process.env, fetchImpl = fetch, logger = null } = {}) {
  const rawUrl = env.SMS_V2_AI_SERVICE_URL;
  const token = env.SMS_V2_AI_SERVICE_TOKEN;
  if (!rawUrl && !token) return null;
  const endpoint = serviceEndpoint(rawUrl);
  if (typeof token !== "string" || !/^[A-Za-z0-9_-]{32,512}$/.test(token))
    throw new Error("SMS_V2_AI_SERVICE_TOKEN_invalid");
  const timeoutMs = Number(env.SMS_V2_AI_SERVICE_TIMEOUT_MS || DEFAULT_TIMEOUT_MS);
  if (!Number.isInteger(timeoutMs) || timeoutMs < 5000 || timeoutMs > 170000)
    throw new Error("SMS_V2_AI_SERVICE_TIMEOUT_MS_invalid");
  // The service owns the model, the output cap and the prompt, so none is sent. A prompt version is checked only when
  // one is pinned (SMS_V2_AI_SERVICE_PROMPT_VERSION); otherwise whatever version answers is recorded.
  const pinnedVersion = env.SMS_V2_AI_SERVICE_PROMPT_VERSION || null;
  if (pinnedVersion && !/^[a-zA-Z0-9_.-]{1,64}$/.test(pinnedVersion))
    throw new Error("SMS_V2_AI_SERVICE_PROMPT_VERSION_invalid");
  let seenVersion = null;
  const versionOk = (response) => {
    const seen = response.headers.get("x-prompt-version");
    if (seen && /^[a-zA-Z0-9_.-]{1,64}$/.test(seen)) seenVersion = seen;
    return !pinnedVersion || seen === pinnedVersion;
  };

  return {
    assertLayout,
    get promptVersion() {
      return pinnedVersion ?? seenVersion ?? DEFAULT_PROMPT_VERSION;
    },
    async generateLayout({ senderBrand, redactedBody }) {
      assertLayout({ senderBrand, redactedBody });
      const requestId = randomUUID();
      const started = performance.now();
      let response;
      let outcome = "ok";
      const busy = (code, fallbackDelayMs) => new ProviderBusyError(code, {
        status: response?.status,
        retryAfterMs: providerDelayMs("", response?.headers) || fallbackDelayMs,
        // A service/transport failure gives no evidence about a specific layout.
        systemic: true,
      });
      try {
        response = await fetchImpl(endpoint, {
          method: "POST",
          redirect: "error",
          signal: AbortSignal.timeout(timeoutMs),
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
            "X-Request-ID": requestId,
            // The same layout always carries the same key, so the service can recognise a retry of work it already did.
            "X-Idempotency-Key": createHash("sha256").update(`${senderBrand}
${redactedBody}`).digest("hex"),
            ...(pinnedVersion ? { "X-Prompt-Version": pinnedVersion } : {}),
          },
          body: JSON.stringify({ senderBrand, redactedBody }),
        });
        if (!response.ok && ![422, 502].includes(response.status)) {
          await response.body?.cancel();
          // Any 5xx (a proxy gives 520-524 when the service is slow or restarting) is the service being unavailable, not a bad setup.
          if ([408, 425, 429].includes(response.status) || response.status >= 500)
            throw busy("ai_service_unavailable", 15000);
          if (response.status === 409) throw busy("ai_service_prompt_version_mismatch", 300000);
          if (response.status === 412) throw busy("ai_service_config_mismatch", 300000);
          throw busy("ai_service_misconfigured", 300000);
        }
        const body = await readJson(response);
        const usage = readUsage(body);
        if (response.status === 422) {
          if (body?.error?.code === "invalid_layout") throw new LayoutError("ai_service_invalid_layout");
          throw busy("ai_service_misconfigured", 300000);
        }
        if (response.status === 502) {
          if (body?.error?.code !== "invalid_provider_output") throw busy("ai_service_unavailable", 15000);
          if (!versionOk(response)) throw busy("ai_service_prompt_version_mismatch", 300000);
          throw Object.assign(new SyntaxError("ai_service_invalid_provider_output"), {
            usage: usage && MODEL_ID.test(body.model ?? "") ? { ...usage, model: body.model } : null,
          });
        }
        if (!versionOk(response)) throw busy("ai_service_prompt_version_mismatch", 300000);
        if (!usage || typeof body?.model !== "string" || !body.answer || typeof body.answer !== "object" || Array.isArray(body.answer))
          throw busy("ai_service_invalid_response", 300000);
        // A fallback AI may answer instead of the primary one: accept it and record which model it was.
        if (!MODEL_ID.test(body.model)) throw busy("ai_service_invalid_response", 300000);
        return { answer: body.answer, model: body.model, ...usage };
      } catch (error) {
        const known = error instanceof ProviderBusyError || error instanceof SyntaxError || error instanceof LayoutError;
        // A timeout is retried like any outage (the layout goes back in the queue); it is named apart so it can be counted.
        const failure = known ? error : error?.name === "TimeoutError" ? busy("ai_service_timeout", 30000) : busy("ai_service_unreachable", 15000);
        outcome = failure.message;
        throw failure;
      } finally {
        logger?.({
          event: "sms_v2_ai_service_request",
          entryPoint: "template_worker",
          requestId,
          outcome,
          httpStatus: response?.status ?? null,
          latencyMs: Math.round(performance.now() - started),
        });
      }
    },
  };
}

module.exports = { createAiServiceProvider };
