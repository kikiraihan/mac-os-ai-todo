package httpapi

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"

	"aitodo/server/internal/core"
	"aitodo/server/internal/db"
	"aitodo/server/internal/schedule"
	"aitodo/server/internal/scheduler"
)

const (
	cookieName  = "aitodo_session"
	tokenPrefix = "ait_"

	webSessionTTL    = 30 * 24 * time.Hour
	deviceSessionTTL = 365 * 24 * time.Hour
	touchEvery       = time.Hour

	MinPasswordLen = 10

	loginFailsPerIP     = 5
	loginFailWindow     = 15 * time.Minute
	loginFailsGlobal    = 100
	loginGlobalWindow   = time.Hour
	maxSessionsPerUser  = 30
	bcryptCost          = 12
	maxDisplayNameChars = 60
)

// dummyHash dipakai saat username tidak ada supaya waktu respons sama
// (tidak membocorkan username mana yang terdaftar).
var dummyHash, _ = bcrypt.GenerateFromPassword([]byte("dummy-password-for-timing"), bcryptCost)

func HashPassword(pw string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(pw), bcryptCost)
	return string(b), err
}

func CheckPassword(pw string) error {
	if utf8.RuneCountInString(pw) < MinPasswordLen {
		return &core.ValidationError{Msg: "password minimal 10 karakter"}
	}
	if len(pw) > 72 {
		return &core.ValidationError{Msg: "password maksimal 72 byte"}
	}
	return nil
}

func newToken() (token, hash string) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	token = tokenPrefix + base64.RawURLEncoding.EncodeToString(b)
	return token, hashToken(token)
}

func hashToken(t string) string {
	sum := sha256.Sum256([]byte(t))
	return hex.EncodeToString(sum[:])
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}

// authenticate membaca token dari Authorization: Bearer (aplikasi Mac) atau
// cookie (browser/PWA). Server hanya menyimpan hash token.
func (s *Server) authenticate(w http.ResponseWriter, r *http.Request) (db.Session, db.User, bool) {
	token := bearer(r)
	fromCookie := false
	if token == "" {
		c, err := r.Cookie(cookieName)
		if err != nil {
			return db.Session{}, db.User{}, false
		}
		token, fromCookie = c.Value, true
	}
	if !strings.HasPrefix(token, tokenPrefix) || len(token) > 100 {
		return db.Session{}, db.User{}, false
	}
	sess, user, err := s.DB.SessionByTokenHash(hashToken(token))
	if err != nil || user.Disabled {
		if fromCookie {
			s.clearCookie(w)
		}
		return db.Session{}, db.User{}, false
	}
	if last, err := db.ParseStamp(sess.LastSeenAt); err == nil && time.Since(last) > touchEvery {
		ttl := webSessionTTL
		if sess.Kind == db.SessionDevice {
			ttl = deviceSessionTTL
		}
		exp := time.Now().Add(ttl)
		s.DB.TouchSession(sess.ID, db.Stamp(exp))
		if fromCookie {
			s.setCookie(w, token, exp)
		}
	}
	return sess, user, true
}

func (s *Server) setCookie(w http.ResponseWriter, token string, exp time.Time) {
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: token, Path: "/", Expires: exp, MaxAge: int(time.Until(exp).Seconds()),
		HttpOnly: true, Secure: s.Cfg.SecureCookies, SameSite: http.SameSiteStrictMode})
}

func (s *Server) clearCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1, HttpOnly: true,
		Secure: s.Cfg.SecureCookies, SameSite: http.SameSiteStrictMode})
}

func userAgent(r *http.Request) string {
	ua := r.UserAgent()
	if len(ua) > 200 {
		ua = ua[:200]
	}
	return ua
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !decode(w, r, &in) {
		return
	}
	ip := s.clientIP(r)
	if s.loginLimit.count("ip:"+ip, loginFailWindow) >= loginFailsPerIP ||
		s.loginLimit.count("global", loginGlobalWindow) >= loginFailsGlobal {
		writeErr(w, http.StatusTooManyRequests, "terlalu banyak percobaan gagal, coba lagi 15 menit lagi")
		return
	}
	user, err := s.DB.GetUserByUsername(strings.TrimSpace(in.Username))
	hash := string(dummyHash)
	if err == nil {
		hash = user.PasswordHash
	} else if !errors.Is(err, db.ErrNotFound) {
		fail(w, err)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(in.Password)) != nil || err != nil || user.Disabled {
		s.loginLimit.add("ip:" + ip)
		s.loginLimit.add("global")
		writeErr(w, http.StatusUnauthorized, "username atau password salah")
		return
	}
	token, th := newToken()
	exp := time.Now().Add(webSessionTTL)
	if _, err := s.DB.CreateSession(db.Session{UserID: user.ID, Kind: db.SessionWeb, Name: "Browser", UserAgent: userAgent(r),
		ExpiresAt: db.Stamp(exp)}, th); err != nil {
		fail(w, err)
		return
	}
	s.setCookie(w, token, exp)
	s.trimSessions(user.ID)
	writeJSON(w, http.StatusOK, map[string]any{"user": user})
}

// trimSessions membuang sesi tertua kalau terlalu banyak.
func (s *Server) trimSessions(userID int64) {
	ss, err := s.DB.ListSessions(userID)
	if err != nil || len(ss) <= maxSessionsPerUser {
		return
	}
	for _, x := range ss[maxSessionsPerUser:] {
		s.DB.DeleteSession(userID, x.ID)
	}
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	s.DB.DeleteSession(userOf(r).ID, sessionOf(r).ID)
	s.clearCookie(w)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	u := userOf(r)
	m, err := s.DB.GetUserSettings(u.ID)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"user":      u,
		"timezone":  s.loc(u).String(),
		"prefs":     scheduler.PrefsFrom(m),
		"sessionId": sessionOf(r).ID,
		"version":   s.Cfg.Version,
	})
}

func (s *Server) updateMe(w http.ResponseWriter, r *http.Request) {
	var in struct {
		DisplayName *string `json:"displayName"`
		Timezone    *string `json:"timezone"`
	}
	if !decode(w, r, &in) {
		return
	}
	u := userOf(r)
	if in.DisplayName != nil {
		name := strings.TrimSpace(*in.DisplayName)
		if utf8.RuneCountInString(name) > maxDisplayNameChars {
			writeErr(w, http.StatusBadRequest, "nama tampilan maksimal 60 karakter")
			return
		}
		u.DisplayName = name
	}
	if in.Timezone != nil {
		tz := strings.TrimSpace(*in.Timezone)
		if tz != "" {
			if _, err := time.LoadLocation(tz); err != nil || len(tz) > 64 {
				writeErr(w, http.StatusBadRequest, "zona waktu tidak dikenal")
				return
			}
		}
		u.Timezone = tz
	}
	if err := s.DB.UpdateUser(u); err != nil {
		fail(w, err)
		return
	}
	s.Hub.Bump(u.ID)
	writeJSON(w, http.StatusOK, map[string]any{"user": u})
}

func (s *Server) changePassword(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Current string `json:"current"`
		New     string `json:"new"`
	}
	if !decode(w, r, &in) {
		return
	}
	u := userOf(r)
	ip := s.clientIP(r)
	if s.loginLimit.count("ip:"+ip, loginFailWindow) >= loginFailsPerIP {
		writeErr(w, http.StatusTooManyRequests, "terlalu banyak percobaan gagal, coba lagi nanti")
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(in.Current)) != nil {
		s.loginLimit.add("ip:" + ip)
		writeErr(w, http.StatusBadRequest, "password lama salah")
		return
	}
	if err := CheckPassword(in.New); err != nil {
		fail(w, err)
		return
	}
	hash, err := HashPassword(in.New)
	if err != nil {
		fail(w, err)
		return
	}
	if err := s.DB.SetPassword(u.ID, hash); err != nil {
		fail(w, err)
		return
	}
	// Keluarkan perangkat lain; sesi ini tetap.
	s.DB.DeleteUserSessions(u.ID, sessionOf(r).ID)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) updatePrefs(w http.ResponseWriter, r *http.Request) {
	var p scheduler.UserPrefs
	if !decode(w, r, &p) {
		return
	}
	for _, t := range []string{p.BriefTime, p.NudgeTime} {
		if t != "" && !schedule.ValidTime(t) {
			writeErr(w, http.StatusBadRequest, "jam harus HH:MM atau kosong")
			return
		}
	}
	u := userOf(r)
	b := func(v bool) string {
		if v {
			return "1"
		}
		return "0"
	}
	for k, v := range map[string]string{scheduler.KeyBriefTime: p.BriefTime, scheduler.KeyNudgeTime: p.NudgeTime,
		scheduler.KeyHideContent: b(p.HideContent), scheduler.KeyDueNotify: b(p.DueNotify)} {
		if err := s.DB.SetUserSetting(u.ID, k, v); err != nil {
			fail(w, err)
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"prefs": p})
}

func (s *Server) listSessions(w http.ResponseWriter, r *http.Request) {
	ss, err := s.DB.ListSessions(userOf(r).ID)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": ss, "currentId": sessionOf(r).ID})
}

func (s *Server) deleteSession(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	if err := s.DB.DeleteSession(userOf(r).ID, id); err != nil {
		fail(w, err)
		return
	}
	if id == sessionOf(r).ID {
		s.clearCookie(w)
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// createDevice membuat token untuk aplikasi Mac (atau klien lain tanpa cookie).
// Token hanya ditampilkan sekali.
func (s *Server) createDevice(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Name string `json:"name"`
	}
	if !decode(w, r, &in) {
		return
	}
	name := strings.TrimSpace(in.Name)
	if name == "" {
		name = "Perangkat"
	}
	if utf8.RuneCountInString(name) > 60 {
		writeErr(w, http.StatusBadRequest, "nama perangkat maksimal 60 karakter")
		return
	}
	u := userOf(r)
	token, th := newToken()
	sess, err := s.DB.CreateSession(db.Session{UserID: u.ID, Kind: db.SessionDevice, Name: name,
		ExpiresAt: db.Stamp(time.Now().Add(deviceSessionTTL))}, th)
	if err != nil {
		fail(w, err)
		return
	}
	s.trimSessions(u.ID)
	writeJSON(w, http.StatusCreated, map[string]any{"token": token, "session": sess})
}
