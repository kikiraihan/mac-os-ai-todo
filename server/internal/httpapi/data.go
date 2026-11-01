package httpapi

import (
	"database/sql"
	"net/http"
	"strconv"
	"strings"
	"time"

	"aitodo/server/internal/core"
	"aitodo/server/internal/db"
	"aitodo/server/internal/push"
)

const pollWait = 25 * time.Second

// changes: long-poll. Klien mengirim revisi terakhir; server menjawab segera
// kalau sudah berubah, atau menahan sampai 25 detik.
func (s *Server) changes(w http.ResponseWriter, r *http.Request) {
	u := userOf(r)
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	rev := s.Hub.Rev(u.ID)
	if r.URL.Query().Get("wait") == "1" && since == rev {
		rev = s.Hub.Wait(r.Context(), u.ID, since, pollWait)
	}
	writeJSON(w, http.StatusOK, map[string]int64{"rev": rev})
}

// mutate menjalankan f dalam satu transaksi dengan konteks core pengguna,
// lalu membangunkan perangkat lain.
func (s *Server) mutate(w http.ResponseWriter, r *http.Request, f func(c *core.Ctx) (any, error)) {
	u := userOf(r)
	var out any
	err := s.DB.Tx(func(tx *sql.Tx) error {
		var err error
		out, err = f(&core.Ctx{Q: tx, UserID: u.ID, Loc: s.loc(u), Source: "manual"})
		return err
	})
	if err != nil {
		fail(w, err)
		return
	}
	s.Hub.Bump(u.ID)
	writeJSON(w, http.StatusOK, out)
}

// --- todo -------------------------------------------------------------------------

func (s *Server) listTodos(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	f := db.TodoFilter{Status: q.Get("status"), From: q.Get("from"), To: q.Get("to"), List: q.Get("list"), Query: q.Get("q")}
	switch f.Status {
	case "", "all", "open", "done", "archived":
	default:
		writeErr(w, http.StatusBadRequest, "status tidak dikenal")
		return
	}
	todos, err := db.ListTodos(s.DB, userOf(r).ID, f)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"todos": todos, "rev": s.Hub.Rev(userOf(r).ID)})
}

func (s *Server) createTodo(w http.ResponseWriter, r *http.Request) {
	var in core.TodoInput
	if !decode(w, r, &in) {
		return
	}
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		t, err := core.CreateTodo(c, in)
		return map[string]any{"todo": t}, err
	})
}

func (s *Server) updateTodo(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	var in core.TodoInput
	if !decode(w, r, &in) {
		return
	}
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		t, err := core.UpdateTodo(c, id, in)
		return map[string]any{"todo": t}, err
	})
}

func (s *Server) todoAction(w http.ResponseWriter, r *http.Request, f func(c *core.Ctx, id int64) (db.Todo, error)) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		t, err := f(c, id)
		return map[string]any{"todo": t}, err
	})
}

func (s *Server) deleteTodo(w http.ResponseWriter, r *http.Request) {
	s.todoAction(w, r, core.DeleteTodo)
}

func (s *Server) completeTodo(w http.ResponseWriter, r *http.Request) {
	s.todoAction(w, r, core.CompleteTodo)
}

func (s *Server) reopenTodo(w http.ResponseWriter, r *http.Request) {
	s.todoAction(w, r, core.ReopenTodo)
}

func (s *Server) archiveDone(w http.ResponseWriter, r *http.Request) {
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		n, err := core.ArchiveDone(c)
		return map[string]int{"archived": n}, err
	})
}

// --- pengingat -------------------------------------------------------------------

func (s *Server) listReminders(w http.ResponseWriter, r *http.Request) {
	rs, err := db.ListReminders(s.DB, userOf(r).ID)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"reminders": core.ViewReminders(rs), "rev": s.Hub.Rev(userOf(r).ID)})
}

// upcoming: kemunculan pengingat dalam N jam ke depan (untuk notifikasi lokal
// di aplikasi Mac).
func (s *Server) upcoming(w http.ResponseWriter, r *http.Request) {
	u := userOf(r)
	hours, err := strconv.Atoi(r.URL.Query().Get("hours"))
	if err != nil || hours <= 0 {
		hours = 48
	}
	if hours > 24*7 {
		hours = 24 * 7
	}
	rs, err := db.ListReminders(s.DB, u.ID)
	if err != nil {
		fail(w, err)
		return
	}
	occ := core.Upcoming(rs, time.Now(), time.Duration(hours)*time.Hour, s.loc(u), 200)
	writeJSON(w, http.StatusOK, map[string]any{"occurrences": occ, "rev": s.Hub.Rev(u.ID)})
}

func (s *Server) createReminder(w http.ResponseWriter, r *http.Request) {
	var in core.ReminderInput
	if !decode(w, r, &in) {
		return
	}
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		rem, err := core.CreateReminder(c, in)
		return map[string]any{"reminder": core.ViewReminder(rem)}, err
	})
}

func (s *Server) updateReminder(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	var in core.ReminderInput
	if !decode(w, r, &in) {
		return
	}
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		rem, err := core.UpdateReminder(c, id, in)
		return map[string]any{"reminder": core.ViewReminder(rem)}, err
	})
}

func (s *Server) deleteReminder(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		_, err := core.DeleteReminder(c, id)
		return map[string]bool{"ok": true}, err
	})
}

func (s *Server) snoozeReminder(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	var in struct {
		Minutes int `json:"minutes"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Minutes == 0 {
		in.Minutes = 10
	}
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		rem, err := core.SnoozeReminder(c, id, in.Minutes)
		return map[string]any{"reminder": core.ViewReminder(rem)}, err
	})
}

// --- chat ---------------------------------------------------------------------------

func (s *Server) listChat(w http.ResponseWriter, r *http.Request) {
	u := userOf(r)
	before, _ := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	msgs, err := s.DB.ListChat(u.ID, before, 50)
	if err != nil {
		fail(w, err)
		return
	}
	var ids []int64
	for _, m := range msgs {
		if m.BatchID > 0 {
			ids = append(ids, m.BatchID)
		}
	}
	views, err := s.Assistant.Views(u.ID, ids)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": msgs, "batches": views})
}

func (s *Server) postChat(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Message string `json:"message"`
	}
	if !decode(w, r, &in) {
		return
	}
	u := userOf(r)
	if !strings.HasPrefix(strings.TrimSpace(in.Message), "/") {
		set := s.assistantSettings()
		key := "chat:" + strconv.FormatInt(u.ID, 10)
		if s.chatLimit.count(key, 24*time.Hour) >= set.PerDay {
			writeErr(w, http.StatusTooManyRequests, "batas pesan AI hari ini sudah habis")
			return
		}
		if !s.chatLimit.allow(key+":m", set.PerMinute, time.Minute) {
			writeErr(w, http.StatusTooManyRequests, "terlalu cepat, tunggu sebentar")
			return
		}
		s.chatLimit.add(key)
	}
	rep, err := s.Assistant.Handle(r.Context(), u, s.loc(u), in.Message)
	if err != nil {
		fail(w, err)
		return
	}
	s.Hub.Bump(u.ID)
	writeJSON(w, http.StatusOK, rep)
}

func (s *Server) clearChat(w http.ResponseWriter, r *http.Request) {
	u := userOf(r)
	if err := s.DB.ClearChat(u.ID); err != nil {
		fail(w, err)
		return
	}
	s.Hub.Bump(u.ID)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) batchAction(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	u := userOf(r)
	var err error
	var view any
	switch r.PathValue("action") {
	case "confirm":
		view, err = s.Assistant.Confirm(u, s.loc(u), id)
	case "reject":
		view, err = s.Assistant.Reject(u, id)
	case "undo":
		view, err = s.Assistant.Undo(u, id)
	default:
		writeErr(w, http.StatusNotFound, "aksi tidak dikenal")
		return
	}
	if err != nil {
		fail(w, err)
		return
	}
	s.Hub.Bump(u.ID)
	writeJSON(w, http.StatusOK, map[string]any{"batch": view})
}

// --- push ---------------------------------------------------------------------------

func (s *Server) pushKey(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"publicKey": s.Push.PublicKey})
}

func (s *Server) pushSubscribe(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Endpoint string `json:"endpoint"`
		Keys     struct {
			P256dh string `json:"p256dh"`
			Auth   string `json:"auth"`
		} `json:"keys"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !push.AllowedEndpoint(in.Endpoint) || in.Keys.P256dh == "" || in.Keys.Auth == "" ||
		len(in.Keys.P256dh) > 200 || len(in.Keys.Auth) > 100 {
		writeErr(w, http.StatusBadRequest, "langganan push tidak valid")
		return
	}
	u := userOf(r)
	if err := s.DB.UpsertPushSub(db.PushSub{UserID: u.ID, SessionID: sessionOf(r).ID, Endpoint: in.Endpoint,
		P256dh: in.Keys.P256dh, Auth: in.Keys.Auth}); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) pushUnsubscribe(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Endpoint string `json:"endpoint"`
	}
	if !decode(w, r, &in) {
		return
	}
	if err := s.DB.DeletePushSub(userOf(r).ID, in.Endpoint); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) pushTest(w http.ResponseWriter, r *http.Request) {
	n, err := s.Push.SendToUser(userOf(r).ID, push.Notification{Title: "Tes notifikasi", Body: "Notifikasi AI Todo sudah jalan 👍",
		URL: "/pengaturan", Tag: "test"})
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"sent": n})
}
