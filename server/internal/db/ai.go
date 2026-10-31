package db

import (
	"database/sql"
	"errors"
)

const (
	ModelActive      = "active"
	ModelDisabled    = "disabled"    // dimatikan admin
	ModelUnavailable = "unavailable" // ditolak provider saat dites
)

// AIModel adalah satu baris katalog model AI yang dikelola admin.
type AIModel struct {
	ID            int64  `json:"id"`
	Provider      string `json:"provider"`
	ModelID       string `json:"modelId"`
	Label         string `json:"label"`
	Status        string `json:"status"`
	StatusNote    string `json:"statusNote"`
	ExtraBody     string `json:"extraBody"` // JSON objek yang digabung ke body request
	SortOrder     int    `json:"sortOrder"`
	Builtin       bool   `json:"builtin"`
	Free          bool   `json:"free"`
	LastCheckedAt string `json:"lastCheckedAt"`
	LastLatencyMs int    `json:"lastLatencyMs"`
	CreatedAt     string `json:"createdAt"`
	UpdatedAt     string `json:"updatedAt"`
}

const modelCols = `id, provider, model_id, label, status, status_note, extra_body, sort_order, builtin, free, last_checked_at, last_latency_ms, created_at, updated_at`

func scanModel(row interface{ Scan(...any) error }) (AIModel, error) {
	var m AIModel
	var builtin, free int
	err := row.Scan(&m.ID, &m.Provider, &m.ModelID, &m.Label, &m.Status, &m.StatusNote, &m.ExtraBody, &m.SortOrder,
		&builtin, &free, &m.LastCheckedAt, &m.LastLatencyMs, &m.CreatedAt, &m.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return m, ErrNotFound
	}
	m.Builtin, m.Free = builtin == 1, free == 1
	return m, err
}

// ListModels mengembalikan katalog berurutan sort_order — urutan ini sekaligus
// urutan fallback asisten.
func (d *DB) ListModels() ([]AIModel, error) {
	rows, err := d.Query(`SELECT ` + modelCols + ` FROM ai_models ORDER BY sort_order, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AIModel{}
	for rows.Next() {
		m, err := scanModel(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (d *DB) GetModel(id int64) (AIModel, error) {
	return scanModel(d.QueryRow(`SELECT `+modelCols+` FROM ai_models WHERE id = ?`, id))
}

func (d *DB) ModelExists(provider, modelID string) (bool, error) {
	var n int
	err := d.QueryRow(`SELECT COUNT(*) FROM ai_models WHERE provider = ? AND model_id = ?`, provider, modelID).Scan(&n)
	return n > 0, err
}

func (d *DB) nextSortOrder() (int, error) {
	var n sql.NullInt64
	err := d.QueryRow(`SELECT MAX(sort_order) FROM ai_models`).Scan(&n)
	return int(n.Int64) + 10, err
}

func (d *DB) InsertModel(m AIModel) (AIModel, error) {
	now := Now()
	if m.SortOrder == 0 {
		next, err := d.nextSortOrder()
		if err != nil {
			return m, err
		}
		m.SortOrder = next
	}
	if m.Status == "" {
		m.Status = ModelActive
	}
	res, err := d.Exec(`INSERT INTO ai_models (provider, model_id, label, status, status_note, extra_body, sort_order, builtin, free, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, m.Provider, m.ModelID, m.Label, m.Status, m.StatusNote, m.ExtraBody, m.SortOrder,
		boolInt(m.Builtin), boolInt(m.Free), now, now)
	if err != nil {
		return m, err
	}
	m.ID, _ = res.LastInsertId()
	m.CreatedAt, m.UpdatedAt = now, now
	return m, nil
}

func (d *DB) UpdateModel(m AIModel) error {
	_, err := d.Exec(`UPDATE ai_models SET label = ?, status = ?, status_note = ?, extra_body = ?, free = ?, updated_at = ? WHERE id = ?`,
		m.Label, m.Status, m.StatusNote, m.ExtraBody, boolInt(m.Free), Now(), m.ID)
	return err
}

func (d *DB) RecordModelCheck(id int64, status, note string, latencyMs int) error {
	_, err := d.Exec(`UPDATE ai_models SET status = ?, status_note = ?, last_checked_at = ?, last_latency_ms = ?, updated_at = ? WHERE id = ?`,
		status, note, Now(), latencyMs, Now(), id)
	return err
}

func (d *DB) DeleteModel(id int64) error {
	_, err := d.Exec(`DELETE FROM ai_models WHERE id = ?`, id)
	return err
}

// ReorderModels menyimpan urutan baru (ids dari atas ke bawah).
func (d *DB) ReorderModels(ids []int64) error {
	return d.Tx(func(tx *sql.Tx) error {
		for i, id := range ids {
			if _, err := tx.Exec(`UPDATE ai_models SET sort_order = ?, updated_at = ? WHERE id = ?`, (i+1)*10, Now(), id); err != nil {
				return err
			}
		}
		return nil
	})
}

// --- chat & batch aksi ----------------------------------------------------------

type ChatMessage struct {
	ID        int64  `json:"id"`
	UserID    int64  `json:"-"`
	Role      string `json:"role"` // user | assistant
	Content   string `json:"content"`
	BatchID   int64  `json:"batchId,omitempty"`
	Provider  string `json:"provider,omitempty"`
	Model     string `json:"model,omitempty"`
	LatencyMs int    `json:"latencyMs,omitempty"`
	CreatedAt string `json:"createdAt"`
}

func (d *DB) InsertChat(m ChatMessage) (ChatMessage, error) {
	m.CreatedAt = Now()
	res, err := d.Exec(`INSERT INTO chat_messages (user_id, role, content, batch_id, provider, model, latency_ms, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, m.UserID, m.Role, m.Content, m.BatchID, m.Provider, m.Model, m.LatencyMs, m.CreatedAt)
	if err != nil {
		return m, err
	}
	m.ID, _ = res.LastInsertId()
	return m, nil
}

// ListChat mengembalikan maksimal limit pesan sebelum id before (0 = terbaru),
// urut dari lama ke baru.
func (d *DB) ListChat(userID, before int64, limit int) ([]ChatMessage, error) {
	if before <= 0 {
		before = 1 << 62
	}
	rows, err := d.Query(`SELECT id, user_id, role, content, batch_id, provider, model, latency_ms, created_at FROM chat_messages
		WHERE user_id = ? AND id < ? ORDER BY id DESC LIMIT ?`, userID, before, limit)
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
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, rows.Err()
}

func (d *DB) ClearChat(userID int64) error {
	return d.Tx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`DELETE FROM chat_messages WHERE user_id = ?`, userID); err != nil {
			return err
		}
		_, err := tx.Exec(`DELETE FROM action_batches WHERE user_id = ?`, userID)
		return err
	})
}

// PruneChat menyimpan hanya keep pesan terakhir per pengguna dan batch 30 hari.
func (d *DB) PruneChat(keep int) error {
	if _, err := d.Exec(`DELETE FROM chat_messages WHERE id IN (
		SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY id DESC) AS rn FROM chat_messages) WHERE rn > ?)`, keep); err != nil {
		return err
	}
	_, err := d.Exec(`DELETE FROM action_batches WHERE created_at < datetime('now', '-30 days')`)
	return err
}

const (
	BatchPending  = "pending"
	BatchApplied  = "applied"
	BatchRejected = "rejected"
	BatchExpired  = "expired"
	BatchUndone   = "undone"
	BatchFailed   = "failed"
)

type Batch struct {
	ID        int64  `json:"id"`
	UserID    int64  `json:"-"`
	Status    string `json:"status"`
	Ops       string `json:"-"`
	Items     string `json:"-"`
	Undo      string `json:"-"`
	ExpiresAt string `json:"expiresAt"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

const batchCols = `id, user_id, status, ops, items, undo, expires_at, created_at, updated_at`

func scanBatch(row interface{ Scan(...any) error }) (Batch, error) {
	var b Batch
	err := row.Scan(&b.ID, &b.UserID, &b.Status, &b.Ops, &b.Items, &b.Undo, &b.ExpiresAt, &b.CreatedAt, &b.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return b, ErrNotFound
	}
	return b, err
}

func InsertBatch(q Q, b Batch) (Batch, error) {
	now := Now()
	b.CreatedAt, b.UpdatedAt = now, now
	res, err := q.Exec(`INSERT INTO action_batches (user_id, status, ops, items, undo, expires_at, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, b.UserID, b.Status, b.Ops, b.Items, b.Undo, b.ExpiresAt, now, now)
	if err != nil {
		return b, err
	}
	b.ID, _ = res.LastInsertId()
	return b, nil
}

func UpdateBatch(q Q, b Batch) error {
	_, err := q.Exec(`UPDATE action_batches SET status = ?, items = ?, undo = ?, updated_at = ? WHERE id = ? AND user_id = ?`,
		b.Status, b.Items, b.Undo, Now(), b.ID, b.UserID)
	return err
}

func GetBatch(q Q, userID, id int64) (Batch, error) {
	return scanBatch(q.QueryRow(`SELECT `+batchCols+` FROM action_batches WHERE id = ? AND user_id = ?`, id, userID))
}

func (d *DB) GetBatches(userID int64, ids []int64) (map[int64]Batch, error) {
	out := map[int64]Batch{}
	for _, id := range ids {
		b, err := GetBatch(d, userID, id)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		out[id] = b
	}
	return out, nil
}

func (d *DB) LastAppliedBatch(userID int64) (Batch, error) {
	return scanBatch(d.QueryRow(`SELECT `+batchCols+` FROM action_batches WHERE user_id = ? AND status = 'applied'
		ORDER BY id DESC LIMIT 1`, userID))
}

// --- push ---------------------------------------------------------------------------

type PushSub struct {
	ID        int64
	UserID    int64
	SessionID int64
	Endpoint  string
	P256dh    string
	Auth      string
}

func (d *DB) UpsertPushSub(s PushSub) error {
	_, err := d.Exec(`INSERT INTO push_subscriptions (user_id, session_id, endpoint, p256dh, auth, created_at) VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(endpoint) DO UPDATE SET user_id = excluded.user_id, session_id = excluded.session_id,
			p256dh = excluded.p256dh, auth = excluded.auth`, s.UserID, s.SessionID, s.Endpoint, s.P256dh, s.Auth, Now())
	return err
}

func (d *DB) DeletePushSub(userID int64, endpoint string) error {
	_, err := d.Exec(`DELETE FROM push_subscriptions WHERE user_id = ? AND endpoint = ?`, userID, endpoint)
	return err
}

func (d *DB) DeletePushSubByID(id int64) error {
	_, err := d.Exec(`DELETE FROM push_subscriptions WHERE id = ?`, id)
	return err
}

func (d *DB) PushSubsForUser(userID int64) ([]PushSub, error) {
	rows, err := d.Query(`SELECT id, user_id, COALESCE(session_id, 0), endpoint, p256dh, auth FROM push_subscriptions WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []PushSub{}
	for rows.Next() {
		var s PushSub
		if err := rows.Scan(&s.ID, &s.UserID, &s.SessionID, &s.Endpoint, &s.P256dh, &s.Auth); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (d *DB) HasPushSub(userID int64, endpoint string) (bool, error) {
	var n int
	err := d.QueryRow(`SELECT COUNT(*) FROM push_subscriptions WHERE user_id = ? AND endpoint = ?`, userID, endpoint).Scan(&n)
	return n > 0, err
}
