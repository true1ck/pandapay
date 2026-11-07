'use strict';
/**
 * The one member-name cleaner (mirrors shared_expenses._clean_label in SQL):
 * C0/DEL/C1 control characters (including U+0085) and line/paragraph separators
 * become a space, whitespace collapses, trimmed, capped at 40 code points (never
 * splitting a surrogate pair). Returns '' when nothing is left.
 */
function cleanLabel(value) {
  if (typeof value !== 'string') return '';
  const spaced = value.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, ' ').replace(/\s+/g, ' ').trim();
  return Array.from(spaced).slice(0, 40).join('').trim();
}
module.exports = { cleanLabel };
