package db

import (
	"database/sql"
	"strings"
	"time"
)

// AICall adalah satu baris AI Call Log (request HTTP keluar ke provider AI).
type AICall struct {
	ID               int64  `json:"id"`
	UserID           int64  `json:"userId"`
	Username         string `json:"username"`
	Feature          string `json:"feature"`
	Provider         string `json:"provider"`
	Model            string `json:"model"`
	Endpoint         string `json:"endpoint"`
	Operation        string `json:"operation"`
	HTTPStatus       int    `json:"httpStatus"`
	OK               bool   `json:"ok"`
	LatencyMs        int    `json:"latencyMs"`
	PromptTokens     int    `json:"promptTokens"`
	CompletionTokens int    `json:"completionTokens"`
	Error            string `json:"error"`
	CreatedAt        string `json:"createdAt"`
}

func (d *DB) InsertAICall(c AICall) error {
	var uid any
	if c.UserID > 0 {
		uid = c.UserID
	}
	if c.CreatedAt == "" {
		c.CreatedAt = Now()
	}
	_, err := d.Exec(`INSERT INTO ai_calls (user_id, feature, provider, model, endpoint, operation, http_status, ok, latency_ms,
		prompt_tokens, completion_tokens, error, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		uid, c.Feature, c.Provider, c.Model, c.Endpoint, c.Operation, c.HTTPStatus, boolInt(c.OK), c.LatencyMs,
		c.PromptTokens, c.CompletionTokens, c.Error, c.CreatedAt)
	return err
}

// AICallFilter: filter daftar AI Call Log. Waktu From/To dalam UTC (To eksklusif).
type AICallFilter struct {
	Text     string // cari di model, fitur, error, username
	Provider string
	Feature  string
	Status   string // ok | error | "" (semua)
	From, To time.Time
	Page     int
	Size     int
}

func (f AICallFilter) where() (string, []any) {
	var conds []string
	var args []any
	if t := strings.TrimSpace(f.Text); t != "" {
		like := "%" + strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(t) + "%"
		conds = append(conds, `(c.model LIKE ? ESCAPE '\' OR c.feature LIKE ? ESCAPE '\' OR c.error LIKE ? ESCAPE '\' OR u.username LIKE ? ESCAPE '\')`)
		args = append(args, like, like, like, like)
	}
	if f.Provider != "" {
		conds, args = append(conds, `c.provider = ?`), append(args, f.Provider)
	}
	if f.Feature != "" {
		conds, args = append(conds, `c.feature = ?`), append(args, f.Feature)
	}
	switch f.Status {
	case "ok":
		conds = append(conds, `c.ok = 1`)
	case "error":
		conds = append(conds, `c.ok = 0`)
	}
	if !f.From.IsZero() {
		conds, args = append(conds, `c.created_at >= ?`), append(args, Stamp(f.From))
	}
	if !f.To.IsZero() {
		conds, args = append(conds, `c.created_at < ?`), append(args, Stamp(f.To))
	}
	if len(conds) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(conds, " AND "), args
}

// ListAICalls mengembalikan log terbaru dulu beserta jumlah total yang cocok.
func (d *DB) ListAICalls(f AICallFilter) ([]AICall, int, error) {
	if f.Size <= 0 {
		f.Size = 50
	}
	f.Size = min(f.Size, 200)
	f.Page = max(f.Page, 1)
	where, args := f.where()
	from := ` FROM ai_calls c LEFT JOIN users u ON u.id = c.user_id`
	var total int
	if err := d.QueryRow(`SELECT COUNT(*)`+from+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := d.Query(`SELECT c.id, COALESCE(c.user_id, 0), COALESCE(u.username, ''), c.feature, c.provider, c.model, c.endpoint,
		c.operation, c.http_status, c.ok, c.latency_ms, c.prompt_tokens, c.completion_tokens, c.error, c.created_at`+from+where+
		` ORDER BY c.created_at DESC, c.id DESC LIMIT ? OFFSET ?`, append(args, f.Size, (f.Page-1)*f.Size)...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []AICall{}
	for rows.Next() {
		var c AICall
		var ok int
		if err := rows.Scan(&c.ID, &c.UserID, &c.Username, &c.Feature, &c.Provider, &c.Model, &c.Endpoint, &c.Operation,
			&c.HTTPStatus, &ok, &c.LatencyMs, &c.PromptTokens, &c.CompletionTokens, &c.Error, &c.CreatedAt); err != nil {
			return nil, 0, err
		}
		c.OK = ok == 1
		out = append(out, c)
	}
	return out, total, rows.Err()
}

// AICallSummary: ringkasan per provider + model sejak waktu tertentu.
type AICallSummary struct {
	Provider         string  `json:"provider"`
	Model            string  `json:"model"`
	Calls            int     `json:"calls"`
	Errors           int     `json:"errors"`
	AvgMs            float64 `json:"avgMs"`
	MaxMs            int     `json:"maxMs"`
	PromptTokens     int     `json:"promptTokens"`
	CompletionTokens int     `json:"completionTokens"`
	LastCall         string  `json:"lastCall"`
}

func (d *DB) SummarizeAICalls(since time.Time) ([]AICallSummary, error) {
	rows, err := d.Query(`SELECT provider, model, COUNT(*), SUM(CASE WHEN ok = 0 THEN 1 ELSE 0 END), AVG(latency_ms), MAX(latency_ms),
		SUM(prompt_tokens), SUM(completion_tokens), MAX(created_at)
		FROM ai_calls WHERE created_at >= ? GROUP BY provider, model ORDER BY COUNT(*) DESC LIMIT 100`, Stamp(since))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AICallSummary{}
	for rows.Next() {
		var s AICallSummary
		var avg sql.NullFloat64
		if err := rows.Scan(&s.Provider, &s.Model, &s.Calls, &s.Errors, &avg, &s.MaxMs, &s.PromptTokens, &s.CompletionTokens, &s.LastCall); err != nil {
			return nil, err
		}
		s.AvgMs = avg.Float64
		out = append(out, s)
	}
	return out, rows.Err()
}

// AICallFeatures: daftar fitur yang pernah tercatat (untuk pilihan filter).
func (d *DB) AICallFeatures() ([]string, error) {
	rows, err := d.Query(`SELECT DISTINCT feature FROM ai_calls WHERE feature != '' ORDER BY feature LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var f string
		if err := rows.Scan(&f); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// DeleteAICalls menghapus baris terpilih; ids kosong = kosongkan semua log.
func (d *DB) DeleteAICalls(ids []int64) (int64, error) {
	var res sql.Result
	var err error
	if len(ids) == 0 {
		res, err = d.Exec(`DELETE FROM ai_calls`)
	} else {
		ph := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
		args := make([]any, len(ids))
		for i, id := range ids {
			args[i] = id
		}
		res, err = d.Exec(`DELETE FROM ai_calls WHERE id IN (`+ph+`)`, args...)
	}
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// PruneAICalls menghapus log yang lebih tua dari before.
func (d *DB) PruneAICalls(before time.Time) error {
	_, err := d.Exec(`DELETE FROM ai_calls WHERE created_at < ?`, Stamp(before))
	return err
}
