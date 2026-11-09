import { DatabaseSync } from 'node:sqlite';

/** Schema for phase 1 (homework management). Bump `version` and append a migration when it changes. */
const migrations = [`
  CREATE TABLE families (
    id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', timezone TEXT NOT NULL DEFAULT 'Asia/Shanghai',
    created_at TEXT NOT NULL);
  CREATE TABLE children (
    id TEXT PRIMARY KEY, family_id TEXT NOT NULL, name TEXT NOT NULL, grade INTEGER NOT NULL, avatar TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1);
  CREATE TABLE devices (
    id TEXT PRIMARY KEY, family_id TEXT NOT NULL, role TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
    token_hash TEXT NOT NULL UNIQUE, push_token TEXT, created_at TEXT NOT NULL, last_seen_at TEXT, revoked_at TEXT);
  CREATE TABLE pairing_codes (
    code_hash TEXT PRIMARY KEY, family_id TEXT NOT NULL, expires_at INTEGER NOT NULL, used_at TEXT);
  CREATE TABLE homework (
    id TEXT PRIMARY KEY, family_id TEXT NOT NULL, child_id TEXT NOT NULL, subject TEXT NOT NULL, date TEXT NOT NULL,
    due_date TEXT, content TEXT NOT NULL, raw_text TEXT NOT NULL DEFAULT '', mode TEXT NOT NULL, online_kind TEXT,
    duration_minutes INTEGER, parent_todo TEXT NOT NULL DEFAULT '', status TEXT NOT NULL, source TEXT NOT NULL,
    routine_id TEXT, attachment_ids TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1);
  CREATE INDEX homework_child_date ON homework (child_id, date);
  CREATE UNIQUE INDEX homework_routine_day ON homework (routine_id, date) WHERE routine_id IS NOT NULL;
  CREATE TABLE routines (
    id TEXT PRIMARY KEY, family_id TEXT NOT NULL, child_id TEXT NOT NULL, title TEXT NOT NULL, subject TEXT NOT NULL,
    mode TEXT NOT NULL, online_kind TEXT, duration_minutes INTEGER, quantity INTEGER, weekdays TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1);
  CREATE TABLE submissions (
    id TEXT PRIMARY KEY, family_id TEXT NOT NULL, homework_id TEXT NOT NULL, attempt INTEGER NOT NULL,
    file_ids TEXT NOT NULL DEFAULT '[]', duration_seconds INTEGER, submitted_at TEXT NOT NULL, received_at TEXT NOT NULL,
    on_time INTEGER NOT NULL, UNIQUE (homework_id, attempt));
  CREATE TABLE reviews (
    id TEXT PRIMARY KEY, family_id TEXT NOT NULL, submission_id TEXT NOT NULL UNIQUE, homework_id TEXT NOT NULL,
    grade TEXT NOT NULL, comment TEXT NOT NULL DEFAULT '', require_correction INTEGER NOT NULL,
    annotation_file_ids TEXT NOT NULL DEFAULT '[]', reviewed_at TEXT NOT NULL);
  CREATE TABLE reward_rules (family_id TEXT PRIMARY KEY, rules TEXT NOT NULL);
  CREATE TABLE reward_ledger (
    id TEXT PRIMARY KEY, family_id TEXT NOT NULL, child_id TEXT NOT NULL, minutes INTEGER NOT NULL, reason TEXT NOT NULL,
    ref_id TEXT NOT NULL, local_date TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE (family_id, reason, ref_id));
  CREATE INDEX ledger_child ON reward_ledger (child_id, local_date);
  CREATE TABLE files (
    id TEXT PRIMARY KEY, family_id TEXT NOT NULL, kind TEXT NOT NULL, mime TEXT NOT NULL, bytes INTEGER NOT NULL,
    sha256 TEXT NOT NULL, created_at TEXT NOT NULL);
  CREATE TABLE changes (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, family_id TEXT NOT NULL, entity TEXT NOT NULL, entity_id TEXT NOT NULL,
    op TEXT NOT NULL, at TEXT NOT NULL);
  CREATE INDEX changes_family ON changes (family_id, seq);
`];

export function openDatabase(path) {
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;');
  const current = db.prepare('PRAGMA user_version').get().user_version;
  for (let version = current; version < migrations.length; version++) {
    transaction(db, () => {
      db.exec(migrations[version]);
      db.exec(`PRAGMA user_version = ${version + 1}`);
    });
  }
  return db;
}

/** Runs `fn` in one write transaction. node:sqlite is synchronous, so nothing else interleaves. */
export function transaction(db, fn) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}
