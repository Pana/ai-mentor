import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createGateway } from '../src/gateway.mjs';
import { createApi, localParts } from '../src/api.mjs';
import { validateParseReply } from '../src/parse.mjs';

const bootstrapToken = 'parent-bootstrap-token-not-a-secret';
const tutorToken = 'device-test-token-not-a-secret-12345';
const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
const m4a = Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from('ftypM4A '), Buffer.alloc(8)]);
// 2026-11-09 is a Monday. 10:00Z is 18:00 in Beijing: before the 19:30 finish time and the 19:00 reward window.
const beijing = (date, time) => Date.parse(`${date}T${time}:00+08:00`);

async function setup(t, { model = {}, fetchImpl } = {}) {
  const dataDir = mkdtempSync(join(tmpdir(), 'littlebear-'));
  const clock = { ms: beijing('2026-11-09', '18:00') };
  const api = createApi({ dataDir, bootstrapToken, model, fetchImpl, now: () => clock.ms });
  const server = createGateway({ token: tutorToken, api });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(() => { api.close(); rmSync(dataDir, { recursive: true, force: true }); resolve(); }); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${server.address().port}`;
  async function call(method, path, { token, body, raw, type } = {}) {
    const headers = {};
    if (token) headers.Authorization = `Bearer ${token}`;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (raw) headers['Content-Type'] = type;
    const response = await fetch(base + path, { method, headers, body: raw ?? (body === undefined ? undefined : JSON.stringify(body)) });
    const isJson = response.headers.get('content-type')?.startsWith('application/json');
    return { status: response.status, body: isJson ? await response.json() : Buffer.from(await response.arrayBuffer()) };
  }
  const parent = (await call('POST', '/v1/devices/bootstrap', { body: { token: bootstrapToken, deviceId: randomUUID(), name: '妈妈的 iPhone' } })).body.deviceToken;
  const { code } = (await call('POST', '/v1/devices/pairing-codes', { token: parent, body: {} })).body;
  const child = (await call('POST', '/v1/devices/pair', { body: { code, deviceId: randomUUID(), name: '林林的 iPad' } })).body.deviceToken;
  const childId = randomUUID();
  await call('PUT', `/v1/children/${childId}`, { token: parent, body: { name: '林林', grade: 2 } });
  const upload = async (bytes = jpeg, type = 'image/jpeg', token = child) => {
    const id = randomUUID();
    assert.equal((await call('PUT', `/v1/files/${id}`, { token, raw: bytes, type })).status, 200);
    return id;
  };
  const addHomework = async (fields = {}) => (await call('POST', '/v1/homework', { token: parent, body: { items: [{
    id: randomUUID(), childId, subject: 'MATH', date: '2026-11-09', content: '口算本第 12 页', mode: 'OFFLINE', ...fields }] } })).body.items[0];
  const submit = async (hw, fields = {}) => call('POST', `/v1/homework/${hw.id}/submissions`, { token: child,
    body: { id: randomUUID(), fileIds: [await upload()], submittedAt: new Date(clock.ms).toISOString(), ...fields } });
  const balance = async () => (await call('GET', `/v1/rewards?childId=${childId}`, { token: child })).body;
  return { call, clock, parent, child, childId, upload, addHomework, submit, balance, dataDir };
}

test('family time is computed in Beijing time', () => {
  assert.deepEqual(localParts(Date.parse('2026-11-09T16:30:00Z'), 'Asia/Shanghai'), { date: '2026-11-10', time: '00:30' });
});

test('devices: bootstrap needs the secret, pairing codes are single use, roles are enforced, revoked devices are locked out', async t => {
  const { call, parent, child } = await setup(t);
  assert.equal((await call('POST', '/v1/devices/bootstrap', { body: { token: 'wrong', deviceId: randomUUID() } })).status, 401);
  const { code } = (await call('POST', '/v1/devices/pairing-codes', { token: parent, body: {} })).body;
  assert.equal((await call('POST', '/v1/devices/pair', { body: { code, deviceId: randomUUID() } })).status, 200);
  assert.equal((await call('POST', '/v1/devices/pair', { body: { code, deviceId: randomUUID() } })).status, 401);
  assert.equal((await call('GET', '/v1/homework?from=2026-11-01&to=2026-11-09')).status, 401);
  assert.equal((await call('POST', '/v1/homework', { token: child, body: { items: [] } })).status, 403);
  assert.equal((await call('POST', '/v1/devices/pairing-codes', { token: child, body: {} })).status, 403);
  const me = (await call('GET', '/v1/me', { token: child })).body;
  assert.equal(me.device.role, 'child');
  assert.equal(me.family.today, '2026-11-09');
  assert.equal(me.rules.finishTime, '19:30');
  const devices = (await call('GET', '/v1/devices', { token: parent })).body.devices;
  const childDevice = devices.find(d => d.role === 'child' && d.name === '林林的 iPad');
  assert.equal((await call('DELETE', `/v1/devices/${childDevice.id}`, { token: parent })).status, 200);
  assert.equal((await call('GET', '/v1/me', { token: child })).status, 401);
});

test('homework: batch create is idempotent, validated, and listed by date with the child device', async t => {
  const { call, parent, child, childId } = await setup(t);
  const item = { id: randomUUID(), childId, subject: 'ENGLISH', date: '2026-11-09', dueDate: '2026-11-10',
    content: 'Unit 3 单词抄写两遍', rawText: '英语U3单词抄两遍哦[抱拳]', mode: 'OFFLINE', parentTodo: '' };
  const first = await call('POST', '/v1/homework', { token: parent, body: { items: [item] } });
  assert.equal(first.status, 200);
  assert.equal(first.body.items[0].source, 'PASTE');
  assert.equal(first.body.items[0].status, 'NOT_STARTED');
  assert.equal((await call('POST', '/v1/homework', { token: parent, body: { items: [item] } })).body.items[0].id, item.id);
  for (const bad of [{ subject: 'ART' }, { mode: 'ONLINE' }, { dueDate: '2026-11-08' }, { content: ' ' }, { childId: randomUUID() }, { attachmentIds: [randomUUID()] }]) {
    const response = await call('POST', '/v1/homework', { token: parent, body: { items: [{ ...item, id: randomUUID(), ...bad }] } });
    assert.ok(response.status >= 400, JSON.stringify(bad));
  }
  const listed = (await call('GET', `/v1/homework?childId=${childId}&from=2026-11-03&to=2026-11-09`, { token: child })).body.items;
  assert.equal(listed.length, 1);
  assert.equal(listed[0].content, 'Unit 3 单词抄写两遍');
  const patched = await call('PATCH', `/v1/homework/${item.id}`, { token: parent, body: { content: 'Unit 3 单词抄写三遍', status: 'REVIEWED' } });
  assert.equal(patched.body.content, 'Unit 3 单词抄写三遍');
  assert.equal(patched.body.status, 'NOT_STARTED');
  assert.equal(patched.body.version, 2);
});

test('offline homework: photo submission, on-time reward, review, correction and grade top-up', async t => {
  const { call, parent, addHomework, submit, balance } = await setup(t);
  const hw = await addHomework();
  assert.equal((await submit(hw, { fileIds: [] })).body.error, 'photo_required');
  const submitted = await submit(hw);
  assert.equal(submitted.status, 200);
  assert.equal(submitted.body.status, 'SUBMITTED');
  assert.equal(submitted.body.submissions[0].onTime, true);
  assert.equal((await submit(hw)).status, 409);
  assert.equal((await balance()).balance, 5);

  const first = submitted.body.submissions[0];
  const reviewed = await call('POST', `/v1/submissions/${first.id}/review`, { token: parent, body: { grade: 'GOOD', comment: '第 7 题进位再看看', requireCorrection: true } });
  assert.equal(reviewed.body.status, 'NEEDS_CORRECTION');
  assert.equal(reviewed.body.submissions[0].review.grade, 'GOOD');
  assert.equal((await balance()).balance, 8);
  assert.equal((await call('POST', `/v1/submissions/${first.id}/review`, { token: parent, body: { grade: 'GOOD' } })).status, 409);

  const corrected = await submit(hw);
  assert.equal(corrected.body.submissions.length, 2);
  const second = corrected.body.submissions[1];
  await call('POST', `/v1/submissions/${second.id}/review`, { token: parent, body: { grade: 'EXCELLENT' } });
  const summary = await balance();
  assert.equal(summary.balance, 10, 'on time 5 + good 3 + top-up to excellent 2; the correction earns no second on-time reward');
  assert.deepEqual(summary.entries.map(e => e.reason).sort(), ['GRADE', 'GRADE', 'ON_TIME']);
});

test('late submissions earn no on-time reward; offline queues are judged by device time', async t => {
  const { clock, addHomework, submit, balance } = await setup(t);
  const hw = await addHomework();
  clock.ms = beijing('2026-11-09', '20:10');
  const late = await submit(hw);
  assert.equal(late.body.submissions[0].onTime, false);
  assert.equal((await balance()).balance, 0);
  const queued = await addHomework();
  const response = await submit(queued, { submittedAt: new Date(beijing('2026-11-09', '19:00')).toISOString() });
  assert.equal(response.body.submissions[0].onTime, true);
});

test('online homework: recordings need audio, timers need the full duration and complete themselves', async t => {
  const { call, upload, addHomework, submit } = await setup(t);
  const recording = await addHomework({ subject: 'CHINESE', content: '背诵《咏柳》', mode: 'ONLINE', onlineKind: 'RECORDING' });
  assert.equal((await submit(recording)).status, 400, 'a photo is not a recording');
  const ok = await submit(recording, { fileIds: [await upload(m4a, 'audio/mp4')] });
  assert.equal(ok.body.status, 'SUBMITTED');
  const timer = await addHomework({ subject: 'ENGLISH', content: '英语朗读', mode: 'ONLINE', onlineKind: 'TIMER', durationMinutes: 5 });
  assert.equal((await submit(timer, { fileIds: [], durationSeconds: 200 })).status, 409);
  const done = await submit(timer, { fileIds: [], durationSeconds: 300 });
  assert.equal(done.body.status, 'REVIEWED');
  assert.equal(done.body.submissions[0].durationSeconds, 300);
});

test('routines: at most five active, generated for today only, check-in and seven-day streak rewards', async t => {
  const { call, clock, parent, child, childId, submit, balance } = await setup(t);
  const routine = id => ({ childId, title: `朗读 5 分钟 ${id.slice(0, 4)}`, subject: 'ENGLISH', mode: 'ONLINE', onlineKind: 'TIMER', durationMinutes: 5, weekdays: [0, 1, 2, 3, 4, 5, 6] });
  const ids = Array.from({ length: 6 }, () => randomUUID());
  for (const id of ids.slice(0, 5)) assert.equal((await call('PUT', `/v1/routines/${id}`, { token: parent, body: routine(id) })).status, 200);
  assert.equal((await call('PUT', `/v1/routines/${ids[5]}`, { token: parent, body: routine(ids[5]) })).body.error, 'routine_limit');
  assert.equal((await call('PUT', `/v1/routines/${ids[5]}`, { token: parent, body: { ...routine(ids[5]), active: false } })).status, 200);
  for (const id of ids.slice(1, 5)) await call('DELETE', `/v1/routines/${id}`, { token: parent });

  let streakReward = null;
  for (let i = 0; i < 7; i++) {
    const date = new Date(Date.parse('2026-11-09T12:00:00Z') + i * 86_400_000).toISOString().slice(0, 10);
    clock.ms = beijing(date, '18:00');
    const items = (await call('GET', `/v1/homework?childId=${childId}&from=${date}&to=${date}`, { token: child })).body.items;
    assert.equal(items.length, 1, `one generated item on ${date}`);
    assert.equal(items[0].source, 'ROUTINE');
    assert.equal((await call('GET', `/v1/homework?childId=${childId}&from=${date}&to=${date}`, { token: child })).body.items.length, 1, 'generated once');
    await submit(items[0], { fileIds: [], durationSeconds: 300 });
    streakReward = (await balance()).entries.find(e => e.reason === 'STREAK7');
  }
  const summary = await balance();
  assert.equal(summary.entries.filter(e => e.reason === 'CHECKIN').length, 7);
  assert.ok(streakReward, 'seventh consecutive day earns the streak reward');
  assert.equal(summary.balance, 7 * 3 + 10);
  const future = (await call('GET', `/v1/homework?childId=${childId}&from=2026-11-16&to=2026-11-20`, { token: child })).body.items;
  assert.equal(future.length, 0, 'future days are not generated in advance');
});

test('reward sessions follow the window, pending homework, daily cap and balance rules', async t => {
  const { call, clock, parent, childId, addHomework, submit, balance } = await setup(t);
  const hw = await addHomework();
  const graded = await submit(hw);
  await call('POST', `/v1/submissions/${graded.body.submissions[0].id}/review`, { token: parent, body: { grade: 'EXCELLENT' } });
  await call('PUT', '/v1/reward-rules', { token: parent, body: { finishTime: '19:30', onTime: 5, gradeExcellent: 5, gradeGood: 3,
    gradeFair: 1, checkin: 3, streak7: 10, dailyCap: 8, windowStart: '19:00', windowEnd: '20:30', requireAllSubmitted: true } });
  const spend = minutes => call('POST', '/v1/rewards/sessions', { token: parent, body: { id: randomUUID(), childId, minutes } });
  assert.equal((await spend(5)).body.error, 'outside_window');
  clock.ms = beijing('2026-11-09', '19:10');
  const pending = await addHomework({ content: '语文生字' });
  assert.equal((await spend(5)).body.error, 'homework_pending');
  await call('DELETE', `/v1/homework/${pending.id}`, { token: parent });
  const id = randomUUID();
  const started = await call('POST', '/v1/rewards/sessions', { token: parent, body: { id, childId, minutes: 5 } });
  assert.equal(started.status, 200);
  assert.equal(started.body.endsAt, new Date(clock.ms + 5 * 60_000).toISOString());
  assert.equal((await call('POST', '/v1/rewards/sessions', { token: parent, body: { id, childId, minutes: 5 } })).body.minutes, 5, 'retry is idempotent');
  assert.equal((await spend(4)).body.error, 'daily_cap');
  assert.equal((await spend(3)).status, 200);
  const summary = await balance();
  assert.equal(summary.balance, 2);
  assert.equal(summary.usedToday, 8);
});

test('files: type checks, downloads, and deletion with their homework', async t => {
  const { call, child, parent, upload, addHomework, submit, dataDir } = await setup(t);
  const bad = await call('PUT', `/v1/files/${randomUUID()}`, { token: child, raw: Buffer.from('not a jpeg'), type: 'image/jpeg' });
  assert.equal(bad.status, 400);
  assert.equal((await call('PUT', `/v1/files/${randomUUID()}`, { token: child, raw: jpeg, type: 'text/html' })).status, 415);
  const attachment = await upload(jpeg, 'image/jpeg', parent);
  const downloaded = await call('GET', `/v1/files/${attachment}`, { token: child });
  assert.deepEqual(downloaded.body, jpeg);
  const hw = await addHomework({ attachmentIds: [attachment] });
  const submitted = await submit(hw);
  const familyDir = (await call('GET', '/v1/me', { token: parent })).body.family.id;
  const photo = submitted.body.submissions[0].fileIds[0];
  assert.ok(existsSync(join(dataDir, 'files', familyDir, photo)));
  await call('DELETE', `/v1/homework/${hw.id}`, { token: parent });
  assert.equal((await call('GET', `/v1/files/${attachment}`, { token: child })).status, 404);
  assert.ok(!existsSync(join(dataDir, 'files', familyDir, photo)));
});

test('change feed lists what to re-fetch, in order', async t => {
  const { call, child, addHomework, submit } = await setup(t);
  const start = (await call('GET', '/v1/me', { token: child })).body.cursor;
  assert.equal(start, (await call('GET', '/v1/changes?since=0', { token: child })).body.next, 'me.cursor is the latest change');
  const hw = await addHomework();
  await submit(hw);
  const feed = (await call('GET', `/v1/changes?since=${start}`, { token: child })).body;
  assert.deepEqual(feed.changes.map(c => `${c.entity}:${c.op}`), ['homework:UPSERT', 'homework:UPSERT', 'reward:UPSERT']);
  assert.ok(feed.changes.every(c => c.seq > start));
  assert.deepEqual((await call('GET', `/v1/changes?since=${feed.next}`, { token: child })).body.changes, []);
});

test('deleting a child removes their homework, routines and rewards', async t => {
  const { call, parent, childId, addHomework, submit, balance } = await setup(t);
  await submit(await addHomework());
  assert.equal((await balance()).balance, 5);
  assert.equal((await call('DELETE', `/v1/children/${childId}`, { token: parent })).status, 200);
  assert.equal((await call('GET', `/v1/rewards?childId=${childId}`, { token: parent })).status, 404);
  assert.deepEqual((await call('GET', '/v1/homework?from=2026-11-01&to=2026-11-30', { token: parent })).body.items, []);
});

test('AI parse: sends the pasted text, returns cleaned items, never stores them', async t => {
  let sent;
  const reply = { items: [
    { subject: 'MATH', content: '口算本第 12 页，第 1–20 题，竖式写在本子上。', due_text: '明早交', due_date: '2026-11-10', mode: 'OFFLINE', parent_todo: '' },
    { subject: 'CHINESE', content: '背诵《咏柳》。', due_text: '', due_date: '', mode: 'ONLINE', parent_todo: '检查背诵后签字' }
  ], message: '拆成了 2 项' };
  const fetchImpl = async (url, options) => { sent = JSON.parse(options.body); return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(reply) } }] })); };
  const { call, parent, child } = await setup(t, { model: { apiUrl: 'https://model.example/v1/chat/completions', apiKey: 'k', model: 'm', jsonMode: true }, fetchImpl });
  const text = '各位家长好！1、数学口算本第12页1-20题，明早交哈～ 2、语文背诵《咏柳》，家长签字[强]';
  assert.equal((await call('POST', '/v1/homework/parse', { token: child, body: { text } })).status, 403);
  const parsed = await call('POST', '/v1/homework/parse', { token: parent, body: { text, date: '2026-11-09' } });
  assert.equal(parsed.status, 200);
  assert.equal(parsed.body.items.length, 2);
  assert.equal(parsed.body.items[0].dueDate, '2026-11-10');
  assert.equal(parsed.body.items[1].parentTodo, '检查背诵后签字');
  assert.equal(JSON.parse(sent.messages[1].content).text, text);
  assert.equal(JSON.parse(sent.messages[1].content).weekday, '星期一');
  assert.deepEqual((await call('GET', '/v1/homework?from=2026-11-01&to=2026-11-30', { token: parent })).body.items, []);
});

test('AI parse: model missing is explicit and malformed replies are rejected', async t => {
  const { call, parent } = await setup(t);
  assert.equal((await call('POST', '/v1/homework/parse', { token: parent, body: { text: '作业' } })).body.error, 'model_not_configured');
  const input = { date: '2026-11-09' };
  assert.throws(() => validateParseReply(JSON.stringify({ items: [{ subject: 'ART', content: 'x', mode: 'OFFLINE' }] }), input));
  assert.throws(() => validateParseReply(JSON.stringify({ items: [{ subject: 'MATH', content: '', mode: 'OFFLINE' }] }), input));
  const kept = validateParseReply('```json\n' + JSON.stringify({ items: [{ subject: 'OTHER', content: '科学：观察月亮', mode: 'OFFLINE', due_date: '2026-11-01' }] }) + '\n```', input);
  assert.equal(kept.items[0].dueDate, null, 'a due date before the assigned date is dropped');
  assert.equal(kept.items[0].parentTodo, '');
});
