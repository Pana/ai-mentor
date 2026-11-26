import test from 'node:test';
import assert from 'node:assert/strict';
import { compare, imageInfo, parseReading, readPhoto, recompute, requestBody, runEval, summarize } from '../eval/vision-read.mjs';
import { renderReport } from '../eval/vision-report.mjs';

/** A JPEG with only the headers the size reader looks at: an optional EXIF orientation and a frame header. */
function jpeg(width, height, orientation) {
  const exif = orientation ? Buffer.concat([Buffer.from('Exif\0\0MM\0*\0\0\0\x08\0\x01\x01\x12\0\x03\0\0\0\x01', 'latin1'), Buffer.from([0, orientation, 0, 0, 0, 0, 0, 0])]) : null;
  const app1 = exif ? Buffer.concat([Buffer.from([0xff, 0xe1, 0, exif.length + 2]), exif]) : Buffer.alloc(0);
  const frame = Buffer.from([0xff, 0xc0, 0, 17, 8, height >> 8, height & 255, width >> 8, width & 255, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), app1, frame, Buffer.from([0xff, 0xd9])]);
}
const photo = (name = 'a.jpg') => ({ name, bytes: jpeg(1600, 1200), mime: 'image/jpeg', width: 1600, height: 1200, orientation: 1 });
const model = (name, extra = {}) => ({ name, apiUrl: 'https://vision.example/v1/chat/completions', apiKey: `key-${name}-not-a-secret`, model: `${name}-model`, ...extra });
const reply = (reading, usage = { prompt_tokens: 1200, completion_tokens: 300 }) =>
  new Response(JSON.stringify({ choices: [{ message: { content: typeof reading === 'string' ? reading : JSON.stringify(reading) } }], usage }), { status: 200 });
const item = (no, question, answer, more = {}) => ({ no, kind: 'arithmetic', question, answer, answerClear: true, judgement: 'correct', box: [100, 100, 500, 200], ...more });

test('reads the size and rotation of a JPEG and the size of a PNG, and refuses other files', () => {
  assert.deepEqual(imageInfo(jpeg(1600, 1200)), { mime: 'image/jpeg', width: 1600, height: 1200, orientation: 1 });
  assert.equal(imageInfo(jpeg(1200, 1600, 6)).orientation, 6);
  const png = Buffer.alloc(33);
  Buffer.from('\x89PNG\r\n\x1a\n', 'latin1').copy(png);
  png.writeUInt32BE(800, 16); png.writeUInt32BE(600, 20);
  assert.deepEqual(imageInfo(png), { mime: 'image/png', width: 800, height: 600, orientation: 1 });
  assert.equal(imageInfo(Buffer.from('not an image at all')), null);
});

test('the request carries the photo as a data URL and the vendor switches last', () => {
  const body = requestBody(model('a', { jsonMode: true, extra: { thinking: { type: 'disabled' }, max_tokens: 9000 }, imageExtra: { detail: 'xhigh' } }), photo());
  assert.equal(body.model, 'a-model');
  assert.match(body.messages[1].content[0].image_url.url, /^data:image\/jpeg;base64,\/9j/);
  assert.equal(body.messages[1].content[0].image_url.detail, 'xhigh');
  assert.deepEqual(body.response_format, { type: 'json_object' });
  assert.deepEqual(body.thinking, { type: 'disabled' });
  assert.equal(body.max_tokens, 9000);
});

test('parses a reply wrapped in a code fence or a sentence, and keeps the child\'s wrong answer as written', () => {
  const reading = { legible: true, note: '', items: [item('1', '35-18=', '27', { judgement: 'incorrect' }), { no: '', kind: 'essay', question: '看图写话', answer: '', box: null }] };
  for (const raw of ['```json\n' + JSON.stringify(reading) + '\n```', '好的，结果如下：' + JSON.stringify(reading) + '。']) {
    const parsed = parseReading(raw, photo());
    assert.equal(parsed.items[0].answer, '27');
    assert.equal(parsed.items[0].judgement, 'incorrect');
    assert.deepEqual(parsed.items[1], { no: '2', kind: 'other', question: '看图写话', answer: null, answerClear: false, judgement: 'unknown', box: null });
  }
  assert.throws(() => parseReading('我看不清这张照片', photo()));
  assert.throws(() => parseReading('{"items":"none"}', photo()));
});

test('boxes come out as fractions of the image whether the model wrote per mille, pixels or fractions', () => {
  const read = (boxes, unit) => parseReading(JSON.stringify({ items: boxes.map((box, i) => item(String(i + 1), '1+1=', '2', { box })) }), photo(), unit).items.map(i => i.box);
  assert.deepEqual(read([[100, 250, 500, 750]]), [[0.1, 0.25, 0.5, 0.75]]);
  assert.deepEqual(read([[160, 300, 800, 900], [0, 0, 1600, 1200]]), [[0.1, 0.25, 0.5, 0.75], [0, 0, 1, 1]]);
  assert.deepEqual(read([[0.1, 0.25, 0.5, 0.75]]), [[0.1, 0.25, 0.5, 0.75]]);
  assert.deepEqual(read([[160, 300, 800, 900]], 'pixels'), [[0.1, 0.25, 0.5, 0.75]]);
  assert.deepEqual(read(['<bbox>100 250 500 750</bbox>', { x1: 500, y1: 750, x2: 100, y2: 250 }, [5, 5, 5, 5], 'none']), [[0.1, 0.25, 0.5, 0.75], [0.1, 0.25, 0.5, 0.75], null, null]);
});

test('plain arithmetic is recomputed; anything else is left to a person', () => {
  const check = (question, answer, more) => recompute({ kind: 'arithmetic', question, answer, answerClear: true, ...more });
  assert.deepEqual(check('35 - 18 =', '17'), { verdict: 'correct', expected: '17' });
  assert.deepEqual(check('35-18', '27'), { verdict: 'incorrect', expected: '17' });
  assert.deepEqual(check('6×7=', '42'), { verdict: 'correct', expected: '42' });
  assert.deepEqual(check('17÷5=', '3……2'), { verdict: 'correct', expected: '3余2' });
  assert.deepEqual(check('17÷5=', '3'), { verdict: 'incorrect', expected: '3余2' });
  assert.equal(check('35-( )=17', '18'), null);
  assert.equal(check('3米+20厘米=', '320厘米'), null);
  assert.equal(check('35-18=', '17', { answerClear: false }), null);
  assert.equal(check('35-18=', null), null);
  assert.equal(check('35-18=', '17', { kind: 'fill' }), null);
});

test('lines the models up question by question and points at the one that read it differently', () => {
  const a = [item('1', '35-18=', '17'), item('2', '6×7=', '42'), item('1', '8+5=', '13')];
  const b = [item('1.', '35 - 18 =', '17'), item('2.', '6x7=', '42'), item('1.', '8+5=', '13')];
  const c = [item('(1)', '35-18=', '11'), item('(1)', '8+5=', '13')];
  const rows = compare([{ model: 'a', items: a }, { model: 'b', items: b }, { model: 'c', items: c }]);
  assert.deepEqual(rows.map(row => [row.key, row.contested, row.outliers]), [['1', true, ['c']], ['2', true, ['c']], ['1#2', false, []]]);
  assert.equal(rows[1].cells.c, undefined);
  const pair = compare([{ model: 'a', items: a }, { model: 'c', items: c }]);
  assert.deepEqual(pair.map(row => [row.contested, row.outliers]), [[true, []], [true, []], [false, []]]);
});

test('a busy vendor is retried once; a refused key is reported without the key', async () => {
  let calls = 0;
  const busyThenFine = async () => (++calls === 1 ? new Response('busy', { status: 503 }) : reply({ items: [item('1', '1+1=', '2')] }));
  const fine = await readPhoto(model('a'), photo(), { fetchImpl: busyThenFine, retryDelayMs: 1 });
  assert.equal(calls, 2);
  assert.equal(fine.ok, true);
  assert.deepEqual(fine.usage, { input: 1200, output: 300 });
  let sent;
  const refused = await readPhoto(model('a'), photo(), { fetchImpl: async (url, init) => { sent = init; return new Response('{"error":"invalid api key"}', { status: 401 }); } });
  assert.equal(sent.headers.Authorization, 'Bearer key-a-not-a-secret');
  assert.deepEqual([refused.ok, refused.error.startsWith('HTTP 401')], [false, true]);
  assert.doesNotMatch(JSON.stringify(refused), /key-a-not-a-secret/);
  const garbled = await readPhoto(model('a'), photo(), { fetchImpl: async () => reply('抱歉，我无法处理图片') });
  assert.equal(garbled.ok, false);
  assert.match(garbled.error, /^回复不是要求的 JSON/);
  assert.equal(garbled.raw, '抱歉，我无法处理图片');
  const cut = await readPhoto(model('a'), photo(), { fetchImpl: async () => new Response(JSON.stringify({ choices: [{ finish_reason: 'length', message: { content: '{"items":[{"no":"1","que' } }] }), { status: 200 }) });
  assert.deepEqual([cut.ok, cut.error], [false, '回复太长被截断']);
});

test('a whole run: every photo through every model, summarised and rendered without trusting model text', async () => {
  const readings = {
    'a-model': { legible: true, note: '', items: [item('1', '35-18=', '27', { judgement: 'correct' }), item('2', '6×7=', '42')] },
    'b-model': { legible: true, note: '</script><img src=x onerror=alert(1)>', items: [item('1', '35-18=', '27', { judgement: 'incorrect' }), item('2', '6×7=', '42')] },
    'c-model': { legible: true, note: '', items: [item('1', '35-18=', '17')] }
  };
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    return body.model === 'd-model' ? new Response('down', { status: 500 }) : reply(readings[body.model]);
  };
  const models = [model('a', { price: { input: 1, output: 4 } }), model('b'), model('c'), model('d')];
  const run = await runEval({ photos: [photo('一.jpg'), photo('two.jpg')], models, fetchImpl, retryDelayMs: 1 });
  assert.equal(run.photos[0].bytes, undefined);
  assert.equal(run.photos[0].results.d.ok, false);
  assert.deepEqual(run.photos[0].results.a.reading.items[0].check, { verdict: 'incorrect', expected: '17' });
  assert.deepEqual(run.photos[0].rows.map(row => row.outliers), [['c'], ['c']]);

  const summary = summarize(run, models);
  assert.deepEqual(summary.map(s => [s.name, s.ok, s.items, s.judged, s.misjudged, s.outliers]),
    [['a', 2, 4, 4, 2, 0], ['b', 2, 4, 4, 0, 0], ['c', 2, 2, 2, 0, 4], ['d', 0, 0, 0, 0, 0]]);
  assert.equal(summary[0].costPerPhoto, 0.0024);
  assert.equal(summary[1].costPerPhoto, null);

  const html = renderReport({ runId: 'test', startedAt: '2026-11-26 08:00 UTC', models, run, summary, src: p => `photos/${encodeURIComponent(p.name)}` });
  const data = JSON.parse(html.match(/<script id="data" type="application\/json">(.*?)<\/script>/s)[1]);
  assert.equal(data.photos[0].src, 'photos/%E4%B8%80.jpg');
  assert.equal(data.photos[0].results.b.reading.note, '</script><img src=x onerror=alert(1)>');
  assert.equal(html.includes('<img src=x'), false);
  assert.doesNotMatch(html, /not-a-secret/);
});
