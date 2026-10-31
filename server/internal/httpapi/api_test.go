package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"aitodo/server/internal/ai"
	"aitodo/server/internal/db"
	"aitodo/server/internal/push"
)

type client struct {
	t      *testing.T
	h      http.Handler
	cookie *http.Cookie
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
	if c.bearer != "" {
		req.Header.Set("Authorization", "Bearer "+c.bearer)
	}
	rec := httptest.NewRecorder()
	c.h.ServeHTTP(rec, req)
	for _, ck := range rec.Result().Cookies() {
		if ck.Name == cookieName {
			if ck.MaxAge < 0 {
				c.cookie = nil
			} else {
				c.cookie = ck
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

func mkUser(t *testing.T, s *Server, name, role string) {
	t.Helper()
	hash, _ := HashPassword("password-panjang-1")
	if _, err := s.DB.CreateUser(db.User{Username: name, PasswordHash: hash, Role: role}); err != nil {
		t.Fatal(err)
	}
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
	mkUser(t, s, "budi", db.RoleUser)
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
	if code, _ := c.do("GET", "/api/admin/users", nil, true); code != 403 {
		t.Fatalf("user must not reach admin: %d", code)
	}
	c.do("POST", "/api/logout", nil, true)
	if code, _ := c.do("GET", "/api/todos", nil, true); code != 401 {
		t.Fatalf("after logout: %d", code)
	}
}

func TestLoginRateLimit(t *testing.T) {
	s, h := newTestServer(t)
	mkUser(t, s, "budi", db.RoleUser)
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
	mkUser(t, s, "budi", db.RoleUser)
	mkUser(t, s, "siti", db.RoleUser)
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

func TestLastAdminGuardAndNoKeyLeak(t *testing.T) {
	s, h := newTestServer(t)
	mkUser(t, s, "admin", db.RoleAdmin)
	a := login(t, h, "admin")
	_, users := a.do("GET", "/api/admin/users", nil, true)
	id := int64(users["users"].([]any)[0].(map[string]any)["id"].(float64))
	if code, _ := a.do("PUT", "/api/admin/users/"+itoa(id), map[string]any{"role": "user"}, true); code != 400 {
		t.Fatalf("self demote: %d", code)
	}
	if code, _ := a.do("DELETE", "/api/admin/users/"+itoa(id), nil, true); code != 400 {
		t.Fatalf("self delete: %d", code)
	}
	if code, _ := a.do("POST", "/api/admin/ai/models", map[string]any{"provider": "kenari", "modelId": "x:free",
		"extraBody": `{"model":"hijack"}`}, true); code != 400 {
		t.Fatalf("extra body overriding model must be rejected: %d", code)
	}
	code, out := a.do("GET", "/api/admin/ai", nil, true)
	raw, _ := json.Marshal(out)
	if code != 200 || strings.Contains(string(raw), "apiKey") || strings.Contains(string(raw), "API_KEY") {
		t.Fatalf("admin ai: %d %s", code, raw)
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
