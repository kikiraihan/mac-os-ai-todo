package ai

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func testRegistry(t *testing.T, handler http.HandlerFunc) *Registry {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	r := NewRegistry(func(k string) string {
		if strings.HasSuffix(k, "_API_KEY") {
			return "kn-test-secret-key-123456"
		}
		return ""
	})
	for _, p := range r.providers {
		p.BaseURL = srv.URL
	}
	r.allowHost = func(*Provider, string) bool { return true }
	return r
}

func TestChatOK(t *testing.T) {
	var got map[string]any
	r := testRegistry(t, func(w http.ResponseWriter, req *http.Request) {
		if req.Header.Get("Authorization") != "Bearer kn-test-secret-key-123456" {
			t.Errorf("auth header missing")
		}
		b, _ := io.ReadAll(req.Body)
		json.Unmarshal(b, &got)
		// kenari: spasi dulu, baru JSON.
		io.WriteString(w, "   \n  "+`{"choices":[{"message":{"content":"{\"reply\":\"hai\"}"}}]}`)
	})
	res, err := r.Chat(context.Background(), ChatRequest{Provider: ProviderKenari, Model: "m:free", MaxTokens: 100, JSON: true,
		ExtraBody: `{"reasoning_effort":"low","model":"hijack"}`, Messages: []Message{{"user", "hai"}}})
	if err != nil {
		t.Fatal(err)
	}
	if res.Content != `{"reply":"hai"}` {
		t.Fatalf("content %q", res.Content)
	}
	if got["model"] != "m:free" || got["reasoning_effort"] != "low" || got["response_format"] == nil {
		t.Fatalf("body %v", got)
	}
}

func TestChatErrorIn200(t *testing.T) {
	r := testRegistry(t, func(w http.ResponseWriter, req *http.Request) {
		io.WriteString(w, `{"error":{"message":"upstream timeout"}}`)
	})
	_, err := r.Chat(context.Background(), ChatRequest{Provider: ProviderOpenRouter, Model: "x", MaxTokens: 10})
	if err == nil || !strings.Contains(err.Error(), "upstream timeout") {
		t.Fatalf("err %v", err)
	}
}

func TestChatStatusAndScrub(t *testing.T) {
	r := testRegistry(t, func(w http.ResponseWriter, req *http.Request) {
		w.WriteHeader(402)
		io.WriteString(w, `{"error":{"message":"no credits for key sk-or-abcdefghijklmnop"}}`)
	})
	_, err := r.Chat(context.Background(), ChatRequest{Provider: ProviderOpenRouter, Model: "x", MaxTokens: 10})
	e, ok := err.(*Error)
	if !ok || e.Status != 402 || e.Rejected() {
		t.Fatalf("err %#v", err)
	}
	if strings.Contains(e.Msg, "abcdefghijklmnop") {
		t.Fatalf("key leaked: %s", e.Msg)
	}
}

func TestNoKeyNoRequest(t *testing.T) {
	r := NewRegistry(func(string) string { return "" })
	if _, err := r.Chat(context.Background(), ChatRequest{Provider: ProviderAgnes, Model: "x"}); err == nil {
		t.Fatal("expected error without key")
	}
	for _, p := range r.Providers() {
		if p.HasKey {
			t.Fatal("no provider should have a key")
		}
	}
}

func TestBaseURLAllowlist(t *testing.T) {
	r := NewRegistry(func(k string) string {
		switch k {
		case "KENARI_BASE_URL":
			return "https://evil.example.com/v1"
		case "OPENROUTER_BASE_URL":
			return "https://openrouter.ai/api/v1/"
		}
		return ""
	})
	if r.providers[ProviderKenari].BaseURL != "https://kenari.id/v1" {
		t.Fatalf("evil base url accepted: %s", r.providers[ProviderKenari].BaseURL)
	}
	if r.providers[ProviderOpenRouter].BaseURL != "https://openrouter.ai/api/v1" {
		t.Fatalf("got %s", r.providers[ProviderOpenRouter].BaseURL)
	}
	// Host di luar allowlist ditolak saat request, bukan hanya saat start.
	r.providers[ProviderAgnes].BaseURL = "https://evil.example.com"
	r.providers[ProviderAgnes].apiKey = "x"
	if _, err := r.Chat(context.Background(), ChatRequest{Provider: ProviderAgnes, Model: "m"}); err == nil || !strings.Contains(err.Error(), "tidak diizinkan") {
		t.Fatalf("err %v", err)
	}
}

func TestListModels(t *testing.T) {
	r := testRegistry(t, func(w http.ResponseWriter, req *http.Request) {
		io.WriteString(w, `{"data":[
			{"id":"qwen/qwen3:free","name":"Qwen3","architecture":{"output_modalities":["text"]},"pricing":{"prompt":"0","completion":"0"}},
			{"id":"flux/img","architecture":{"output_modalities":["image"]}},
			{"id":"gpt:batch"},
			{"id":"paid/model","pricing":{"prompt":"0.1","completion":"0.2"}}]}`)
	})
	ms, err := r.ListModels(context.Background(), ProviderOpenRouter)
	if err != nil {
		t.Fatal(err)
	}
	if len(ms) != 2 || ms[0].ID != "qwen/qwen3:free" || !ms[0].Free || ms[1].Free {
		t.Fatalf("got %+v", ms)
	}
}
