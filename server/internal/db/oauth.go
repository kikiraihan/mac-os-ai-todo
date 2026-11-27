package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"time"
)

// OAuthClient: klien MCP yang mendaftar sendiri (RFC 7591), mis. claude.ai.
// Mendaftar tidak memberi akses apa pun — akses baru ada setelah pengguna
// menyetujui di halaman izin.
type OAuthClient struct {
	ClientID     string   `json:"clientId"`
	Name         string   `json:"name"`
	RedirectURIs []string `json:"redirectUris"`
	CreatedAt    string   `json:"createdAt"`
}

func (d *DB) CreateOAuthClient(c OAuthClient) (OAuthClient, error) {
	c.CreatedAt = Now()
	uris, _ := json.Marshal(c.RedirectURIs)
	_, err := d.Exec(`INSERT INTO oauth_clients (client_id, name, redirect_uris, created_at) VALUES (?, ?, ?, ?)`,
		c.ClientID, c.Name, string(uris), c.CreatedAt)
	return c, err
}

func (d *DB) GetOAuthClient(clientID string) (OAuthClient, error) {
	var c OAuthClient
	var uris string
	err := d.QueryRow(`SELECT client_id, name, redirect_uris, created_at FROM oauth_clients WHERE client_id = ?`, clientID).
		Scan(&c.ClientID, &c.Name, &uris, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	if err != nil {
		return c, err
	}
	err = json.Unmarshal([]byte(uris), &c.RedirectURIs)
	return c, err
}

func (d *DB) TouchOAuthClient(clientID string) {
	d.Exec(`UPDATE oauth_clients SET last_used_at = ? WHERE client_id = ?`, Now(), clientID)
}

func (d *DB) CountOAuthClients() (int, error) {
	var n int
	err := d.QueryRow(`SELECT COUNT(*) FROM oauth_clients`).Scan(&n)
	return n, err
}

// OAuthCode: kode otorisasi sekali pakai (10 menit), terikat ke PKCE challenge.
type OAuthCode struct {
	ClientID    string
	UserID      int64
	RedirectURI string
	Challenge   string
	Scope       string
	Resource    string
	ExpiresAt   string
}

func (d *DB) InsertOAuthCode(hash string, c OAuthCode) error {
	_, err := d.Exec(`INSERT INTO oauth_codes (code_hash, client_id, user_id, redirect_uri, challenge, scope, resource, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, hash, c.ClientID, c.UserID, c.RedirectURI, c.Challenge, c.Scope, c.Resource, c.ExpiresAt)
	return err
}

// TakeOAuthCode mengambil & sekaligus menghapus kode (tidak bisa dipakai dua kali).
func (d *DB) TakeOAuthCode(hash string) (OAuthCode, error) {
	var c OAuthCode
	err := d.QueryRow(`DELETE FROM oauth_codes WHERE code_hash = ? AND expires_at > ?
		RETURNING client_id, user_id, redirect_uri, challenge, scope, resource, expires_at`, hash, Now()).
		Scan(&c.ClientID, &c.UserID, &c.RedirectURI, &c.Challenge, &c.Scope, &c.Resource, &c.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

// OAuthRefresh: refresh token milik satu sesi MCP.
type OAuthRefresh struct {
	SessionID int64
	ClientID  string
	ExpiresAt string
}

func (d *DB) InsertOAuthRefresh(hash string, r OAuthRefresh) error {
	_, err := d.Exec(`INSERT INTO oauth_refresh (token_hash, session_id, client_id, expires_at) VALUES (?, ?, ?, ?)`,
		hash, r.SessionID, r.ClientID, r.ExpiresAt)
	return err
}

// TakeOAuthRefresh mengambil & menghapus refresh token (rotasi: setiap refresh memberi token baru).
func (d *DB) TakeOAuthRefresh(hash string) (OAuthRefresh, error) {
	var r OAuthRefresh
	err := d.QueryRow(`DELETE FROM oauth_refresh WHERE token_hash = ? AND expires_at > ?
		RETURNING session_id, client_id, expires_at`, hash, Now()).Scan(&r.SessionID, &r.ClientID, &r.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return r, ErrNotFound
	}
	return r, err
}

// SessionByID (tanpa user_id): hanya untuk refresh OAuth, setelah refresh token terbukti sah.
func (d *DB) SessionByID(id int64) (Session, User, error) {
	s, err := scanSession(d.QueryRow(`SELECT `+sessionCols+` FROM sessions WHERE id = ? AND expires_at > ?`, id, Now()))
	if err != nil {
		return s, User{}, err
	}
	u, err := d.GetUser(s.UserID)
	return s, u, err
}

// PruneOAuth membuang kode & refresh token kedaluwarsa, dan klien yang 30 hari
// tidak pernah dipakai serta tidak punya sesi.
func (d *DB) PruneOAuth() error {
	now := Now()
	if _, err := d.Exec(`DELETE FROM oauth_codes WHERE expires_at <= ?`, now); err != nil {
		return err
	}
	if _, err := d.Exec(`DELETE FROM oauth_refresh WHERE expires_at <= ?`, now); err != nil {
		return err
	}
	old := Stamp(time.Now().Add(-30 * 24 * time.Hour))
	_, err := d.Exec(`DELETE FROM oauth_clients WHERE created_at < ? AND (last_used_at = '' OR last_used_at < ?)
		AND client_id NOT IN (SELECT client_id FROM sessions WHERE client_id != '')`, old, old)
	return err
}
