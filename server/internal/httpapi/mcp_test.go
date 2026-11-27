package httpapi

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
)

type fakeWaker struct {
	mu   sync.Mutex
	nids []int64
}

func (f *fakeWaker) Wake(token string, nid int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nids = append(f.nids, nid)
	return nil
}

func deviceLogin(t *testing.T, h http.Handler, name string) *client {
	t.Helper()
	c := &client{t: t, h: h}
	code, out := c.do("POST", "/api/login/device", map[string]string{"username": name, "password": "password-panjang-1", "device": "Pixel"}, true)
	if code != 200 && code != 201 {
		t.Fatalf("device login: %d %v", code, out)
	}
	c.bearer = out["token"].(string)
	return c
}

func TestClipsInboxAndFCM(t *testing.T) {
	s, h := newTestServer(t)
	waker := &fakeWaker{}
	s.Push.FCM = waker
	mkUser(t, s, "budi")
	mkUser(t, s, "siti")
	web := login(t, h, "budi")
	phone := deviceLogin(t, h, "budi")

	// Awal: hanya nomor terakhir, tanpa isi.
	code, out := phone.do("GET", "/api/notifications", nil, true)
	if code != 200 || len(out["items"].([]any)) != 0 {
		t.Fatalf("inbox awal: %d %v", code, out)
	}
	last := int64(out["last"].(float64))

	if code, _ := web.do("POST", "/api/push/fcm", map[string]string{"token": "dGVzdA:APA91bH-token-panjang"}, true); code != 400 {
		t.Fatalf("browser tidak boleh daftar FCM: %d", code)
	}
	if code, out := phone.do("POST", "/api/push/fcm", map[string]string{"token": "dGVzdA:APA91bH-token-panjang"}, true); code != 200 {
		t.Fatalf("daftar FCM: %d %v", code, out)
	}
	if code, _ := web.do("POST", "/api/clips", map[string]string{"content": "   "}, true); code != 400 {
		t.Fatal("kiriman kosong harus ditolak")
	}
	code, out = web.do("POST", "/api/clips", map[string]string{"content": "ssh root@10.0.0.1\n"}, true)
	if code != 200 {
		t.Fatalf("kirim: %d %v", code, out)
	}
	clipID := int64(out["clip"].(map[string]any)["id"].(float64))
	if len(waker.nids) != 1 {
		t.Fatalf("FCM harus dibangunkan sekali, dapat %v", waker.nids)
	}

	code, out = phone.do("GET", fmt.Sprintf("/api/notifications?after=%d", last), nil, true)
	items := out["items"].([]any)
	if code != 200 || len(items) != 1 {
		t.Fatalf("inbox HP: %d %v", code, out)
	}
	n := items[0].(map[string]any)
	if n["kind"] != "clip" || n["text"] != "ssh root@10.0.0.1\n" || int64(n["clipId"].(float64)) != clipID ||
		int64(n["id"].(float64)) != waker.nids[0] || n["title"] != "Kiriman dari Browser" {
		t.Fatalf("isi notifikasi: %v", n)
	}
	// Pengirim tidak mendapat notifikasi kirimannya sendiri.
	_, out = web.do("GET", fmt.Sprintf("/api/notifications?after=%d", last), nil, true)
	if len(out["items"].([]any)) != 0 {
		t.Fatalf("pengirim ikut dapat: %v", out)
	}
	// Isolasi pengguna.
	siti := login(t, h, "siti")
	if code, _ := siti.do("GET", fmt.Sprintf("/api/clips/%d", clipID), nil, true); code != 404 {
		t.Fatalf("kiriman pengguna lain: %d", code)
	}
	_, out = siti.do("GET", "/api/notifications?after=0", nil, true)
	if len(out["items"].([]any)) != 0 {
		t.Fatal("kotak masuk pengguna lain bocor")
	}
	code, out = phone.do("GET", "/api/clips", nil, true)
	if code != 200 || len(out["clips"].([]any)) != 1 {
		t.Fatalf("daftar kiriman: %d %v", code, out)
	}
	if code, _ := phone.do("DELETE", fmt.Sprintf("/api/clips/%d", clipID), nil, true); code != 200 {
		t.Fatal("hapus kiriman")
	}
	// Batas jumlah: hanya 50 terbaru disimpan.
	for i := 0; i < 55; i++ {
		web.do("POST", "/api/clips", map[string]string{"content": fmt.Sprintf("isi %d", i)}, true)
	}
	_, out = phone.do("GET", "/api/clips", nil, true)
	if len(out["clips"].([]any)) != 50 {
		t.Fatalf("pangkas kiriman: %d", len(out["clips"].([]any)))
	}
}

// --- MCP -----------------------------------------------------------------------------

type mcpClient struct {
	t      *testing.T
	h      http.Handler
	token  string
	origin string
	nextID int
}

func (m *mcpClient) raw(body string) (int, http.Header, map[string]any) {
	m.t.Helper()
	req := httptest.NewRequest("POST", "/mcp", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	if m.token != "" {
		req.Header.Set("Authorization", "Bearer "+m.token)
	}
	if m.origin != "" {
		req.Header.Set("Origin", m.origin)
	}
	rec := httptest.NewRecorder()
	m.h.ServeHTTP(rec, req)
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, rec.Header(), out
}

func (m *mcpClient) rpc(method string, params any) map[string]any {
	m.t.Helper()
	m.nextID++
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": m.nextID, "method": method, "params": params})
	code, _, out := m.raw(string(b))
	if code != 200 {
		m.t.Fatalf("%s: HTTP %d %v", method, code, out)
	}
	if out["error"] != nil {
		m.t.Fatalf("%s: %v", method, out["error"])
	}
	return out["result"].(map[string]any)
}

// call menjalankan tool; mengembalikan JSON hasil & apakah error.
func (m *mcpClient) call(name string, args any) (map[string]any, bool, string) {
	m.t.Helper()
	res := m.rpc("tools/call", map[string]any{"name": name, "arguments": args})
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	var out map[string]any
	json.Unmarshal([]byte(text), &out)
	return out, res["isError"] == true, text
}

func toolNames(res map[string]any) map[string]bool {
	out := map[string]bool{}
	for _, t := range res["tools"].([]any) {
		out[t.(map[string]any)["name"].(string)] = true
	}
	return out
}

func TestMCPManualToken(t *testing.T) {
	s, h := newTestServer(t)
	mkUser(t, s, "budi")
	web := login(t, h, "budi")

	anon := &mcpClient{t: t, h: h}
	code, hdr, _ := anon.raw(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)
	if code != 401 || !strings.Contains(hdr.Get("WWW-Authenticate"), "/.well-known/oauth-protected-resource") {
		t.Fatalf("tanpa token: %d %v", code, hdr)
	}

	// Token baca saja.
	code, out := web.do("POST", "/api/mcp/tokens", map[string]any{"name": "Claude Code"}, true)
	if code != 201 {
		t.Fatalf("buat token: %d %v", code, out)
	}
	ro := &mcpClient{t: t, h: h, token: out["token"].(string)}
	init := ro.rpc("initialize", map[string]any{"protocolVersion": "2025-03-26"})
	if init["protocolVersion"] != "2025-03-26" || !strings.Contains(init["instructions"].(string), "UTC") {
		t.Fatalf("initialize: %v", init)
	}
	names := toolNames(ro.rpc("tools/list", nil))
	if !names["list_todos"] || names["create_todo"] || names["send_to_devices"] {
		t.Fatalf("token baca tidak boleh melihat tool tulis: %v", names)
	}
	if _, isErr, _ := ro.call("create_todo", map[string]any{"title": "x"}); !isErr {
		t.Fatal("token baca menulis")
	}
	// Token MCP tidak berlaku di /api/.
	if code, _ := (&client{t: t, h: h, bearer: ro.token}).do("GET", "/api/todos", nil, true); code != 401 {
		t.Fatalf("token MCP di /api/: %d", code)
	}
	// Cookie browser tidak berlaku di /mcp.
	req := httptest.NewRequest("POST", "/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	req.AddCookie(web.cookie)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 401 {
		t.Fatalf("cookie di /mcp: %d", rec.Code)
	}

	// Token tulis.
	_, out = web.do("POST", "/api/mcp/tokens", map[string]any{"name": "Claude Desktop", "write": true}, true)
	rw := &mcpClient{t: t, h: h, token: out["token"].(string)}
	sessID := int64(out["session"].(map[string]any)["id"].(float64))
	if code, _, _ := rw.raw(`{"jsonrpc":"2.0","method":"notifications/initialized"}`); code != 202 {
		t.Fatalf("notifikasi harus 202, dapat %d", code)
	}
	names = toolNames(rw.rpc("tools/list", nil))
	for _, n := range []string{"create_todo", "create_reminder", "send_to_devices", "get_context"} {
		if !names[n] {
			t.Fatalf("tool %s hilang", n)
		}
	}
	for n := range names {
		if strings.Contains(n, "delete") {
			t.Fatalf("tidak boleh ada tool hapus: %s", n)
		}
	}
	res, isErr, text := rw.call("create_todo", map[string]any{"title": "Bayar listrik", "due_date": "2099-01-02", "due_time": "09:00"})
	if isErr {
		t.Fatalf("create_todo: %s", text)
	}
	todoID := res["todo"].(map[string]any)["id"].(float64)
	if _, isErr, _ := rw.call("create_todo", map[string]any{"title": "x", "due_time": "09:00"}); !isErr {
		t.Fatal("validasi core harus berlaku (jam tanpa tanggal)")
	}
	if _, isErr, _ := rw.call("create_todo", map[string]any{"title": "x", "hapus_semua": true}); !isErr {
		t.Fatal("argumen asing harus ditolak")
	}
	res, _, _ = rw.call("list_todos", map[string]any{})
	if len(res["todos"].([]any)) != 1 {
		t.Fatalf("list_todos: %v", res)
	}
	// Todo terlihat di aplikasi (form manual), sumbernya "mcp".
	_, out = web.do("GET", "/api/todos", nil, true)
	if out["todos"].([]any)[0].(map[string]any)["source"] != "mcp" {
		t.Fatalf("source: %v", out)
	}
	res, isErr, text = rw.call("create_reminder", map[string]any{"title": "Telepon ibu", "at": "2099-03-04T15:30", "todo_id": todoID})
	if isErr || res["reminder"].(map[string]any)["next_fire"] != "2099-03-04 15:30" {
		t.Fatalf("create_reminder: %s", text)
	}
	if _, isErr, _ := rw.call("create_reminder", map[string]any{"title": "lewat", "at": "2000-01-01T10:00"}); !isErr {
		t.Fatal("waktu lewat harus ditolak")
	}
	if _, isErr, text := rw.call("create_reminder", map[string]any{"title": "Minum air", "schedule": map[string]any{"kind": "daily", "time": "08:00"}}); isErr {
		t.Fatalf("jadwal harian: %s", text)
	}
	if res, isErr, text := rw.call("send_to_devices", map[string]any{"text": "halo dari Claude"}); isErr || res["clip_id"] == nil {
		t.Fatalf("send_to_devices: %s", text)
	}
	_, out = web.do("GET", "/api/clips", nil, true)
	if c := out["clips"].([]any)[0].(map[string]any); c["content"] != "halo dari Claude" || c["device"] != "Claude Desktop" {
		t.Fatalf("kiriman dari MCP: %v", c)
	}
	// Origin asing ditolak (DNS rebinding).
	evil := &mcpClient{t: t, h: h, token: rw.token, origin: "https://jahat.example"}
	if code, _, _ := evil.raw(`{"jsonrpc":"2.0","id":1,"method":"ping"}`); code != 403 {
		t.Fatalf("origin asing: %d", code)
	}
	// Isolasi: token budi tidak melihat todo siti.
	mkUser(t, s, "siti")
	siti := login(t, h, "siti")
	siti.do("POST", "/api/todos", map[string]string{"title": "rahasia siti"}, true)
	res, _, text = rw.call("list_todos", map[string]any{"status": "all"})
	if strings.Contains(text, "rahasia siti") {
		t.Fatal("data pengguna lain bocor lewat MCP")
	}
	// Cabut token dari Pengaturan → langsung tidak berlaku.
	if code, _ := web.do("DELETE", fmt.Sprintf("/api/sessions/%d", sessID), nil, true); code != 200 {
		t.Fatalf("cabut: %d", code)
	}
	if code, _, _ := rw.raw(`{"jsonrpc":"2.0","id":1,"method":"ping"}`); code != 401 {
		t.Fatalf("token dicabut masih jalan: %d", code)
	}
}

// --- OAuth ---------------------------------------------------------------------------

func form(t *testing.T, h http.Handler, path string, v url.Values) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest("POST", path, strings.NewReader(v.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func TestOAuthFlow(t *testing.T) {
	s, h := newTestServer(t)
	s.Cfg.PublicURL = "https://todo.example"
	mkUser(t, s, "budi")
	web := login(t, h, "budi")

	get := func(path string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		return rec
	}
	var meta map[string]any
	json.Unmarshal(get("/.well-known/oauth-authorization-server").Body.Bytes(), &meta)
	if meta["issuer"] != "https://todo.example" || meta["token_endpoint"] != "https://todo.example/oauth/token" {
		t.Fatalf("metadata: %v", meta)
	}
	json.Unmarshal(get("/.well-known/oauth-protected-resource").Body.Bytes(), &meta)
	if meta["resource"] != "https://todo.example/mcp" {
		t.Fatalf("resource metadata: %v", meta)
	}

	// Pendaftaran klien.
	reg := func(body string) (int, map[string]any) {
		req := httptest.NewRequest("POST", "/oauth/register", strings.NewReader(body))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		var out map[string]any
		json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out
	}
	if code, _ := reg(`{"client_name":"Jahat","redirect_uris":["http://jahat.example/cb"]}`); code != 400 {
		t.Fatal("redirect http non-loopback harus ditolak")
	}
	code, out := reg(`{"client_name":"Claude","redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}`)
	if code != 201 {
		t.Fatalf("register: %d %v", code, out)
	}
	clientID := out["client_id"].(string)
	redirect := "https://claude.ai/api/mcp/auth_callback"
	verifier := strings.Repeat("v", 50)
	sum := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	q := url.Values{"response_type": {"code"}, "client_id": {clientID}, "redirect_uri": {redirect},
		"code_challenge": {challenge}, "code_challenge_method": {"S256"}, "state": {"xyz"}, "scope": {"read write"},
		"resource": {"https://todo.example/mcp"}}

	// redirect_uri lain tidak pernah dipakai sebagai tujuan.
	bad := url.Values{}
	for k, v := range q {
		bad[k] = v
	}
	bad.Set("redirect_uri", "https://jahat.example/cb")
	if loc := get("/oauth/authorize?" + bad.Encode()).Header().Get("Location"); !strings.HasPrefix(loc, "/izinkan?error=") {
		t.Fatalf("redirect asing: %q", loc)
	}
	if loc := get("/oauth/authorize?" + q.Encode()).Header().Get("Location"); loc != "/izinkan?"+q.Encode() {
		t.Fatalf("authorize: %q", loc)
	}
	code, out = web.do("GET", "/api/oauth/request?"+q.Encode(), nil, true)
	if code != 200 || out["clientName"] != "Claude" || out["redirectHost"] != "claude.ai" {
		t.Fatalf("info permintaan: %d %v", code, out)
	}
	// Token perangkat tidak boleh menyetujui (harus orangnya di browser).
	phone := deviceLogin(t, h, "budi")
	if code, _ := phone.do("POST", "/api/oauth/approve", map[string]any{"query": q.Encode(), "allow": true}, true); code != 403 {
		t.Fatalf("setuju dari token perangkat: %d", code)
	}
	code, out = web.do("POST", "/api/oauth/approve", map[string]any{"query": q.Encode(), "allow": true, "write": true}, true)
	if code != 200 {
		t.Fatalf("approve: %d %v", code, out)
	}
	dest, _ := url.Parse(out["redirect"].(string))
	if dest.Host != "claude.ai" || dest.Query().Get("state") != "xyz" || dest.Query().Get("code") == "" {
		t.Fatalf("redirect: %v", dest)
	}
	authCode := dest.Query().Get("code")

	tok := url.Values{"grant_type": {"authorization_code"}, "code": {authCode}, "client_id": {clientID},
		"redirect_uri": {redirect}, "code_verifier": {strings.Repeat("x", 50)}}
	if code, _ := form(t, h, "/oauth/token", tok); code != 400 {
		t.Fatal("verifier salah harus ditolak")
	}
	// Kode sudah terpakai (sekali pakai, walau percobaan tadi gagal) → minta kode baru.
	_, out = web.do("POST", "/api/oauth/approve", map[string]any{"query": q.Encode(), "allow": true, "write": true}, true)
	dest, _ = url.Parse(out["redirect"].(string))
	tok.Set("code", dest.Query().Get("code"))
	tok.Set("code_verifier", verifier)
	code, out = form(t, h, "/oauth/token", tok)
	if code != 200 || out["token_type"] != "Bearer" || out["scope"] != "read write" {
		t.Fatalf("token: %d %v", code, out)
	}
	if code, _ := form(t, h, "/oauth/token", tok); code != 400 {
		t.Fatal("kode dipakai dua kali")
	}
	access, refresh := out["access_token"].(string), out["refresh_token"].(string)
	m := &mcpClient{t: t, h: h, token: access}
	if _, isErr, text := m.call("create_todo", map[string]any{"title": "dari claude.ai"}); isErr {
		t.Fatalf("akses OAuth: %s", text)
	}

	// Refresh dirotasi: token lama mati.
	ref := url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {clientID}}
	code, out = form(t, h, "/oauth/token", ref)
	if code != 200 {
		t.Fatalf("refresh: %d %v", code, out)
	}
	if code, _ := form(t, h, "/oauth/token", ref); code != 400 {
		t.Fatal("refresh token lama masih berlaku")
	}
	if code, _, _ := m.raw(`{"jsonrpc":"2.0","id":1,"method":"ping"}`); code != 401 {
		t.Fatal("access token lama masih berlaku setelah refresh")
	}
	m.token = out["access_token"].(string)
	m.rpc("ping", nil)

	// Cabut di Pengaturan → akses & refresh mati.
	_, sess := web.do("GET", "/api/sessions", nil, true)
	var mcpID float64
	for _, x := range sess["sessions"].([]any) {
		if x.(map[string]any)["kind"] == "mcp" {
			mcpID = x.(map[string]any)["id"].(float64)
		}
	}
	web.do("DELETE", fmt.Sprintf("/api/sessions/%d", int64(mcpID)), nil, true)
	ref.Set("refresh_token", out["refresh_token"].(string))
	if code, _ := form(t, h, "/oauth/token", ref); code != 400 {
		t.Fatal("refresh setelah dicabut")
	}
	if code, _, _ := m.raw(`{"jsonrpc":"2.0","id":1,"method":"ping"}`); code != 401 {
		t.Fatal("akses setelah dicabut")
	}

	// Tolak = error access_denied ke aplikasi.
	_, out = web.do("POST", "/api/oauth/approve", map[string]any{"query": q.Encode(), "allow": false}, true)
	if !strings.Contains(out["redirect"].(string), "error=access_denied") {
		t.Fatalf("tolak: %v", out)
	}
}
