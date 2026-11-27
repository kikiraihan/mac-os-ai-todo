package db

import (
	"database/sql"
	"errors"
)

// Clip adalah satu kiriman teks antarperangkat (mis. dari Mac ke HP).
type Clip struct {
	ID        int64  `json:"id"`
	UserID    int64  `json:"-"`
	Content   string `json:"content"`
	Device    string `json:"device"`
	SessionID int64  `json:"-"`
	CreatedAt string `json:"createdAt"`
}

const clipCols = `id, user_id, content, device, session_id, created_at`

func scanClip(row interface{ Scan(...any) error }) (Clip, error) {
	var c Clip
	err := row.Scan(&c.ID, &c.UserID, &c.Content, &c.Device, &c.SessionID, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

// ListClips: terbaru dulu. afterID > 0 = hanya yang lebih baru dari id itu.
func ListClips(q Q, userID, afterID int64, limit int) ([]Clip, error) {
	if limit <= 0 || limit > 200 {
		limit = 200
	}
	rows, err := q.Query(`SELECT `+clipCols+` FROM clips WHERE user_id = ? AND id > ? ORDER BY id DESC LIMIT ?`, userID, afterID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Clip{}
	for rows.Next() {
		c, err := scanClip(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func GetClip(q Q, userID, id int64) (Clip, error) {
	return scanClip(q.QueryRow(`SELECT `+clipCols+` FROM clips WHERE id = ? AND user_id = ?`, id, userID))
}

func InsertClip(q Q, c Clip) (Clip, error) {
	c.CreatedAt = Now()
	res, err := q.Exec(`INSERT INTO clips (user_id, content, device, session_id, created_at) VALUES (?, ?, ?, ?, ?)`,
		c.UserID, c.Content, c.Device, c.SessionID, c.CreatedAt)
	if err != nil {
		return c, err
	}
	c.ID, _ = res.LastInsertId()
	return c, nil
}

func DeleteClip(q Q, userID, id int64) error {
	res, err := q.Exec(`DELETE FROM clips WHERE id = ? AND user_id = ?`, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func ClearClips(q Q, userID int64) error {
	_, err := q.Exec(`DELETE FROM clips WHERE user_id = ?`, userID)
	return err
}

// TrimClips menyisakan keep kiriman terbaru milik pengguna.
func TrimClips(q Q, userID int64, keep int) error {
	_, err := q.Exec(`DELETE FROM clips WHERE user_id = ? AND id NOT IN
		(SELECT id FROM clips WHERE user_id = ? ORDER BY id DESC LIMIT ?)`, userID, userID, keep)
	return err
}

// PruneClips membuang kiriman yang lebih tua dari stempel before (semua pengguna).
func (d *DB) PruneClips(before string) error {
	_, err := d.Exec(`DELETE FROM clips WHERE created_at < ?`, before)
	return err
}

// --- kotak masuk notifikasi ------------------------------------------------------

// InboxItem: salinan satu notifikasi yang dikirim server (payload JSON push.Notification).
type InboxItem struct {
	ID              int64
	UserID          int64
	Payload         string
	ExceptSessionID int64
	CreatedAt       string
}

func (d *DB) InsertNotification(userID, exceptSession int64, payload string) (int64, error) {
	res, err := d.Exec(`INSERT INTO notifications (user_id, payload, except_session_id, created_at) VALUES (?, ?, ?, ?)`,
		userID, payload, exceptSession, Now())
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// ListNotifications: notifikasi setelah afterID (urutan lama → baru), maksimal limit.
func (d *DB) ListNotifications(userID, afterID int64, limit int) ([]InboxItem, error) {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	rows, err := d.Query(`SELECT id, user_id, payload, except_session_id, created_at FROM notifications
		WHERE user_id = ? AND id > ? ORDER BY id LIMIT ?`, userID, afterID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []InboxItem{}
	for rows.Next() {
		var n InboxItem
		if err := rows.Scan(&n.ID, &n.UserID, &n.Payload, &n.ExceptSessionID, &n.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// LastNotificationID: id notifikasi terakhir pengguna (0 = belum ada).
func (d *DB) LastNotificationID(userID int64) (int64, error) {
	var id sql.NullInt64
	err := d.QueryRow(`SELECT MAX(id) FROM notifications WHERE user_id = ?`, userID).Scan(&id)
	return id.Int64, err
}

func (d *DB) PruneNotifications(before string) error {
	_, err := d.Exec(`DELETE FROM notifications WHERE created_at < ?`, before)
	return err
}

// --- token FCM (aplikasi Android) ------------------------------------------------

type FCMToken struct {
	ID        int64
	UserID    int64
	SessionID int64
	Token     string
}

func (d *DB) UpsertFCMToken(t FCMToken) error {
	// Satu token per sesi perangkat: token lama sesi ini diganti.
	if _, err := d.Exec(`DELETE FROM fcm_tokens WHERE session_id = ? AND token != ?`, t.SessionID, t.Token); err != nil {
		return err
	}
	_, err := d.Exec(`INSERT INTO fcm_tokens (user_id, session_id, token, created_at) VALUES (?, ?, ?, ?)
		ON CONFLICT(token) DO UPDATE SET user_id = excluded.user_id, session_id = excluded.session_id`,
		t.UserID, t.SessionID, t.Token, Now())
	return err
}

func (d *DB) DeleteFCMToken(userID int64, token string) error {
	_, err := d.Exec(`DELETE FROM fcm_tokens WHERE user_id = ? AND token = ?`, userID, token)
	return err
}

func (d *DB) DeleteFCMTokenByID(id int64) error {
	_, err := d.Exec(`DELETE FROM fcm_tokens WHERE id = ?`, id)
	return err
}

func (d *DB) FCMTokensForUser(userID int64) ([]FCMToken, error) {
	rows, err := d.Query(`SELECT id, user_id, COALESCE(session_id, 0), token FROM fcm_tokens WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FCMToken{}
	for rows.Next() {
		var t FCMToken
		if err := rows.Scan(&t.ID, &t.UserID, &t.SessionID, &t.Token); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
