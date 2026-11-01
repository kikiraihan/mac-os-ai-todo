// Package scheduler membunyikan pengingat, notifikasi tenggat, ringkasan pagi,
// dan dorongan untuk todo yang terlambat.
package scheduler

import (
	"context"
	"fmt"
	"log"
	"strings"
	"time"

	"aitodo/server/internal/core"
	"aitodo/server/internal/db"
	"aitodo/server/internal/push"
)

const (
	tick = 30 * time.Second
	// Kemunculan yang terlewat (server mati) lebih lama dari ini tidak dikirim.
	maxLate = 30 * time.Minute
	// Notifikasi tenggat dikirim sekian menit sebelum jam tenggat.
	dueLead = 10 * time.Minute

	// Pengaturan per pengguna (user_settings).
	KeyBriefTime   = "brief_time"   // "06:30", "" = mati
	KeyNudgeTime   = "nudge_time"   // "19:00", "" = mati
	KeyHideContent = "hide_content" // "1" = sembunyikan isi notifikasi
	KeyDueNotify   = "due_notify"   // "0" = jangan beri tahu tenggat
	keyLastBrief   = "last_brief_date"
	keyLastNudge   = "last_nudge_date"

	DefaultBriefTime = "06:30"
	DefaultNudgeTime = "19:00"
)

// UserPrefs adalah pengaturan notifikasi seorang pengguna.
type UserPrefs struct {
	BriefTime   string `json:"briefTime"`
	NudgeTime   string `json:"nudgeTime"`
	HideContent bool   `json:"hideContent"`
	DueNotify   bool   `json:"dueNotify"`
}

func PrefsFrom(m map[string]string) UserPrefs {
	p := UserPrefs{BriefTime: DefaultBriefTime, NudgeTime: DefaultNudgeTime, DueNotify: true}
	if v, ok := m[KeyBriefTime]; ok {
		p.BriefTime = v
	}
	if v, ok := m[KeyNudgeTime]; ok {
		p.NudgeTime = v
	}
	p.HideContent = m[KeyHideContent] == "1"
	p.DueNotify = m[KeyDueNotify] != "0"
	return p
}

type Scheduler struct {
	DB   *db.DB
	Push *push.Service
	// Loc mengembalikan zona waktu pengguna.
	Loc func(u db.User) *time.Location
	// OnChange dipanggil saat data pengguna berubah (next_fire_at maju).
	OnChange func(userID int64)
}

func (s *Scheduler) Run(ctx context.Context) {
	t := time.NewTicker(tick)
	defer t.Stop()
	s.runOnce(time.Now())
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			s.runOnce(now)
		}
	}
}

func (s *Scheduler) runOnce(now time.Time) {
	users, err := s.DB.ListUsers()
	if err != nil {
		log.Printf("scheduler: list users: %v", err)
		return
	}
	byID := map[int64]db.User{}
	for _, u := range users {
		if !u.Disabled {
			byID[u.ID] = u
		}
	}
	prefs := map[int64]UserPrefs{}
	prefsOf := func(id int64) UserPrefs {
		if p, ok := prefs[id]; ok {
			return p
		}
		m, _ := s.DB.GetUserSettings(id)
		p := PrefsFrom(m)
		prefs[id] = p
		return p
	}
	s.fireReminders(now, byID, prefsOf)
	s.dueTodos(now, byID, prefsOf)
	for _, u := range byID {
		s.daily(now, u, prefsOf(u.ID))
	}
}

func (s *Scheduler) notify(userID int64, p UserPrefs, n push.Notification) {
	if p.HideContent {
		n.Title, n.Body = "Pengingat", "Buka AI Todo untuk melihatnya"
	}
	if _, err := s.Push.SendToUser(userID, n); err != nil && !strings.Contains(err.Error(), "belum ada perangkat") {
		log.Printf("scheduler: push user %d: %v", userID, err)
	}
}

func (s *Scheduler) fireReminders(now time.Time, users map[int64]db.User, prefsOf func(int64) UserPrefs) {
	due, err := s.DB.DueReminders(db.Stamp(now))
	if err != nil {
		log.Printf("scheduler: due reminders: %v", err)
		return
	}
	for _, r := range due {
		u, ok := users[r.UserID]
		if !ok {
			continue
		}
		loc := s.Loc(u)
		sched, err := core.ParseSchedule(r.Schedule)
		if err != nil {
			continue
		}
		fireAt, err := db.ParseStamp(r.NextFireAt)
		if err != nil {
			continue
		}
		// Hitung kemunculan berikutnya dari "sekarang" supaya kemunculan yang
		// terlewat saat server mati tidak dikirim beruntun.
		after := now
		if fireAt.After(after) {
			after = fireAt
		}
		next, more := sched.Next(after, loc, r.FireCount+1)
		newNext := ""
		if more {
			newNext = db.Stamp(next)
		}
		claimed, err := s.DB.AdvanceReminder(r.ID, r.NextFireAt, newNext, more)
		if err != nil || !claimed {
			continue
		}
		if s.OnChange != nil {
			s.OnChange(r.UserID)
		}
		if now.Sub(fireAt) > maxLate {
			continue
		}
		body := core.ReminderBody(r, sched)
		if now.Sub(fireAt) > 2*time.Minute {
			body = "(terlambat) " + body
		}
		n := push.Notification{Title: r.Title, Body: body, URL: "/pengingat", Tag: fmt.Sprintf("reminder-%d", r.ID), ReminderID: r.ID}
		if r.TodoID != nil {
			n.TodoID = *r.TodoID
			n.URL = "/todo"
		}
		s.notify(r.UserID, prefsOf(r.UserID), n)
	}
}

func (s *Scheduler) dueTodos(now time.Time, users map[int64]db.User, prefsOf func(int64) UserPrefs) {
	// Rentang tanggal lebar supaya semua zona waktu tercakup.
	from := now.AddDate(0, 0, -1).Format("2006-01-02")
	to := now.AddDate(0, 0, 2).Format("2006-01-02")
	todos, err := s.DB.DueTodosToNotify(from, to)
	if err != nil {
		log.Printf("scheduler: due todos: %v", err)
		return
	}
	for _, t := range todos {
		u, ok := users[t.UserID]
		if !ok {
			continue
		}
		p := prefsOf(t.UserID)
		if !p.DueNotify {
			continue
		}
		due, err := time.ParseInLocation("2006-01-02 15:04", t.DueDate+" "+t.DueTime, s.Loc(u))
		if err != nil {
			continue
		}
		if now.Before(due.Add(-dueLead)) || now.After(due.Add(maxLate)) {
			continue
		}
		claimed, err := s.DB.ClaimDueNotification(t.ID)
		if err != nil || !claimed {
			continue
		}
		mins := int(due.Sub(now).Round(time.Minute).Minutes())
		body := "Tenggat sekarang (" + t.DueTime + ")"
		if mins > 0 {
			body = fmt.Sprintf("Tenggat %d menit lagi (%s)", mins, t.DueTime)
		}
		s.notify(t.UserID, p, push.Notification{Title: t.Title, Body: body, URL: "/todo", Tag: fmt.Sprintf("todo-%d", t.ID), TodoID: t.ID})
	}
}

// daily mengirim ringkasan pagi & dorongan terlambat, sekali per hari.
func (s *Scheduler) daily(now time.Time, u db.User, p UserPrefs) {
	loc := s.Loc(u)
	local := now.In(loc)
	today := local.Format("2006-01-02")
	clock := local.Format("15:04")
	settings, _ := s.DB.GetUserSettings(u.ID)

	ready := func(at string) bool {
		if at == "" {
			return false
		}
		t, err := time.ParseInLocation("2006-01-02 15:04", today+" "+at, loc)
		// Hanya dalam 30 menit setelah jamnya, supaya restart siang tidak
		// mengirim ringkasan pagi.
		return err == nil && clock >= at && local.Sub(t) <= maxLate
	}

	if ready(p.BriefTime) && settings[keyLastBrief] != today {
		if ok, _ := s.DB.ClaimUserSetting(u.ID, keyLastBrief, settings[keyLastBrief], today); ok {
			if n, send := s.brief(u, today); send {
				s.notify(u.ID, p, n)
			}
		}
	}
	if ready(p.NudgeTime) && settings[keyLastNudge] != today {
		if ok, _ := s.DB.ClaimUserSetting(u.ID, keyLastNudge, settings[keyLastNudge], today); ok {
			if n, send := s.nudge(u, today); send {
				s.notify(u.ID, p, n)
			}
		}
	}
}

func (s *Scheduler) openTodos(u db.User) []db.Todo {
	ts, err := db.ListTodos(s.DB, u.ID, db.TodoFilter{Status: core.StatusOpen})
	if err != nil {
		return nil
	}
	return ts
}

func titles(ts []db.Todo, n int) string {
	var out []string
	for i, t := range ts {
		if i == n {
			out = append(out, fmt.Sprintf("+%d lagi", len(ts)-n))
			break
		}
		out = append(out, t.Title)
	}
	return strings.Join(out, ", ")
}

func (s *Scheduler) brief(u db.User, today string) (push.Notification, bool) {
	var todayList, late []db.Todo
	for _, t := range s.openTodos(u) {
		switch {
		case t.DueDate == today:
			todayList = append(todayList, t)
		case t.DueDate != "" && t.DueDate < today:
			late = append(late, t)
		}
	}
	if len(todayList) == 0 && len(late) == 0 {
		return push.Notification{}, false
	}
	title := fmt.Sprintf("%d todo hari ini", len(todayList))
	if len(late) > 0 {
		title += fmt.Sprintf(", %d terlambat", len(late))
	}
	return push.Notification{Title: title, Body: titles(append(todayList, late...), 3), URL: "/todo", Tag: "brief-" + today}, true
}

func (s *Scheduler) nudge(u db.User, today string) (push.Notification, bool) {
	var late []db.Todo
	for _, t := range s.openTodos(u) {
		if t.DueDate != "" && t.DueDate < today {
			late = append(late, t)
		}
	}
	if len(late) == 0 {
		return push.Notification{}, false
	}
	return push.Notification{Title: fmt.Sprintf("%d todo lewat tenggat", len(late)), Body: titles(late, 3), URL: "/todo",
		Tag: "nudge-" + today}, true
}
