package ai

import (
	"context"
	"time"
)

// AI Call Log (Admin → AI Call Log, pola dari Racik): setiap request HTTP keluar
// ke provider AI dicatat — provider, model, endpoint, status HTTP, latensi,
// token, dan pesan error. Body request/response SENGAJA tidak disimpan karena
// berisi todo, chat, dan ingatan pengguna; admin tidak boleh membaca data
// pengguna lain (lihat AGENTS.md).

const (
	OpChat   = "chat"
	OpModels = "models"
)

// CallRecord adalah satu request HTTP ke provider AI.
type CallRecord struct {
	UserID           int64  // 0 = bukan atas nama pengguna tertentu
	Feature          string // asal panggilan, mis. "asisten", "admin.tes-model"
	Provider         string
	Model            string
	Endpoint         string // path relatif base URL, mis. /chat/completions
	Operation        string // chat | models
	HTTPStatus       int    // 0 = tidak sampai mendapat respons HTTP
	OK               bool
	Latency          time.Duration
	PromptTokens     int
	CompletionTokens int
	Error            string // sudah dibersihkan dari apa pun yang mirip API key
	At               time.Time
}

// Caller menandai siapa / fitur apa yang memicu panggilan AI.
type Caller struct {
	UserID  int64
	Feature string
}

type callerKey struct{}

// WithCaller menempelkan info pemanggil ke ctx supaya ikut tercatat di AI Call Log.
func WithCaller(ctx context.Context, c Caller) context.Context {
	return context.WithValue(ctx, callerKey{}, c)
}

func callerFrom(ctx context.Context) Caller {
	c, _ := ctx.Value(callerKey{}).(Caller)
	return c
}

// record mengirim rec ke Recorder (kalau dipasang). Recorder tidak boleh memblokir.
func (r *Registry) record(ctx context.Context, rec *CallRecord, start time.Time, err error) {
	if r.Recorder == nil {
		return
	}
	c := callerFrom(ctx)
	rec.UserID, rec.Feature = c.UserID, c.Feature
	rec.At = start
	rec.Latency = time.Since(start)
	rec.OK = err == nil
	if err != nil {
		rec.Error = truncate(scrub(err.Error()), 500)
	}
	r.Recorder(*rec)
}

// Scrub membuang apa pun yang mirip API key / token dari teks (dipakai juga
// oleh system log sebelum ditampilkan di panel admin).
func Scrub(s string) string { return scrub(s) }
