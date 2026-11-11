import { createHash, randomBytes, randomInt, randomUUID, timingSafeEqual } from 'node:crypto';
import { createReadStream, mkdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { openDatabase, transaction } from './db.mjs';
import { homeworkSubjects, parseBody, validateParseReply } from './parse.mjs';

/**
 * Phase-1 homework API: families, devices, homework, routines, submissions, reviews, rewards, files and a change feed.
 * The server is the single source of truth; the parent iPhone and the child iPad sync through it.
 */

class ApiError extends Error { constructor(status, code) { super(code); this.status = status; } }
const fail = (status, code) => { throw new ApiError(status, code); };

// ---------- validation ----------
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uuid = value => (typeof value === 'string' && uuidPattern.test(value) ? value.toLowerCase() : fail(400, 'invalid_id'));
function text(value, max, required = false) {
  if (value == null) value = '';
  if (typeof value !== 'string' || value.length > max) fail(400, 'invalid_input');
  const trimmed = value.trim();
  if (required && !trimmed) fail(400, 'invalid_input');
  return trimmed;
}
const oneOf = (value, list) => (list.includes(value) ? value : fail(400, 'invalid_input'));
const integer = (value, min, max) => (Number.isInteger(value) && value >= min && value <= max ? value : fail(400, 'invalid_input'));
const optionalInteger = (value, min, max) => (value == null ? null : integer(value, min, max));
const bool = value => (typeof value === 'boolean' ? value : fail(400, 'invalid_input'));
function day(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) fail(400, 'invalid_date');
  if (new Date(`${value}T12:00:00Z`).toISOString().slice(0, 10) !== value) fail(400, 'invalid_date');
  return value;
}
const clock = value => (typeof value === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(value) ? value : fail(400, 'invalid_time'));
const uuidList = (value, max) => (Array.isArray(value) && value.length <= max ? [...new Set(value.map(uuid))] : fail(400, 'invalid_input'));

// ---------- dates in the family's time zone ----------
export function localParts(ms, timeZone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(ms)).map(p => [p.type, p.value]));
  return { date: `${parts.year}-${parts.month}-${parts.day}`, time: `${parts.hour}:${parts.minute}` };
}
const weekdayOf = date => new Date(`${date}T12:00:00Z`).getUTCDay();
const addDays = (date, n) => new Date(Date.parse(`${date}T12:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);

// ---------- rewards ----------
export const defaultRules = Object.freeze({ finishTime: '19:30', onTime: 5, gradeExcellent: 5, gradeGood: 3, gradeFair: 1,
  checkin: 3, streak7: 10, dailyCap: 30, windowStart: '19:00', windowEnd: '20:30', requireAllSubmitted: true });
function validateRules(input) {
  if (!input || typeof input !== 'object') fail(400, 'invalid_input');
  const rules = {};
  for (const key of ['onTime', 'gradeExcellent', 'gradeGood', 'gradeFair', 'checkin', 'streak7']) rules[key] = integer(input[key], 0, 120);
  rules.dailyCap = integer(input.dailyCap, 0, 240);
  for (const key of ['finishTime', 'windowStart', 'windowEnd']) rules[key] = clock(input[key]);
  if (rules.windowStart >= rules.windowEnd) fail(400, 'invalid_window');
  rules.requireAllSubmitted = bool(input.requireAllSubmitted);
  return rules;
}
const gradePoints = (rules, grade) => ({ EXCELLENT: rules.gradeExcellent, GOOD: rules.gradeGood, FAIR: rules.gradeFair, TRY_AGAIN: 0 })[grade];

// ---------- files ----------
const fileKinds = {
  'image/jpeg': { kind: 'IMAGE', max: 2_000_000, check: b => b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff },
  'image/png': { kind: 'PNG', max: 4_000_000, check: b => b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) },
  'audio/mp4': { kind: 'AUDIO', max: 10_000_000, check: b => b.subarray(4, 8).toString('latin1') === 'ftyp' },
  'application/octet-stream': { kind: 'DATA', max: 1_000_000, check: () => true }
};

const hash = value => createHash('sha256').update(value).digest('hex');
const json = value => JSON.stringify(value);
const list = value => JSON.parse(value || '[]');

async function readBody(req, max) {
  if (Number(req.headers?.['content-length']) > max) fail(413, 'body_too_large');
  const chunks = []; let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > max) fail(413, 'body_too_large');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export function createApi({ dataDir, bootstrapToken = '', model = {}, fetchImpl = fetch, now = Date.now }) {
  if (bootstrapToken && (bootstrapToken.length < 24 || /\s/.test(bootstrapToken))) throw new Error('PARENT_BOOTSTRAP_TOKEN must contain at least 24 non-space characters');
  mkdirSync(join(dataDir, 'files'), { recursive: true });
  const db = openDatabase(join(dataDir, 'littlebear.db'));
  const q = sql => db.prepare(sql);
  const iso = () => new Date(now()).toISOString();
  const deviceRequests = new Map();
  let anonymousAttempts = [];

  // ---------- helpers bound to the database ----------
  const record = (familyId, entity, id, op = 'UPSERT') =>
    q('INSERT INTO changes (family_id, entity, entity_id, op, at) VALUES (?, ?, ?, ?, ?)').run(familyId, entity, id, op, iso());
  const family = familyId => q('SELECT * FROM families WHERE id = ?').get(familyId);
  const rulesFor = familyId => ({ ...defaultRules, ...JSON.parse(q('SELECT rules FROM reward_rules WHERE family_id = ?').get(familyId)?.rules ?? '{}') });
  const today = familyId => localParts(now(), family(familyId).timezone);
  const childIn = (familyId, childId) => q('SELECT * FROM children WHERE id = ? AND family_id = ?').get(uuid(childId), familyId) ?? fail(404, 'child_not_found');
  const homeworkIn = (familyId, id) => q('SELECT * FROM homework WHERE id = ? AND family_id = ?').get(uuid(id), familyId) ?? fail(404, 'homework_not_found');
  function filesIn(familyId, ids, kinds) {
    for (const id of ids) {
      const row = q('SELECT kind FROM files WHERE id = ? AND family_id = ?').get(id, familyId);
      if (!row) fail(400, 'file_not_found');
      if (!kinds.includes(row.kind)) fail(400, 'invalid_file_kind');
    }
    return ids;
  }
  function deleteFiles(familyId, ids) {
    for (const id of ids) {
      q('DELETE FROM files WHERE id = ? AND family_id = ?').run(id, familyId);
      rmSync(join(dataDir, 'files', familyId, id), { force: true });
    }
  }
  function credit(familyId, childId, minutes, reason, refId) {
    if (minutes <= 0) return;
    const result = q(`INSERT OR IGNORE INTO reward_ledger (id, family_id, child_id, minutes, reason, ref_id, local_date, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run(randomUUID(), familyId, childId, minutes, reason, refId, today(familyId).date, iso());
    if (result.changes) record(familyId, 'reward', childId);
  }

  function serializeChild(row) { return { id: row.id, name: row.name, grade: row.grade, avatar: row.avatar, updatedAt: row.updated_at, version: row.version }; }
  function serializeRoutine(row) {
    return { id: row.id, childId: row.child_id, title: row.title, subject: row.subject, mode: row.mode, onlineKind: row.online_kind,
      durationMinutes: row.duration_minutes, quantity: row.quantity, weekdays: list(row.weekdays), active: !!row.active,
      sortOrder: row.sort_order, updatedAt: row.updated_at, version: row.version };
  }
  function serializeHomework(row) {
    const submissions = q('SELECT * FROM submissions WHERE homework_id = ? ORDER BY attempt').all(row.id).map(s => {
      const review = q('SELECT * FROM reviews WHERE submission_id = ?').get(s.id);
      return { id: s.id, attempt: s.attempt, fileIds: list(s.file_ids), durationSeconds: s.duration_seconds, submittedAt: s.submitted_at,
        receivedAt: s.received_at, onTime: !!s.on_time,
        review: review ? { id: review.id, grade: review.grade, comment: review.comment, requireCorrection: !!review.require_correction,
          annotationFileIds: list(review.annotation_file_ids), reviewedAt: review.reviewed_at } : null };
    });
    return { id: row.id, childId: row.child_id, subject: row.subject, date: row.date, dueDate: row.due_date, content: row.content,
      rawText: row.raw_text, mode: row.mode, onlineKind: row.online_kind, durationMinutes: row.duration_minutes,
      parentTodo: row.parent_todo, status: row.status, source: row.source, routineId: row.routine_id,
      attachmentIds: list(row.attachment_ids), createdAt: row.created_at, updatedAt: row.updated_at, version: row.version, submissions };
  }

  /** Creates today's homework for each active routine scheduled today. Past and future days are never generated. */
  function materializeRoutines(familyId) {
    const { date } = today(familyId);
    const weekday = weekdayOf(date);
    for (const routine of q('SELECT * FROM routines WHERE family_id = ? AND active = 1').all(familyId)) {
      if (!list(routine.weekdays).includes(weekday)) continue;
      const id = randomUUID();
      const inserted = q(`INSERT OR IGNORE INTO homework (id, family_id, child_id, subject, date, content, mode, online_kind,
        duration_minutes, status, source, routine_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'NOT_STARTED', 'ROUTINE', ?, ?, ?)`)
        .run(id, familyId, routine.child_id, routine.subject, date, routine.title, routine.mode, routine.online_kind,
          routine.duration_minutes, routine.id, iso(), iso());
      if (inserted.changes) record(familyId, 'homework', id);
    }
  }

  /** Consecutive scheduled days, ending on `date`, on which this routine's homework was submitted. */
  function streak(routine, date) {
    const weekdays = list(routine.weekdays);
    let count = 0;
    for (let d = date, i = 0; i < 400; i++, d = addDays(d, -1)) {
      if (!weekdays.includes(weekdayOf(d))) continue;
      const done = q(`SELECT 1 FROM homework h JOIN submissions s ON s.homework_id = h.id WHERE h.routine_id = ? AND h.date = ? LIMIT 1`).get(routine.id, d);
      if (!done) break;
      count++;
    }
    return count;
  }

  function issueDevice(familyId, deviceId, role, name) {
    const token = randomBytes(32).toString('hex');
    const existing = q('SELECT family_id FROM devices WHERE id = ?').get(deviceId);
    if (existing && existing.family_id !== familyId) fail(409, 'device_conflict');
    if (existing) q('UPDATE devices SET token_hash = ?, role = ?, name = ?, revoked_at = NULL WHERE id = ?').run(hash(token), role, name, deviceId);
    else q('INSERT INTO devices (id, family_id, role, name, token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)').run(deviceId, familyId, role, name, hash(token), iso());
    return { deviceId, deviceToken: token, role, familyId };
  }

  function limitAnonymous() {
    anonymousAttempts = anonymousAttempts.filter(t => now() - t < 60_000);
    if (anonymousAttempts.length >= 10) fail(429, 'rate_limited');
    anonymousAttempts.push(now());
  }

  // ---------- routes ----------
  const routes = [];
  const route = (method, path, roles, handler) => {
    const keys = [];
    const pattern = new RegExp(`^${path.replace(/:(\w+)/g, (_, key) => { keys.push(key); return '([^/]+)'; })}$`);
    routes.push({ method, pattern, keys, roles, handler });
  };
  const PARENT = ['parent'], ANY = ['parent', 'child'];

  route('POST', '/v1/devices/bootstrap', null, ({ body }) => {
    if (!bootstrapToken) fail(503, 'api_not_configured');
    limitAnonymous();
    const received = Buffer.from(typeof body.token === 'string' ? body.token : '');
    const expected = Buffer.from(bootstrapToken);
    if (received.length !== expected.length || !timingSafeEqual(received, expected)) fail(401, 'unauthorized');
    const deviceId = uuid(body.deviceId), name = text(body.name, 60);
    return transaction(db, () => {
      let familyRow = q('SELECT * FROM families ORDER BY created_at LIMIT 1').get();
      if (!familyRow) {
        const id = randomUUID();
        q('INSERT INTO families (id, created_at) VALUES (?, ?)').run(id, iso());
        q('INSERT INTO reward_rules (family_id, rules) VALUES (?, ?)').run(id, json(defaultRules));
        familyRow = family(id);
      }
      return issueDevice(familyRow.id, deviceId, 'parent', name);
    });
  });

  route('POST', '/v1/devices/pairing-codes', PARENT, ({ familyId }) => {
    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    const expiresAt = now() + 10 * 60_000;
    q('INSERT OR REPLACE INTO pairing_codes (code_hash, family_id, expires_at) VALUES (?, ?, ?)').run(hash(code), familyId, expiresAt);
    return { code, expiresAt: new Date(expiresAt).toISOString() };
  });

  route('POST', '/v1/devices/pair', null, ({ body }) => {
    limitAnonymous();
    const code = typeof body.code === 'string' && /^\d{6}$/.test(body.code) ? body.code : fail(400, 'invalid_code');
    const deviceId = uuid(body.deviceId), name = text(body.name, 60);
    return transaction(db, () => {
      const row = q('SELECT * FROM pairing_codes WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?').get(hash(code), now());
      if (!row) fail(401, 'invalid_code');
      q('UPDATE pairing_codes SET used_at = ? WHERE code_hash = ?').run(iso(), row.code_hash);
      return issueDevice(row.family_id, deviceId, 'child', name);
    });
  });

  route('GET', '/v1/devices', PARENT, ({ familyId, device }) => ({
    devices: q('SELECT * FROM devices WHERE family_id = ? AND revoked_at IS NULL ORDER BY created_at').all(familyId)
      .map(d => ({ id: d.id, role: d.role, name: d.name, createdAt: d.created_at, lastSeenAt: d.last_seen_at, self: d.id === device.id }))
  }));

  route('DELETE', '/v1/devices/:id', PARENT, ({ familyId, params }) => {
    const result = q('UPDATE devices SET revoked_at = ? WHERE id = ? AND family_id = ? AND revoked_at IS NULL').run(iso(), uuid(params.id), familyId);
    if (!result.changes) fail(404, 'device_not_found');
    return { ok: true };
  });

  route('PUT', '/v1/devices/self/push-token', ANY, ({ device, body }) => {
    const token = text(body.pushToken, 200);
    q('UPDATE devices SET push_token = ? WHERE id = ?').run(token || null, device.id);
    return { ok: true };
  });

  route('GET', '/v1/me', ANY, ({ familyId, device }) => {
    const f = family(familyId);
    // `cursor` is the latest change seq: a client doing a full refresh starts its change feed here.
    const cursor = q('SELECT COALESCE(MAX(seq), 0) AS n FROM changes WHERE family_id = ?').get(familyId).n;
    return { cursor, device: { id: device.id, role: device.role, name: device.name },
      family: { id: f.id, name: f.name, timezone: f.timezone, today: today(familyId).date },
      children: q('SELECT * FROM children WHERE family_id = ? ORDER BY created_at').all(familyId).map(serializeChild),
      rules: rulesFor(familyId) };
  });

  route('GET', '/v1/children', ANY, ({ familyId }) => ({
    children: q('SELECT * FROM children WHERE family_id = ? ORDER BY created_at').all(familyId).map(serializeChild)
  }));

  route('PUT', '/v1/children/:id', PARENT, ({ familyId, params, body }) => {
    const id = uuid(params.id), name = text(body.name, 20, true), grade = integer(body.grade, 1, 6), avatar = text(body.avatar, 20);
    return transaction(db, () => {
      const existing = q('SELECT family_id FROM children WHERE id = ?').get(id);
      if (existing && existing.family_id !== familyId) fail(404, 'child_not_found');
      if (existing) q('UPDATE children SET name = ?, grade = ?, avatar = ?, updated_at = ?, version = version + 1 WHERE id = ?').run(name, grade, avatar, iso(), id);
      else q('INSERT INTO children (id, family_id, name, grade, avatar, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)').run(id, familyId, name, grade, avatar, iso(), iso());
      record(familyId, 'child', id);
      return serializeChild(q('SELECT * FROM children WHERE id = ?').get(id));
    });
  });

  function deleteHomeworkRows(familyId, hw) {
    const files = list(hw.attachment_ids);
    for (const s of q('SELECT * FROM submissions WHERE homework_id = ?').all(hw.id)) {
      files.push(...list(s.file_ids));
      const review = q('SELECT annotation_file_ids FROM reviews WHERE submission_id = ?').get(s.id);
      if (review) files.push(...list(review.annotation_file_ids));
    }
    q('DELETE FROM reviews WHERE homework_id = ?').run(hw.id);
    q('DELETE FROM submissions WHERE homework_id = ?').run(hw.id);
    q('DELETE FROM homework WHERE id = ?').run(hw.id);
    deleteFiles(familyId, files);
    record(familyId, 'homework', hw.id, 'DELETE');
  }

  route('DELETE', '/v1/children/:id', PARENT, ({ familyId, params }) => transaction(db, () => {
    const child = childIn(familyId, params.id);
    for (const hw of q('SELECT * FROM homework WHERE child_id = ?').all(child.id)) deleteHomeworkRows(familyId, hw);
    for (const r of q('SELECT id FROM routines WHERE child_id = ?').all(child.id)) record(familyId, 'routine', r.id, 'DELETE');
    q('DELETE FROM routines WHERE child_id = ?').run(child.id);
    q('DELETE FROM reward_ledger WHERE child_id = ?').run(child.id);
    q('DELETE FROM children WHERE id = ?').run(child.id);
    record(familyId, 'child', child.id, 'DELETE');
    return { ok: true };
  }));

  route('POST', '/v1/homework/parse', PARENT, async ({ body, familyId, signal }) => {
    const input = { text: text(body.text, 5000, true), date: body.date == null ? today(familyId).date : day(body.date) };
    if (!model.apiUrl || !model.apiKey || !model.model) fail(503, 'model_not_configured');
    // Some vendors (e.g. DeepSeek JSON mode) occasionally return whitespace-only content; retry that once.
    for (let attempt = 0; ; attempt++) {
      const upstream = await fetchImpl(model.apiUrl, { method: 'POST', redirect: 'error', signal: AbortSignal.any([signal, AbortSignal.timeout(55_000)]),
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${model.apiKey}` }, body: json(parseBody(input, model)) });
      if (!upstream.ok) fail(502, 'model_unavailable');
      const data = JSON.parse((await readBody(upstream.body, 65_536)).toString('utf8'));
      const content = data.choices?.[0]?.message?.content;
      if (attempt === 0 && typeof content === 'string' && !content.trim()) continue;
      try { return validateParseReply(content, input); } catch { fail(502, 'invalid_model_reply'); }
    }
  });

  function homeworkFields(familyId, input, base = {}) {
    const merged = { ...base, ...input };
    const mode = oneOf(merged.mode, ['OFFLINE', 'ONLINE']);
    const date = day(merged.date);
    const dueDate = merged.dueDate == null ? null : day(merged.dueDate);
    if (dueDate && dueDate < date) fail(400, 'invalid_due_date');
    return {
      subject: oneOf(merged.subject, homeworkSubjects), date, dueDate, content: text(merged.content, 2000, true),
      mode, onlineKind: mode === 'ONLINE' ? oneOf(merged.onlineKind, ['TIMER', 'RECORDING']) : null,
      durationMinutes: optionalInteger(merged.durationMinutes, 1, 120), parentTodo: text(merged.parentTodo, 500),
      attachmentIds: filesIn(familyId, uuidList(merged.attachmentIds ?? [], 9), ['IMAGE'])
    };
  }

  route('POST', '/v1/homework', PARENT, ({ familyId, body }) => {
    if (!Array.isArray(body.items) || body.items.length === 0 || body.items.length > 20) fail(400, 'invalid_input');
    return transaction(db, () => ({ items: body.items.map(item => {
      const id = uuid(item.id);
      const existing = q('SELECT * FROM homework WHERE id = ?').get(id);
      if (existing) return existing.family_id === familyId ? serializeHomework(existing) : fail(409, 'id_conflict');
      const child = childIn(familyId, item.childId);
      const f = homeworkFields(familyId, item);
      const rawText = text(item.rawText, 5000);
      q(`INSERT INTO homework (id, family_id, child_id, subject, date, due_date, content, raw_text, mode, online_kind, duration_minutes,
        parent_todo, status, source, attachment_ids, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'NOT_STARTED', ?, ?, ?, ?)`)
        .run(id, familyId, child.id, f.subject, f.date, f.dueDate, f.content, rawText, f.mode, f.onlineKind, f.durationMinutes,
          f.parentTodo, rawText ? 'PASTE' : 'MANUAL', json(f.attachmentIds), iso(), iso());
      record(familyId, 'homework', id);
      return serializeHomework(q('SELECT * FROM homework WHERE id = ?').get(id));
    }) }));
  });

  route('PATCH', '/v1/homework/:id', PARENT, ({ familyId, params, body }) => transaction(db, () => {
    const hw = homeworkIn(familyId, params.id);
    const base = { subject: hw.subject, date: hw.date, dueDate: hw.due_date, content: hw.content, mode: hw.mode, onlineKind: hw.online_kind,
      durationMinutes: hw.duration_minutes, parentTodo: hw.parent_todo, attachmentIds: list(hw.attachment_ids) };
    const allowed = Object.fromEntries(Object.entries(body).filter(([key]) => key in base));
    const f = homeworkFields(familyId, allowed, base);
    q(`UPDATE homework SET subject = ?, date = ?, due_date = ?, content = ?, mode = ?, online_kind = ?, duration_minutes = ?, parent_todo = ?,
      attachment_ids = ?, updated_at = ?, version = version + 1 WHERE id = ?`).run(f.subject, f.date, f.dueDate, f.content, f.mode,
      f.onlineKind, f.durationMinutes, f.parentTodo, json(f.attachmentIds), iso(), hw.id);
    deleteFiles(familyId, list(hw.attachment_ids).filter(id => !f.attachmentIds.includes(id)));
    record(familyId, 'homework', hw.id);
    return serializeHomework(q('SELECT * FROM homework WHERE id = ?').get(hw.id));
  }));

  route('DELETE', '/v1/homework/:id', PARENT, ({ familyId, params }) => transaction(db, () => {
    deleteHomeworkRows(familyId, homeworkIn(familyId, params.id));
    return { ok: true };
  }));

  route('GET', '/v1/homework', ANY, ({ familyId, query }) => {
    const from = day(query.get('from')), to = day(query.get('to'));
    if (to < from || to > addDays(from, 62)) fail(400, 'invalid_range');
    const childId = query.get('childId');
    const { date } = today(familyId);
    if (from <= date && date <= to) transaction(db, () => materializeRoutines(familyId));
    const rows = childId
      ? q('SELECT * FROM homework WHERE family_id = ? AND child_id = ? AND date BETWEEN ? AND ? ORDER BY date DESC, created_at').all(familyId, uuid(childId), from, to)
      : q('SELECT * FROM homework WHERE family_id = ? AND date BETWEEN ? AND ? ORDER BY date DESC, created_at').all(familyId, from, to);
    return { items: rows.map(serializeHomework) };
  });

  route('GET', '/v1/homework/:id', ANY, ({ familyId, params }) => serializeHomework(homeworkIn(familyId, params.id)));

  route('GET', '/v1/routines', ANY, ({ familyId, query }) => {
    const childId = query.get('childId');
    const rows = childId
      ? q('SELECT * FROM routines WHERE family_id = ? AND child_id = ? ORDER BY sort_order, created_at').all(familyId, uuid(childId))
      : q('SELECT * FROM routines WHERE family_id = ? ORDER BY sort_order, created_at').all(familyId);
    return { routines: rows.map(serializeRoutine) };
  });

  route('PUT', '/v1/routines/:id', PARENT, ({ familyId, params, body }) => transaction(db, () => {
    const id = uuid(params.id);
    const existing = q('SELECT * FROM routines WHERE id = ?').get(id);
    if (existing && existing.family_id !== familyId) fail(404, 'routine_not_found');
    const child = childIn(familyId, body.childId);
    if (existing && existing.child_id !== child.id) fail(400, 'invalid_input');
    const mode = oneOf(body.mode, ['OFFLINE', 'ONLINE']);
    const weekdays = Array.isArray(body.weekdays) && body.weekdays.length ? [...new Set(body.weekdays.map(d => integer(d, 0, 6)))].sort() : fail(400, 'invalid_input');
    const r = { title: text(body.title, 40, true), subject: oneOf(body.subject, homeworkSubjects), mode,
      onlineKind: mode === 'ONLINE' ? oneOf(body.onlineKind, ['TIMER', 'RECORDING']) : null,
      durationMinutes: optionalInteger(body.durationMinutes, 1, 120), quantity: optionalInteger(body.quantity, 1, 200),
      active: body.active == null ? true : bool(body.active), sortOrder: body.sortOrder == null ? 0 : integer(body.sortOrder, 0, 1000) };
    if (r.active) {
      const others = q('SELECT COUNT(*) AS n FROM routines WHERE child_id = ? AND active = 1 AND id != ?').get(child.id, id).n;
      if (others >= 5) fail(409, 'routine_limit');
    }
    if (existing) {
      q(`UPDATE routines SET title = ?, subject = ?, mode = ?, online_kind = ?, duration_minutes = ?, quantity = ?, weekdays = ?, active = ?,
        sort_order = ?, updated_at = ?, version = version + 1 WHERE id = ?`).run(r.title, r.subject, r.mode, r.onlineKind, r.durationMinutes,
        r.quantity, json(weekdays), r.active ? 1 : 0, r.sortOrder, iso(), id);
    } else {
      q(`INSERT INTO routines (id, family_id, child_id, title, subject, mode, online_kind, duration_minutes, quantity, weekdays, active,
        sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(id, familyId, child.id, r.title, r.subject,
        r.mode, r.onlineKind, r.durationMinutes, r.quantity, json(weekdays), r.active ? 1 : 0, r.sortOrder, iso(), iso());
    }
    record(familyId, 'routine', id);
    return serializeRoutine(q('SELECT * FROM routines WHERE id = ?').get(id));
  }));

  route('DELETE', '/v1/routines/:id', PARENT, ({ familyId, params }) => transaction(db, () => {
    const routine = q('SELECT * FROM routines WHERE id = ? AND family_id = ?').get(uuid(params.id), familyId) ?? fail(404, 'routine_not_found');
    // Past check-ins stay as history; today's untouched item goes away with the routine.
    for (const hw of q("SELECT * FROM homework WHERE routine_id = ? AND date = ? AND status = 'NOT_STARTED'").all(routine.id, today(familyId).date)) deleteHomeworkRows(familyId, hw);
    q('DELETE FROM routines WHERE id = ?').run(routine.id);
    record(familyId, 'routine', routine.id, 'DELETE');
    return { ok: true };
  }));

  route('POST', '/v1/homework/:id/submissions', ANY, ({ familyId, params, body }) => transaction(db, () => {
    const hw = homeworkIn(familyId, params.id);
    const id = uuid(body.id);
    const existing = q('SELECT * FROM submissions WHERE id = ?').get(id);
    if (existing) return existing.homework_id === hw.id ? serializeHomework(hw) : fail(409, 'id_conflict');
    if (!['NOT_STARTED', 'NEEDS_CORRECTION'].includes(hw.status)) fail(409, 'not_submittable');
    const fileIds = uuidList(body.fileIds ?? [], 6);
    const durationSeconds = optionalInteger(body.durationSeconds, 0, 6 * 3600);
    if (hw.mode === 'OFFLINE') {
      if (!fileIds.length) fail(400, 'photo_required');
      filesIn(familyId, fileIds, ['IMAGE']);
    }
    if (hw.online_kind === 'RECORDING') {
      if (fileIds.length !== 1) fail(400, 'recording_required');
      filesIn(familyId, fileIds, ['AUDIO']);
    }
    if (hw.online_kind === 'TIMER') {
      if (fileIds.length) fail(400, 'invalid_input');
      if (hw.duration_minutes && (durationSeconds ?? 0) < hw.duration_minutes * 60) fail(409, 'duration_not_met');
    }
    // Device time is trusted (one family), so a submission queued offline is judged by when it was made, never in the future.
    const claimed = Date.parse(typeof body.submittedAt === 'string' ? body.submittedAt : '');
    const submittedMs = Number.isFinite(claimed) ? Math.min(claimed, now()) : now();
    const f = family(familyId), rules = rulesFor(familyId);
    const local = localParts(submittedMs, f.timezone);
    const onTime = local.date < hw.date || (local.date === hw.date && local.time <= rules.finishTime);
    const attempt = (q('SELECT MAX(attempt) AS n FROM submissions WHERE homework_id = ?').get(hw.id).n ?? 0) + 1;
    q(`INSERT INTO submissions (id, family_id, homework_id, attempt, file_ids, duration_seconds, submitted_at, received_at, on_time)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(id, familyId, hw.id, attempt, json(fileIds), durationSeconds,
      new Date(submittedMs).toISOString(), iso(), onTime ? 1 : 0);
    // A timer has nothing for a parent to look at, so it completes on submission.
    const status = hw.online_kind === 'TIMER' ? 'REVIEWED' : 'SUBMITTED';
    q('UPDATE homework SET status = ?, updated_at = ?, version = version + 1 WHERE id = ?').run(status, iso(), hw.id);
    record(familyId, 'homework', hw.id);
    if (attempt === 1 && hw.source === 'ROUTINE') {
      credit(familyId, hw.child_id, rules.checkin, 'CHECKIN', hw.id);
      const routine = q('SELECT * FROM routines WHERE id = ?').get(hw.routine_id);
      const days = routine ? streak(routine, hw.date) : 0;
      if (days > 0 && days % 7 === 0) credit(familyId, hw.child_id, rules.streak7, 'STREAK7', `${routine.id}:${hw.date}`);
    } else if (attempt === 1 && onTime) {
      credit(familyId, hw.child_id, rules.onTime, 'ON_TIME', hw.id);
    }
    return serializeHomework(q('SELECT * FROM homework WHERE id = ?').get(hw.id));
  }));

  route('POST', '/v1/submissions/:id/review', PARENT, ({ familyId, params, body }) => transaction(db, () => {
    const submission = q('SELECT * FROM submissions WHERE id = ? AND family_id = ?').get(uuid(params.id), familyId) ?? fail(404, 'submission_not_found');
    const hw = homeworkIn(familyId, submission.homework_id);
    const latest = q('SELECT MAX(attempt) AS n FROM submissions WHERE homework_id = ?').get(hw.id).n;
    if (submission.attempt !== latest) fail(409, 'not_latest_submission');
    if (hw.status !== 'SUBMITTED' || q('SELECT 1 FROM reviews WHERE submission_id = ?').get(submission.id)) fail(409, 'already_reviewed');
    const grade = oneOf(body.grade, ['EXCELLENT', 'GOOD', 'FAIR', 'TRY_AGAIN']);
    const requireCorrection = body.requireCorrection == null ? false : bool(body.requireCorrection);
    const annotations = filesIn(familyId, uuidList(body.annotationFileIds ?? [], 12), ['PNG', 'DATA']);
    q(`INSERT INTO reviews (id, family_id, submission_id, homework_id, grade, comment, require_correction, annotation_file_ids, reviewed_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(randomUUID(), familyId, submission.id, hw.id, grade, text(body.comment, 500),
      requireCorrection ? 1 : 0, json(annotations), iso());
    q('UPDATE homework SET status = ?, updated_at = ?, version = version + 1 WHERE id = ?').run(requireCorrection ? 'NEEDS_CORRECTION' : 'REVIEWED', iso(), hw.id);
    record(familyId, 'homework', hw.id);
    // Grade rewards never go down; a better grade after a correction tops up the difference.
    const earned = q("SELECT COALESCE(SUM(minutes), 0) AS n FROM reward_ledger WHERE reason = 'GRADE' AND ref_id LIKE ? AND family_id = ?").get(`${hw.id}:%`, familyId).n;
    credit(familyId, hw.child_id, gradePoints(rulesFor(familyId), grade) - earned, 'GRADE', `${hw.id}:${submission.attempt}`);
    return serializeHomework(q('SELECT * FROM homework WHERE id = ?').get(hw.id));
  }));

  route('GET', '/v1/reward-rules', ANY, ({ familyId }) => rulesFor(familyId));
  route('PUT', '/v1/reward-rules', PARENT, ({ familyId, body }) => {
    const rules = validateRules(body);
    q('INSERT INTO reward_rules (family_id, rules) VALUES (?, ?) ON CONFLICT (family_id) DO UPDATE SET rules = excluded.rules').run(familyId, json(rules));
    record(familyId, 'rules', familyId);
    return rules;
  });

  function rewardSummary(familyId, childId) {
    const { date } = today(familyId);
    const sum = (sql, ...args) => q(sql).get(...args).n;
    return {
      childId,
      balance: sum('SELECT COALESCE(SUM(minutes), 0) AS n FROM reward_ledger WHERE child_id = ?', childId),
      earnedToday: sum('SELECT COALESCE(SUM(minutes), 0) AS n FROM reward_ledger WHERE child_id = ? AND local_date = ? AND minutes > 0', childId, date),
      usedToday: -sum('SELECT COALESCE(SUM(minutes), 0) AS n FROM reward_ledger WHERE child_id = ? AND local_date = ? AND minutes < 0', childId, date),
      entries: q('SELECT * FROM reward_ledger WHERE child_id = ? ORDER BY created_at DESC LIMIT 50').all(childId)
        .map(e => ({ id: e.id, minutes: e.minutes, reason: e.reason, refId: e.ref_id, date: e.local_date, createdAt: e.created_at }))
    };
  }

  route('GET', '/v1/rewards', ANY, ({ familyId, query }) => rewardSummary(familyId, childIn(familyId, query.get('childId')).id));

  route('POST', '/v1/rewards/sessions', ANY, ({ familyId, body }) => transaction(db, () => {
    const id = uuid(body.id);
    const child = childIn(familyId, body.childId);
    const minutes = integer(body.minutes, 1, 60);
    const previous = q("SELECT * FROM reward_ledger WHERE reason = 'SPEND' AND ref_id = ? AND family_id = ?").get(id, familyId);
    if (previous) return { id, minutes: -previous.minutes, endsAt: new Date(Date.parse(previous.created_at) - previous.minutes * 60_000).toISOString() };
    const rules = rulesFor(familyId);
    const local = today(familyId);
    if (local.time < rules.windowStart || local.time >= rules.windowEnd) fail(409, 'outside_window');
    if (rules.requireAllSubmitted) {
      materializeRoutines(familyId);
      const pending = q("SELECT COUNT(*) AS n FROM homework WHERE child_id = ? AND date = ? AND status IN ('NOT_STARTED', 'NEEDS_CORRECTION')").get(child.id, local.date).n;
      if (pending) fail(409, 'homework_pending');
    }
    const summary = rewardSummary(familyId, child.id);
    if (summary.usedToday + minutes > rules.dailyCap) fail(409, 'daily_cap');
    if (summary.balance < minutes) fail(409, 'insufficient_balance');
    q(`INSERT INTO reward_ledger (id, family_id, child_id, minutes, reason, ref_id, local_date, created_at) VALUES (?, ?, ?, ?, 'SPEND', ?, ?, ?)`)
      .run(randomUUID(), familyId, child.id, -minutes, id, local.date, iso());
    record(familyId, 'reward', child.id);
    return { id, minutes, endsAt: new Date(now() + minutes * 60_000).toISOString() };
  }));

  route('GET', '/v1/changes', ANY, ({ familyId, query }) => {
    const since = Number(query.get('since') ?? 0);
    if (!Number.isInteger(since) || since < 0) fail(400, 'invalid_input');
    const rows = q('SELECT seq, entity, entity_id, op FROM changes WHERE family_id = ? AND seq > ? ORDER BY seq LIMIT 501').all(familyId, since);
    const page = rows.slice(0, 500);
    return { changes: page.map(c => ({ seq: c.seq, entity: c.entity, id: c.entity_id, op: c.op })),
      next: page.at(-1)?.seq ?? since, hasMore: rows.length > 500 };
  });

  // Files are uploaded and downloaded as raw bytes, not JSON.
  async function putFile(req, ctx, id) {
    const type = (req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
    const spec = fileKinds[type] ?? fail(415, 'unsupported_file_type');
    const bytes = await readBody(req, spec.max);
    if (!bytes.length || !spec.check(bytes)) fail(400, 'invalid_file');
    const sha = hash(bytes);
    const existing = q('SELECT * FROM files WHERE id = ?').get(id);
    if (existing) {
      if (existing.family_id !== ctx.familyId || existing.sha256 !== sha) fail(409, 'id_conflict');
      return { id, kind: existing.kind, bytes: existing.bytes };
    }
    const dir = join(dataDir, 'files', ctx.familyId);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `${id}.part`), bytes);
    renameSync(join(dir, `${id}.part`), join(dir, id));
    q('INSERT INTO files (id, family_id, kind, mime, bytes, sha256, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)').run(id, ctx.familyId, spec.kind, type, bytes.length, sha, iso());
    return { id, kind: spec.kind, bytes: bytes.length };
  }

  function getFile(res, ctx, id) {
    const row = q('SELECT * FROM files WHERE id = ? AND family_id = ?').get(id, ctx.familyId) ?? fail(404, 'file_not_found');
    res.writeHead(200, { 'Content-Type': row.mime, 'Content-Length': row.bytes, 'Cache-Control': 'private, max-age=31536000, immutable', 'X-Content-Type-Options': 'nosniff' });
    createReadStream(join(dataDir, 'files', ctx.familyId, row.id)).pipe(res);
  }

  function authenticate(req) {
    const header = req.headers.authorization ?? '';
    if (!header.startsWith('Bearer ')) fail(401, 'unauthorized');
    const device = q('SELECT * FROM devices WHERE token_hash = ? AND revoked_at IS NULL').get(hash(header.slice(7)));
    if (!device) fail(401, 'unauthorized');
    const recent = (deviceRequests.get(device.id) ?? []).filter(t => now() - t < 60_000);
    if (recent.length >= 300) fail(429, 'rate_limited');
    recent.push(now());
    deviceRequests.set(device.id, recent);
    if (!device.last_seen_at || now() - Date.parse(device.last_seen_at) > 60_000) q('UPDATE devices SET last_seen_at = ? WHERE id = ?').run(iso(), device.id);
    return { device, familyId: device.family_id, role: device.role };
  }

  async function handle(req, res) {
    const send = (status, body) => {
      if (res.headersSent || res.destroyed) return;
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
      res.end(json(body));
    };
    const controller = new AbortController();
    res.on('close', () => { if (!res.writableFinished) controller.abort(); });
    try {
      const url = new URL(req.url, 'http://localhost');
      const file = url.pathname.match(/^\/v1\/files\/([^/]+)$/);
      if (file) {
        const ctx = authenticate(req);
        const id = uuid(file[1]);
        if (req.method === 'PUT') return send(200, await putFile(req, ctx, id));
        if (req.method === 'GET') return getFile(res, ctx, id);
        fail(405, 'method_not_allowed');
      }
      let matched = null, params = {};
      for (const r of routes) {
        const m = url.pathname.match(r.pattern);
        if (!m) continue;
        if (r.method !== req.method) { matched ??= 'wrong_method'; continue; }
        matched = r; params = Object.fromEntries(r.keys.map((key, i) => [key, decodeURIComponent(m[i + 1])]));
        break;
      }
      if (!matched) fail(404, 'not_found');
      if (matched === 'wrong_method') fail(405, 'method_not_allowed');
      const ctx = matched.roles ? authenticate(req) : {};
      if (matched.roles && !matched.roles.includes(ctx.role)) fail(403, 'forbidden');
      let body = {};
      if (['POST', 'PUT', 'PATCH'].includes(req.method)) {
        if (!req.headers['content-type']?.startsWith('application/json')) fail(415, 'json_required');
        try { body = JSON.parse((await readBody(req, 1_000_000)).toString('utf8') || '{}'); } catch (e) { if (e instanceof ApiError) throw e; fail(400, 'invalid_json'); }
        if (!body || typeof body !== 'object' || Array.isArray(body)) fail(400, 'invalid_json');
      }
      send(200, await matched.handler({ ...ctx, params, body, query: url.searchParams, signal: controller.signal }));
    } catch (error) {
      if (error instanceof ApiError) return send(error.status, { error: error.message });
      if (error?.name === 'AbortError' || error?.name === 'TimeoutError') return send(504, { error: 'timeout' });
      console.error('api error', error?.code ?? error?.name);
      send(500, { error: 'internal' });
    }
  }

  return { handle, db, close: () => db.close() };
}
