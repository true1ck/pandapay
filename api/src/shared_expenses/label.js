'use strict';
/**
 * Member-name helpers, mirrored in SQL (shared_expenses._clean_text / _clean_label / _label_key).
 *
 * cleanText: invisible, bidi and zero-width characters are removed; control
 * characters and exotic spaces become a space; whitespace collapses; capped at
 * `max` code points (never splitting a surrogate pair). '' when nothing is left.
 * cleanLabel is cleanText with the 40 code point cap used for member labels.
 *
 * labelKey: the uniqueness key. NFKD, lower case, look-alike Cyrillic/Greek
 * letters folded to Latin, combining marks (every block) removed and the rest
 * recomposed, then symbols, emoji, punctuation, spaces and invisible characters
 * removed. Shared vectors: contracts/shared_expenses/v1/label_key_vectors.json.
 */
const INVISIBLE = /[\u{ad}\u{180e}\u{200b}-\u{200f}\u{202a}-\u{202e}\u{2060}-\u{2064}\u{2066}-\u{2069}\u{feff}]+/gu;
const SPACEY = /[\u{0}-\u{1f}\u{7f}-\u{9f}\u{a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}]+/gu;

function cleanText(value, max) {
  if (typeof value !== 'string') return '';
  const spaced = value.replace(INVISIBLE, '').replace(SPACEY, ' ').replace(/ +/g, ' ').trim();
  return Array.from(spaced).slice(0, max).join('').trim();
}
const cleanLabel = (value) => cleanText(value, 40);

const FROM = 'аеорсухктмнвіјѕԁԛһӏԝѵοναριεκυτβχηωγμıАЕОРСУХКТМНВІЈЅԀԚҺӀԜѴΟΝΑΡΙΕΚΥΤΒΧΗΩΓΜI';
const TO = 'aeopcyxktmhbijsdqhlwvovapiekutbxnwymiaeopcyxktmhbijsdqhlwvovapiekutbxnwymi';
const FOLD = new Map(Array.from(FROM).map((c, i) => [c, Array.from(TO)[i]]));
const MARKS = /[\u{300}-\u{36f}\u{1ab0}-\u{1aff}\u{1dc0}-\u{1dff}\u{20d0}-\u{20ff}\u{fe20}-\u{fe2f}]+/gu;
const SYMBOLS = /[\u{ad}\u{180e}\u{2000}-\u{2bff}\u{3000}-\u{303f}\u{fe00}-\u{fe0f}\u{feff}\u{e000}-\u{f8ff}\u{1f000}-\u{1faff}\u{e0000}-\u{e007f}]+/gu;
const ASCII_JUNK = /[\u{1}-\u{20}\u{21}-\u{2f}\u{3a}-\u{40}\u{5b}-\u{60}\u{7b}-\u{a0}]+/gu;

function labelKey(value) {
  if (typeof value !== 'string') return '';
  const lowered = value.normalize('NFKD').toLowerCase();
  let folded = '';
  for (const ch of lowered) folded += FOLD.get(ch) ?? ch;
  return folded.replace(MARKS, '').normalize('NFC').replace(SYMBOLS, '').replace(ASCII_JUNK, '');
}

/** exact you/me/myself; starts with owner/admin/support/someone/unknown/deleted/formermember; contains pandapay. */
function isReservedKey(key) {
  return ['you', 'me', 'myself'].includes(key) || key.includes('pandapay') || /^(owner|admin|support|someone|unknown|deleted|formermember)/.test(key);
}
const isReservedLabel = (value) => isReservedKey(labelKey(value));

module.exports = { cleanText, cleanLabel, labelKey, isReservedLabel, isReservedKey };
