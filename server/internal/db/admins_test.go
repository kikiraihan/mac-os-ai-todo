package db

import (
	"path/filepath"
	"testing"
	"time"
)

// Database lama: admin = baris users ber-role admin yang juga punya todo.
// Setelah migrasi: akun admin terpisah (password sama), baris users tetap ada
// sebagai pengguna biasa beserta todo & sesinya.
func TestSplitAdminsMigration(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	now := Now()
	res, err := d.Exec(`INSERT INTO users (username, display_name, password_hash, role, created_at, updated_at)
		VALUES ('kiki', 'Kiki', 'hash-lama', 'admin', ?, ?)`, now, now)
	if err != nil {
		t.Fatal(err)
	}
	uid, _ := res.LastInsertId()
	if _, err := d.Exec(`INSERT INTO todos (user_id, title, created_at, updated_at) VALUES (?, 'todo lama', ?, ?)`, uid, now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := d.CreateSession(Session{UserID: uid, Kind: SessionDevice, Name: "Mac", ExpiresAt: Stamp(time.Now().AddDate(1, 0, 0))}, "h1"); err != nil {
		t.Fatal(err)
	}
	if err := d.SetSetting("admins_split", "0"); err != nil { // seolah database dari versi lama
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ { // idempoten
		if err := d.splitAdmins(); err != nil {
			t.Fatal(err)
		}
		d.SetSetting("admins_split", "0")
	}
	a, err := d.GetAdminByUsername("kiki")
	if err != nil || a.PasswordHash != "hash-lama" || a.DisplayName != "Kiki" {
		t.Fatalf("admin: %+v %v", a, err)
	}
	if n, _ := d.CountAdmins(); n != 1 {
		t.Fatalf("admins: %d", n)
	}
	u, err := d.GetUser(uid)
	if err != nil || u.Role != RoleUser {
		t.Fatalf("user: %+v %v", u, err)
	}
	var todos int
	d.QueryRow(`SELECT COUNT(*) FROM todos WHERE user_id = ?`, uid).Scan(&todos)
	ss, _ := d.ListSessions(uid)
	if todos != 1 || len(ss) != 1 {
		t.Fatalf("data pengguna hilang: todos=%d sesi=%d", todos, len(ss))
	}
}
