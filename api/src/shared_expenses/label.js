'use strict';
/**
 * Member-name helpers, mirrored in SQL (shared_expenses._clean_label / _label_key).
 *
 * cleanLabel: invisible, bidi and zero-width characters are removed; control
 * characters and exotic spaces become a space; whitespace collapses; capped at
 * 40 code points (never splitting a surrogate pair). '' when nothing is left.
 *
 * labelKey: the uniqueness key. NFKD, lower case, look-alike Cyrillic/Greek
 * letters folded to Latin, accents, punctuation, spaces and invisible
 * characters removed. Shared vectors: contracts/shared_expenses/v1/label_key_vectors.json.
 */
const INVISIBLE = /[\u{ad}\u{180e}\u{200b}-\u{200f}\u{202a}-\u{202e}\u{2060}-\u{2064}\u{2066}-\u{2069}\u{feff}]+/gu;
const SPACEY = /[\u{0}-\u{1f}\u{7f}-\u{9f}\u{a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}]+/gu;

function cleanLabel(value) {
  if (typeof value !== 'string') return '';
  const spaced = value.replace(INVISIBLE, '').replace(SPACEY, ' ').replace(/ +/g, ' ').trim();
  return Array.from(spaced).slice(0, 40).join('').trim();
}

const FROM = 'аеорсухктмнвіјАЕОРСУХКТМНВІЈοναρΟΝΑΡ';
const TO = 'aeopcyxktmhbijaeopcyxktmhbijovapovap';
const FOLD = new Map(Array.from(FROM).map((c, i) => [c, TO[i]]));
const REMOVE_MARKS = /[\u{300}-\u{36f}\u{ad}\u{180e}\u{2000}-\u{206f}\u{3000}-\u{303f}\u{fe00}-\u{fe0f}\u{feff}]+/gu;
const REMOVE_ASCII = /[\u{1}-\u{20}\u{21}-\u{2f}\u{3a}-\u{40}\u{5b}-\u{60}\u{7b}-\u{a0}]+/gu;

function labelKey(value) {
  if (typeof value !== 'string') return '';
  const lowered = value.normalize('NFKD').toLowerCase();
  let folded = '';
  for (const ch of lowered) folded += FOLD.get(ch) ?? ch;
  return folded.replace(REMOVE_MARKS, '').replace(REMOVE_ASCII, '');
}

const RESERVED = new Set(['you', 'me', 'myself', 'owner', 'admin', 'support', 'someone', 'pandapay', 'pandapayfriend', 'formermember', 'unknown', 'deleted']);
const isReservedLabel = (value) => RESERVED.has(labelKey(value));

module.exports = { cleanLabel, labelKey, isReservedLabel };
