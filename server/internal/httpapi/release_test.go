package httpapi

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"aitodo/server/internal/release"
)

func TestMacRelease(t *testing.T) {
	s, h := newTestServer(t)
	mkUser(t, s, "budi")
	anon := &client{t: t, h: h}
	if code, _ := anon.do("GET", "/api/app/mac/latest", nil, true); code != 401 {
		t.Fatalf("tanpa login harus 401: %d", code)
	}
	c := login(t, h, "budi")
	if code, _ := c.do("GET", "/api/app/mac/latest", nil, true); code != 501 {
		t.Fatalf("fitur belum diatur harus 501: %d", code)
	}

	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tkn" {
			http.NotFound(w, r)
			return
		}
		switch r.URL.Path {
		case "/repos/o/r/releases/latest":
			fmt.Fprint(w, `{"tag_name":"v9.0.0","html_url":"https://github.com/o/r/releases/tag/v9.0.0",
				"assets":[{"id":1,"name":"AITodo.zip"},{"id":2,"name":"AITodo.zip.sig"},{"id":3,"name":"AITodo.apk"}]}`)
		case "/repos/o/r/releases/assets/1":
			fmt.Fprint(w, "ZIP")
		case "/repos/o/r/releases/assets/3":
			fmt.Fprint(w, "APK")
		default:
			http.NotFound(w, r)
		}
	}))
	defer gh.Close()
	rel, err := release.New("o/r", "tkn")
	if err != nil {
		t.Fatal(err)
	}
	rel.API = gh.URL
	s.Release = rel

	code, out := c.do("GET", "/api/app/mac/latest", nil, true)
	if code != 200 || out["version"] != "v9.0.0" || out["zip"] != true || out["sig"] != true {
		t.Fatalf("latest: %d %v", code, out)
	}
	for k := range out {
		if k != "version" && k != "publishedAt" && k != "page" && k != "zip" && k != "sig" && k != "apk" {
			t.Fatalf("field tak terduga dikirim ke klien: %q", k)
		}
	}

	req := httptest.NewRequest("GET", "/api/app/mac/download/AITodo.zip", nil)
	req.Header.Set(csrfHeader, "1")
	req.AddCookie(c.cookie)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 200 || rec.Body.String() != "ZIP" || rec.Header().Get("Content-Type") != "application/octet-stream" {
		t.Fatalf("download: %d %q %q", rec.Code, rec.Body.String(), rec.Header().Get("Content-Type"))
	}
	if code, _ := c.do("GET", "/api/app/mac/download/..%2F..%2Fetc", nil, true); code != 404 {
		t.Fatalf("nama file asing harus 404: %d", code)
	}
	if code, _ := anon.do("GET", "/api/app/mac/download/AITodo.zip", nil, true); code != 401 {
		t.Fatalf("unduh tanpa login harus 401: %d", code)
	}

	// Tautan unduh APK dari web: navigasi browser biasa (tanpa header X-AITodo), wajib login.
	if _, out := c.do("GET", "/api/app/android/latest", nil, true); out["apk"] != true {
		t.Fatalf("android latest: %v", out)
	}
	req = httptest.NewRequest("GET", "/unduh/AITodo.apk", nil)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != "/masuk?next=%2Faplikasi" {
		t.Fatalf("APK tanpa login harus ke halaman masuk: %d %q", rec.Code, rec.Header().Get("Location"))
	}
	req = httptest.NewRequest("GET", "/unduh/AITodo.apk", nil)
	req.AddCookie(c.cookie)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 200 || rec.Body.String() != "APK" || rec.Header().Get("Content-Type") != "application/vnd.android.package-archive" {
		t.Fatalf("unduh APK: %d %q %q", rec.Code, rec.Body.String(), rec.Header().Get("Content-Type"))
	}
}
