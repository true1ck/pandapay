/**
 * Known-brand catalog for subscription display and detection.
 *
 * A plain table, no code per brand. It provides three facts per brand:
 *   match  — how the brand's merchant strings are recognised (deliberately
 *            narrow; 'amazon' alone is shopping, 'amazonprime' is a plan)
 *   name   — the canonical display name shown on the card
 *   cadence — the cadence to assume in the absence of any better evidence;
 *            mandate text and observed charges always override this
 *
 * Detection uses it for display names and a relaxed two-charge admission —
 * a brand-name match is strong prior evidence. Annual plans seen once
 * (₹1,499 Amazon Prime, ₹899 Hotstar) stay out for now: one matching charge
 * is still a coincidence for rarer amounts, and an estimated renewal date
 * built from a guess is not worth it yet.
 *
 * ponytail: curated list, extend from observed merchant strings; add
 * insurance/telecom once mandate amounts carry real charge values.
 */

const BRANDS = [
  // AI + productivity
  { match: /openaillc|openai|chatgpt/i, name: 'OpenAI', cadence: 30 },
  { match: /anthropic|claude\.ai|claudepro|\bclaude\b/i, name: 'Claude', cadence: 30 },
  { match: /google[*\s]?gemini|gemini(?:\.google|advanced)?|\bgemini\b/i, name: 'Google Gemini', cadence: 30 },
  { match: /google\s*one|googleone/i, name: 'Google One', cadence: 30 },
  { match: /google\s*play|googleplay/i, name: 'Google Play', cadence: 30 },
  { match: /cursor|anysphere/i, name: 'Cursor', cadence: 30 },
  { match: /github/i, name: 'GitHub', cadence: 30 },
  { match: /perplexity/i, name: 'Perplexity', cadence: 30 },
  { match: /midjourney/i, name: 'Midjourney', cadence: 30 },
  { match: /notion\./i, name: 'Notion', cadence: 30 },
  { match: /figma/i, name: 'Figma', cadence: 30 },
  { match: /canva/i, name: 'Canva', cadence: 30 },
  { match: /adobe/i, name: 'Adobe', cadence: 30 },
  { match: /dropbox/i, name: 'Dropbox', cadence: 30 },
  { match: /linkedinpremium|linkedin\s*premium/i, name: 'LinkedIn Premium', cadence: 30 },
  { match: /ind\*microsoft|microsoftrs|microsoft365|office365|office\s*365|\bmicrosoft\b/i, name: 'Microsoft 365', cadence: 30 },
  { match: /icloud|apple\b/i, name: 'Apple', cadence: 30 },

  // Streaming + music
  { match: /netflix/i, name: 'Netflix', cadence: 30 },
  { match: /amazonprime|amazon\s*prime|primevideo|prime\s*video/i, name: 'Amazon Prime', cadence: 365 },
  { match: /hotstar|jiocinema|jiohostar/i, name: 'JioHotstar', cadence: 365 },
  { match: /youtube(?!mail)|ytpremium|ytkids/i, name: 'YouTube Premium', cadence: 30 },
  { match: /spotify/i, name: 'Spotify', cadence: 30 },
  { match: /sonyliv|sonylivfhd/i, name: 'SonyLIV', cadence: 365 },
  { match: /zee5|zilra/i, name: 'ZEE5', cadence: 30 },
  { match: /jiosaavn|wynk|gaana/i, name: 'Music streaming', cadence: 30 },

  // India utility + telecom (postpaid/broadband plans, not one-off recharges:
  // observed pattern evidence still gates these)
  { match: /tataplay|tataplayfhd|tata\s*play|dth/i, name: 'Tata Play', cadence: 30 },
  { match: /airtel/i, name: 'Airtel', cadence: 30 },
  { match: /jio\d?\b|\bfiber/i, name: 'Jio', cadence: 30 },
  { match: /\bvi\b|vodafone\s*idea|ideacellular/i, name: 'Vi', cadence: 30 },
  { match: /act\s*fibernett?|actfibernett/i, name: 'ACT Fibernet', cadence: 30 },
  { match: /hathway|excitel|tikona/i, name: 'Broadband', cadence: 30 },

  // Fitness + memberships
  { match: /cult\.|cultfit|cultelite/i, name: 'Cult.Fit', cadence: 30 },

];

/** The brand whose match pattern fits `name`, or undefined. */
function brandFor(name) {
  const value = String(name || '');
  for (const brand of BRANDS) {
    if (brand.match.test(value)) return brand;
  }
  return undefined;
}

module.exports = { brandFor };
