'use strict';
/*
 * Persistence: one JSON file, written atomically, held in memory.
 *
 * The whole dataset for a booking marketplace at pilot scale is a few hundred
 * kilobytes. A database is a deployment dependency we do not need yet, and the
 * finance tracker has run on exactly this shape without losing a byte. When a
 * single pro's job history stops fitting comfortably in memory, this is the
 * one file to replace.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const COLLECTIONS = [
  'pros', 'services', 'availability', 'bookings', 'requests',
  'quotes', 'invoices', 'reviews', 'customers', 'events',
  'payments', 'receipts',
];

function emptyDb() {
  const db = { version: 1, createdAt: new Date().toISOString() };
  for (const c of COLLECTIONS) db[c] = [];
  return db;
}

class Store {
  constructor(file) {
    this.file = file;
    this.db = emptyDb();
    this.writing = false;
    this.dirty = false;
    this.load();
  }

  load() {
    try {
      const raw = fs.readFileSync(this.file, 'utf8');
      const parsed = JSON.parse(raw);
      this.db = Object.assign(emptyDb(), parsed);
      for (const c of COLLECTIONS) if (!Array.isArray(this.db[c])) this.db[c] = [];
    } catch (err) {
      if (err.code !== 'ENOENT') throw err;
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      this.persist();
    }
    this.reindex();
  }

  /** Rebuild the id lookups. Cheap, and always correct after a bulk change. */
  reindex() {
    this.byId = new Map();
    for (const c of COLLECTIONS) {
      for (const row of this.db[c]) this.byId.set(`${c}:${row.id}`, row);
    }
  }

  /*
   * Write to a sibling temp file and rename. Rename is atomic within a
   * filesystem, so a crash mid-write leaves the previous file intact rather
   * than a half-written one that will not parse on boot.
   */
  persist() {
    const tmp = `${this.file}.${process.pid}.tmp`;
    const fd = fs.openSync(tmp, 'w', 0o600);
    try {
      fs.writeFileSync(fd, JSON.stringify(this.db, null, 1));
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmp, this.file);
    const dir = fs.openSync(path.dirname(this.file), 'r');
    try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
  }

  /** Coalesce bursts of writes; a booking touches three collections. */
  save() {
    this.dirty = true;
    if (this.writing) return;
    this.writing = true;
    setTimeout(() => {
      this.writing = false;
      if (!this.dirty) return;
      this.dirty = false;
      this.persist();
    }, 25);
  }

  saveNow() {
    this.dirty = false;
    this.persist();
  }

  all(c) { return this.db[c] || []; }
  get(c, id) { return this.byId.get(`${c}:${id}`) || null; }
  find(c, fn) { return this.all(c).find(fn) || null; }
  filter(c, fn) { return this.all(c).filter(fn); }

  insert(c, row) {
    if (!COLLECTIONS.includes(c)) throw new Error(`unknown collection: ${c}`);
    const rec = { id: row.id || newId(), createdAt: new Date().toISOString(), ...row };
    this.db[c].push(rec);
    this.byId.set(`${c}:${rec.id}`, rec);
    this.save();
    return rec;
  }

  update(c, id, patch) {
    const row = this.get(c, id);
    if (!row) return null;
    Object.assign(row, patch, { updatedAt: new Date().toISOString() });
    this.save();
    return row;
  }

  remove(c, id) {
    const i = this.db[c].findIndex((r) => r.id === id);
    if (i < 0) return false;
    this.db[c].splice(i, 1);
    this.byId.delete(`${c}:${id}`);
    this.save();
    return true;
  }

  /** Append-only audit trail. What was agreed, and when, is the product. */
  log(type, subject, detail = {}) {
    return this.insert('events', { type, subject, detail, at: new Date().toISOString() });
  }
}

function newId() {
  return crypto.randomBytes(9).toString('base64url');
}

/*
 * Customer-facing reference. Read aloud over the phone in a van, so no
 * vowels (no accidental words), no 0/O/1/I/5/S.
 */
const REF_ALPHABET = '23479ACDEFHJKLMNPQRTWXY';
function newRef() {
  const bytes = crypto.randomBytes(8);
  let out = '';
  for (let i = 0; i < 8; i++) {
    out += REF_ALPHABET[bytes[i] % REF_ALPHABET.length];
    if (i === 3) out += '-';
  }
  return out;
}

function slugify(s) {
  return String(s).toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '').slice(0, 60) || 'pro';
}

module.exports = { Store, COLLECTIONS, newId, newRef, slugify };
