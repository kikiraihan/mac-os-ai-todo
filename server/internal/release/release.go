// Package release mengambil rilis aplikasi Mac dari GitHub untuk diteruskan ke
// aplikasi Mac lewat server ini. Repo boleh private: token GitHub (read-only)
// hanya dibaca dari environment, tidak pernah dikirim ke klien atau ditulis ke log.
//
// Host-nya tetap api.github.com (tidak bisa diganti lewat env), dan hanya file
// rilis yang ada di Assets yang boleh diunduh — server tidak menjadi proxy umum.
package release

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"sync"
	"time"
)

// Assets: satu-satunya file rilis yang boleh diteruskan ke klien.
var Assets = []string{"AITodo.zip", "AITodo.zip.sig"}

// MaxAssetSize: batas ukuran satu file rilis yang diteruskan.
const MaxAssetSize = 200 << 20

const (
	githubAPI = "https://api.github.com"
	cacheOK   = 10 * time.Minute
	cacheFail = time.Minute
)

var (
	// ErrDisabled: GITHUB_RELEASE_REPO kosong → fitur update lewat server mati.
	ErrDisabled = errors.New("pembaruan lewat server belum diatur (GITHUB_RELEASE_REPO)")
	// ErrNoRelease: repo belum punya rilis, atau token tidak punya akses ke repo private.
	ErrNoRelease = errors.New("rilis tidak ditemukan (belum ada rilis, atau GITHUB_RELEASE_TOKEN belum diatur / tidak punya akses)")
	// ErrNoAsset: nama file di luar Assets, atau tidak ada di rilis terbaru.
	ErrNoAsset = errors.New("file rilis tidak ada")

	// owner diawali huruf/angka; nama repo tidak boleh "." / ".." (path traversal di URL API).
	repoPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]*/([A-Za-z0-9_-][A-Za-z0-9_.-]*|\.[A-Za-z0-9_-][A-Za-z0-9_.-]*)$`)
)

// Info: ringkasan rilis terbaru yang aman dikirim ke klien.
type Info struct {
	Version     string `json:"version"` // tag rilis apa adanya, mis. "v0.10.2" (ikut ditandatangani)
	PublishedAt string `json:"publishedAt"`
	Page        string `json:"page"` // halaman rilis di GitHub (butuh login kalau repo private)
	Zip         bool   `json:"zip"`
	Sig         bool   `json:"sig"`

	assets map[string]int64 // nama → id aset GitHub (tidak dikirim ke klien)
}

type Service struct {
	Repo  string // owner/nama
	token string
	// API & HTTP bisa diganti di tes; produksi selalu api.github.com.
	API  string
	HTTP *http.Client

	mu      sync.Mutex
	cached  *Info
	err     error
	fetched time.Time
}

// New: repo kosong → fitur mati (ErrDisabled). Token boleh kosong untuk repo publik.
func New(repo, token string) (*Service, error) {
	if repo != "" && !repoPattern.MatchString(repo) {
		return nil, fmt.Errorf("GITHUB_RELEASE_REPO %q tidak valid (format: owner/nama)", repo)
	}
	return &Service{Repo: repo, token: token, API: githubAPI, HTTP: &http.Client{Timeout: 10 * time.Minute}}, nil
}

// HasToken: untuk log saat start (tanpa menampilkan isinya).
func (s *Service) HasToken() bool { return s.token != "" }

func (s *Service) request(ctx context.Context, url, accept string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "AITodo-Server")
	if s.token != "" {
		// Go membuang header Authorization saat redirect ke host lain (unduhan aset
		// dialihkan ke penyimpanan GitHub), jadi token tidak bocor ke sana.
		req.Header.Set("Authorization", "Bearer "+s.token)
	}
	return s.HTTP.Do(req)
}

// Latest mengembalikan rilis terbaru (cache 10 menit; kegagalan di-cache 1 menit).
func (s *Service) Latest(ctx context.Context) (Info, error) {
	if s == nil || s.Repo == "" {
		return Info{}, ErrDisabled
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	age := time.Since(s.fetched)
	if s.cached != nil && age < cacheOK {
		return *s.cached, nil
	}
	if s.err != nil && age < cacheFail {
		return Info{}, s.err
	}
	info, err := s.fetch(ctx)
	s.fetched = time.Now()
	if err != nil {
		s.cached, s.err = nil, err
		return Info{}, err
	}
	s.cached, s.err = &info, nil
	return info, nil
}

func (s *Service) fetch(ctx context.Context) (Info, error) {
	resp, err := s.request(ctx, s.API+"/repos/"+s.Repo+"/releases/latest", "application/vnd.github+json")
	if err != nil {
		return Info{}, fmt.Errorf("hubungi GitHub: %w", err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusNotFound:
		return Info{}, ErrNoRelease
	case resp.StatusCode == http.StatusUnauthorized:
		return Info{}, errors.New("GITHUB_RELEASE_TOKEN ditolak GitHub (kedaluwarsa / salah)")
	case resp.StatusCode != http.StatusOK:
		return Info{}, fmt.Errorf("GitHub menjawab HTTP %d", resp.StatusCode)
	}
	var r struct {
		Tag         string `json:"tag_name"`
		Page        string `json:"html_url"`
		PublishedAt string `json:"published_at"`
		Assets      []struct {
			ID   int64  `json:"id"`
			Name string `json:"name"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&r); err != nil || r.Tag == "" {
		return Info{}, errors.New("jawaban GitHub tidak dikenali")
	}
	info := Info{Version: r.Tag, Page: r.Page, PublishedAt: r.PublishedAt, assets: map[string]int64{}}
	for _, a := range r.Assets {
		for _, allowed := range Assets {
			if a.Name == allowed {
				info.assets[a.Name] = a.ID
			}
		}
	}
	_, info.Zip = info.assets["AITodo.zip"]
	_, info.Sig = info.assets["AITodo.zip.sig"]
	return info, nil
}

// Download menulis isi file rilis terbaru bernama name ke w. Hanya nama di Assets.
// size = ukuran dari GitHub (-1 kalau tidak diketahui), dipanggil sebelum isi ditulis.
func (s *Service) Download(ctx context.Context, name string, w io.Writer, size func(int64)) error {
	info, err := s.Latest(ctx)
	if err != nil {
		return err
	}
	id, ok := info.assets[name]
	if !ok {
		return ErrNoAsset
	}
	resp, err := s.request(ctx, fmt.Sprintf("%s/repos/%s/releases/assets/%d", s.API, s.Repo, id), "application/octet-stream")
	if err != nil {
		return fmt.Errorf("unduh dari GitHub: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unduh dari GitHub: HTTP %d", resp.StatusCode)
	}
	if resp.ContentLength > MaxAssetSize {
		return fmt.Errorf("file rilis terlalu besar (%d byte)", resp.ContentLength)
	}
	if size != nil {
		size(resp.ContentLength)
	}
	_, err = io.Copy(w, io.LimitReader(resp.Body, MaxAssetSize))
	return err
}
