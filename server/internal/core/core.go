// Package core berisi aturan bisnis todo & pengingat. Form manual dan asisten
// AI memakai fungsi yang sama, jadi validasinya tidak bisa berbeda: AI tidak
// punya jalan pintas ke database.
package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"aitodo/server/internal/db"
	"aitodo/server/internal/schedule"
)

const (
	MaxTitle           = 200
	MaxNotes           = 2000
	MaxList            = 40
	MaxReminderMessage = 500
	MaxActiveReminders = 100

	StatusOpen     = "open"
	StatusDone     = "done"
	StatusArchived = "archived"
)

// ValidationError adalah kesalahan input yang aman ditampilkan ke pengguna.
type ValidationError struct{ Msg string }

func (e *ValidationError) Error() string { return e.Msg }

func invalid(format string, a ...any) error { return &ValidationError{Msg: fmt.Sprintf(format, a...)} }

// IsValidation melaporkan apakah err berasal dari validasi input.
func IsValidation(err error) bool {
	var v *ValidationError
	return errors.As(err, &v)
}

// Ctx membawa siapa yang beraksi, zona waktunya, dan perekam undo (boleh nil).
type Ctx struct {
	Q      db.Q
	UserID int64
	Loc    *time.Location
	Now    time.Time
	Rec    *Recorder
	Source string // manual | chat | notif
}

func (c *Ctx) now() time.Time {
	if c.Now.IsZero() {
		return time.Now().In(c.Loc)
	}
	return c.Now.In(c.Loc)
}

// Today mengembalikan tanggal hari ini (YYYY-MM-DD) di zona pengguna.
func (c *Ctx) Today() string { return c.now().Format("2006-01-02") }

// --- perekam undo ------------------------------------------------------------------

// Change adalah satu baris yang berubah. Before kosong = baris baru (undo
// menghapusnya); After kosong = baris dihapus (undo memulihkannya).
type Change struct {
	Kind   string          `json:"kind"` // todo | reminder | memory
	ID     int64           `json:"id"`
	Before json.RawMessage `json:"before,omitempty"`
	After  json.RawMessage `json:"after,omitempty"`
}

type Recorder struct {
	Changes []Change
}

func (r *Recorder) add(kind string, id int64, before, after any) {
	if r == nil {
		return
	}
	enc := func(v any) json.RawMessage {
		if v == nil {
			return nil
		}
		b, _ := json.Marshal(v)
		return b
	}
	r.Changes = append(r.Changes, Change{Kind: kind, ID: id, Before: enc(before), After: enc(after)})
}

// ErrStale: data sudah diubah lagi setelah aksi yang mau di-undo.
var ErrStale = errors.New("data sudah berubah sejak aksi itu, undo dibatalkan")

// Undo membalik perubahan dalam urutan terbalik. Setiap baris harus masih sama
// persis dengan keadaan setelah aksi (updated_at), supaya undo tidak menimpa
// perubahan yang dibuat belakangan.
func Undo(q db.Q, userID int64, changes []Change) error {
	for i := len(changes) - 1; i >= 0; i-- {
		ch := changes[i]
		switch ch.Kind {
		case "todo":
			cur, err := db.GetTodo(q, userID, ch.ID)
			if err := checkCurrent(err, ch.After, func(s db.TodoSnapshot) string { return s.UpdatedAt }, cur.UpdatedAt); err != nil {
				return err
			}
			if ch.Before == nil {
				if err := db.DeleteTodo(q, userID, ch.ID); err != nil {
					return err
				}
				continue
			}
			var snap db.TodoSnapshot
			if err := json.Unmarshal(ch.Before, &snap); err != nil || snap.UserID != userID {
				return errors.New("data undo rusak")
			}
			if err := db.RestoreTodo(q, snap); err != nil {
				return err
			}
		case "reminder":
			cur, err := db.GetReminder(q, userID, ch.ID)
			if err := checkCurrent(err, ch.After, func(s db.ReminderSnapshot) string { return s.UpdatedAt }, cur.UpdatedAt); err != nil {
				return err
			}
			if ch.Before == nil {
				if err := db.DeleteReminder(q, userID, ch.ID); err != nil {
					return err
				}
				continue
			}
			var snap db.ReminderSnapshot
			if err := json.Unmarshal(ch.Before, &snap); err != nil || snap.UserID != userID {
				return errors.New("data undo rusak")
			}
			if err := db.RestoreReminder(q, snap); err != nil {
				return err
			}
		case "memory":
			if err := undoMemory(q, userID, ch); err != nil {
				return err
			}
		default:
			return errors.New("data undo rusak")
		}
	}
	return nil
}

func checkCurrent[S any](getErr error, after json.RawMessage, stamp func(S) string, current string) error {
	if after == nil {
		// Baris dihapus oleh aksi: harus masih tidak ada.
		if getErr == nil {
			return ErrStale
		}
		if errors.Is(getErr, db.ErrNotFound) {
			return nil
		}
		return getErr
	}
	if errors.Is(getErr, db.ErrNotFound) {
		return ErrStale
	}
	if getErr != nil {
		return getErr
	}
	var s S
	if err := json.Unmarshal(after, &s); err != nil {
		return errors.New("data undo rusak")
	}
	if stamp(s) != current {
		return ErrStale
	}
	return nil
}

// --- todo ------------------------------------------------------------------------

// TodoInput: field nil berarti "tidak diubah".
type TodoInput struct {
	Title    *string `json:"title"`
	Notes    *string `json:"notes"`
	List     *string `json:"list"`
	Priority *string `json:"priority"`
	DueDate  *string `json:"dueDate"`
	DueTime  *string `json:"dueTime"`
	Status   *string `json:"status"`
}

func clean(s string) string {
	s = strings.TrimSpace(s)
	// Buang karakter kontrol selain baris baru/tab.
	return strings.Map(func(r rune) rune {
		if r < 32 && r != '\n' && r != '\t' {
			return -1
		}
		return r
	}, s)
}

func applyTodoInput(t *db.Todo, in TodoInput) {
	if in.Title != nil {
		t.Title = strings.ReplaceAll(clean(*in.Title), "\n", " ")
	}
	if in.Notes != nil {
		t.Notes = clean(*in.Notes)
	}
	if in.List != nil {
		t.List = strings.ReplaceAll(clean(*in.List), "\n", " ")
	}
	if in.Priority != nil {
		t.Priority = strings.ToLower(clean(*in.Priority))
	}
	if in.DueDate != nil {
		t.DueDate = clean(*in.DueDate)
		if t.DueDate == "" {
			t.DueTime = ""
		}
	}
	if in.DueTime != nil {
		t.DueTime = clean(*in.DueTime)
	}
	if in.Status != nil {
		t.Status = strings.ToLower(clean(*in.Status))
	}
}

func validateTodo(t *db.Todo) error {
	if t.Title == "" {
		return invalid("judul todo wajib diisi")
	}
	if utf8.RuneCountInString(t.Title) > MaxTitle {
		return invalid("judul maksimal %d karakter", MaxTitle)
	}
	if utf8.RuneCountInString(t.Notes) > MaxNotes {
		return invalid("catatan maksimal %d karakter", MaxNotes)
	}
	if utf8.RuneCountInString(t.List) > MaxList {
		return invalid("nama daftar maksimal %d karakter", MaxList)
	}
	if t.Priority == "" {
		t.Priority = "normal"
	}
	switch t.Priority {
	case "low", "normal", "high":
	default:
		return invalid("prioritas harus low, normal, atau high")
	}
	switch t.Status {
	case StatusOpen, StatusDone, StatusArchived:
	default:
		return invalid("status harus open, done, atau archived")
	}
	if t.DueDate != "" && !schedule.ValidDate(t.DueDate) {
		return invalid("tanggal tenggat %q tidak valid (YYYY-MM-DD)", t.DueDate)
	}
	if t.DueTime != "" {
		if t.DueDate == "" {
			return invalid("jam tenggat butuh tanggal")
		}
		if !schedule.ValidTime(t.DueTime) {
			return invalid("jam tenggat %q tidak valid (HH:MM)", t.DueTime)
		}
	}
	return nil
}

func CreateTodo(c *Ctx, in TodoInput) (db.Todo, error) {
	t := db.Todo{UserID: c.UserID, Status: StatusOpen, Priority: "normal", Source: c.Source}
	if t.Source == "" {
		t.Source = "manual"
	}
	applyTodoInput(&t, in)
	if err := validateTodo(&t); err != nil {
		return t, err
	}
	if t.Status == StatusDone {
		t.CompletedAt = db.Now()
	}
	t, err := db.InsertTodo(c.Q, t)
	if err != nil {
		return t, err
	}
	c.Rec.add("todo", t.ID, nil, db.SnapshotTodo(t))
	return t, nil
}

func UpdateTodo(c *Ctx, id int64, in TodoInput) (db.Todo, error) {
	before, err := db.GetTodo(c.Q, c.UserID, id)
	if err != nil {
		return before, err
	}
	t := before
	applyTodoInput(&t, in)
	if err := validateTodo(&t); err != nil {
		return t, err
	}
	if t.DueDate != before.DueDate || t.DueTime != before.DueTime {
		t.DueNotifiedAt = "" // tenggat baru → boleh diberi notifikasi lagi
	}
	if t.Status == StatusDone && before.Status != StatusDone {
		t.CompletedAt = db.Now()
	} else if t.Status == StatusOpen {
		t.CompletedAt = ""
	}
	t, err = db.UpdateTodo(c.Q, t)
	if err != nil {
		return t, err
	}
	c.Rec.add("todo", t.ID, db.SnapshotTodo(before), db.SnapshotTodo(t))
	if t.Status == StatusDone && before.Status != StatusDone {
		if err := deactivateOnceReminders(c, t.ID); err != nil {
			return t, err
		}
	}
	return t, nil
}

func setStatus(c *Ctx, id int64, status string) (db.Todo, error) {
	return UpdateTodo(c, id, TodoInput{Status: &status})
}

func CompleteTodo(c *Ctx, id int64) (db.Todo, error) { return setStatus(c, id, StatusDone) }
func ReopenTodo(c *Ctx, id int64) (db.Todo, error)   { return setStatus(c, id, StatusOpen) }

// deactivateOnceReminders mematikan pengingat sekali milik todo yang selesai.
// Pengingat berulang dibiarkan: bisa jadi memang rutinitas.
func deactivateOnceReminders(c *Ctx, todoID int64) error {
	rems, err := db.RemindersForTodo(c.Q, c.UserID, todoID)
	if err != nil {
		return err
	}
	for _, r := range rems {
		var s schedule.Schedule
		if json.Unmarshal(r.Schedule, &s) != nil || s.Kind != schedule.KindOnce || !r.Active {
			continue
		}
		before := r
		r.Active = false
		r.NextFireAt = ""
		r, err = db.UpdateReminder(c.Q, r)
		if err != nil {
			return err
		}
		c.Rec.add("reminder", r.ID, db.SnapshotReminder(before), db.SnapshotReminder(r))
	}
	return nil
}

// DeleteTodo menghapus todo beserta semua pengingatnya.
func DeleteTodo(c *Ctx, id int64) (db.Todo, error) {
	t, err := db.GetTodo(c.Q, c.UserID, id)
	if err != nil {
		return t, err
	}
	rems, err := db.RemindersForTodo(c.Q, c.UserID, id)
	if err != nil {
		return t, err
	}
	for _, r := range rems {
		if err := db.DeleteReminder(c.Q, c.UserID, r.ID); err != nil {
			return t, err
		}
		c.Rec.add("reminder", r.ID, db.SnapshotReminder(r), nil)
	}
	if err := db.DeleteTodo(c.Q, c.UserID, id); err != nil {
		return t, err
	}
	c.Rec.add("todo", t.ID, db.SnapshotTodo(t), nil)
	return t, nil
}

// ArchiveDone mengarsipkan semua todo yang sudah selesai.
func ArchiveDone(c *Ctx) (int, error) {
	done, err := db.ListTodos(c.Q, c.UserID, db.TodoFilter{Status: StatusDone})
	if err != nil {
		return 0, err
	}
	for _, t := range done {
		if _, err := setStatus(c, t.ID, StatusArchived); err != nil {
			return 0, err
		}
	}
	return len(done), nil
}

// --- pengingat -----------------------------------------------------------------------

type ReminderInput struct {
	Title    *string            `json:"title"`
	Message  *string            `json:"message"`
	Schedule *schedule.Schedule `json:"schedule"`
	TodoID   *int64             `json:"todoId"` // 0 = lepas dari todo
	Active   *bool              `json:"active"`
}

func ParseSchedule(raw json.RawMessage) (schedule.Schedule, error) {
	var s schedule.Schedule
	err := json.Unmarshal(raw, &s)
	return s, err
}

// computeNext menghitung next_fire_at dari keadaan pengingat.
func computeNext(c *Ctx, r *db.Reminder, s schedule.Schedule) {
	if !r.Active {
		r.NextFireAt = ""
		return
	}
	next, ok := s.Next(c.now(), c.Loc, r.FireCount)
	if !ok {
		r.NextFireAt = ""
		r.Active = false
		return
	}
	r.NextFireAt = db.Stamp(next)
}

func applyReminderInput(c *Ctx, r *db.Reminder, in ReminderInput, sched *schedule.Schedule) error {
	if in.Title != nil {
		r.Title = strings.ReplaceAll(clean(*in.Title), "\n", " ")
	}
	if in.Message != nil {
		r.Message = clean(*in.Message)
	}
	if in.TodoID != nil {
		if *in.TodoID == 0 {
			r.TodoID = nil
		} else {
			t, err := db.GetTodo(c.Q, c.UserID, *in.TodoID)
			if err != nil {
				return invalid("todo #%d tidak ditemukan", *in.TodoID)
			}
			id := t.ID
			r.TodoID = &id
			if r.Title == "" {
				r.Title = t.Title
			}
		}
	}
	if in.Active != nil {
		r.Active = *in.Active
	}
	if in.Schedule != nil {
		s := *in.Schedule
		if err := s.Normalize(c.Today()); err != nil {
			return invalid("jadwal tidak valid: %s", err.Error())
		}
		b, _ := json.Marshal(s)
		r.Schedule = b
		r.FireCount = 0
		*sched = s
	}
	if r.Title == "" {
		return invalid("judul pengingat wajib diisi")
	}
	if utf8.RuneCountInString(r.Title) > MaxTitle {
		return invalid("judul pengingat maksimal %d karakter", MaxTitle)
	}
	if utf8.RuneCountInString(r.Message) > MaxReminderMessage {
		return invalid("pesan pengingat maksimal %d karakter", MaxReminderMessage)
	}
	return nil
}

func checkReminderLimit(c *Ctx) error {
	n, err := db.CountActiveReminders(c.Q, c.UserID)
	if err != nil {
		return err
	}
	if n >= MaxActiveReminders {
		return invalid("sudah ada %d pengingat aktif (batas), jeda atau hapus yang lama dulu", n)
	}
	return nil
}

func CreateReminder(c *Ctx, in ReminderInput) (db.Reminder, error) {
	if in.Schedule == nil {
		return db.Reminder{}, invalid("jadwal pengingat wajib diisi")
	}
	if err := checkReminderLimit(c); err != nil {
		return db.Reminder{}, err
	}
	r := db.Reminder{UserID: c.UserID, Active: true}
	var s schedule.Schedule
	if err := applyReminderInput(c, &r, in, &s); err != nil {
		return r, err
	}
	r.Active = true
	computeNext(c, &r, s)
	if r.NextFireAt == "" {
		return r, invalid("waktu pengingat sudah lewat atau jadwalnya tidak pernah terjadi")
	}
	r, err := db.InsertReminder(c.Q, r)
	if err != nil {
		return r, err
	}
	c.Rec.add("reminder", r.ID, nil, db.SnapshotReminder(r))
	return r, nil
}

func UpdateReminder(c *Ctx, id int64, in ReminderInput) (db.Reminder, error) {
	before, err := db.GetReminder(c.Q, c.UserID, id)
	if err != nil {
		return before, err
	}
	r := before
	s, err := ParseSchedule(r.Schedule)
	if err != nil {
		return r, err
	}
	if err := applyReminderInput(c, &r, in, &s); err != nil {
		return r, err
	}
	if r.Active && !before.Active {
		if err := checkReminderLimit(c); err != nil {
			return r, err
		}
	}
	if in.Schedule != nil || in.Active != nil {
		wasActive := r.Active
		computeNext(c, &r, s)
		if wasActive && !r.Active && in.Schedule != nil {
			return r, invalid("waktu pengingat sudah lewat atau jadwalnya tidak pernah terjadi")
		}
		if wasActive && !r.Active && in.Active != nil && *in.Active {
			return r, invalid("jadwal pengingat ini sudah selesai, ubah jadwalnya dulu")
		}
	}
	r, err = db.UpdateReminder(c.Q, r)
	if err != nil {
		return r, err
	}
	c.Rec.add("reminder", r.ID, db.SnapshotReminder(before), db.SnapshotReminder(r))
	return r, nil
}

func SetReminderActive(c *Ctx, id int64, active bool) (db.Reminder, error) {
	return UpdateReminder(c, id, ReminderInput{Active: &active})
}

// SnoozeReminder memajukan bunyi berikutnya ke sekarang + minutes.
func SnoozeReminder(c *Ctx, id int64, minutes int) (db.Reminder, error) {
	if minutes < 5 || minutes > 24*60 {
		return db.Reminder{}, invalid("tunda harus 5–1440 menit")
	}
	before, err := db.GetReminder(c.Q, c.UserID, id)
	if err != nil {
		return before, err
	}
	r := before
	r.Active = true
	r.NextFireAt = db.Stamp(c.now().Add(time.Duration(minutes) * time.Minute))
	r, err = db.UpdateReminder(c.Q, r)
	if err != nil {
		return r, err
	}
	c.Rec.add("reminder", r.ID, db.SnapshotReminder(before), db.SnapshotReminder(r))
	return r, nil
}

func DeleteReminder(c *Ctx, id int64) (db.Reminder, error) {
	r, err := db.GetReminder(c.Q, c.UserID, id)
	if err != nil {
		return r, err
	}
	if err := db.DeleteReminder(c.Q, c.UserID, id); err != nil {
		return r, err
	}
	c.Rec.add("reminder", r.ID, db.SnapshotReminder(r), nil)
	return r, nil
}

// --- tampilan ----------------------------------------------------------------------

// ReminderView menambahkan teks jadwal yang mudah dibaca.
type ReminderView struct {
	db.Reminder
	ScheduleText string `json:"scheduleText"`
}

func ViewReminder(r db.Reminder) ReminderView {
	s, err := ParseSchedule(r.Schedule)
	text := ""
	if err == nil {
		text = s.Describe()
	}
	return ReminderView{Reminder: r, ScheduleText: text}
}

func ViewReminders(rs []db.Reminder) []ReminderView {
	out := make([]ReminderView, len(rs))
	for i, r := range rs {
		out[i] = ViewReminder(r)
	}
	return out
}

// Occurrence adalah satu kemunculan pengingat (untuk notifikasi lokal di Mac).
type Occurrence struct {
	ReminderID int64  `json:"reminderId"`
	TodoID     *int64 `json:"todoId"`
	Title      string `json:"title"`
	Body       string `json:"body"`
	At         string `json:"at"`
}

// Upcoming menghitung kemunculan pengingat aktif dalam rentang [now, now+d].
func Upcoming(rs []db.Reminder, now time.Time, d time.Duration, loc *time.Location, limit int) []Occurrence {
	end := now.Add(d)
	out := []Occurrence{}
	for _, r := range rs {
		if !r.Active || r.NextFireAt == "" {
			continue
		}
		s, err := ParseSchedule(r.Schedule)
		if err != nil {
			continue
		}
		t, err := db.ParseStamp(r.NextFireAt)
		fired := r.FireCount
		for n := 0; err == nil && !t.After(end) && n < 200; n++ {
			if !t.Before(now.Add(-time.Minute)) {
				out = append(out, Occurrence{ReminderID: r.ID, TodoID: r.TodoID, Title: r.Title, Body: ReminderBody(r, s), At: db.Stamp(t)})
			}
			fired++
			next, ok := s.Next(t, loc, fired)
			if !ok {
				break
			}
			t = next
		}
	}
	sortOccurrences(out)
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

// ReminderBody adalah isi notifikasi pengingat.
func ReminderBody(r db.Reminder, s schedule.Schedule) string {
	if r.Message != "" {
		return r.Message
	}
	if s.Kind == schedule.KindOnce {
		return "Pengingat"
	}
	return s.Describe()
}

func sortOccurrences(o []Occurrence) {
	for i := 1; i < len(o); i++ {
		for j := i; j > 0 && o[j].At < o[j-1].At; j-- {
			o[j], o[j-1] = o[j-1], o[j]
		}
	}
}
