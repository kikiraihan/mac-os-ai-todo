package httpapi

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"aitodo/server/internal/release"
)

// Pembaruan aplikasi Mac lewat server: repo GitHub boleh private, token-nya hanya
// ada di server (GITHUB_RELEASE_TOKEN). Wajib login (token perangkat / cookie),
// jadi file rilis tidak terbuka untuk umum. Keaslian file tetap dicek di Mac lewat
// tanda tangan Ed25519 — server ini hanya perantara.

func (s *Server) releaseRoutes() {
	m := s.Mux
	m.HandleFunc("GET /api/app/mac/latest", s.authed(s.macLatest))
	m.HandleFunc("GET /api/app/mac/download/{name}", s.authed(s.macDownload))
	// Android memakai rilis yang sama (file AITodo.apk).
	m.HandleFunc("GET /api/app/android/latest", s.authed(s.macLatest))
	m.HandleFunc("GET /api/app/android/download/{name}", s.authed(s.macDownload))
	// Tautan unduh APK untuk browser (web/PWA): navigasi biasa tidak bisa mengirim header X-AITodo,
	// jadi di luar /api/. Tetap wajib login (cookie SameSite=Strict / Bearer); belum login → halaman masuk.
	m.HandleFunc("GET /unduh/AITodo.apk", s.apkBrowserDownload)
}

func releaseErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, release.ErrDisabled):
		writeErr(w, http.StatusNotImplemented, err.Error())
	case errors.Is(err, release.ErrNoRelease), errors.Is(err, release.ErrNoAsset):
		writeErr(w, http.StatusNotFound, err.Error())
	default:
		log.Printf("rilis: %v", err)
		writeErr(w, http.StatusBadGateway, "server gagal menghubungi GitHub, coba lagi nanti")
	}
}

func (s *Server) macLatest(w http.ResponseWriter, r *http.Request) {
	info, err := s.Release.Latest(r.Context())
	if err != nil {
		releaseErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, info)
}

func (s *Server) apkBrowserDownload(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	sess, user, ok := s.authenticate(w, r)
	if !ok {
		http.Redirect(w, r, "/masuk?next=%2Faplikasi", http.StatusFound)
		return
	}
	ctx := context.WithValue(r.Context(), keyUser, user)
	ctx = context.WithValue(ctx, keySession, sess)
	s.serveAsset(w, r.WithContext(ctx), "AITodo.apk")
}

func (s *Server) macDownload(w http.ResponseWriter, r *http.Request) {
	s.serveAsset(w, r, r.PathValue("name"))
}

// serveAsset meneruskan satu file rilis (hanya nama di release.Assets) ke pengguna yang sudah login.
func (s *Server) serveAsset(w http.ResponseWriter, r *http.Request, name string) {
	known := false
	for _, a := range release.Assets {
		known = known || a == name
	}
	if !known {
		writeErr(w, http.StatusNotFound, release.ErrNoAsset.Error())
		return
	}
	if !s.dlLimit.allow(strconv.FormatInt(userOf(r).ID, 10), 30, time.Hour) {
		writeErr(w, http.StatusTooManyRequests, "terlalu sering mengunduh, coba lagi nanti")
		return
	}
	// WriteTimeout server (100 detik) terlalu pendek untuk koneksi lambat.
	http.NewResponseController(w).SetWriteDeadline(time.Now().Add(10 * time.Minute))
	started := false
	err := s.Release.Download(r.Context(), name, w, func(size int64) {
		started = true
		h := w.Header()
		if strings.HasSuffix(name, ".apk") {
			h.Set("Content-Type", "application/vnd.android.package-archive")
		} else {
			h.Set("Content-Type", "application/octet-stream")
		}
		h.Set("Content-Disposition", `attachment; filename="`+name+`"`)
		if size >= 0 {
			h.Set("Content-Length", strconv.FormatInt(size, 10))
		}
		w.WriteHeader(http.StatusOK)
	})
	if err != nil {
		if started {
			// Header sudah terkirim: koneksi diputus, klien melihat unduhan tidak lengkap.
			log.Printf("rilis: unduh %s terputus: %v", name, err)
			return
		}
		releaseErr(w, err)
	}
}
