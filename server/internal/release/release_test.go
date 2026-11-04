package release

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
)

// fakeGitHub: rilis terbaru + unduhan aset yang dialihkan ke host lain (seperti
// api.github.com → objects.githubusercontent.com). leaked mencatat header
// Authorization yang sampai ke host penyimpanan.
func fakeGitHub(t *testing.T, private bool) (*Service, *atomic.Value, *atomic.Int32) {
	t.Helper()
	var leaked atomic.Value
	leaked.Store("")
	storage := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		leaked.Store(r.Header.Get("Authorization"))
		fmt.Fprint(w, "ISI-ZIP")
	}))
	t.Cleanup(storage.Close)
	su, _ := url.Parse(storage.URL)
	// "localhost" ≠ "127.0.0.1" → bagi Go ini host lain, sama seperti GitHub → penyimpanan.
	blob := "http://localhost:" + su.Port() + "/blob"

	var calls atomic.Int32
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if private && r.Header.Get("Authorization") != "Bearer rahasia" {
			http.NotFound(w, r) // repo private tanpa token → 404, sama seperti GitHub
			return
		}
		switch r.URL.Path {
		case "/repos/o/r/releases/latest":
			calls.Add(1)
			fmt.Fprint(w, `{"tag_name":"v1.2.3","html_url":"https://github.com/o/r/releases/tag/v1.2.3",
				"published_at":"2026-11-04T00:00:00Z","assets":[{"id":7,"name":"AITodo.zip"},{"id":9,"name":"lain.txt"}]}`)
		case "/repos/o/r/releases/assets/7":
			if r.Header.Get("Accept") != "application/octet-stream" {
				t.Errorf("Accept = %q", r.Header.Get("Accept"))
			}
			http.Redirect(w, r, blob, http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(api.Close)
	token := ""
	if private {
		token = "rahasia"
	}
	s, err := New("o/r", token)
	if err != nil {
		t.Fatal(err)
	}
	s.API = api.URL
	return s, &leaked, &calls
}

func TestLatestAndDownloadPrivate(t *testing.T) {
	s, leaked, calls := fakeGitHub(t, true)
	ctx := context.Background()
	info, err := s.Latest(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if info.Version != "v1.2.3" || !info.Zip || info.Sig {
		t.Fatalf("info = %+v", info)
	}
	if _, ok := info.assets["lain.txt"]; ok {
		t.Fatal("aset di luar daftar Assets tidak boleh dicatat")
	}
	s.Latest(ctx)
	if calls.Load() != 1 {
		t.Fatalf("Latest harus memakai cache, GitHub dipanggil %d kali", calls.Load())
	}

	var buf bytes.Buffer
	if err := s.Download(ctx, "AITodo.zip", &buf, nil); err != nil {
		t.Fatal(err)
	}
	if buf.String() != "ISI-ZIP" {
		t.Fatalf("isi = %q", buf.String())
	}
	if got := leaked.Load().(string); got != "" {
		t.Fatalf("token GitHub bocor ke host penyimpanan: %q", got)
	}
	if err := s.Download(ctx, "AITodo.zip.sig", &buf, nil); !errors.Is(err, ErrNoAsset) {
		t.Fatalf("aset yang tidak ada: %v", err)
	}
	if err := s.Download(ctx, "lain.txt", &buf, nil); !errors.Is(err, ErrNoAsset) {
		t.Fatalf("nama di luar Assets: %v", err)
	}
}

func TestPrivateWithoutToken(t *testing.T) {
	s, _, _ := fakeGitHub(t, true)
	s.token = ""
	if _, err := s.Latest(context.Background()); !errors.Is(err, ErrNoRelease) {
		t.Fatalf("repo private tanpa token: %v", err)
	}
}

func TestDisabledAndValidation(t *testing.T) {
	var nilSvc *Service
	if _, err := nilSvc.Latest(context.Background()); !errors.Is(err, ErrDisabled) {
		t.Fatalf("nil: %v", err)
	}
	s, _ := New("", "")
	if _, err := s.Latest(context.Background()); !errors.Is(err, ErrDisabled) {
		t.Fatalf("repo kosong: %v", err)
	}
	for _, bad := range []string{"o", "o/r/x", "https://github.com/o/r", "o/r?x=1", "../r", "o/..", "o/."} {
		if _, err := New(bad, ""); err == nil {
			t.Errorf("repo %q harus ditolak", bad)
		}
	}
}

func TestValidRepoNames(t *testing.T) {
	for _, ok := range []string{"kikiraihan/mac-os-ai-todo", "o/.github", "a-b/c_d.e"} {
		if _, err := New(ok, ""); err != nil {
			t.Errorf("repo %q harus diterima: %v", ok, err)
		}
	}
}
