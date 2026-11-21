/**
 * Checks the arithmetic the teacher says out loud. The column calculation on the board is computed by the client,
 * but a spoken conclusion ("三十五减十八等于十七") comes straight from the model and can be wrong. Claims are found
 * in speech (Chinese numerals) and in board text ("35 - 18 = 17"), recomputed exactly, and wrong ones reported.
 *
 * Only plain claims are checked: a sentence that quotes or questions an answer ("你说八加七等于十四，对吗？",
 * "如果写成……就不对了") is skipped, because the teacher says wrong results on purpose when discussing a mistake.
 */

const digits = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
const units = { 十: 10, 百: 100, 千: 1000 };

/** A Chinese numeral up to 99,999,999 (三十八, 一百零五, 两千, 十二, 三万五千) as a number, or null. */
export function chineseNumber(text) {
  if (!text) return null;
  let total = 0, section = 0, number = 0, seen = false;
  for (const ch of text) {
    if (ch in digits) { number = digits[ch]; seen = true; }
    else if (ch in units) { section += (number || (seen ? 0 : 1)) * units[ch]; number = 0; seen = true; }
    else if (ch === '万') { total += (section + number) * 10_000; section = 0; number = 0; seen = true; }
    else return null;
  }
  return seen ? total + section + number : null;
}

const numeral = '[零〇一二两三四五六七八九十百千万]+';
const operators = [
  [/乘以|乘上|乘|[×xX*]/g, '×'],
  [/除以|[÷/]/g, '÷'],
  [/加上|加|＋|\+/g, '+'],
  [/减去|减掉|减|－|−|-/g, '-'],
  [/等于|得|＝|=/g, '=']
];

/** Rewrites numerals as digits and spoken operators as symbols: 三十五减十八等于十七 → 35-18=17. */
export function normalizeArithmetic(text) {
  let out = text.replace(new RegExp(numeral, 'gu'), match => {
    const value = chineseNumber(match);
    return value === null ? match : String(value);
  });
  for (const [pattern, symbol] of operators) out = out.replace(pattern, symbol);
  return out.replace(/\s+/g, '');
}

function evaluate(expression) {
  // Left to right with × and ÷ first; integers only. Returns null for anything that is not exact.
  const tokens = expression.match(/\d+|[+\-×÷]/g);
  if (!tokens || tokens.join('') !== expression) return null;
  const values = [Number(tokens[0])], ops = [];
  for (let i = 1; i < tokens.length; i += 2) {
    const op = tokens[i], value = Number(tokens[i + 1]);
    if (!Number.isFinite(value)) return null;
    if (op === '×') values.push(values.pop() * value);
    else if (op === '÷') {
      const left = values.pop();
      if (value === 0) return null;
      values.push(left / value);
    } else { ops.push(op); values.push(value); }
  }
  let result = values[0];
  for (let i = 0; i < ops.length; i++) result = ops[i] === '+' ? result + values[i + 1] : result - values[i + 1];
  return result;
}

const hedges = /吗|呢|？|\?|如果|假如|你说|你算|你写|说成|写成|算成|看成|是不是|不是|不等于|不对|错|猜/;

/**
 * The arithmetic claims in `text`: `{claim, expected, stated}` per "expression = number", with `ok` false when
 * the stated result is wrong. Division with a remainder ("十七除以五等于三余二") is checked as quotient and remainder.
 */
export function findClaims(text) {
  if (typeof text !== 'string' || !text) return [];
  const claims = [];
  for (const sentence of text.split(/(?<=[。！？!?；;\n])/u)) {
    if (hedges.test(sentence)) continue;
    const plain = normalizeArithmetic(sentence);
    const pattern = /(\d+(?:[+\-×÷]\d+)+)=(\d+)(?:余(\d+))?/g;
    let match;
    while ((match = pattern.exec(plain))) {
      const [claim, expression, statedText, remainderText] = match;
      const stated = Number(statedText);
      if (remainderText !== undefined) {
        const parts = expression.split('÷');
        if (parts.length !== 2) continue;
        const [a, b] = parts.map(Number);
        if (!b) continue;
        const expected = `${Math.floor(a / b)}余${a % b}`;
        claims.push({ claim, expected, stated: `${stated}余${remainderText}`, ok: expected === `${stated}余${remainderText}` });
        continue;
      }
      const expected = evaluate(expression);
      if (expected === null) continue;
      if (!Number.isInteger(expected)) {
        // 17÷5 with no remainder said: the model left out the remainder, which is a mistake for this age.
        claims.push({ claim, expected: `${Math.floor(expected)}余${Math.round((expected % 1) * Number(expression.split('÷').at(-1)))}`, stated: String(stated), ok: false });
        continue;
      }
      claims.push({ claim, expected: String(expected), stated: String(stated), ok: expected === stated });
    }
  }
  return claims;
}

/** Board text a raw (not yet validated) segment would show: added or updated text elements. */
function boardTexts(segment) {
  const texts = [];
  for (const op of Array.isArray(segment?.board) ? segment.board : []) {
    if (op?.op === 'add' && typeof op.el?.text === 'string') texts.push(op.el.text);
    if (op?.op === 'update' && typeof op.set?.text === 'string') texts.push(op.set.text);
  }
  return texts;
}

/** Wrong claims in a raw segment's speech and board text. */
export function wrongClaims(segment) {
  const sources = [segment?.speech, ...boardTexts(segment)].filter(text => typeof text === 'string');
  return sources.flatMap(findClaims).filter(claim => !claim.ok);
}
