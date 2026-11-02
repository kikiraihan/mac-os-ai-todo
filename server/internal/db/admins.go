package db

import (
	"database/sql"
	"errors"
)

// Admin adalah akun pengelola server (pengguna, model AI, log). Terpisah dari
// User: tidak punya todo/chat/ingatan, sesinya di tabel admin_sessions, dan
// hanya bisa dibuat dari server (env/CLI) atau oleh admin lain.
type Admin struct {
	ID           int64  `json:"id"`
	Username     string `json:"username"`
	DisplayName  string `json:"displayName"`
	Disabled     bool   `json:"disabled"`
	CreatedAt    string `json:"createdAt"`
	PasswordHash string `json:"-"`
}

type AdminSession struct {
	ID         int64  `json:"id"`
	AdminID    int64  `json:"-"`
	UserAgent  string `json:"userAgent"`
	CreatedAt  string `json:"createdAt"`
	LastSeenAt string `json:"lastSeenAt"`
	ExpiresAt  string `json:"expiresAt"`
}

const adminCols = `id, username, display_name, password_hash, disabled, created_at`

func scanAdmin(row interface{ Scan(...any) error }) (Admin, error) {
	var a Admin
	var disabled int
	err := row.Scan(&a.ID, &a.Username, &a.DisplayName, &a.PasswordHash, &disabled, &a.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return a, ErrNotFound
	}
	a.Disabled = disabled == 1
	return a, err
}

// splitAdmins memindahkan akun ber-role admin lama ke tabel admins (sekali).
// Baris users-nya tetap ada sebagai pengguna biasa — todo, chat, ingatan, dan
// sesi perangkat (aplikasi Mac) tidak berubah — sedangkan akun admin baru
// memakai username & password yang sama, jadi tinggal masuk ulang di /admin.
func (d *DB) splitAdmins() error {
	const key = "admins_split"
	if v, err := d.GetSetting(key); err != nil || v == "1" {
		return err
	}
	return d.Tx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO admins (username, display_name, password_hash, disabled, created_at, updated_at)
			SELECT username, display_name, password_hash, disabled, created_at, updated_at FROM users WHERE role = 'admin'`); err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE users SET role = 'user' WHERE role != 'user'`); err != nil {
			return err
		}
		_, err := tx.Exec(`INSERT INTO settings (key, value) VALUES (?, '1')
			ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key)
		return err
	})
}

func (d *DB) CountAdmins() (int, error) {
	var n int
	err := d.QueryRow(`SELECT COUNT(*) FROM admins`).Scan(&n)
	return n, err
}

func (d *DB) CountActiveAdmins() (int, error) {
	var n int
	err := d.QueryRow(`SELECT COUNT(*) FROM admins WHERE disabled = 0`).Scan(&n)
	return n, err
}

func (d *DB) CreateAdmin(a Admin) (Admin, error) {
	now := Now()
	res, err := d.Exec(`INSERT INTO admins (username, display_name, password_hash, disabled, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)`, a.Username, a.DisplayName, a.PasswordHash, boolInt(a.Disabled), now, now)
	if err != nil {
		return a, err
	}
	a.ID, _ = res.LastInsertId()
	a.CreatedAt = now
	return a, nil
}

func (d *DB) GetAdmin(id int64) (Admin, error) {
	return scanAdmin(d.QueryRow(`SELECT `+adminCols+` FROM admins WHERE id = ?`, id))
}

func (d *DB) GetAdminByUsername(username string) (Admin, error) {
	return scanAdmin(d.QueryRow(`SELECT `+adminCols+` FROM admins WHERE username = ?`, username))
}

func (d *DB) ListAdmins() ([]Admin, error) {
	rows, err := d.Query(`SELECT ` + adminCols + ` FROM admins ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Admin{}
	for rows.Next() {
		a, err := scanAdmin(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func (d *DB) UpdateAdmin(a Admin) error {
	_, err := d.Exec(`UPDATE admins SET display_name = ?, disabled = ?, updated_at = ? WHERE id = ?`,
		a.DisplayName, boolInt(a.Disabled), Now(), a.ID)
	return err
}

func (d *DB) SetAdminPassword(id int64, hash string) error {
	_, err := d.Exec(`UPDATE admins SET password_hash = ?, updated_at = ? WHERE id = ?`, hash, Now(), id)
	return err
}

func (d *DB) DeleteAdmin(id int64) error {
	_, err := d.Exec(`DELETE FROM admins WHERE id = ?`, id)
	return err
}

// --- sesi admin ------------------------------------------------------------------

const adminSessionCols = `id, admin_id, user_agent, created_at, last_seen_at, expires_at`

func (d *DB) CreateAdminSession(s AdminSession, tokenHash string) (AdminSession, error) {
	now := Now()
	res, err := d.Exec(`INSERT INTO admin_sessions (admin_id, token_hash, user_agent, created_at, last_seen_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?)`, s.AdminID, tokenHash, s.UserAgent, now, now, s.ExpiresAt)
	if err != nil {
		return s, err
	}
	s.ID, _ = res.LastInsertId()
	s.CreatedAt, s.LastSeenAt = now, now
	return s, nil
}

// AdminSessionByTokenHash mengembalikan sesi admin yang masih berlaku beserta akunnya.
func (d *DB) AdminSessionByTokenHash(hash string) (AdminSession, Admin, error) {
	var s AdminSession
	err := d.QueryRow(`SELECT `+adminSessionCols+` FROM admin_sessions WHERE token_hash = ? AND expires_at > ?`, hash, Now()).
		Scan(&s.ID, &s.AdminID, &s.UserAgent, &s.CreatedAt, &s.LastSeenAt, &s.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return s, Admin{}, ErrNotFound
	}
	if err != nil {
		return s, Admin{}, err
	}
	a, err := d.GetAdmin(s.AdminID)
	return s, a, err
}

func (d *DB) TouchAdminSession(id int64, expiresAt string) error {
	_, err := d.Exec(`UPDATE admin_sessions SET last_seen_at = ?, expires_at = ? WHERE id = ?`, Now(), expiresAt, id)
	return err
}

func (d *DB) DeleteAdminSession(id int64) error {
	_, err := d.Exec(`DELETE FROM admin_sessions WHERE id = ?`, id)
	return err
}

// DeleteAdminSessions mengeluarkan admin dari semua browser, kecuali keepID.
func (d *DB) DeleteAdminSessions(adminID, keepID int64) error {
	_, err := d.Exec(`DELETE FROM admin_sessions WHERE admin_id = ? AND id != ?`, adminID, keepID)
	return err
}

// TrimAdminSessions menyisakan max sesi terbaru milik satu admin.
func (d *DB) TrimAdminSessions(adminID int64, max int) error {
	_, err := d.Exec(`DELETE FROM admin_sessions WHERE admin_id = ? AND id NOT IN
		(SELECT id FROM admin_sessions WHERE admin_id = ? ORDER BY last_seen_at DESC, id DESC LIMIT ?)`, adminID, adminID, max)
	return err
}
