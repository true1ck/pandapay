"use strict";
const { workerConfig } = require("../../../src/sms_v2/template_worker");
const template = {
  template_hash: "a".repeat(64),
  sender_brand: "TESTBK",
  redacted_body: "<AMT> paid to <PARTY>.",
};
const config = workerConfig({
  SMS_V2_AI_MODEL: "test-model",
  SMS_V2_AI_TPM: "200000",
  SMS_V2_AI_INPUT_USD_PER_MILLION: "1",
  SMS_V2_AI_OUTPUT_USD_PER_MILLION: "2",
});
function rule() {
  return {
    id: `AI-${template.template_hash}`,
    version: 1,
    family: "bank_debit",
    senders: ["TESTBK"],
    priority: 500,
    match: {
      pattern: "^Rs\\. (?<amt>[0-9.]+) paid to (?<merchant>[A-Z ]+)\\.$",
      flags: "i",
      templateHash: template.template_hash,
    },
    emit: [
      {
        factType: "movement",
        attrs: { direction: "debit", purpose: "purchase", rail: "upi" },
        amounts: [{ role: "posted", from: "amt", unit: "INR" }],
        counterparty: { nameFrom: "merchant", kind: "merchant" },
      },
    ],
    confidence: 0.6,
    status: "provisional",
    createdBy: "ai:test-model",
    updatedAt: "2026-11-20T00:00:00Z",
    examples: [
      {
        sender: "TESTBK",
        body: "Rs. 127.45 paid to SYNTHETIC STORE.",
        expectFactTypes: ["movement"],
      },
      {
        sender: "TESTBK",
        body: "Rs. 239.12 paid to TEST SHOP.",
        expectFactTypes: ["movement"],
      },
      {
        sender: "TESTBK",
        body: "Rs. 127.45 payment to SYNTHETIC STORE failed.",
        expectFactTypes: [],
      },
      {
        sender: "TESTBK",
        body: "Rs. 239.12 will be paid to TEST SHOP.",
        expectFactTypes: [],
      },
    ],
  };
}
module.exports = { template, config, rule };
