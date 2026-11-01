package ai

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestCallRecorder(t *testing.T) {
	r := testRegistry(t, func(w http.ResponseWriter, req *http.Request) {
		if strings.HasSuffix(req.URL.Path, "/models") {
			w.WriteHeader(500)
			io.WriteString(w, `{"error":{"message":"rusak, key kn-test-secret-key-123456"}}`)
			return
		}
		io.WriteString(w, `{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":12,"completion_tokens":3}}`)
	})
	var got []CallRecord
	r.Recorder = func(c CallRecord) { got = append(got, c) }

	ctx := WithCaller(context.Background(), Caller{UserID: 7, Feature: "asisten"})
	if _, err := r.Chat(ctx, ChatRequest{Provider: ProviderKenari, Model: "m:free", MaxTokens: 10}); err != nil {
		t.Fatal(err)
	}
	if _, err := r.ListModels(context.Background(), ProviderOpenRouter); err == nil {
		t.Fatal("ListModels harus gagal")
	}
	// Tanpa API key / provider tidak dikenal: tidak ada request keluar, tidak dicatat.
	r.Chat(ctx, ChatRequest{Provider: "entah", Model: "x"})

	// chat + 2 percobaan GET /models (500 dicoba ulang sekali)
	if len(got) != 3 {
		t.Fatalf("tercatat %d, mau 3: %+v", len(got), got)
	}
	c := got[0]
	if !c.OK || c.UserID != 7 || c.Feature != "asisten" || c.Provider != ProviderKenari || c.Model != "m:free" ||
		c.Operation != OpChat || c.HTTPStatus != 200 || c.PromptTokens != 12 || c.CompletionTokens != 3 || c.At.IsZero() {
		t.Errorf("chat record salah: %+v", c)
	}
	m := got[1]
	if m.OK || m.HTTPStatus != 500 || m.Operation != OpModels || m.Error == "" || m.UserID != 0 {
		t.Errorf("models record salah: %+v", m)
	}
	if strings.Contains(m.Error, "kn-test-secret") {
		t.Errorf("error log membocorkan key: %q", m.Error)
	}
}
