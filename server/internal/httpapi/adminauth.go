package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"

	"aitodo/server/internal/db"
)

// Akun admin terpisah total dari akun pengguna:
//   - tabel admins + admin_sessions (bukan users/sessions);
//   - cookie sendiri "aitodo_admin" dengan Path=/api/admin, jadi browser tidak
//     pernah mengirimnya ke endpoint pengguna, dan cookie pengguna tidak pernah
//     dibaca oleh endpoint admin;
//   - token berawalan "aia_" (pengguna "ait_"), tanpa Bearer: aplikasi Mac
//     tidak punya akses admin;
//   - tidak ada endpoint pengguna yang bisa membuat admin. Admin hanya dibuat
//     dari server (ADMIN_USERNAME/ADMIN_PASSWORD saat kosong, atau perintah
//     `aitodo admin <username>`) atau oleh admin lain lewat menu Akun admin.
//
// Kalau satu orang punya akun admin & pengguna dengan username yang sama, web
// bisa berpindah mode (/admin ⇄ /) — masing-masing tetap login sendiri.

const (
	adminCookieName  = "aitodo_admin"
	adminCookiePath  = "/api/admin"
	adminTokenPrefix = "aia_"
	adminSessionTTL  = 3 * 24 * time.Hour
	maxAdminSessions = 10
)

const (
	keyAdmin ctxKey = iota + 100
	keyAdminSession
)

func adminOf(r *http.Request) db.Admin { return r.Context().Value(keyAdmin).(db.Admin) }
func adminSessionOf(r *http.Request) db.AdminSession {
	return r.Context().Value(keyAdminSession).(db.AdminSession)
}

func newAdminToken() (token, hash string) {
	t, _ := newToken()
	token = adminTokenPrefix + strings.TrimPrefix(t, tokenPrefix)
	return token, hashToken(token)
}

func (s *Server) setAdminCookie(w http.ResponseWriter, token string, exp time.Time) {
	http.SetCookie(w, &http.Cookie{Name: adminCookieName, Value: token, Path: adminCookiePath, Expires: exp,
		MaxAge: int(time.Until(exp).Seconds()), HttpOnly: true, Secure: s.Cfg.SecureCookies, SameSite: http.SameSiteStrictMode})
}

func (s *Server) clearAdminCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: adminCookieName, Value: "", Path: adminCookiePath, MaxAge: -1, HttpOnly: true,
		Secure: s.Cfg.SecureCookies, SameSite: http.SameSiteStrictMode})
}

// authenticateAdmin hanya membaca cookie admin (bukan Bearer, bukan cookie pengguna).
func (s *Server) authenticateAdmin(w http.ResponseWriter, r *http.Request) (db.AdminSession, db.Admin, bool) {
	c, err := r.Cookie(adminCookieName)
	if err != nil {
		return db.AdminSession{}, db.Admin{}, false
	}
	token := c.Value
	if !strings.HasPrefix(token, adminTokenPrefix) || len(token) > 100 {
		s.clearAdminCookie(w)
		return db.AdminSession{}, db.Admin{}, false
	}
	sess, a, err := s.DB.AdminSessionByTokenHash(hashToken(token))
	if err != nil || a.Disabled {
		s.clearAdminCookie(w)
		return db.AdminSession{}, db.Admin{}, false
	}
	if last, err := db.ParseStamp(sess.LastSeenAt); err == nil && time.Since(last) > touchEvery {
		exp := time.Now().Add(adminSessionTTL)
		s.DB.TouchAdminSession(sess.ID, db.Stamp(exp))
		s.setAdminCookie(w, token, exp)
	}
	return sess, a, true
}

// admin: semua /api/admin/* (kecuali login) wajib sesi admin.
func (s *Server) admin(h http.HandlerFunc) http.HandlerFunc {
	return s.api(func(w http.ResponseWriter, r *http.Request) {
		sess, a, ok := s.authenticateAdmin(w, r)
		if !ok {
			writeErr(w, http.StatusUnauthorized, "silakan masuk sebagai admin")
			return
		}
		ctx := context.WithValue(r.Context(), keyAdmin, a)
		ctx = context.WithValue(ctx, keyAdminSession, sess)
		h(w, r.WithContext(ctx))
	})
}

func (s *Server) adminLogin(w http.ResponseWriter, r *http.Request) {
	var in loginInput
	if !decode(w, r, &in) {
		return
	}
	ip := s.clientIP(r)
	if s.loginLimit.count("ip:"+ip, loginFailWindow) >= loginFailsPerIP ||
		s.loginLimit.count("global", loginGlobalWindow) >= loginFailsGlobal {
		writeErr(w, http.StatusTooManyRequests, "terlalu banyak percobaan gagal, coba lagi 15 menit lagi")
		return
	}
	a, err := s.DB.GetAdminByUsername(strings.TrimSpace(in.Username))
	hash := string(dummyHash)
	if err == nil {
		hash = a.PasswordHash
	} else if !errors.Is(err, db.ErrNotFound) {
		fail(w, err)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(in.Password)) != nil || err != nil || a.Disabled {
		s.loginLimit.add("ip:" + ip)
		s.loginLimit.add("global")
		writeErr(w, http.StatusUnauthorized, "username atau password admin salah")
		return
	}
	token, th := newAdminToken()
	exp := time.Now().Add(adminSessionTTL)
	if _, err := s.DB.CreateAdminSession(db.AdminSession{AdminID: a.ID, UserAgent: userAgent(r), ExpiresAt: db.Stamp(exp)}, th); err != nil {
		fail(w, err)
		return
	}
	s.DB.TrimAdminSessions(a.ID, maxAdminSessions)
	s.setAdminCookie(w, token, exp)
	writeJSON(w, http.StatusOK, map[string]any{"admin": a})
}

func (s *Server) adminLogout(w http.ResponseWriter, r *http.Request) {
	s.DB.DeleteAdminSession(adminSessionOf(r).ID)
	s.clearAdminCookie(w)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) adminMe(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"admin": adminOf(r), "version": s.Cfg.Version})
}

func (s *Server) adminChangePassword(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Current string `json:"current"`
		New     string `json:"new"`
	}
	if !decode(w, r, &in) {
		return
	}
	a := adminOf(r)
	ip := s.clientIP(r)
	if s.loginLimit.count("ip:"+ip, loginFailWindow) >= loginFailsPerIP {
		writeErr(w, http.StatusTooManyRequests, "terlalu banyak percobaan gagal, coba lagi nanti")
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(a.PasswordHash), []byte(in.Current)) != nil {
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
	if err := s.DB.SetAdminPassword(a.ID, hash); err != nil {
		fail(w, err)
		return
	}
	s.DB.DeleteAdminSessions(a.ID, adminSessionOf(r).ID)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// --- kelola akun admin ---------------------------------------------------------------

func (s *Server) adminListAdmins(w http.ResponseWriter, r *http.Request) {
	as, err := s.DB.ListAdmins()
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"admins": as, "currentId": adminOf(r).ID})
}

func (s *Server) adminCreateAdmin(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Username    string `json:"username"`
		DisplayName string `json:"displayName"`
		Password    string `json:"password"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.Username = strings.TrimSpace(in.Username)
	if !usernamePattern.MatchString(in.Username) {
		writeErr(w, http.StatusBadRequest, "username 3–32 karakter: huruf, angka, titik, minus, garis bawah")
		return
	}
	if utf8.RuneCountInString(in.DisplayName) > maxDisplayNameChars {
		writeErr(w, http.StatusBadRequest, "nama tampilan maksimal 60 karakter")
		return
	}
	if err := CheckPassword(in.Password); err != nil {
		fail(w, err)
		return
	}
	if _, err := s.DB.GetAdminByUsername(in.Username); err == nil {
		writeErr(w, http.StatusConflict, "username admin sudah dipakai")
		return
	}
	hash, err := HashPassword(in.Password)
	if err != nil {
		fail(w, err)
		return
	}
	a, err := s.DB.CreateAdmin(db.Admin{Username: in.Username, DisplayName: strings.TrimSpace(in.DisplayName), PasswordHash: hash})
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"admin": a})
}

// lastAdminGuard menolak perubahan yang membuat tidak ada admin aktif tersisa.
func (s *Server) lastAdminGuard(target db.Admin, stillActive bool) error {
	if target.Disabled || stillActive {
		return nil
	}
	n, err := s.DB.CountActiveAdmins()
	if err != nil {
		return err
	}
	if n <= 1 {
		return errors.New("harus ada minimal satu admin aktif")
	}
	return nil
}

func (s *Server) adminUpdateAdmin(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	var in struct {
		DisplayName *string `json:"displayName"`
		Disabled    *bool   `json:"disabled"`
		Password    *string `json:"password"`
	}
	if !decode(w, r, &in) {
		return
	}
	a, err := s.DB.GetAdmin(id)
	if err != nil {
		fail(w, err)
		return
	}
	next := a
	if in.DisplayName != nil {
		if utf8.RuneCountInString(*in.DisplayName) > maxDisplayNameChars {
			writeErr(w, http.StatusBadRequest, "nama tampilan maksimal 60 karakter")
			return
		}
		next.DisplayName = strings.TrimSpace(*in.DisplayName)
	}
	if in.Disabled != nil {
		next.Disabled = *in.Disabled
	}
	if id == adminOf(r).ID && next.Disabled {
		writeErr(w, http.StatusBadRequest, "tidak bisa menonaktifkan akun admin sendiri")
		return
	}
	if err := s.lastAdminGuard(a, !next.Disabled); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	reset := in.Password != nil && *in.Password != ""
	if reset {
		if id == adminOf(r).ID {
			writeErr(w, http.StatusBadRequest, "ganti password sendiri lewat Akun admin → Ganti password")
			return
		}
		if err := CheckPassword(*in.Password); err != nil {
			fail(w, err)
			return
		}
		hash, err := HashPassword(*in.Password)
		if err != nil {
			fail(w, err)
			return
		}
		if err := s.DB.SetAdminPassword(id, hash); err != nil {
			fail(w, err)
			return
		}
	}
	if err := s.DB.UpdateAdmin(next); err != nil {
		fail(w, err)
		return
	}
	if reset || (next.Disabled && !a.Disabled) {
		s.DB.DeleteAdminSessions(id, 0)
	}
	writeJSON(w, http.StatusOK, map[string]any{"admin": next})
}

func (s *Server) adminDeleteAdmin(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	if id == adminOf(r).ID {
		writeErr(w, http.StatusBadRequest, "tidak bisa menghapus akun admin sendiri")
		return
	}
	a, err := s.DB.GetAdmin(id)
	if err != nil {
		fail(w, err)
		return
	}
	if err := s.lastAdminGuard(a, false); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.DB.DeleteAdmin(id); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
