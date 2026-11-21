package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"aitodo/server/internal/ai"
	"aitodo/server/internal/applog"
	"aitodo/server/internal/db"
	"aitodo/server/internal/push"
)

type client struct {
	t      *testing.T
	h      http.Handler
	cookie *http.Cookie
	admin  *http.Cookie // cookie sesi admin (terpisah dari cookie pengguna)
	bearer string
}

func (c *client) do(method, path string, body any, csrf bool) (int, map[string]any) {
	c.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req := httptest.NewRequest(method, path, &buf)
	if csrf {
		req.Header.Set(csrfHeader, "1")
	}
	if c.cookie != nil {
		req.AddCookie(c.cookie)
	}
	// Browser hanya mengirim cookie admin ke path /api/admin.
	if c.admin != nil && strings.HasPrefix(path, c.admin.Path) {
		req.AddCookie(c.admin)
	}
	if c.bearer != "" {
		req.Header.Set("Authorization", "Bearer "+c.bearer)
	}
	rec := httptest.NewRecorder()
	c.h.ServeHTTP(rec, req)
	for _, ck := range rec.Result().Cookies() {
		switch ck.Name {
		case cookieName:
			if ck.MaxAge < 0 {
				c.cookie = nil
			} else {
				c.cookie = ck
			}
		case adminCookieName:
			if ck.MaxAge < 0 {
				c.admin = nil
			} else {
				c.admin = ck
			}
		}
	}
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func newTestServer(t *testing.T) (*Server, http.Handler) {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	p, err := push.New(d, "mailto:test@example.com")
	if err != nil {
		t.Fatal(err)
	}
	s := New(d, ai.NewRegistry(func(string) string { return "" }), p, Config{Version: "test", DefaultTZ: time.UTC})
	return s, SecurityHeaders(false, s.Mux)
}

func mkUser(t *testing.T, s *Server, name string) {
	t.Helper()
	hash, _ := HashPassword("password-panjang-1")
	if _, err := s.DB.CreateUser(db.User{Username: name, PasswordHash: hash}); err != nil {
		t.Fatal(err)
	}
}

// mkAdmin membuat akun admin (tabel admins) dengan password berbeda dari pengguna.
func mkAdmin(t *testing.T, s *Server, name string) {
	t.Helper()
	hash, _ := HashPassword("password-admin-123")
	if _, err := s.DB.CreateAdmin(db.Admin{Username: name, PasswordHash: hash}); err != nil {
		t.Fatal(err)
	}
}

func adminLogin(t *testing.T, h http.Handler, name string) *client {
	t.Helper()
	c := &client{t: t, h: h}
	code, _ := c.do("POST", "/api/admin/login", map[string]string{"username": name, "password": "password-admin-123"}, true)
	if code != 200 || c.admin == nil {
		t.Fatalf("admin login %s: %d", name, code)
	}
	if !c.admin.HttpOnly || c.admin.SameSite != http.SameSiteStrictMode || c.admin.Path != "/api/admin" {
		t.Fatalf("admin cookie must be HttpOnly + SameSite=Strict + Path=/api/admin: %+v", c.admin)
	}
	if c.cookie != nil {
		t.Fatal("admin login must not create a user session")
	}
	return c
}

func login(t *testing.T, h http.Handler, name string) *client {
	t.Helper()
	c := &client{t: t, h: h}
	code, _ := c.do("POST", "/api/login", map[string]string{"username": name, "password": "password-panjang-1"}, true)
	if code != 200 || c.cookie == nil {
		t.Fatalf("login %s: %d", name, code)
	}
	if !c.cookie.HttpOnly || c.cookie.SameSite != http.SameSiteStrictMode {
		t.Fatal("session cookie must be HttpOnly + SameSite=Strict")
	}
	return c
}

func TestCSRFAndAuth(t *testing.T) {
	s, h := newTestServer(t)
	mkUser(t, s, "budi")
	anon := &client{t: t, h: h}
	if code, _ := anon.do("GET", "/api/todos", nil, true); code != 401 {
		t.Fatalf("no session: %d", code)
	}
	c := login(t, h, "budi")
	if code, _ := c.do("POST", "/api/todos", map[string]string{"title": "x"}, false); code != 403 {
		t.Fatalf("missing CSRF header must be rejected, got %d", code)
	}
	if code, _ := c.do("POST", "/api/todos", map[string]string{"title": "beli galon"}, true); code != 200 {
		t.Fatalf("create todo: %d", code)
	}
	if code, _ := c.do("GET", "/api/admin/users", nil, true); code != 401 {
		t.Fatalf("user must not reach admin: %d", code)
	}
	c.do("POST", "/api/logout", nil, true)
	if code, _ := c.do("GET", "/api/todos", nil, true); code != 401 {
		t.Fatalf("after logout: %d", code)
	}
}

func TestLoginRateLimit(t *testing.T) {
	s, h := newTestServer(t)
	mkUser(t, s, "budi")
	c := &client{t: t, h: h}
	for i := 0; i < loginFailsPerIP; i++ {
		c.do("POST", "/api/login", map[string]string{"username": "budi", "password": "salah-salah-salah"}, true)
	}
	if code, _ := c.do("POST", "/api/login", map[string]string{"username": "budi", "password": "password-panjang-1"}, true); code != 429 {
		t.Fatalf("expected lockout, got %d", code)
	}
}

func TestUserIsolationAndDeviceToken(t *testing.T) {
	s, h := newTestServer(t)
	mkUser(t, s, "budi")
	mkUser(t, s, "siti")
	budi, siti := login(t, h, "budi"), login(t, h, "siti")
	_, out := budi.do("POST", "/api/todos", map[string]string{"title": "rahasia budi"}, true)
	id := int64(out["todo"].(map[string]any)["id"].(float64))
	path := "/api/todos/" + itoa(id)
	if code, _ := siti.do("PUT", path, map[string]string{"title": "dibajak"}, true); code != 404 {
		t.Fatalf("other user edit: %d", code)
	}
	if code, _ := siti.do("DELETE", path, nil, true); code != 404 {
		t.Fatalf("other user delete: %d", code)
	}
	_, list := siti.do("GET", "/api/todos", nil, true)
	if len(list["todos"].([]any)) != 0 {
		t.Fatal("siti sees budi's todos")
	}
	budi.do("POST", "/api/memory", map[string]string{"target": "profile", "content": "Suka kopi"}, true)
	_, mem := siti.do("GET", "/api/memory", nil, true)
	if len(mem["memories"].([]any)) != 0 {
		t.Fatal("memory leaked across users")
	}

	// Token perangkat (Mac) bekerja lewat Bearer dan bisa dicabut.
	_, dev := budi.do("POST", "/api/devices", map[string]string{"name": "MacBook"}, true)
	mac := &client{t: t, h: h, bearer: dev["token"].(string)}
	if code, _ := mac.do("GET", "/api/reminders/upcoming", nil, true); code != 200 {
		t.Fatalf("device token: %d", code)
	}
	sid := int64(dev["session"].(map[string]any)["id"].(float64))
	budi.do("DELETE", "/api/sessions/"+itoa(sid), nil, true)
	if code, _ := mac.do("GET", "/api/todos", nil, true); code != 401 {
		t.Fatalf("revoked device token still works: %d", code)
	}
}

func TestDeviceLogin(t *testing.T) {
	s, h := newTestServer(t)
	mkUser(t, s, "budi")
	c := &client{t: t, h: h}
	code, out := c.do("POST", "/api/login/device", map[string]string{"username": "budi", "password": "password-panjang-1", "device": "MacBook"}, true)
	if code != 200 || c.cookie != nil {
		t.Fatalf("device login: %d, cookie set: %v", code, c.cookie != nil)
	}
	mac := &client{t: t, h: h, bearer: out["token"].(string)}
	if code, _ := mac.do("GET", "/api/me", nil, true); code != 200 {
		t.Fatalf("device token: %d", code)
	}
	if code, _ := c.do("POST", "/api/login/device", map[string]string{"username": "budi", "password": "salah-salah-salah"}, true); code != 401 {
		t.Fatalf("wrong password: %d", code)
	}
}

func TestLastAdminGuardAndNoKeyLeak(t *testing.T) {
	s, h := newTestServer(t)
	mkAdmin(t, s, "admin")
	a := adminLogin(t, h, "admin")
	_, list := a.do("GET", "/api/admin/admins", nil, true)
	id := int64(list["admins"].([]any)[0].(map[string]any)["id"].(float64))
	if code, _ := a.do("PUT", "/api/admin/admins/"+itoa(id), map[string]any{"disabled": true}, true); code != 400 {
		t.Fatalf("self disable: %d", code)
	}
	if code, _ := a.do("DELETE", "/api/admin/admins/"+itoa(id), nil, true); code != 400 {
		t.Fatalf("self delete: %d", code)
	}
	// admin kedua: boleh dinonaktifkan; setelah itu admin pertama = admin aktif terakhir
	code, out := a.do("POST", "/api/admin/admins", map[string]any{"username": "admin2", "password": "password-admin-456"}, true)
	if code != 201 {
		t.Fatalf("create admin: %d %v", code, out)
	}
	id2 := int64(out["admin"].(map[string]any)["id"].(float64))
	a2 := &client{t: t, h: h}
	if code, _ := a2.do("POST", "/api/admin/login", map[string]string{"username": "admin2", "password": "password-admin-456"}, true); code != 200 {
		t.Fatalf("admin2 login: %d", code)
	}
	if code, _ := a.do("PUT", "/api/admin/admins/"+itoa(id2), map[string]any{"disabled": true}, true); code != 200 {
		t.Fatalf("disable admin2: %d", code)
	}
	if code, _ := a2.do("GET", "/api/admin/me", nil, true); code != 401 {
		t.Fatalf("disabled admin still logged in: %d", code)
	}
	if code, _ := a.do("POST", "/api/admin/ai/models", map[string]any{"provider": "kenari", "modelId": "x:free",
		"extraBody": `{"model":"hijack"}`}, true); code != 400 {
		t.Fatalf("extra body overriding model must be rejected: %d", code)
	}
	code, out = a.do("GET", "/api/admin/ai", nil, true)
	raw, _ := json.Marshal(out)
	if code != 200 || strings.Contains(string(raw), "apiKey") || strings.Contains(string(raw), "API_KEY") {
		t.Fatalf("admin ai: %d %s", code, raw)
	}
}

// Pengguna biasa tidak pernah bisa menjadi / bertindak sebagai admin, dan sesi
// admin tidak bisa membaca data pengguna.
func TestAdminUserSeparation(t *testing.T) {
	s, h := newTestServer(t)
	mkAdmin(t, s, "kiki")
	mkUser(t, s, "kiki") // orang yang sama: akun admin & pengguna, username sama, password beda
	mkUser(t, s, "budi")
	a := adminLogin(t, h, "kiki")
	u := login(t, h, "kiki")
	budi := login(t, h, "budi")

	// sesi admin tidak bisa memakai endpoint pengguna
	if code, _ := a.do("GET", "/api/todos", nil, true); code != 401 {
		t.Fatalf("admin session on user endpoint: %d", code)
	}
	// sesi pengguna (cookie / Bearer) tidak bisa memakai endpoint admin
	for _, p := range []string{"/api/admin/me", "/api/admin/users", "/api/admin/admins"} {
		if code, _ := u.do("GET", p, nil, true); code != 401 {
			t.Fatalf("user session on %s: %d", p, code)
		}
	}
	_, dev := u.do("POST", "/api/devices", map[string]string{"name": "Mac"}, true)
	mac := &client{t: t, h: h, bearer: dev["token"].(string)}
	if code, _ := mac.do("GET", "/api/admin/users", nil, true); code != 401 {
		t.Fatalf("device token on admin endpoint: %d", code)
	}
	// token pengguna ditaruh di cookie admin → ditolak (prefix & tabel berbeda)
	forged := &client{t: t, h: h, admin: &http.Cookie{Name: adminCookieName, Value: u.cookie.Value, Path: adminCookiePath}}
	if code, _ := forged.do("GET", "/api/admin/me", nil, true); code != 401 {
		t.Fatalf("user token as admin cookie: %d", code)
	}
	// token admin ditaruh sebagai cookie / Bearer pengguna → ditolak
	asUser := &client{t: t, h: h, cookie: &http.Cookie{Name: cookieName, Value: a.admin.Value}}
	if code, _ := asUser.do("GET", "/api/me", nil, true); code != 401 {
		t.Fatalf("admin token as user cookie: %d", code)
	}
	if code, _ := (&client{t: t, h: h, bearer: a.admin.Value}).do("GET", "/api/admin/me", nil, true); code != 401 {
		t.Fatalf("admin token via Bearer: %d", code)
	}
	// password pengguna tidak membuka akun admin dengan username sama
	if code, _ := (&client{t: t, h: h}).do("POST", "/api/admin/login",
		map[string]string{"username": "kiki", "password": "password-panjang-1"}, true); code != 401 {
		t.Fatalf("user password on admin login: %d", code)
	}
	if code, _ := (&client{t: t, h: h}).do("POST", "/api/admin/login",
		map[string]string{"username": "budi", "password": "password-panjang-1"}, true); code != 401 {
		t.Fatalf("user without admin account on admin login: %d", code)
	}
	// pengguna mencoba menaikkan peran sendiri → diabaikan
	budi.do("PUT", "/api/me", map[string]any{"role": "admin", "displayName": "Budi"}, true)
	_, me := budi.do("GET", "/api/me", nil, true)
	if me["user"].(map[string]any)["role"] != "user" {
		t.Fatalf("role changed via /api/me: %v", me)
	}
	// admin membuat pengguna dengan role admin → tetap pengguna biasa
	code, out := a.do("POST", "/api/admin/users", map[string]any{"username": "nakal", "password": "password-panjang-1", "role": "admin"}, true)
	if code != 201 || out["user"].(map[string]any)["role"] != "user" {
		t.Fatalf("create user with role admin: %d %v", code, out)
	}
	nakal := login(t, h, "nakal")
	if code, _ := nakal.do("GET", "/api/admin/stats", nil, true); code != 401 {
		t.Fatalf("user created with role=admin reaches admin: %d", code)
	}
	if n, _ := s.DB.CountAdmins(); n != 1 {
		t.Fatalf("admins: %d", n)
	}
	// keluar dari mode admin tidak mengeluarkan mode pengguna (dan sebaliknya)
	both := &client{t: t, h: h, cookie: u.cookie, admin: a.admin}
	both.do("POST", "/api/admin/logout", nil, true)
	if code, _ := both.do("GET", "/api/me", nil, true); code != 200 {
		t.Fatalf("user session after admin logout: %d", code)
	}
	if code, _ := both.do("GET", "/api/admin/me", nil, true); code != 401 {
		t.Fatalf("admin session after admin logout: %d", code)
	}
}

func TestSecurityHeaders(t *testing.T) {
	_, h := newTestServer(t)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/api/health", nil))
	csp := rec.Header().Get("Content-Security-Policy")
	if !strings.Contains(csp, "script-src 'self'") || strings.Contains(csp, "unsafe") || rec.Header().Get("X-Frame-Options") != "DENY" {
		t.Fatalf("headers: %v", rec.Header())
	}
}

func itoa(n int64) string { b, _ := json.Marshal(n); return string(b) }

func TestAdminLogs(t *testing.T) {
	s, h := newTestServer(t)
	s.SystemLog = applog.NewRing(10)
	fmt.Fprintln(s.SystemLog, "api: database is locked")
	mkAdmin(t, s, "admin")
	mkUser(t, s, "budi")
	s.DB.InsertAICall(db.AICall{Provider: "kenari", Model: "m", Operation: "chat", HTTPStatus: 200, OK: true})
	s.DB.InsertAICall(db.AICall{Provider: "kenari", Model: "m", Operation: "chat", HTTPStatus: 429, Error: "penuh"})

	u := login(t, h, "budi")
	for _, p := range []string{"/api/admin/ai-calls", "/api/admin/ai-calls/summary", "/api/admin/system-logs"} {
		if code, _ := u.do("GET", p, nil, true); code != 401 {
			t.Fatalf("%s: user biasa harus ditolak, dapat %d", p, code)
		}
	}
	a := adminLogin(t, h, "admin")
	code, out := a.do("GET", "/api/admin/ai-calls?status=error", nil, true)
	if code != 200 || out["total"].(float64) != 1 {
		t.Fatalf("list: %d %v", code, out)
	}
	code, out = a.do("GET", "/api/admin/ai-calls/summary?days=7", nil, true)
	if code != 200 || out["total"].(map[string]any)["calls"].(float64) != 2 {
		t.Fatalf("summary: %d %v", code, out)
	}
	code, out = a.do("GET", "/api/admin/system-logs?level=error", nil, true)
	if code != 200 || len(out["items"].([]any)) != 1 {
		t.Fatalf("system log: %d %v", code, out)
	}
	if code, _ := a.do("POST", "/api/admin/ai-calls/delete", map[string]any{}, true); code != 400 {
		t.Fatalf("hapus tanpa pilihan: %d", code)
	}
	code, out = a.do("POST", "/api/admin/ai-calls/delete", map[string]any{"all": true}, true)
	if code != 200 || out["deleted"].(float64) != 2 {
		t.Fatalf("hapus semua: %d %v", code, out)
	}
}

func TestNotesAPI(t *testing.T) {
	s, h := newTestServer(t)
	mkUser(t, s, "budi")
	mkUser(t, s, "siti")
	budi, siti := login(t, h, "budi"), login(t, h, "siti")
	code, out := budi.do("POST", "/api/notes", map[string]any{"content": "https://contoh.id/a\nlink bagus", "list": "Link"}, true)
	if code != 200 {
		t.Fatalf("create: %d %v", code, out)
	}
	n := out["note"].(map[string]any)
	if n["title"] != "https://contoh.id/a" || n["pinned"] != false {
		t.Fatalf("note %v", n)
	}
	path := "/api/notes/" + itoa(int64(n["id"].(float64)))
	if code, _ := budi.do("POST", "/api/notes", map[string]any{"title": "  "}, true); code != 400 {
		t.Fatalf("empty note: %d", code)
	}
	if code, out := budi.do("PUT", path, map[string]any{"pinned": true, "title": "Link bagus"}, true); code != 200 ||
		out["note"].(map[string]any)["pinned"] != true {
		t.Fatalf("pin: %d %v", code, out)
	}
	budi.do("POST", "/api/notes", map[string]any{"title": "Belanja bulanan"}, true)
	_, list := budi.do("GET", "/api/notes", nil, true)
	notes := list["notes"].([]any)
	if len(notes) != 2 || notes[0].(map[string]any)["title"] != "Link bagus" {
		t.Fatalf("list (disematkan dulu): %v", notes)
	}
	if _, q := budi.do("GET", "/api/notes?q=contoh.id", nil, true); len(q["notes"].([]any)) != 1 {
		t.Fatalf("search: %v", q)
	}
	// Pengguna lain tidak bisa melihat / mengubah / menghapus.
	if _, l := siti.do("GET", "/api/notes", nil, true); len(l["notes"].([]any)) != 0 {
		t.Fatal("siti sees budi's notes")
	}
	if code, _ := siti.do("PUT", path, map[string]any{"title": "dibajak"}, true); code != 404 {
		t.Fatalf("other user edit: %d", code)
	}
	if code, _ := siti.do("DELETE", path, nil, true); code != 404 {
		t.Fatalf("other user delete: %d", code)
	}
	if code, _ := budi.do("DELETE", path, nil, true); code != 200 {
		t.Fatalf("delete: %d", code)
	}
	if code, _ := budi.do("GET", "/api/notes", nil, false); code != 403 {
		t.Fatalf("no csrf header: %d", code)
	}
	// Isi maksimal (20.000 karakter) dengan huruf 4 byte tetap muat di batas body.
	big := strings.Repeat("😀", 20000)
	if code, out := budi.do("POST", "/api/notes", map[string]any{"title": "emoji", "content": big}, true); code != 200 {
		t.Fatalf("isi maksimal ditolak: %d %v", code, out)
	}
	if code, _ := budi.do("POST", "/api/notes", map[string]any{"title": "x", "content": big + "😀"}, true); code != 400 {
		t.Fatalf("isi kelebihan diterima: %d", code)
	}
}
