package httpapi

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"aitodo/server/internal/core"
	"aitodo/server/internal/db"
	"aitodo/server/internal/fcm"
	"aitodo/server/internal/push"
	"aitodo/server/internal/scheduler"
)

// Kiriman antarperangkat, kotak masuk notifikasi (aplikasi Android), dan
// pendaftaran token FCM.

func (s *Server) clipRoutes() {
	m := s.Mux
	m.HandleFunc("GET /api/clips", s.authed(s.listClips))
	m.HandleFunc("POST /api/clips", s.authed(s.createClip))
	m.HandleFunc("GET /api/clips/{id}", s.authed(s.getClip))
	m.HandleFunc("DELETE /api/clips/{id}", s.authed(s.deleteClip))
	m.HandleFunc("DELETE /api/clips", s.authed(s.clearClips))

	m.HandleFunc("GET /api/notifications", s.authed(s.listInbox))
	m.HandleFunc("POST /api/push/fcm", s.authed(s.fcmRegister))
	m.HandleFunc("POST /api/push/fcm/unregister", s.authed(s.fcmUnregister))
	m.HandleFunc("GET /api/app/android/config", s.authed(s.androidConfig))
}

func (s *Server) listClips(w http.ResponseWriter, r *http.Request) {
	u := userOf(r)
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	clips, err := db.ListClips(s.DB, u.ID, after, core.MaxClipsPerUser)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"clips": clips, "rev": s.Hub.Rev(u.ID)})
}

func (s *Server) getClip(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	c, err := db.GetClip(s.DB, userOf(r).ID, id)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"clip": c})
}

// deviceLabel: nama perangkat pengirim untuk ditampilkan ("dari MacBook").
func deviceLabel(sess db.Session) string {
	if sess.Kind == db.SessionWeb {
		return "Browser"
	}
	return sess.Name
}

func (s *Server) createClip(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Content string `json:"content"`
	}
	if !decode(w, r, &in) {
		return
	}
	u, sess := userOf(r), sessionOf(r)
	if !s.chatLimit.allow("clip:"+strconv.FormatInt(u.ID, 10), 60, time.Minute) {
		writeErr(w, http.StatusTooManyRequests, "terlalu banyak kiriman, tunggu sebentar")
		return
	}
	clip, sent, err := s.sendClip(u, sess.ID, deviceLabel(sess), in.Content)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"clip": clip, "sent": sent})
}

// sendClip menyimpan kiriman lalu memberi tahu semua perangkat lain (dipakai API & MCP).
func (s *Server) sendClip(u db.User, sessionID int64, device, content string) (db.Clip, int, error) {
	var clip db.Clip
	err := s.DB.Tx(func(tx *sql.Tx) error {
		var err error
		clip, err = core.CreateClip(&core.Ctx{Q: tx, UserID: u.ID, Loc: s.loc(u), Source: "manual"}, content, device, sessionID)
		return err
	})
	if err != nil {
		return clip, 0, err
	}
	s.Hub.Bump(u.ID)
	m, _ := s.DB.GetUserSettings(u.ID)
	n := push.Notification{Kind: "clip", Title: "Kiriman baru", Body: core.ClipPreview(clip.Content, 200), URL: "/kiriman",
		Tag: "clip-" + strconv.FormatInt(clip.ID, 10), ClipID: clip.ID, Text: clip.Content}
	if clip.Device != "" {
		n.Title = "Kiriman dari " + clip.Device
	}
	if scheduler.PrefsFrom(m).HideContent {
		// Isi tetap bisa disalin: tombol Salin mengambilnya lewat GET /api/clips/{id}.
		n.Title, n.Body, n.Text, n.TextTruncated = "Kiriman baru", "Ketuk Salin untuk menyalin", "", true
	}
	sent, _ := s.Push.Notify(u.ID, sessionID, n)
	return clip, sent, nil
}

func (s *Server) deleteClip(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	u := userOf(r)
	if err := db.DeleteClip(s.DB, u.ID, id); err != nil {
		fail(w, err)
		return
	}
	s.Hub.Bump(u.ID)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) clearClips(w http.ResponseWriter, r *http.Request) {
	u := userOf(r)
	if err := db.ClearClips(s.DB, u.ID); err != nil {
		fail(w, err)
		return
	}
	s.Hub.Bump(u.ID)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// listInbox: notifikasi setelah ?after=<id> untuk aplikasi Android. Tanpa after =
// hanya nomor terakhir (dipakai saat baru login supaya notifikasi lama tidak muncul).
func (s *Server) listInbox(w http.ResponseWriter, r *http.Request) {
	u, sess := userOf(r), sessionOf(r)
	last, err := s.DB.LastNotificationID(u.ID)
	if err != nil {
		fail(w, err)
		return
	}
	items := []json.RawMessage{}
	if v := r.URL.Query().Get("after"); v != "" {
		after, err := strconv.ParseInt(v, 10, 64)
		if err != nil || after < 0 {
			writeErr(w, http.StatusBadRequest, "after tidak valid")
			return
		}
		rows, err := s.DB.ListNotifications(u.ID, after, 50)
		if err != nil {
			fail(w, err)
			return
		}
		for _, n := range rows {
			if n.ExceptSessionID != 0 && n.ExceptSessionID == sess.ID {
				continue
			}
			var p map[string]any
			if json.Unmarshal([]byte(n.Payload), &p) != nil {
				continue
			}
			p["id"], p["createdAt"] = n.ID, n.CreatedAt
			b, _ := json.Marshal(p)
			items = append(items, b)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"last": last, "items": items, "rev": s.Hub.Rev(u.ID)})
}

func (s *Server) fcmRegister(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Token string `json:"token"`
	}
	if !decode(w, r, &in) {
		return
	}
	sess := sessionOf(r)
	if sess.Kind != db.SessionDevice {
		writeErr(w, http.StatusBadRequest, "token FCM hanya untuk aplikasi Android")
		return
	}
	if !fcm.ValidToken(in.Token) {
		writeErr(w, http.StatusBadRequest, "token FCM tidak valid")
		return
	}
	if err := s.DB.UpsertFCMToken(db.FCMToken{UserID: userOf(r).ID, SessionID: sess.ID, Token: in.Token}); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) fcmUnregister(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Token string `json:"token"`
	}
	if !decode(w, r, &in) {
		return
	}
	if err := s.DB.DeleteFCMToken(userOf(r).ID, in.Token); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// androidConfig: pengenal Firebase (bukan rahasia; normalnya tertanam di google-services.json)
// supaya satu APK bisa dipakai dengan server mana pun. fcm = null → aplikasi memakai long-poll.
func (s *Server) androidConfig(w http.ResponseWriter, r *http.Request) {
	var cfg any
	if s.FCM.Ready() {
		cfg = s.FCM.Android
	}
	writeJSON(w, http.StatusOK, map[string]any{"fcm": cfg, "version": s.Cfg.Version})
}
