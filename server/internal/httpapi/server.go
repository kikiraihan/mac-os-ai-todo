// Package httpapi berisi semua endpoint /api/ dan middleware keamanannya.
package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"aitodo/server/internal/ai"
	"aitodo/server/internal/assistant"
	"aitodo/server/internal/core"
	"aitodo/server/internal/db"
	"aitodo/server/internal/push"
)

const (
	// Semua request /api/ wajib membawa header ini (perlindungan CSRF, selain
	// cookie SameSite=Strict). Browser tidak bisa menambahkannya lintas situs
	// tanpa preflight CORS, dan server tidak membuka CORS.
	csrfHeader = "X-AITodo"

	maxBody = 64 << 10
)

type Config struct {
	Version       string
	SecureCookies bool
	TrustProxy    bool
	DefaultTZ     *time.Location
}

type Server struct {
	DB        *db.DB
	AI        *ai.Registry
	Assistant *assistant.Assistant
	Push      *push.Service
	Hub       *Hub
	Cfg       Config
	Mux       *http.ServeMux

	loginLimit *limiter
	chatLimit  *limiter

	locMu    sync.Mutex
	locCache map[string]*time.Location
}

func New(d *db.DB, reg *ai.Registry, p *push.Service, cfg Config) *Server {
	s := &Server{DB: d, AI: reg, Push: p, Hub: NewHub(), Cfg: cfg, Mux: http.NewServeMux(),
		loginLimit: newLimiter(), chatLimit: newLimiter(), locCache: map[string]*time.Location{}}
	s.Assistant = &assistant.Assistant{DB: d, AI: reg, OnChange: s.Hub.Bump}
	s.routes()
	return s
}

func (s *Server) routes() {
	m := s.Mux
	m.HandleFunc("GET /api/health", s.health)
	m.HandleFunc("GET /api/config", s.api(s.config))
	m.HandleFunc("POST /api/login", s.api(s.login))
	m.HandleFunc("POST /api/login/device", s.api(s.loginDevice))
	m.HandleFunc("POST /api/logout", s.authed(s.logout))
	m.HandleFunc("GET /api/me", s.authed(s.me))
	m.HandleFunc("PUT /api/me", s.authed(s.updateMe))
	m.HandleFunc("PUT /api/me/password", s.authed(s.changePassword))
	m.HandleFunc("PUT /api/me/prefs", s.authed(s.updatePrefs))
	m.HandleFunc("GET /api/sessions", s.authed(s.listSessions))
	m.HandleFunc("DELETE /api/sessions/{id}", s.authed(s.deleteSession))
	m.HandleFunc("POST /api/devices", s.authed(s.createDevice))

	m.HandleFunc("GET /api/changes", s.authed(s.changes))

	m.HandleFunc("GET /api/todos", s.authed(s.listTodos))
	m.HandleFunc("POST /api/todos", s.authed(s.createTodo))
	m.HandleFunc("PUT /api/todos/{id}", s.authed(s.updateTodo))
	m.HandleFunc("DELETE /api/todos/{id}", s.authed(s.deleteTodo))
	m.HandleFunc("POST /api/todos/{id}/complete", s.authed(s.completeTodo))
	m.HandleFunc("POST /api/todos/{id}/reopen", s.authed(s.reopenTodo))
	m.HandleFunc("POST /api/todos/archive-done", s.authed(s.archiveDone))

	m.HandleFunc("GET /api/reminders", s.authed(s.listReminders))
	m.HandleFunc("GET /api/reminders/upcoming", s.authed(s.upcoming))
	m.HandleFunc("POST /api/reminders", s.authed(s.createReminder))
	m.HandleFunc("PUT /api/reminders/{id}", s.authed(s.updateReminder))
	m.HandleFunc("DELETE /api/reminders/{id}", s.authed(s.deleteReminder))
	m.HandleFunc("POST /api/reminders/{id}/snooze", s.authed(s.snoozeReminder))

	m.HandleFunc("GET /api/chat", s.authed(s.listChat))
	m.HandleFunc("POST /api/chat", s.authed(s.postChat))
	m.HandleFunc("DELETE /api/chat", s.authed(s.clearChat))
	m.HandleFunc("POST /api/chat/batches/{id}/{action}", s.authed(s.batchAction))

	m.HandleFunc("GET /api/push/key", s.authed(s.pushKey))
	m.HandleFunc("POST /api/push/subscribe", s.authed(s.pushSubscribe))
	m.HandleFunc("POST /api/push/unsubscribe", s.authed(s.pushUnsubscribe))
	m.HandleFunc("POST /api/push/test", s.authed(s.pushTest))

	m.HandleFunc("GET /api/admin/stats", s.admin(s.adminStats))
	m.HandleFunc("GET /api/admin/users", s.admin(s.adminListUsers))
	m.HandleFunc("POST /api/admin/users", s.admin(s.adminCreateUser))
	m.HandleFunc("PUT /api/admin/users/{id}", s.admin(s.adminUpdateUser))
	m.HandleFunc("DELETE /api/admin/users/{id}", s.admin(s.adminDeleteUser))
	m.HandleFunc("GET /api/admin/ai", s.admin(s.adminAI))
	m.HandleFunc("PUT /api/admin/ai/settings", s.admin(s.adminAISettings))
	m.HandleFunc("POST /api/admin/ai/models", s.admin(s.adminCreateModel))
	m.HandleFunc("POST /api/admin/ai/models/reorder", s.admin(s.adminReorderModels))
	m.HandleFunc("POST /api/admin/ai/models/import", s.admin(s.adminImportModels))
	m.HandleFunc("PUT /api/admin/ai/models/{id}", s.admin(s.adminUpdateModel))
	m.HandleFunc("DELETE /api/admin/ai/models/{id}", s.admin(s.adminDeleteModel))
	m.HandleFunc("POST /api/admin/ai/models/{id}/test", s.admin(s.adminTestModel))
	m.HandleFunc("GET /api/admin/ai/providers/{provider}/models", s.admin(s.adminRemoteModels))

	s.memoryRoutes()

	// /api/ lain → 404 JSON (bukan halaman SPA).
	m.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		writeErr(w, http.StatusNotFound, "endpoint tidak ada")
	})
}

// --- middleware ----------------------------------------------------------------

// SecurityHeaders membungkus seluruh handler (API & halaman).
func SecurityHeaders(secure bool, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "+
			"connect-src 'self'; font-src 'self'; manifest-src 'self'; worker-src 'self'; object-src 'none'; "+
			"base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "same-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		if secure {
			h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
		}
		next.ServeHTTP(w, r)
	})
}

type ctxKey int

const (
	keyUser ctxKey = iota
	keySession
)

func userOf(r *http.Request) db.User       { return r.Context().Value(keyUser).(db.User) }
func sessionOf(r *http.Request) db.Session { return r.Context().Value(keySession).(db.Session) }

// api: header CSRF wajib + batas ukuran body + respons tanpa cache.
func (s *Server) api(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get(csrfHeader) != "1" {
			writeErr(w, http.StatusForbidden, "header "+csrfHeader+" wajib")
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		r.Body = http.MaxBytesReader(w, r.Body, maxBody)
		h(w, r)
	}
}

func (s *Server) authed(h http.HandlerFunc) http.HandlerFunc {
	return s.api(func(w http.ResponseWriter, r *http.Request) {
		sess, user, ok := s.authenticate(w, r)
		if !ok {
			writeErr(w, http.StatusUnauthorized, "silakan masuk dulu")
			return
		}
		ctx := context.WithValue(r.Context(), keyUser, user)
		ctx = context.WithValue(ctx, keySession, sess)
		h(w, r.WithContext(ctx))
	})
}

func (s *Server) admin(h http.HandlerFunc) http.HandlerFunc {
	return s.authed(func(w http.ResponseWriter, r *http.Request) {
		if userOf(r).Role != db.RoleAdmin {
			writeErr(w, http.StatusForbidden, "khusus admin")
			return
		}
		h(w, r)
	})
}

// --- helper -------------------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// fail memetakan error ke respons: validasi → 400, tidak ada → 404, lainnya 500.
func fail(w http.ResponseWriter, err error) {
	var ve *core.ValidationError
	switch {
	case errors.As(err, &ve):
		writeErr(w, http.StatusBadRequest, ve.Msg)
	case errors.Is(err, db.ErrNotFound):
		writeErr(w, http.StatusNotFound, "tidak ditemukan")
	default:
		log.Printf("api: %v", err)
		writeErr(w, http.StatusInternalServerError, "terjadi kesalahan di server")
	}
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(r.Body).Decode(v); err != nil && !errors.Is(err, io.EOF) {
		writeErr(w, http.StatusBadRequest, "body JSON tidak valid")
		return false
	}
	return true
}

func pathID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id, err == nil && id > 0
}

func (s *Server) clientIP(r *http.Request) string {
	if s.Cfg.TrustProxy {
		if ip := strings.TrimSpace(r.Header.Get("X-Real-IP")); ip != "" {
			return ip
		}
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// LoadLocation mengembalikan zona waktu (dengan cache); kosong → bawaan server.
func (s *Server) LoadLocation(name string) *time.Location {
	if name == "" {
		return s.Cfg.DefaultTZ
	}
	s.locMu.Lock()
	defer s.locMu.Unlock()
	if loc, ok := s.locCache[name]; ok {
		return loc
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		loc = s.Cfg.DefaultTZ
	}
	s.locCache[name] = loc
	return loc
}

func (s *Server) loc(u db.User) *time.Location { return s.LoadLocation(u.Timezone) }

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	if err := s.DB.Ping(); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "database tidak tersedia")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": s.Cfg.Version})
}

func (s *Server) config(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"name": "AI Todo", "version": s.Cfg.Version})
}

// --- limiter --------------------------------------------------------------------

type limiter struct {
	mu   sync.Mutex
	hits map[string][]time.Time
}

func newLimiter() *limiter { return &limiter{hits: map[string][]time.Time{}} }

func (l *limiter) prune(key string, window time.Duration, now time.Time) []time.Time {
	hs := l.hits[key]
	i := 0
	for i < len(hs) && now.Sub(hs[i]) > window {
		i++
	}
	hs = hs[i:]
	if len(hs) == 0 {
		delete(l.hits, key)
	} else {
		l.hits[key] = hs
	}
	return hs
}

// count menghitung kejadian dalam window tanpa menambah.
func (l *limiter) count(key string, window time.Duration) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.prune(key, window, time.Now()))
}

func (l *limiter) add(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.hits[key] = append(l.hits[key], time.Now())
}

// allow menambah satu kejadian kalau masih di bawah n dalam window.
func (l *limiter) allow(key string, n int, window time.Duration) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.prune(key, window, time.Now())) >= n {
		return false
	}
	l.hits[key] = append(l.hits[key], time.Now())
	return true
}
