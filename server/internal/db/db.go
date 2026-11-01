// Package db menyimpan semua data di satu berkas SQLite (modernc.org/sqlite,
// tanpa cgo) — sama seperti our-life-planner.
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

// ErrNotFound dipakai saat baris tidak ada atau bukan milik pengguna.
var ErrNotFound = errors.New("tidak ditemukan")

// Q adalah kumpulan method yang dimiliki *sql.DB maupun *sql.Tx, supaya fungsi
// data yang sama bisa dipakai di dalam atau di luar transaksi.
type Q interface {
	Exec(query string, args ...any) (sql.Result, error)
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
}

type DB struct {
	*sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS users (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	username TEXT NOT NULL UNIQUE COLLATE NOCASE,
	display_name TEXT NOT NULL DEFAULT '',
	password_hash TEXT NOT NULL,
	role TEXT NOT NULL DEFAULT 'user',
	timezone TEXT NOT NULL DEFAULT '',
	disabled INTEGER NOT NULL DEFAULT 0,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	token_hash TEXT NOT NULL UNIQUE,
	kind TEXT NOT NULL,
	name TEXT NOT NULL DEFAULT '',
	user_agent TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL,
	last_seen_at TEXT NOT NULL,
	expires_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS user_settings (
	user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	key TEXT NOT NULL,
	value TEXT NOT NULL,
	PRIMARY KEY (user_id, key)
);

CREATE TABLE IF NOT EXISTS todos (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	title TEXT NOT NULL,
	notes TEXT NOT NULL DEFAULT '',
	status TEXT NOT NULL DEFAULT 'open',
	priority TEXT NOT NULL DEFAULT 'normal',
	list TEXT NOT NULL DEFAULT '',
	due_date TEXT NOT NULL DEFAULT '',
	due_time TEXT NOT NULL DEFAULT '',
	source TEXT NOT NULL DEFAULT 'manual',
	completed_at TEXT NOT NULL DEFAULT '',
	due_notified_at TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_todos_user ON todos(user_id, status, due_date);

CREATE TABLE IF NOT EXISTS reminders (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	todo_id INTEGER REFERENCES todos(id) ON DELETE SET NULL,
	title TEXT NOT NULL,
	message TEXT NOT NULL DEFAULT '',
	schedule TEXT NOT NULL,
	next_fire_at TEXT NOT NULL DEFAULT '',
	last_fired_at TEXT NOT NULL DEFAULT '',
	fire_count INTEGER NOT NULL DEFAULT 0,
	active INTEGER NOT NULL DEFAULT 1,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(active, next_fire_at);
CREATE INDEX IF NOT EXISTS idx_reminders_user ON reminders(user_id);

CREATE TABLE IF NOT EXISTS ai_models (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	provider TEXT NOT NULL,
	model_id TEXT NOT NULL,
	label TEXT NOT NULL DEFAULT '',
	status TEXT NOT NULL DEFAULT 'active',
	status_note TEXT NOT NULL DEFAULT '',
	extra_body TEXT NOT NULL DEFAULT '',
	sort_order INTEGER NOT NULL DEFAULT 0,
	builtin INTEGER NOT NULL DEFAULT 0,
	free INTEGER NOT NULL DEFAULT 0,
	last_checked_at TEXT NOT NULL DEFAULT '',
	last_latency_ms INTEGER NOT NULL DEFAULT 0,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL,
	UNIQUE (provider, model_id)
);

CREATE TABLE IF NOT EXISTS chat_messages (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	role TEXT NOT NULL,
	content TEXT NOT NULL,
	batch_id INTEGER NOT NULL DEFAULT 0,
	provider TEXT NOT NULL DEFAULT '',
	model TEXT NOT NULL DEFAULT '',
	latency_ms INTEGER NOT NULL DEFAULT 0,
	created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chat_user ON chat_messages(user_id, id);

CREATE TABLE IF NOT EXISTS action_batches (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	status TEXT NOT NULL,
	ops TEXT NOT NULL,
	items TEXT NOT NULL DEFAULT '[]',
	undo TEXT NOT NULL DEFAULT '[]',
	expires_at TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_batches_user ON action_batches(user_id, id);

-- Ingatan asisten per pengguna (konsep MEMORY.md / USER.md dari Hermes Agent,
-- tapi baris SQLite: terisolasi per pengguna, transaksional, ikut backup).
CREATE TABLE IF NOT EXISTS memories (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	target TEXT NOT NULL,
	content TEXT NOT NULL,
	source TEXT NOT NULL DEFAULT 'manual',
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_memories_user ON memories(user_id, target, id);

-- Indeks teks penuh riwayat chat (pencarian percakapan lama, seperti
-- session_search Hermes). Diisi otomatis oleh trigger.
CREATE VIRTUAL TABLE IF NOT EXISTS chat_fts USING fts5(content, content='chat_messages', content_rowid='id',
	tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER IF NOT EXISTS chat_fts_ai AFTER INSERT ON chat_messages BEGIN
	INSERT INTO chat_fts(rowid, content) VALUES (new.id, new.content);
END;
CREATE TRIGGER IF NOT EXISTS chat_fts_ad AFTER DELETE ON chat_messages BEGIN
	INSERT INTO chat_fts(chat_fts, rowid, content) VALUES ('delete', old.id, old.content);
END;

CREATE TABLE IF NOT EXISTS push_subscriptions (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	session_id INTEGER REFERENCES sessions(id) ON DELETE CASCADE,
	endpoint TEXT NOT NULL UNIQUE,
	p256dh TEXT NOT NULL,
	auth TEXT NOT NULL,
	created_at TEXT NOT NULL
);
`

// Open membuka (dan bila perlu membuat) database di path.
func Open(path string) (*DB, error) {
	dsn := "file:" + path + "?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)"
	sqlDB, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// Satu koneksi saja: SQLite hanya punya satu penulis, dan ini menghindari
	// "database is locked". Jangan memanggil d.* dari dalam transaksi — pakai tx.
	sqlDB.SetMaxOpenConns(1)
	if _, err := sqlDB.Exec(schema); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return &DB{sqlDB}, nil
}

// Tx menjalankan f dalam satu transaksi; error dari f membatalkan semuanya.
func (d *DB) Tx(f func(tx *sql.Tx) error) error {
	tx, err := d.Begin()
	if err != nil {
		return err
	}
	if err := f(tx); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

// Now adalah stempel waktu standar di database: RFC3339 UTC, bisa dibandingkan
// secara leksikal.
func Now() string { return Stamp(time.Now()) }

// Stamp memformat t sebagai stempel waktu database.
func Stamp(t time.Time) string { return t.UTC().Format(time.RFC3339) }

// ParseStamp membaca stempel waktu database.
func ParseStamp(s string) (time.Time, error) { return time.Parse(time.RFC3339, s) }

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// --- settings -----------------------------------------------------------------

func (d *DB) GetSetting(key string) (string, error) {
	var v string
	err := d.QueryRow(`SELECT value FROM settings WHERE key = ?`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return v, err
}

func (d *DB) SetSetting(key, value string) error {
	_, err := d.Exec(`INSERT INTO settings (key, value) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

func (d *DB) GetUserSettings(userID int64) (map[string]string, error) {
	rows, err := d.Query(`SELECT key, value FROM user_settings WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return nil, err
		}
		out[k] = v
	}
	return out, rows.Err()
}

func (d *DB) SetUserSetting(userID int64, key, value string) error {
	_, err := d.Exec(`INSERT INTO user_settings (user_id, key, value) VALUES (?, ?, ?)
		ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value`, userID, key, value)
	return err
}

// ClaimUserSetting mengganti nilai key dari old ke new hanya kalau nilainya
// masih old. Dipakai penjadwal supaya ringkasan harian tidak terkirim dua kali.
func (d *DB) ClaimUserSetting(userID int64, key, old, new string) (bool, error) {
	if old == "" {
		res, err := d.Exec(`INSERT OR IGNORE INTO user_settings (user_id, key, value) VALUES (?, ?, ?)`, userID, key, new)
		if err != nil {
			return false, err
		}
		if n, _ := res.RowsAffected(); n == 1 {
			return true, nil
		}
	}
	res, err := d.Exec(`UPDATE user_settings SET value = ? WHERE user_id = ? AND key = ? AND value = ?`, new, userID, key, old)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}
