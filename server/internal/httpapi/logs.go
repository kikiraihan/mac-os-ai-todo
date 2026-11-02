package httpapi

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"aitodo/server/internal/applog"
	"aitodo/server/internal/db"
)

// Admin → AI Call Log & System Log (pola dari Racik). AI Call Log hanya berisi
// metadata request keluar ke provider AI (tanpa isi prompt/jawaban), jadi admin
// tidak bisa membaca todo/chat/ingatan pengguna lewat menu ini.

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

// parseDay membaca YYYY-MM-DD di zona loc.
func parseDay(s string, loc *time.Location) (time.Time, bool) {
	t, err := time.ParseInLocation("2006-01-02", s, loc)
	return t, err == nil
}

// GET /api/admin/ai-calls?q=&provider=&feature=&status=ok|error&from=YYYY-MM-DD&to=YYYY-MM-DD&page=&size=
// from/to memakai zona waktu server; to inklusif sampai akhir hari.
func (s *Server) adminListAICalls(w http.ResponseWriter, r *http.Request) {
	v := r.URL.Query()
	loc := s.Cfg.DefaultTZ // akun admin tidak punya zona sendiri: pakai zona server
	f := db.AICallFilter{Text: v.Get("q"), Provider: v.Get("provider"), Feature: v.Get("feature"), Status: v.Get("status"),
		Page: atoi(v.Get("page")), Size: atoi(v.Get("size"))}
	if f.Size <= 0 {
		f.Size = 50
	}
	if t, ok := parseDay(v.Get("from"), loc); ok {
		f.From = t
	}
	if t, ok := parseDay(v.Get("to"), loc); ok {
		f.To = t.AddDate(0, 0, 1)
	}
	items, total, err := s.DB.ListAICalls(f)
	if err != nil {
		fail(w, err)
		return
	}
	features, _ := s.DB.AICallFeatures()
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": total, "page": max(f.Page, 1), "size": min(max(f.Size, 1), 200),
		"features": features, "providers": s.AI.Providers(), "retentionDays": s.Cfg.AICallRetentionDays})
}

// GET /api/admin/ai-calls/summary?days=7 — ringkasan per provider & model.
func (s *Server) adminAICallSummary(w http.ResponseWriter, r *http.Request) {
	days := atoi(r.URL.Query().Get("days"))
	if days < 1 || days > 365 {
		days = 7
	}
	items, err := s.DB.SummarizeAICalls(time.Now().AddDate(0, 0, -days))
	if err != nil {
		fail(w, err)
		return
	}
	var total struct {
		Calls            int     `json:"calls"`
		Errors           int     `json:"errors"`
		AvgMs            float64 `json:"avgMs"`
		PromptTokens     int     `json:"promptTokens"`
		CompletionTokens int     `json:"completionTokens"`
	}
	var sumMs float64
	for _, x := range items {
		total.Calls += x.Calls
		total.Errors += x.Errors
		total.PromptTokens += x.PromptTokens
		total.CompletionTokens += x.CompletionTokens
		sumMs += x.AvgMs * float64(x.Calls)
	}
	if total.Calls > 0 {
		total.AvgMs = sumMs / float64(total.Calls)
	}
	writeJSON(w, http.StatusOK, map[string]any{"days": days, "items": items, "total": total})
}

// POST /api/admin/ai-calls/delete — {"ids": [...]} hapus baris terpilih, {"all": true} kosongkan log.
func (s *Server) adminDeleteAICalls(w http.ResponseWriter, r *http.Request) {
	var in struct {
		IDs []int64 `json:"ids"`
		All bool    `json:"all"`
	}
	if !decode(w, r, &in) {
		return
	}
	switch {
	case in.All:
		in.IDs = nil
	case len(in.IDs) > 0 && len(in.IDs) <= 1000:
	default:
		writeErr(w, http.StatusBadRequest, "pilih minimal satu log (maksimal 1000)")
		return
	}
	n, err := s.DB.DeleteAICalls(in.IDs)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": n, "message": fmt.Sprintf("%d baris log dihapus", n)})
}

// GET /api/admin/system-logs?q=&level=info|warn|error&source=&after=<seq>&limit=
// Baris log server terakhir dari memori (peringatan, error, kegagalan model AI).
func (s *Server) adminSystemLogs(w http.ResponseWriter, r *http.Request) {
	if s.SystemLog == nil {
		writeJSON(w, http.StatusOK, map[string]any{"enabled": false, "items": []any{}, "lastSeq": 0})
		return
	}
	v := r.URL.Query()
	after, _ := strconv.ParseInt(v.Get("after"), 10, 64)
	items, last := s.SystemLog.Lines(applog.RingQuery{
		Text: v.Get("q"), Level: v.Get("level"), Source: v.Get("source"), After: after, Limit: atoi(v.Get("limit")),
	})
	writeJSON(w, http.StatusOK, map[string]any{"enabled": true, "items": items, "lastSeq": last, "stats": s.SystemLog.Stats()})
}
