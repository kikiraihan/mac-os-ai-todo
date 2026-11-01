// Package ai memanggil provider AI OpenAI-compatible (kenari, Agnes AI,
// OpenRouter). Pola dan jebakan per provider mengikuti klien yang sudah teruji
// di katilidev (KenariClient, AgnesClient, OpenRouterClient).
//
// Keamanan: API key hanya dibaca dari environment, tidak pernah dikembalikan ke
// klien atau ditulis ke log, dan server hanya mau menghubungi host provider
// yang ada di allowlist (redirect tidak diikuti).
package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	ProviderKenari     = "kenari"
	ProviderAgnes      = "agnes"
	ProviderOpenRouter = "openrouter"

	maxResponseBytes = 4 << 20
)

// providerDefs: nama, base URL bawaan, host yang diizinkan, nama env key.
var providerDefs = []struct {
	Key, Name, BaseURL, EnvKey, EnvBase string
	Hosts                               []string
}{
	{ProviderKenari, "kenari", "https://kenari.id/v1", "KENARI_API_KEY", "KENARI_BASE_URL", []string{"kenari.id"}},
	{ProviderAgnes, "Agnes AI", "https://apihub.agnes-ai.com/v1", "AGNES_API_KEY", "AGNES_BASE_URL", []string{"apihub.agnes-ai.com"}},
	{ProviderOpenRouter, "OpenRouter", "https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", "OPENROUTER_BASE_URL", []string{"openrouter.ai"}},
}

type Provider struct {
	Key     string
	Name    string
	BaseURL string
	apiKey  string
	hosts   []string
}

// ProviderInfo aman dikirim ke halaman admin (tanpa key).
type ProviderInfo struct {
	Key     string `json:"key"`
	Name    string `json:"name"`
	BaseURL string `json:"baseUrl"`
	HasKey  bool   `json:"hasKey"`
}

type Registry struct {
	providers map[string]*Provider
	order     []string
	http      *http.Client
	// allowHost bisa diganti di test (httptest memakai 127.0.0.1).
	allowHost func(p *Provider, host string) bool
	// Referer & Title dikirim ke OpenRouter (opsional, untuk statistik mereka).
	Referer string
}

// NewRegistry membaca konfigurasi dari getenv (os.Getenv di produksi).
func NewRegistry(getenv func(string) string) *Registry {
	r := &Registry{providers: map[string]*Provider{}}
	for _, d := range providerDefs {
		p := &Provider{Key: d.Key, Name: d.Name, BaseURL: d.BaseURL, apiKey: strings.TrimSpace(getenv(d.EnvKey)), hosts: d.Hosts}
		if raw := strings.TrimSpace(getenv(d.EnvBase)); raw != "" {
			if u, err := checkBaseURL(raw, d.Hosts); err != nil {
				log.Printf("ai: %s=%q ditolak (%v), memakai %s", d.EnvBase, raw, err, d.BaseURL)
			} else {
				p.BaseURL = u
			}
		}
		r.providers[d.Key] = p
		r.order = append(r.order, d.Key)
	}
	r.http = &http.Client{
		Timeout: 45 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return errors.New("redirect tidak diikuti")
		},
	}
	r.allowHost = func(p *Provider, host string) bool { return hostAllowed(host, p.hosts) }
	return r
}

func checkBaseURL(raw string, hosts []string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	if u.Scheme != "https" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("harus https tanpa userinfo/query")
	}
	if !hostAllowed(u.Hostname(), hosts) {
		return "", fmt.Errorf("host %q tidak ada di allowlist", u.Hostname())
	}
	return strings.TrimRight(u.String(), "/"), nil
}

func hostAllowed(host string, hosts []string) bool {
	host = strings.ToLower(host)
	for _, h := range hosts {
		if host == h {
			return true
		}
	}
	return false
}

// Known melaporkan apakah key adalah provider yang dikenal.
func (r *Registry) Known(key string) bool { _, ok := r.providers[key]; return ok }

// HasKey melaporkan apakah provider punya API key.
func (r *Registry) HasKey(key string) bool {
	p, ok := r.providers[key]
	return ok && p.apiKey != ""
}

func (r *Registry) Providers() []ProviderInfo {
	out := make([]ProviderInfo, 0, len(r.order))
	for _, k := range r.order {
		p := r.providers[k]
		out = append(out, ProviderInfo{Key: p.Key, Name: p.Name, BaseURL: p.BaseURL, HasKey: p.apiKey != ""})
	}
	return out
}

func (r *Registry) ProviderName(key string) string {
	if p, ok := r.providers[key]; ok {
		return p.Name
	}
	return key
}

// Message adalah satu pesan chat OpenAI.
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
}

// Error dari provider. Retryable = boleh pindah ke model berikutnya.
type Error struct {
	Provider string
	Status   int
	Msg      string
}

func (e *Error) Error() string {
	if e.Status > 0 {
		return fmt.Sprintf("%s HTTP %d: %s", e.Provider, e.Status, e.Msg)
	}
	return e.Provider + ": " + e.Msg
}

// Rejected: model ditolak provider (bukan gangguan sementara).
func (e *Error) Rejected() bool {
	switch e.Status {
	case 400, 404, 410, 422:
		return true
	}
	return false
}

// ChatRequest: satu panggilan chat completion.
type ChatRequest struct {
	Provider  string
	Model     string
	ExtraBody string // JSON objek dari katalog, digabung ke body
	Messages  []Message
	MaxTokens int
	JSON      bool // minta output JSON bila provider mendukung
}

type ChatResult struct {
	Content string
	Usage   Usage
	Latency time.Duration
}

func (r *Registry) provider(key string) (*Provider, error) {
	p, ok := r.providers[key]
	if !ok {
		return nil, &Error{Provider: key, Msg: "provider tidak dikenal"}
	}
	if p.apiKey == "" {
		return nil, &Error{Provider: p.Name, Msg: "API key belum diisi di server"}
	}
	return p, nil
}

func (r *Registry) newRequest(ctx context.Context, p *Provider, method, path string, body []byte) (*http.Request, error) {
	u, err := url.Parse(p.BaseURL + path)
	if err != nil {
		return nil, err
	}
	if !r.allowHost(p, u.Hostname()) {
		return nil, &Error{Provider: p.Name, Msg: "host tidak diizinkan"}
	}
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), rd)
	if err != nil {
		return nil, err
	}
	if p.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+p.apiKey)
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if p.Key == ProviderOpenRouter && r.Referer != "" {
		req.Header.Set("HTTP-Referer", r.Referer)
		req.Header.Set("X-Title", "AI Todo")
	}
	return req, nil
}

// Chat memanggil satu model. Tidak ada fallback di sini — urutan fallback
// diatur pemanggil dari katalog.
func (r *Registry) Chat(ctx context.Context, cr ChatRequest) (ChatResult, error) {
	p, err := r.provider(cr.Provider)
	if err != nil {
		return ChatResult{}, err
	}
	body := map[string]any{
		"model":       cr.Model,
		"messages":    cr.Messages,
		"temperature": 0.2,
		"max_tokens":  cr.MaxTokens,
	}
	if cr.JSON && p.Key == ProviderKenari {
		// kenari meneruskan response_format ke model yang mendukung dan
		// membuangnya untuk yang lain; balasan tetap dibersihkan sendiri.
		body["response_format"] = map[string]string{"type": "json_object"}
	}
	if strings.TrimSpace(cr.ExtraBody) != "" {
		var extra map[string]any
		if err := json.Unmarshal([]byte(cr.ExtraBody), &extra); err != nil {
			return ChatResult{}, &Error{Provider: p.Name, Msg: "extra body katalog bukan JSON objek"}
		}
		for k, v := range extra {
			switch k {
			case "model", "messages":
				continue // tidak boleh ditimpa dari katalog
			}
			body[k] = v
		}
	}
	payload, _ := json.Marshal(body)
	req, err := r.newRequest(ctx, p, http.MethodPost, "/chat/completions", payload)
	if err != nil {
		return ChatResult{}, err
	}
	start := time.Now()
	resp, err := r.http.Do(req)
	if err != nil {
		return ChatResult{}, &Error{Provider: p.Name, Msg: "gagal terhubung: " + scrub(err.Error())}
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	latency := time.Since(start)
	if err != nil {
		return ChatResult{}, &Error{Provider: p.Name, Status: resp.StatusCode, Msg: "gagal membaca balasan"}
	}
	// kenari: request > 45 detik dijawab 200 + spasi, lalu JSON.
	raw = bytes.TrimSpace(raw)

	var parsed struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
		Error json.RawMessage `json:"error"`
		Usage Usage           `json:"usage"`
	}
	jsonErr := json.Unmarshal(raw, &parsed)
	if resp.StatusCode >= 400 {
		return ChatResult{}, &Error{Provider: p.Name, Status: resp.StatusCode, Msg: errorMessage(parsed.Error, raw)}
	}
	if jsonErr != nil {
		return ChatResult{}, &Error{Provider: p.Name, Status: resp.StatusCode, Msg: "balasan bukan JSON"}
	}
	// kenari & OpenRouter bisa melaporkan gagal sebagai 200 berisi "error".
	if len(parsed.Error) > 0 && string(parsed.Error) != "null" {
		return ChatResult{}, &Error{Provider: p.Name, Status: resp.StatusCode, Msg: errorMessage(parsed.Error, raw)}
	}
	if len(parsed.Choices) == 0 || strings.TrimSpace(parsed.Choices[0].Message.Content) == "" {
		msg := "balasan kosong"
		if len(parsed.Choices) > 0 && parsed.Choices[0].FinishReason == "length" {
			msg = "balasan kosong: token habis (mungkin dipakai untuk reasoning)"
		}
		return ChatResult{}, &Error{Provider: p.Name, Status: resp.StatusCode, Msg: msg}
	}
	return ChatResult{Content: parsed.Choices[0].Message.Content, Usage: parsed.Usage, Latency: latency}, nil
}

func errorMessage(errField json.RawMessage, raw []byte) string {
	var obj struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(errField, &obj) == nil && obj.Message != "" {
		return truncate(scrub(obj.Message), 300)
	}
	var s string
	if json.Unmarshal(errField, &s) == nil && s != "" {
		return truncate(scrub(s), 300)
	}
	return truncate(scrub(string(raw)), 200)
}

var keyLike = regexp.MustCompile(`(?i)(sk|kn|or)-[a-z0-9_\-]{8,}|bearer\s+\S+`)

// scrub membuang apa pun yang mirip API key dari pesan error sebelum dicatat.
func scrub(s string) string { return keyLike.ReplaceAllString(s, "[disembunyikan]") }

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	if len([]rune(s)) <= n {
		return s
	}
	return string([]rune(s)[:n]) + "…"
}

// RemoteModel adalah satu model dari GET /models milik provider.
type RemoteModel struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Free    bool   `json:"free"`
	Context int    `json:"context,omitempty"`
}

// ListModels mengambil daftar model teks dari provider. Varian ":batch"
// (hanya untuk Batch API) dan model yang tidak menghasilkan teks dibuang.
func (r *Registry) ListModels(ctx context.Context, provider string) ([]RemoteModel, error) {
	p, ok := r.providers[provider]
	if !ok {
		return nil, &Error{Provider: provider, Msg: "provider tidak dikenal"}
	}
	req, err := r.newRequest(ctx, p, http.MethodGet, "/models", nil)
	if err != nil {
		return nil, err
	}
	resp, err := r.http.Do(req)
	if err != nil {
		return nil, &Error{Provider: p.Name, Msg: "gagal terhubung: " + scrub(err.Error())}
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode >= 400 {
		return nil, &Error{Provider: p.Name, Status: resp.StatusCode, Msg: truncate(scrub(string(raw)), 200)}
	}
	var parsed struct {
		Data []struct {
			ID            string `json:"id"`
			Name          string `json:"name"`
			ContextLength int    `json:"context_length"`
			Architecture  struct {
				OutputModalities []string `json:"output_modalities"`
			} `json:"architecture"`
			Pricing struct {
				Prompt     string `json:"prompt"`
				Completion string `json:"completion"`
			} `json:"pricing"`
			Endpoints []string `json:"endpoints"`
			Type      string   `json:"type"`
		} `json:"data"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(raw), &parsed); err != nil {
		return nil, &Error{Provider: p.Name, Msg: "daftar model bukan JSON"}
	}
	out := []RemoteModel{}
	for _, m := range parsed.Data {
		if m.ID == "" || strings.HasSuffix(m.ID, ":batch") {
			continue
		}
		if mods := m.Architecture.OutputModalities; len(mods) > 0 && !containsStr(mods, "text") {
			continue
		}
		if len(m.Endpoints) > 0 && !containsAny(m.Endpoints, "chat") {
			continue
		}
		if m.Type != "" && !strings.Contains(strings.ToLower(m.Type), "chat") && !strings.Contains(strings.ToLower(m.Type), "text") {
			continue
		}
		free := strings.HasSuffix(m.ID, ":free") || (m.Pricing.Prompt == "0" && m.Pricing.Completion == "0")
		out = append(out, RemoteModel{ID: m.ID, Name: m.Name, Free: free, Context: m.ContextLength})
	}
	if len(out) == 0 {
		return nil, &Error{Provider: p.Name, Msg: "provider mengembalikan daftar kosong"}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Free != out[j].Free {
			return out[i].Free
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

func containsStr(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

func containsAny(xs []string, sub string) bool {
	for _, x := range xs {
		if strings.Contains(x, sub) {
			return true
		}
	}
	return false
}
