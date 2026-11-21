"use strict";

const { ProviderError, parseAnswer, readEnvelope, retryAfter } = require("./gemini");
const { chatReason } = require("./rejection");

const ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const MODEL = "openai/gpt-oss-20b";
const POSTGRES_INTEGER_MAX = 2147483647;

function exhaustedQuotaDelay(headers) {
  return Math.max(...["requests", "tokens"].map((unit) => {
    if (headers.get("x-ratelimit-remaining-" + unit) !== "0") return 0;
    const value = headers.get("x-ratelimit-reset-" + unit);
    const duration = /^(?=\d)(?:(\d+)d)?(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?$/.exec(value ?? "");
    if (!duration) return 0;
    const [days, hours, minutes, seconds] = duration.slice(1).map((part) => Number(part ?? 0));
    const delay = days * 86400 + hours * 3600 + minutes * 60 + seconds;
    return Number.isFinite(delay) ? Math.min(86400, Math.ceil(delay)) : 0;
  }));
}

function createGroqProvider({ apiKey, maxOutputTokens = 4096, fetchImpl = fetch, now = Date.now } = {}) {
  if (typeof apiKey !== "string" || !apiKey.trim()) throw new Error("GROQ_API_KEY is required");
  let restUntil = 0;

  return async ({ system, prompt, signal: callerSignal }) => {
    const remaining = restUntil - now();
    if (remaining > 0)
      throw new ProviderError("provider_rate_limited", 429, { retryAfter: Math.ceil(remaining / 1000) });
    const deadline = AbortSignal.timeout(120000);
    const signal = callerSignal ? AbortSignal.any([callerSignal, deadline]) : deadline;
    try {
      const response = await fetchImpl(ENDPOINT, {
        method: "POST",
        redirect: "error",
        signal,
        headers: { authorization: "Bearer " + apiKey, "content-type": "application/json" },
        body: JSON.stringify({
          model: MODEL,
          messages: [{ role: "system", content: system }, { role: "user", content: prompt }],
          response_format: { type: "json_object" },
          max_completion_tokens: maxOutputTokens,
        }),
      });
      const quotaDelay = exhaustedQuotaDelay(response.headers);
      const delay = response.status === 429
        ? Math.max(quotaDelay, retryAfter(response.headers, quotaDelay || 60))
        : quotaDelay;
      if (delay > 0) restUntil = Math.max(restUntil, now() + delay * 1000);
      if (!response.ok) {
        void response.body?.cancel().catch(() => {});
        if (response.status === 429)
          throw new ProviderError("provider_rate_limited", 429, { retryAfter: delay });
        if ([400, 401, 402, 403, 404].includes(response.status))
          throw new ProviderError("provider_misconfigured", 503, { retryAfter: retryAfter(response.headers, 300) });
        throw new ProviderError("provider_unavailable", 503, { retryAfter: retryAfter(response.headers, 15) });
      }
      const envelope = await readEnvelope(response, signal);
      const choice = envelope?.choices?.[0];
      const answer = envelope?.choices?.length === 1 && choice?.finish_reason === "stop"
        ? parseAnswer(choice.message?.content)
        : null;
      const { prompt_tokens: inputTokens, completion_tokens: outputTokens, total_tokens: totalTokens } = envelope?.usage ?? {};
      if (envelope?.model !== MODEL || !answer ||
          ![inputTokens, outputTokens, totalTokens].every(count =>
            Number.isInteger(count) && count > 0 && count <= POSTGRES_INTEGER_MAX) ||
          totalTokens < inputTokens + outputTokens) {
        throw new ProviderError("invalid_provider_output", 502, {
          reason: chatReason(choice, parseAnswer, [inputTokens, outputTokens, totalTokens].every(count => Number.isInteger(count) && count > 0)),
        });
      }
      return { answer, provider: "groq", model: MODEL, inputTokens, outputTokens, totalTokens };
    } catch (error) {
      if (error instanceof ProviderError) throw error;
      throw new ProviderError("provider_unavailable", 503, { retryAfter: 15 });
    }
  };
}

module.exports = { createGroqProvider };
