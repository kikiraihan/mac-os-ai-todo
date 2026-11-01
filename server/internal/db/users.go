package db

import (
	"database/sql"
	"errors"
)

const (
	RoleAdmin = "admin"
	RoleUser  = "user"

	SessionWeb    = "web"
	SessionDevice = "device"
)

type User struct {
	ID           int64  `json:"id"`
	Username     string `json:"username"`
	DisplayName  string `json:"displayName"`
	Role         string `json:"role"`
	Timezone     string `json:"timezone"`
	Disabled     bool   `json:"disabled"`
	CreatedAt    string `json:"createdAt"`
	PasswordHash string `json:"-"`
}

type Session struct {
	ID         int64  `json:"id"`
	UserID     int64  `json:"-"`
	Kind       string `json:"kind"`
	Name       string `json:"name"`
	UserAgent  string `json:"userAgent"`
	CreatedAt  string `json:"createdAt"`
	LastSeenAt string `json:"lastSeenAt"`
	ExpiresAt  string `json:"expiresAt"`
}

const userCols = `id, username, display_name, password_hash, role, timezone, disabled, created_at`

func scanUser(row interface{ Scan(...any) error }) (User, error) {
	var u User
	var disabled int
	err := row.Scan(&u.ID, &u.Username, &u.DisplayName, &u.PasswordHash, &u.Role, &u.Timezone, &disabled, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return u, ErrNotFound
	}
	u.Disabled = disabled == 1
	return u, err
}

func (d *DB) CountUsers() (int, error) {
	var n int
	err := d.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n)
	return n, err
}

func (d *DB) CountActiveAdmins() (int, error) {
	var n int
	err := d.QueryRow(`SELECT COUNT(*) FROM users WHERE role = 'admin' AND disabled = 0`).Scan(&n)
	return n, err
}

func (d *DB) CreateUser(u User) (User, error) {
	now := Now()
	res, err := d.Exec(`INSERT INTO users (username, display_name, password_hash, role, timezone, disabled, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, u.Username, u.DisplayName, u.PasswordHash, u.Role, u.Timezone, boolInt(u.Disabled), now, now)
	if err != nil {
		return u, err
	}
	u.ID, _ = res.LastInsertId()
	u.CreatedAt = now
	return u, nil
}

func (d *DB) GetUser(id int64) (User, error) {
	return scanUser(d.QueryRow(`SELECT `+userCols+` FROM users WHERE id = ?`, id))
}

func (d *DB) GetUserByUsername(username string) (User, error) {
	return scanUser(d.QueryRow(`SELECT `+userCols+` FROM users WHERE username = ?`, username))
}

func (d *DB) ListUsers() ([]User, error) {
	rows, err := d.Query(`SELECT ` + userCols + ` FROM users ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []User{}
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (d *DB) UpdateUser(u User) error {
	_, err := d.Exec(`UPDATE users SET display_name = ?, role = ?, timezone = ?, disabled = ?, updated_at = ? WHERE id = ?`,
		u.DisplayName, u.Role, u.Timezone, boolInt(u.Disabled), Now(), u.ID)
	return err
}

func (d *DB) SetPassword(userID int64, hash string) error {
	_, err := d.Exec(`UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?`, hash, Now(), userID)
	return err
}

func (d *DB) DeleteUser(id int64) error {
	_, err := d.Exec(`DELETE FROM users WHERE id = ?`, id)
	return err
}

// --- sessions -----------------------------------------------------------------

const sessionCols = `id, user_id, kind, name, user_agent, created_at, last_seen_at, expires_at`

func scanSession(row interface{ Scan(...any) error }) (Session, error) {
	var s Session
	err := row.Scan(&s.ID, &s.UserID, &s.Kind, &s.Name, &s.UserAgent, &s.CreatedAt, &s.LastSeenAt, &s.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return s, ErrNotFound
	}
	return s, err
}

func (d *DB) CreateSession(s Session, tokenHash string) (Session, error) {
	now := Now()
	res, err := d.Exec(`INSERT INTO sessions (user_id, token_hash, kind, name, user_agent, created_at, last_seen_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, s.UserID, tokenHash, s.Kind, s.Name, s.UserAgent, now, now, s.ExpiresAt)
	if err != nil {
		return s, err
	}
	s.ID, _ = res.LastInsertId()
	s.CreatedAt, s.LastSeenAt = now, now
	return s, nil
}

// SessionByTokenHash mengembalikan sesi yang masih berlaku beserta penggunanya.
func (d *DB) SessionByTokenHash(hash string) (Session, User, error) {
	s, err := scanSession(d.QueryRow(`SELECT `+sessionCols+` FROM sessions WHERE token_hash = ? AND expires_at > ?`, hash, Now()))
	if err != nil {
		return s, User{}, err
	}
	u, err := d.GetUser(s.UserID)
	return s, u, err
}

func (d *DB) TouchSession(id int64, expiresAt string) error {
	_, err := d.Exec(`UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE id = ?`, Now(), expiresAt, id)
	return err
}

func (d *DB) ListSessions(userID int64) ([]Session, error) {
	rows, err := d.Query(`SELECT `+sessionCols+` FROM sessions WHERE user_id = ? AND expires_at > ? ORDER BY last_seen_at DESC`, userID, Now())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Session{}
	for rows.Next() {
		s, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (d *DB) DeleteSession(userID, id int64) error {
	res, err := d.Exec(`DELETE FROM sessions WHERE id = ? AND user_id = ?`, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteUserSessions mengeluarkan pengguna dari semua perangkat, kecuali keepID.
func (d *DB) DeleteUserSessions(userID, keepID int64) error {
	_, err := d.Exec(`DELETE FROM sessions WHERE user_id = ? AND id != ?`, userID, keepID)
	return err
}

func (d *DB) PruneSessions() error {
	_, err := d.Exec(`DELETE FROM sessions WHERE expires_at <= ?`, Now())
	return err
}
