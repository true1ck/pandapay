"use strict";

// Why a provider's reply was not a usable answer. The caller (PandaPay's worker) reads it to tell a model that wrote
// something wrong from one that wrote nothing, and the log shows it per attempt. Codes only, never any text from the
// layout or the answer.
const REASONS = Object.freeze(["blocked", "truncated", "empty", "not_json", "bad_shape", "no_usage", "bad_output", "no_route_left"]);
const isReason = (value) => typeof value === "string" && REASONS.includes(value);

const GEMINI_BLOCKED = new Set(["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION", "IMAGE_SAFETY", "LANGUAGE"]);

// `parse(text)` is gemini.parseAnswer: the answer object, or null when the text is not a usable draft.
function textReason(text, parse) {
  if (typeof text !== "string" || !text.trim()) return "empty";
  try { JSON.parse(text); } catch { return "not_json"; }
  return parse(text) ? "bad_output" : "bad_shape";
}

function geminiReason(envelope, usage, parse) {
  if (envelope?.promptFeedback?.blockReason) return "blocked";
  const candidates = envelope?.candidates;
  if (!Array.isArray(candidates) || candidates.length !== 1) return "empty";
  const finish = candidates[0]?.finishReason;
  if (finish === "MAX_TOKENS") return "truncated";
  if (GEMINI_BLOCKED.has(finish) || (finish && finish !== "STOP")) return "blocked";
  const parts = candidates[0].content?.parts;
  const text = Array.isArray(parts)
    ? parts.filter((part) => part && !part.thought && typeof part.text === "string").map((part) => part.text).join("")
    : "";
  const reason = textReason(text, parse);
  if (reason !== "bad_output") return reason;
  return usage?.outputTokens ? "bad_output" : "no_usage";
}

// OpenAI-style providers (Groq, OpenRouter, Cloudflare, NVIDIA, Experiential).
function chatReason(choice, parse, tokensOk = true) {
  if (choice?.finish_reason === "length") return "truncated";
  if (choice?.finish_reason === "content_filter") return "blocked";
  const reason = textReason(choice?.message?.content, parse);
  if (reason !== "bad_output") return reason;
  return tokensOk ? "bad_output" : "no_usage";
}

module.exports = { REASONS, isReason, geminiReason, chatReason };
