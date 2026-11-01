package db

import (
	"database/sql"
	"errors"
	"strings"
)

const (
	MemoryProfile = "profile" // siapa pengguna: preferensi, kebiasaan, gaya komunikasi
	MemoryNotes   = "notes"   // catatan asisten: konteks, kesepakatan, pelajaran
)

type Memory struct {
	ID        int64  `json:"id"`
	UserID    int64  `json:"-"`
	Target    string `json:"target"`
	Content   string `json:"content"`
	Source    string `json:"source"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

type MemorySnapshot struct {
	Memory
	UserID int64 `json:"userId"`
}

func SnapshotMemory(m Memory) MemorySnapshot { return MemorySnapshot{Memory: m, UserID: m.UserID} }

const memoryCols = `id, user_id, target, content, source, created_at, updated_at`

func scanMemory(row interface{ Scan(...any) error }) (Memory, error) {
	var m Memory
	err := row.Scan(&m.ID, &m.UserID, &m.Target, &m.Content, &m.Source, &m.CreatedAt, &m.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return m, ErrNotFound
	}
	return m, err
}

func ListMemories(q Q, userID int64) ([]Memory, error) {
	rows, err := q.Query(`SELECT `+memoryCols+` FROM memories WHERE user_id = ? ORDER BY target, id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Memory{}
	for rows.Next() {
		m, err := scanMemory(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func GetMemory(q Q, userID, id int64) (Memory, error) {
	return scanMemory(q.QueryRow(`SELECT `+memoryCols+` FROM memories WHERE id = ? AND user_id = ?`, id, userID))
}

func InsertMemory(q Q, m Memory) (Memory, error) {
	now := Now()
	m.CreatedAt, m.UpdatedAt = now, now
	res, err := q.Exec(`INSERT INTO memories (user_id, target, content, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`,
		m.UserID, m.Target, m.Content, m.Source, now, now)
	if err != nil {
		return m, err
	}
	m.ID, _ = res.LastInsertId()
	return m, nil
}

func UpdateMemory(q Q, m Memory) (Memory, error) {
	m.UpdatedAt = Now()
	_, err := q.Exec(`UPDATE memories SET content = ?, updated_at = ? WHERE id = ? AND user_id = ?`, m.Content, m.UpdatedAt, m.ID, m.UserID)
	return m, err
}

func DeleteMemory(q Q, userID, id int64) error {
	_, err := q.Exec(`DELETE FROM memories WHERE id = ? AND user_id = ?`, id, userID)
	return err
}

func RestoreMemory(q Q, s MemorySnapshot) error {
	_, err := q.Exec(`INSERT OR REPLACE INTO memories (`+memoryCols+`) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		s.ID, s.UserID, s.Target, s.Content, s.Source, s.CreatedAt, s.UpdatedAt)
	return err
}

// ftsQuery mengubah teks bebas menjadi kueri FTS5 yang aman: setiap kata
// dikutip (tanpa operator), jadi input pengguna/AI tidak bisa menyusun sintaks.
func ftsQuery(text string) string {
	var parts []string
	for _, w := range strings.FieldsFunc(text, func(r rune) bool {
		return !(r == '-' || r == '_' || r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r > 127)
	}) {
		if len(parts) == 8 {
			break
		}
		parts = append(parts, `"`+strings.ReplaceAll(w, `"`, ``)+`"`)
	}
	return strings.Join(parts, " ")
}

// SearchChat mencari pesan lama milik pengguna (paling relevan dulu).
func (d *DB) SearchChat(userID int64, text string, limit int) ([]ChatMessage, error) {
	q := ftsQuery(text)
	if q == "" {
		return []ChatMessage{}, nil
	}
	rows, err := d.Query(`SELECT m.id, m.user_id, m.role, m.content, m.batch_id, m.provider, m.model, m.latency_ms, m.created_at
		FROM chat_fts JOIN chat_messages m ON m.id = chat_fts.rowid
		WHERE chat_fts MATCH ? AND m.user_id = ? ORDER BY rank LIMIT ?`, q, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ChatMessage{}
	for rows.Next() {
		var m ChatMessage
		if err := rows.Scan(&m.ID, &m.UserID, &m.Role, &m.Content, &m.BatchID, &m.Provider, &m.Model, &m.LatencyMs, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
