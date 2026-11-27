package fcm

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"aitodo/server/internal/push"
)

func testCreds(t *testing.T) []byte {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	p := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: must(x509.MarshalPKCS8PrivateKey(k))})
	b, _ := json.Marshal(map[string]string{"type": "service_account", "project_id": "aitodo-test",
		"private_key": string(p), "client_email": "fcm@aitodo-test.iam.gserviceaccount.com"})
	return b
}

func must(b []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return b
}

func TestLoadCredentials(t *testing.T) {
	raw := `{"type":"service_account"}`
	if b, _ := LoadCredentials(raw); string(b) != raw {
		t.Fatal("JSON langsung")
	}
	if b, _ := LoadCredentials(base64.StdEncoding.EncodeToString([]byte(raw))); string(b) != raw {
		t.Fatal("base64")
	}
	if _, err := LoadCredentials("bukan-apa-apa"); err == nil {
		t.Fatal("sampah harus ditolak")
	}
	if b, err := LoadCredentials(""); b != nil || err != nil {
		t.Fatal("kosong = mati")
	}
}

func TestNewRejectsBadCreds(t *testing.T) {
	for _, c := range []string{`{}`, `{"type":"service_account","project_id":"x","client_email":"a","private_key":"b"}`, `nope`} {
		if _, err := New([]byte(c), ClientConfig{}); err == nil {
			t.Fatalf("%s harus ditolak", c)
		}
	}
}

func TestWake(t *testing.T) {
	var tokenCalls, sendCalls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			tokenCalls.Add(1)
			b, _ := io.ReadAll(r.Body)
			if !strings.Contains(string(b), "assertion=") {
				t.Error("tanpa assertion")
			}
			w.Write([]byte(`{"access_token":"ya29.tes","expires_in":3600}`))
		case "/send":
			sendCalls.Add(1)
			if r.Header.Get("Authorization") != "Bearer ya29.tes" {
				t.Error("token akses tidak dikirim")
			}
			var in struct {
				Message struct {
					Token string            `json:"token"`
					Data  map[string]string `json:"data"`
				} `json:"message"`
			}
			json.NewDecoder(r.Body).Decode(&in)
			// Hanya nomor notifikasi yang boleh dikirim ke Google.
			if len(in.Message.Data) != 1 || in.Message.Data["nid"] != "42" {
				t.Errorf("data = %v", in.Message.Data)
			}
			if in.Message.Token == "mati" {
				w.WriteHeader(http.StatusNotFound)
				w.Write([]byte(`{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`))
				return
			}
			w.Write([]byte(`{"name":"projects/aitodo-test/messages/1"}`))
		}
	}))
	defer srv.Close()
	c, err := New(testCreds(t), ClientConfig{AppID: "1:2:android:3", APIKey: "AIza", SenderID: "2"})
	if err != nil {
		t.Fatal(err)
	}
	if !c.Ready() || c.Android.ProjectID != "aitodo-test" {
		t.Fatal("config Android")
	}
	c.tokenURL, c.sendURL = srv.URL+"/token", srv.URL+"/send"
	if err := c.Wake("hidup-token-panjang-sekali", 42); err != nil {
		t.Fatal(err)
	}
	if err := c.Wake("mati", 42); !errors.Is(err, push.ErrTokenGone) {
		t.Fatalf("token mati: %v", err)
	}
	if tokenCalls.Load() != 1 || sendCalls.Load() != 2 {
		t.Fatalf("token %d kali, kirim %d kali (token akses harus di-cache)", tokenCalls.Load(), sendCalls.Load())
	}
}

func TestValidToken(t *testing.T) {
	if !ValidToken("dGVzdA:APA91bH-abc_DEF.123456789") || ValidToken("pendek") || ValidToken("ada spasi di dalam token ini ya") {
		t.Fatal("ValidToken")
	}
}
