"use strict";

const { ProviderError, parseAnswer, readEnvelope, retryAfter } = require("./gemini");
const { chatReason } = require("./rejection");

const MAX_TOKEN_COUNT = 2147483647;
const CLOUDFLARE_MODEL = /^@cf\/[a-z0-9_-]+\/[a-z0-9_.-]+$/;
const OPENROUTER_MODEL = /^[a-z0-9][a-z0-9._-]*\/[a-z0-9][a-z0-9._-]*:free$/;
const NVIDIA_MODEL = /^[a-z0-9][a-z0-9._-]*\/[a-z0-9][a-z0-9._-]*$/;
const OPENAI_MODEL = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/;

async function fetchChatDraft({
  endpoint, apiKey, model, maxOutputTokens, outputField = "max_completion_tokens",
  extra = {}, responsePolicy, rateLimitDelay, freeOnly = false, useJsonMode = true, modelMatches = (returned) => returned === model,
  system, prompt, signal, fetchImpl = fetch,
}) {
  const response = await fetchImpl(endpoint, {
    method: "POST",
    redirect: "error",
    signal,
    headers: { authorization: "Bearer " + apiKey, "content-type": "application/json" },
    body: JSON.stringify({
      model,
      messages: [{ role: "system", content: system }, { role: "user", content: prompt }],
      ...(useJsonMode ? { response_format: { type: "json_object" } } : {}),
      [outputField]: maxOutputTokens,
      ...extra,
    }),
  });

  if (response.status !== 200 || (responsePolicy && !responsePolicy(response))) {
    const quotaDelay = response.status === 429 && rateLimitDelay
      ? await rateLimitDelay(response, signal)
      : undefined;
    void response.body?.cancel().catch(() => {});
    if (response.status === 429)
      throw new ProviderError("provider_rate_limited", 429, { retryAfter: quotaDelay ?? retryAfter(response.headers, 60) });
    // 400 / 422 say this one request was refused (a content filter, a schema the model rejects), not that the
    // key or model is wrong: rest the route briefly instead of locking it out for everyone for minutes.
    if ([400, 422].includes(response.status))
      throw new ProviderError("provider_rejected_request", 503, { retryAfter: 5 });
    if (response.status === 200 || [401, 402, 403, 404].includes(response.status))
      throw new ProviderError("provider_misconfigured", 503, { retryAfter: retryAfter(response.headers, 300) });
    throw new ProviderError("provider_unavailable", 503, { retryAfter: retryAfter(response.headers, 15) });
  }

  const envelope = await readEnvelope(response, signal);
  if (envelope?.error) throw new ProviderError("provider_unavailable", 503, { retryAfter: retryAfter(response.headers, 15) });
  const choice = Array.isArray(envelope?.choices) && envelope.choices.length === 1 ? envelope.choices[0] : null;
  const answer = choice?.finish_reason === "stop" ? parseAnswer(choice.message?.content) : null;
  const {
    prompt_tokens: inputTokens, completion_tokens: outputTokens, total_tokens: totalTokens, cost,
  } = envelope?.usage ?? {};
  if ((envelope?.model !== undefined && !modelMatches(envelope.model)) || (freeOnly && cost !== undefined && cost !== 0))
    throw new ProviderError("provider_misconfigured", 503, { retryAfter: 300 });
  if (!answer || !modelMatches(envelope?.model) || ![inputTokens, outputTokens, totalTokens].every(
    count => Number.isInteger(count) && count > 0 && count <= MAX_TOKEN_COUNT,
  ) || totalTokens < inputTokens + outputTokens) {
    const tokensOk = [inputTokens, outputTokens, totalTokens].every(count => Number.isInteger(count) && count > 0);
    throw new ProviderError("invalid_provider_output", 502, { reason: chatReason(choice, parseAnswer, tokensOk) });
  }
  return { answer, model, inputTokens, outputTokens, totalTokens };
}

function createAdditionalProviders({ env, maxOutputTokens, fetchImpl = fetch, now = Date.now }) {
  const routes = {};
  const add = (id, flag, modelKey, pattern, key, options) => {
    if (env[flag] !== "true") return;
    const model = env[modelKey];
    const apiKey = env[key];
    if (typeof apiKey !== "string" || !apiKey.trim()) throw new Error(key + " is required");
    if (typeof model !== "string" || model.length > 128 || !pattern.test(model))
      throw new Error(modelKey + " is required and must be a supported pinned model ID");
    const providerOptions = options(model);
    routes[id] = request => fetchChatDraft({
      ...request, model, apiKey, maxOutputTokens, fetchImpl, ...providerOptions,
    });
  };

  add("cloudflare", "PANDAPAY_AI_CLOUDFLARE_FALLBACK", "PANDAPAY_AI_CLOUDFLARE_MODEL",
    CLOUDFLARE_MODEL, "CLOUDFLARE_API_TOKEN", () => {
      const accountId = env.CLOUDFLARE_ACCOUNT_ID;
      if (typeof accountId !== "string" || !/^[a-f0-9]{32}$/i.test(accountId))
        throw new Error("CLOUDFLARE_ACCOUNT_ID must be a 32-character hexadecimal account ID");
      return {
        endpoint: "https://api.cloudflare.com/client/v4/accounts/" + accountId + "/ai/v1/chat/completions",
        outputField: "max_tokens",
        extra: { options: { rejectIfBusy: true } },
        rateLimitDelay: async (response, signal) => {
          const body = await readEnvelope(response, signal, 16 * 1024);
          const errors = Array.isArray(body?.errors) ? body.errors : [body?.error];
          const dailyQuotaReached = errors.some((error) => error?.code === 3036 || error?.code === "3036");
          if (!dailyQuotaReached) return retryAfter(response.headers, 60);
          const secondsToUtcMidnight = Math.ceil((86400000 - now() % 86400000) / 1000);
          return Math.max(secondsToUtcMidnight, retryAfter(response.headers, 0));
        },
      };
    });

  add("openrouter", "PANDAPAY_AI_OPENROUTER_FALLBACK", "PANDAPAY_AI_OPENROUTER_MODEL",
    OPENROUTER_MODEL, "OPENROUTER_API_KEY", model => ({
      endpoint: "https://openrouter.ai/api/v1/chat/completions",
      outputField: "max_tokens",
      freeOnly: true,
      modelMatches: returned => returned === model || returned === model.slice(0, -5),
      extra: {
        provider: {
          require_parameters: true, data_collection: "deny", zdr: true, allow_fallbacks: false,
          max_price: { prompt: 0, completion: 0, request: 0 },
        },
      },
    }));

  add("nvidia", "PANDAPAY_AI_NVIDIA_FALLBACK", "PANDAPAY_AI_NVIDIA_MODEL",
    NVIDIA_MODEL, "NVIDIA_API_KEY", () => ({
      endpoint: "https://integrate.api.nvidia.com/v1/chat/completions",
      outputField: "max_tokens",
      useJsonMode: false,
      extra: { stream: false },
    }));

  add("openai", "PANDAPAY_AI_OPENAI_PAID_FALLBACK", "PANDAPAY_AI_OPENAI_MODEL",
    OPENAI_MODEL, "OPENAI_API_KEY", () => ({
      endpoint: "https://api.openai.com/v1/chat/completions",
      extra: { store: false },
    }));

  return routes;
}

module.exports = { fetchChatDraft, createAdditionalProviders };
