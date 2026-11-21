import test from 'node:test';
import assert from 'node:assert/strict';
import { chineseNumber, findClaims, wrongClaims } from '../src/verify.mjs';
import { checkedSegments } from '../src/teacher.mjs';

test('Chinese numerals become numbers', () => {
  for (const [text, value] of [['三十八', 38], ['十二', 12], ['一百零五', 105], ['两千', 2000], ['一千零一十', 1010], ['三万五千', 35000]]) {
    assert.equal(chineseNumber(text), value, text);
  }
  assert.equal(chineseNumber('三点'), null);
});

test('spoken and written arithmetic claims are recomputed', () => {
  assert.deepEqual(findClaims('三十五减十八等于十七。').map(c => c.ok), [true]);
  assert.deepEqual(findClaims('三十五减十八等于十三。'), [{ claim: '35-18=13', expected: '17', stated: '13', ok: false }]);
  assert.deepEqual(findClaims('二十八加三十五得六十三').map(c => c.ok), [true]);
  assert.deepEqual(findClaims('5 × 6 = 30 分').map(c => c.ok), [true]);
  assert.deepEqual(findClaims('三加四乘二等于十一。').map(c => c.ok), [true], '× before +');
  assert.deepEqual(findClaims('十七除以五等于三余二。').map(c => c.ok), [true]);
  assert.deepEqual(findClaims('十七除以五等于三。').map(c => c.ok), [false], 'a dropped remainder is wrong');
  assert.deepEqual(findClaims('个位八加七等于十五，满十要向十位进一。').map(c => c.ok), [true]);
});

test('quoted, questioned or open sums are not claims', () => {
  assert.deepEqual(findClaims('你说八加七等于十四，对吗？'), []);
  assert.deepEqual(findClaims('如果写成八加七等于十四就不对了。'), []);
  assert.deepEqual(findClaims('八加七等于多少呢？'), []);
  assert.deepEqual(findClaims('38 + 27 = ?'), []);
  assert.deepEqual(findClaims('现在是三点三十分。'), []);
});

test('wrong claims are found in speech and in board text', () => {
  assert.equal(wrongClaims({ speech: '三十五减十八等于十七。', board: [{ op: 'add', el: { id: 't1', type: 'text', text: '35 - 18 = 13' } }] }).length, 1);
  assert.equal(wrongClaims({ speech: '好。', board: [{ op: 'update', id: 't1', set: { text: '35 - 18 = 17' } }] }).length, 0);
});

function sse(lines) {
  const text = lines.map(content => `data: ${JSON.stringify({ choices: [{ delta: { content } }] })}\n\n`).join('') + 'data: [DONE]\n\n';
  return new Response(text, { status: 200 });
}
const collect = async source => { const out = []; for await (const item of source) out.push(item); return out; };
const messages = [{ role: 'user', content: '35-18' }];

test('a wrong result is never spoken: the model goes on from where it was, told the right result', async () => {
  const requests = [];
  const replies = [
    ['{"speech":"我们来算三十五减十八。","board":[]}\n', '{"speech":"三十五减十八等于十三。","board":[]}\n', '{"speech":"不会到这里","board":[]}\n'],
    ['{"speech":"三十五减十八等于十七，所以还剩十七颗。","board":[],"await":false}\n']
  ];
  const post = async body => { requests.push(body); return sse(replies[requests.length - 1]); };
  const checks = [];
  const out = await collect(checkedSegments(messages, post, { model: 'm', thinking: 'disabled' }, undefined, { onCheck: c => checks.push(c) }));
  assert.deepEqual(out.map(s => s.speech), ['我们来算三十五减十八。', '三十五减十八等于十七，所以还剩十七颗。']);
  assert.equal(requests.length, 2);
  assert.deepEqual(requests[0].thinking, { type: 'disabled' });
  const retry = requests[1].messages;
  assert.equal(retry.at(-2).role, 'assistant');
  assert.match(retry.at(-2).content, /我们来算三十五减十八/);
  assert.doesNotMatch(retry.at(-2).content, /等于十三/, 'the wrong segment was never said');
  assert.match(retry.at(-1).content, /35-18=13 算错了，正确结果是 17/);
  assert.deepEqual(checks.map(c => c.corrected), [true]);
});

test('wrong twice: the reply ends with a question instead of a wrong sum', async () => {
  let calls = 0;
  const post = async () => { calls++; return sse(['{"speech":"三十五减十八等于十三。","board":[]}\n']); };
  const out = await collect(checkedSegments(messages, post, { model: 'm' }, undefined));
  assert.equal(calls, 2);
  assert.equal(out.length, 1);
  assert.equal(out[0].await, true);
  assert.doesNotMatch(out[0].speech, /十三/);
});

test('an upstream error still surfaces as an error', async () => {
  const post = async () => new Response('nope', { status: 502 });
  await assert.rejects(collect(checkedSegments(messages, post, { model: 'm' }, undefined)), /model_http_502/);
});

test('the reply stops at the first question that waits for the child', async () => {
  const post = async () => sse(['{"speech":"一米是多少厘米？","board":[],"await":true}\n', '{"speech":"对啦，一米等于一百厘米。","board":[]}\n']);
  const out = await collect(checkedSegments(messages, post, { model: 'm' }, undefined));
  assert.deepEqual(out.map(s => s.speech), ['一米是多少厘米？']);
});
