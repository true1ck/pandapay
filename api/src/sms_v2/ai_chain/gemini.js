"use strict";

const { geminiReason } = require("./rejection");

const MAX_RESPONSE_BYTES = 256 * 1024;
const MODEL_PATTERN = /^[A-Za-z0-9_.-]{1,100}$/;

class ProviderError extends Error {
  constructor(code, status, { retryAfter, usage, model, reason } = {}) {
    super(code);
    this.code = code;
    this.status = status;
    this.retryAfter = retryAfter;
    this.usage = usage;
    this.model = model;
    // Why an invalid_provider_output was not usable (rejection.js); the caller reads it, the code stays the same.
    this.reason = reason;
  }
}

function retryAfter(headers, fallback) {
  const value = headers.get("retry-after");
  const seconds = /^\d+$/.test(value ?? "") ? Number(value) : Math.ceil((Date.parse(value) - Date.now()) / 1000);
  return Number.isSafeInteger(seconds) && seconds > 0 ? Math.min(86400, seconds) : fallback;
}

async function readEnvelope(response, signal, maxBytes = MAX_RESPONSE_BYTES) {
  if (!response.body) return null;
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    signal.throwIfAborted();
    size += chunk.byteLength;
    if (size > maxBytes) return null;
    chunks.push(chunk);
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)));
  } catch {
    return null;
  }
}

function usageOf(envelope) {
  const { promptTokenCount, candidatesTokenCount = 0, totalTokenCount } = envelope?.usageMetadata ?? {};
  // A blocked/truncated response may omit candidatesTokenCount. PandaPay bills thinking through total minus input.
  if (![promptTokenCount, candidatesTokenCount, totalTokenCount].every((value) => Number.isSafeInteger(value) && value >= 0) ||
      promptTokenCount === 0 || totalTokenCount < promptTokenCount + candidatesTokenCount) return undefined;
  return { inputTokens: promptTokenCount, outputTokens: candidatesTokenCount, totalTokens: totalTokenCount };
}

function answerOf(envelope) {
  const candidates = envelope?.candidates;
  if (!Array.isArray(candidates) || candidates.length !== 1 || candidates[0]?.finishReason !== "STOP") return null;
  const parts = candidates[0].content?.parts;
  if (!Array.isArray(parts)) return null;
  const raw = parts.filter((part) => part && !part.thought && typeof part.text === "string").map((part) => part.text).join("");
  return parseAnswer(raw);
}

function parseAnswer(raw) {
  let answer;
  try {
    answer = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isRecord(answer) || !Array.isArray(answer.emit) || answer.emit.length < 1 || answer.emit.length > 6 || !answer.emit.every(isRecord)) return null;
  // PandaPay still validates fact semantics. Bound nesting and reject dangerous keys before it walks the response.
  return hasSafeStructure(answer) ? answer : null;
}

const isRecord = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

function hasSafeStructure(value, depth = 0) {
  if (depth > 16) return false;
  if (value === null || typeof value !== "object") return true;
  return Object.entries(value).every(([key, child]) =>
    key !== "__proto__" && key !== "constructor" && key !== "prototype" && hasSafeStructure(child, depth + 1));
}

async function errorOf(response, signal) {
  if (response.status === 429 || response.status === 403) {
    const envelope = await readEnvelope(response, signal, 16 * 1024);
    if (response.status === 429 || envelope?.error?.status === "RESOURCE_EXHAUSTED") {
      const details = Array.isArray(envelope?.error?.details) ? envelope.error.details : [];
      const daily = /perday/i.test(JSON.stringify(envelope?.error ?? ""));
      const advised = details.map((detail) => /^([0-9]+(?:\.[0-9]+)?)s$/.exec(detail?.retryDelay)?.[1]).filter(Boolean);
      const backoff = advised.length ? Math.ceil(Math.max(...advised.map(Number))) : 60;
      return new ProviderError("provider_rate_limited", 429, {
        retryAfter: Math.min(86400, Math.max(retryAfter(response.headers, backoff), daily ? 1800 : 1)),
      });
    }
  } else {
    void response.body?.cancel().catch(() => {});
  }
  if ([400, 401, 403, 404].includes(response.status)) {
    return new ProviderError("provider_misconfigured", 503, { retryAfter: retryAfter(response.headers, 300) });
  }
  return new ProviderError("provider_unavailable", 503, { retryAfter: retryAfter(response.headers, 15) });
}

function createSingleGeminiProvider({ apiKey, model, maxOutputTokens = 4096, fetchImpl = fetch, timeoutMs = 20000 }) {
  if (typeof apiKey !== "string" || !apiKey.trim()) throw new Error("GEMINI_API_KEY is required");
  if (typeof model !== "string" || !MODEL_PATTERN.test(model)) throw new Error("PANDAPAY_AI_GEMINI_MODEL is required and must be a Gemini model ID");
  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;

  return async ({ system, prompt, signal: callerSignal }) => {
    const deadline = AbortSignal.timeout(timeoutMs);
    const signal = callerSignal ? AbortSignal.any([deadline, callerSignal]) : deadline;
    try {
      const response = await fetchImpl(endpoint, {
        method: "POST",
        redirect: "error",
        signal,
        headers: { "content-type": "application/json", "x-goog-api-key": apiKey },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: "user", parts: [{ text: prompt }] }],
          generationConfig: { responseMimeType: "application/json", maxOutputTokens },
        }),
      });
      if (!response.ok) throw await errorOf(response, signal);
      const envelope = await readEnvelope(response, signal);
      const answer = answerOf(envelope);
      const usage = usageOf(envelope);
      if (!answer || !usage?.outputTokens) {
        throw new ProviderError("invalid_provider_output", 502, { usage, model, reason: geminiReason(envelope, usage, parseAnswer) });
      }
      return { answer, model, ...usage };
    } catch (error) {
      if (error instanceof ProviderError) throw error;
      throw new ProviderError("provider_unavailable", 503, { retryAfter: 15 });
    }
  };
}

function parseApiKeys(env = process.env) {
  return normalizeKeys([
    env.GEMINI_API_KEY,
    env.GEMINI_FALLBACK_API_KEY,
    ...String(env.GEMINI_API_KEYS ?? "").split(","),
  ]);
}

function normalizeKeys(keys) {
  return [...new Set(keys.map((key) => String(key ?? "").trim()).filter(Boolean))];
}

function createGeminiProvider({ apiKey, apiKeys, now = Date.now, timeoutMs = 20000, ...options }) {
  const keys = normalizeKeys(apiKeys ?? [apiKey]);
  if (!keys.length) throw new Error("A Gemini credential is required");
  const providers = keys.map((key) => createSingleGeminiProvider({ ...options, apiKey: key, timeoutMs }));
  const restingUntil = new Map();
  let unavailableUntil = 0;
  let turn = 0;

  return async (request) => {
    const waitMs = unavailableUntil - now();
    if (waitMs > 0) {
      throw new ProviderError("provider_unavailable", 503, { retryAfter: Math.ceil(waitMs / 1000) });
    }
    // Every distinct-key attempt shares this deadline. Only a definite quota refusal advances the pool.
    const deadline = AbortSignal.timeout(timeoutMs);
    const signal = request.signal ? AbortSignal.any([request.signal, deadline]) : deadline;
    const first = turn;
    for (let step = 0; step < keys.length; step++) {
      const index = (first + step) % keys.length;
      const key = keys[index];
      if ((restingUntil.get(key) ?? 0) > now()) continue;
      turn = (index + 1) % keys.length;
      try {
        return await providers[index]({ ...request, signal });
      } catch (error) {
        if (error.status === 503 && !request.signal?.aborted) {
          unavailableUntil = Math.max(unavailableUntil, now() + (error.retryAfter ?? 15) * 1000);
        }
        if (error.code !== "provider_rate_limited") throw error;
        restingUntil.set(key, now() + error.retryAfter * 1000);
      }
    }
    const quotaWaitMs = Math.min(...keys.map((key) => Math.max(0, (restingUntil.get(key) ?? 0) - now())));
    throw new ProviderError("provider_rate_limited", 429, { retryAfter: Math.max(1, Math.ceil(quotaWaitMs / 1000)) });
  };
}

module.exports = { createGeminiProvider, parseApiKeys, ProviderError, readEnvelope, parseAnswer, retryAfter };
