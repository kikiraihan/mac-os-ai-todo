package push

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"aitodo/server/internal/db"
)

func TestSubscriberClaim(t *testing.T) {
	for in, want := range map[string]string{
		"mailto:admin@example.com":   "admin@example.com",
		" MAILTO: admin@example.com": "admin@example.com",
		"admin@example.com":          "admin@example.com",
		"https://todo.example.com":   "https://todo.example.com",
	} {
		if got := subscriberClaim(in); got != want {
			t.Errorf("subscriberClaim(%q) = %q, mau %q", in, got, want)
		}
	}
}

func TestAllowedEndpoint(t *testing.T) {
	for ep, want := range map[string]bool{
		"https://fcm.googleapis.com/fcm/send/abc":            true,
		"https://jmt17.google.com/fcm/send/abc:APA91b":       true,
		"https://jmt17.google.com/search?q=x":                false,
		"https://jmt17.google.com:8443/fcm/send/abc":         false,
		"https://google.com.evil.com/fcm/send/abc":           false,
		"https://web.push.apple.com/QAbc":                    true,
		"https://updates.push.services.mozilla.com/wpush/v2": true,
		"http://fcm.googleapis.com/fcm/send/abc":             false,
		"https://evil.example.com/x":                         false,
		"https://push.apple.com.evil.com/x":                  false,
	} {
		if got := AllowedEndpoint(ep); got != want {
			t.Errorf("AllowedEndpoint(%q) = %v, mau %v", ep, got, want)
		}
	}
}

// fakeSub membuat kunci langganan sungguhan (P-256 + auth 16 byte) seperti yang dibuat browser.
func fakeSub(t *testing.T) (p256dh, auth string) {
	t.Helper()
	k, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	a := make([]byte, 16)
	rand.Read(a)
	enc := base64.RawURLEncoding
	return enc.EncodeToString(k.PublicKey().Bytes()), enc.EncodeToString(a)
}

// jwtClaims membaca klaim dari header "Authorization: vapid t=<jwt>, k=<kunci>".
func jwtClaims(t *testing.T, header string) map[string]any {
	t.Helper()
	i := strings.Index(header, "t=")
	if !strings.HasPrefix(header, "vapid ") || i < 0 {
		t.Fatalf("header Authorization tak dikenal: %q", header)
	}
	tok := strings.SplitN(header[i+2:], ",", 2)[0]
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("JWT rusak: %q", tok)
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var c map[string]any
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}
	return c
}

func TestSendToUser(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	u, err := d.CreateUser(db.User{Username: "budi", PasswordHash: "x"})
	if err != nil {
		t.Fatal(err)
	}
	sess, err := d.CreateSession(db.Session{UserID: u.ID, Kind: db.SessionWeb, ExpiresAt: "2999-01-01T00:00:00Z"}, "hash")
	if err != nil {
		t.Fatal(err)
	}
	svc, err := New(d, "mailto:admin@example.com")
	if err != nil {
		t.Fatal(err)
	}

	// Layanan push tiruan: status per jalur, catat klaim JWT & header.
	var mu sync.Mutex
	status := map[string]int{"/ok": 201, "/gone": 410, "/jwt": 403}
	var claims []map[string]any
	var headers []http.Header
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		claims = append(claims, jwtClaims(t, r.Header.Get("Authorization")))
		headers = append(headers, r.Header.Clone())
		code := status[r.URL.Path]
		mu.Unlock()
		w.WriteHeader(code)
		if code == 403 {
			w.Write([]byte(`{"reason":"BadJwtToken"}`))
		}
	}))
	defer ts.Close()
	svc.allow = func(string) bool { return true }
	svc.client = ts.Client()

	add := func(path string) {
		p, a := fakeSub(t)
		if err := d.UpsertPushSub(db.PushSub{UserID: u.ID, SessionID: sess.ID, Endpoint: ts.URL + path, P256dh: p, Auth: a}); err != nil {
			t.Fatal(err)
		}
	}
	has := func(path string) bool {
		ok, err := d.HasPushSub(u.ID, ts.URL+path)
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}

	if _, err := svc.SendToUser(u.ID, Notification{Title: "x"}); err == nil || !strings.Contains(err.Error(), "belum ada perangkat") {
		t.Fatalf("tanpa langganan: err = %v", err)
	}

	add("/ok")
	add("/gone")
	add("/jwt")
	n, err := svc.SendToUser(u.ID, Notification{Title: "Bayar listrik", Body: "jam 9", TodoID: 7})
	if err != nil || n != 1 {
		t.Fatalf("SendToUser = %d, %v; mau 1, nil", n, err)
	}
	for _, c := range claims {
		if c["sub"] != "mailto:admin@example.com" {
			t.Errorf("klaim sub = %v, mau mailto:admin@example.com (bukan mailto:mailto:)", c["sub"])
		}
		if !strings.HasPrefix(c["aud"].(string), "http://127.0.0.1") {
			t.Errorf("klaim aud = %v", c["aud"])
		}
	}
	for _, h := range headers {
		if h.Get("Content-Encoding") != "aes128gcm" || h.Get("TTL") == "" || h.Get("Urgency") != "high" {
			t.Errorf("header kurang: %v", h)
		}
	}
	if !has("/ok") {
		t.Error("langganan yang berhasil ikut terhapus")
	}
	if has("/gone") {
		t.Error("langganan 410 Gone harus dihapus")
	}
	if !has("/jwt") {
		t.Error("langganan 403 (masalah VAPID, bukan langganan mati) tidak boleh dihapus")
	}

	// Hanya langganan yang menolak tersisa → galat jelas, langganan tetap disimpan.
	d.DeletePushSub(u.ID, ts.URL+"/ok")
	if _, err := svc.SendToUser(u.ID, Notification{Title: "x"}); err == nil || !strings.Contains(err.Error(), "HTTP 403") {
		t.Fatalf("hanya 403: err = %v", err)
	}
	if !has("/jwt") {
		t.Error("langganan 403 terhapus")
	}

	// Semua kedaluwarsa → pesan "belum ada perangkat" (penjadwal tidak mencatatnya sebagai galat).
	d.DeletePushSub(u.ID, ts.URL+"/jwt")
	add("/gone")
	if _, err := svc.SendToUser(u.ID, Notification{Title: "x"}); err == nil || !strings.Contains(err.Error(), "belum ada perangkat") {
		t.Fatalf("semua kedaluwarsa: err = %v", err)
	}
}
