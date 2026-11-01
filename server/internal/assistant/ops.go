package assistant

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"aitodo/server/internal/core"
	"aitodo/server/internal/db"
	"aitodo/server/internal/schedule"
)

const (
	maxActions = 20
	maxCreates = 10
	// Lebih dari ini perubahan pada data yang sudah ada sekaligus → konfirmasi.
	maxSilentEdits = 3
)

// Op adalah satu aksi tervalidasi bentuknya. Disimpan apa adanya di batch,
// sehingga konfirmasi menjalankan persis apa yang ditampilkan ke pengguna.
type Op struct {
	Op         string             `json:"op"`
	TodoID     int64              `json:"todoId,omitempty"`
	ReminderID int64              `json:"reminderId,omitempty"`
	MemoryID   int64              `json:"memoryId,omitempty"`
	Target     string             `json:"target,omitempty"` // memory: profile | notes
	Content    *string            `json:"content,omitempty"`
	TodoRef    int                `json:"todoRef,omitempty"` // 1-based indeks aksi todo.create di pesan yang sama
	Title      *string            `json:"title,omitempty"`
	Notes      *string            `json:"notes,omitempty"`
	List       *string            `json:"list,omitempty"`
	Priority   *string            `json:"priority,omitempty"`
	DueDate    *string            `json:"dueDate,omitempty"`
	DueTime    *string            `json:"dueTime,omitempty"`
	Message    *string            `json:"message,omitempty"`
	Schedule   *schedule.Schedule `json:"schedule,omitempty"`
	Minutes    int                `json:"minutes,omitempty"`
	// filter untuk *.list
	Status string `json:"status,omitempty"`
	From   string `json:"from,omitempty"`
	To     string `json:"to,omitempty"`
	Query  string `json:"query,omitempty"`
}

var allowedOps = map[string]bool{
	"todo.list": true, "reminder.list": true,
	"todo.create": true, "todo.update": true, "todo.complete": true, "todo.reopen": true, "todo.delete": true,
	"todo.archiveDone": true,
	"reminder.create":  true, "reminder.update": true, "reminder.pause": true, "reminder.resume": true,
	"reminder.snooze": true, "reminder.delete": true,
	"memory.add": true, "memory.update": true, "memory.remove": true,
	"chat.search": true,
}

var dangerousOps = map[string]bool{"todo.delete": true, "reminder.delete": true, "todo.archiveDone": true, "memory.remove": true}

func (o Op) isList() bool {
	return o.Op == "todo.list" || o.Op == "reminder.list" || o.Op == "chat.search"
}

// editsExisting: aksi yang mengubah data yang sudah ada.
func (o Op) editsExisting() bool {
	switch o.Op {
	case "todo.update", "todo.complete", "todo.reopen", "reminder.update", "reminder.pause", "reminder.resume", "reminder.snooze":
		return true
	}
	return false
}

// needsConfirm: hapus/bersihkan selalu, atau terlalu banyak perubahan sekaligus.
func needsConfirm(ops []Op) bool {
	edits := 0
	for _, o := range ops {
		if dangerousOps[o.Op] {
			return true
		}
		if o.editsExisting() {
			edits++
		}
	}
	return edits > maxSilentEdits
}

// --- konversi dari JSON longgar model -----------------------------------------

type rawMap map[string]any

func (m rawMap) first(keys ...string) (any, bool) {
	for _, k := range keys {
		if v, ok := m[k]; ok && v != nil {
			return v, true
		}
	}
	return nil, false
}

func (m rawMap) str(keys ...string) *string {
	v, ok := m.first(keys...)
	if !ok {
		return nil
	}
	switch x := v.(type) {
	case string:
		return &x
	case float64:
		s := strconv.FormatFloat(x, 'f', -1, 64)
		return &s
	case bool:
		s := strconv.FormatBool(x)
		return &s
	}
	return nil
}

func (m rawMap) text(keys ...string) string {
	if p := m.str(keys...); p != nil {
		return strings.TrimSpace(*p)
	}
	return ""
}

func (m rawMap) num(keys ...string) (int64, bool) {
	v, ok := m.first(keys...)
	if !ok {
		return 0, false
	}
	switch x := v.(type) {
	case float64:
		return int64(x), x == float64(int64(x))
	case string:
		v := strings.TrimLeft(strings.TrimSpace(x), "#mM")
		n, err := strconv.ParseInt(v, 10, 64)
		return n, err == nil
	}
	return 0, false
}

// ref membaca rujukan "$N" (indeks aksi, 0-based seperti di prompt).
func (m rawMap) ref(keys ...string) (int, bool) {
	v, ok := m.first(keys...)
	if !ok {
		return 0, false
	}
	s, ok := v.(string)
	if !ok || !strings.HasPrefix(strings.TrimSpace(s), "$") {
		return 0, false
	}
	n, err := strconv.Atoi(strings.TrimPrefix(strings.TrimSpace(s), "$"))
	return n, err == nil
}

// toOps mengubah aksi mentah dari model menjadi Op dan memeriksa bentuknya.
// Kepemilikan & isi data diperiksa lagi oleh core saat dijalankan.
func toOps(raw []map[string]any) ([]Op, error) {
	if len(raw) > maxActions {
		return nil, fmt.Errorf("terlalu banyak aksi (%d), maksimal %d", len(raw), maxActions)
	}
	ops := make([]Op, 0, len(raw))
	createIdx := map[int]int{} // indeks aksi → nomor urut todo.create (1-based)
	creates := 0
	for i, r := range raw {
		m := rawMap(r)
		op := Op{Op: m.text("op", "action", "type")}
		if !allowedOps[op.Op] {
			return nil, fmt.Errorf("aksi ke-%d: op %q tidak dikenal", i, op.Op)
		}
		op.Title = m.str("title")
		op.Notes = m.str("notes", "note")
		op.List = m.str("list")
		op.Priority = m.str("priority")
		op.DueDate = m.str("dueDate", "due_date")
		op.DueTime = m.str("dueTime", "due_time")
		op.Message = m.str("message")
		if n, ok := m.num("minutes"); ok {
			op.Minutes = int(n)
		}
		op.Status = m.text("status")
		op.From = m.text("from")
		op.To = m.text("to")
		op.Query = m.text("query", "q")

		op.Content = m.str("content", "text")
		op.Target = strings.ToLower(m.text("target"))
		switch op.Target {
		case "user", "profil", "profile":
			op.Target = db.MemoryProfile
		case "memory", "catatan", "notes", "note":
			op.Target = db.MemoryNotes
		}
		if strings.HasPrefix(op.Op, "memory.") {
			if n, ok := m.num("memoryId", "memory_id", "id"); ok {
				op.MemoryID = n
			}
		} else if strings.HasPrefix(op.Op, "todo.") {
			if n, ok := m.num("todoId", "todo_id", "id"); ok {
				op.TodoID = n
			}
		} else {
			if n, ok := m.num("reminderId", "reminder_id", "id"); ok {
				op.ReminderID = n
			}
			if n, ok := m.num("todoId", "todo_id"); ok {
				op.TodoID = n
			}
			if ref, ok := m.ref("todoRef", "todo_ref", "todoId"); ok {
				nr, exists := createIdx[ref]
				if !exists {
					return nil, fmt.Errorf("aksi ke-%d: todoRef $%d bukan aksi todo.create sebelumnya", i, ref)
				}
				op.TodoRef = nr
				op.TodoID = 0
			}
		}
		if sch, ok := m.first("schedule"); ok {
			b, _ := json.Marshal(sch)
			var s schedule.Schedule
			if err := json.Unmarshal(b, &s); err != nil {
				return nil, fmt.Errorf("aksi ke-%d: jadwal tidak bisa dibaca", i)
			}
			op.Schedule = &s
		}

		switch op.Op {
		case "todo.create":
			creates++
			createIdx[i] = creates
			if op.Title == nil || strings.TrimSpace(*op.Title) == "" {
				return nil, fmt.Errorf("aksi ke-%d: todo.create butuh title", i)
			}
		case "todo.update", "todo.complete", "todo.reopen", "todo.delete":
			if op.TodoID <= 0 {
				return nil, fmt.Errorf("aksi ke-%d: %s butuh todoId dari data", i, op.Op)
			}
		case "reminder.create":
			if op.Schedule == nil {
				return nil, fmt.Errorf("aksi ke-%d: reminder.create butuh schedule", i)
			}
		case "reminder.update", "reminder.pause", "reminder.resume", "reminder.delete", "reminder.snooze":
			if op.ReminderID <= 0 {
				return nil, fmt.Errorf("aksi ke-%d: %s butuh reminderId dari data", i, op.Op)
			}
		case "memory.add":
			if op.Target == "" || op.Content == nil {
				return nil, fmt.Errorf("aksi ke-%d: memory.add butuh target (profile/notes) dan content", i)
			}
		case "memory.update":
			if op.MemoryID <= 0 || op.Content == nil {
				return nil, fmt.Errorf("aksi ke-%d: memory.update butuh memoryId dan content", i)
			}
		case "memory.remove":
			if op.MemoryID <= 0 {
				return nil, fmt.Errorf("aksi ke-%d: memory.remove butuh memoryId", i)
			}
		case "chat.search":
			if op.Query == "" {
				return nil, fmt.Errorf("aksi ke-%d: chat.search butuh query", i)
			}
		}
		ops = append(ops, op)
	}
	if creates > maxCreates {
		return nil, fmt.Errorf("maksimal %d todo baru per pesan", maxCreates)
	}
	return ops, nil
}

// --- menjalankan aksi -----------------------------------------------------------

// Item adalah satu baris di kartu aksi.
type Item struct {
	Op      string `json:"op"`
	Summary string `json:"summary"`
}

func todoInput(o Op) core.TodoInput {
	return core.TodoInput{Title: o.Title, Notes: o.Notes, List: o.List, Priority: o.Priority, DueDate: o.DueDate, DueTime: o.DueTime}
}

// execute menjalankan aksi non-list secara berurutan di c.Q (sebuah transaksi).
func execute(c *core.Ctx, ops []Op) ([]Item, error) {
	created := map[int]int64{} // nomor urut todo.create → id
	creates := 0
	items := []Item{}
	for _, o := range ops {
		if o.isList() {
			continue
		}
		var summary string
		switch o.Op {
		case "todo.create":
			creates++
			t, err := core.CreateTodo(c, todoInput(o))
			if err != nil {
				return nil, err
			}
			created[creates] = t.ID
			summary = "Ditambahkan: " + todoLabel(c, t)
		case "todo.update":
			t, err := core.UpdateTodo(c, o.TodoID, todoInput(o))
			if err != nil {
				return nil, notFound(err, "todo", o.TodoID)
			}
			summary = "Diubah: " + todoLabel(c, t)
		case "todo.complete":
			t, err := core.CompleteTodo(c, o.TodoID)
			if err != nil {
				return nil, notFound(err, "todo", o.TodoID)
			}
			summary = "Selesai: " + t.Title
		case "todo.reopen":
			t, err := core.ReopenTodo(c, o.TodoID)
			if err != nil {
				return nil, notFound(err, "todo", o.TodoID)
			}
			summary = "Dibuka lagi: " + t.Title
		case "todo.delete":
			t, err := core.DeleteTodo(c, o.TodoID)
			if err != nil {
				return nil, notFound(err, "todo", o.TodoID)
			}
			summary = "Dihapus: " + t.Title
		case "todo.archiveDone":
			n, err := core.ArchiveDone(c)
			if err != nil {
				return nil, err
			}
			summary = fmt.Sprintf("%d todo selesai diarsipkan", n)
		case "reminder.create":
			in := core.ReminderInput{Title: o.Title, Message: o.Message, Schedule: o.Schedule}
			if o.TodoRef > 0 {
				id := created[o.TodoRef]
				in.TodoID = &id
			} else if o.TodoID > 0 {
				id := o.TodoID
				in.TodoID = &id
			}
			r, err := core.CreateReminder(c, in)
			if err != nil {
				return nil, err
			}
			summary = "Pengingat: " + reminderLabel(c, r)
		case "reminder.update":
			in := core.ReminderInput{Title: o.Title, Message: o.Message, Schedule: o.Schedule}
			r, err := core.UpdateReminder(c, o.ReminderID, in)
			if err != nil {
				return nil, notFound(err, "pengingat", o.ReminderID)
			}
			summary = "Pengingat diubah: " + reminderLabel(c, r)
		case "reminder.pause":
			r, err := core.SetReminderActive(c, o.ReminderID, false)
			if err != nil {
				return nil, notFound(err, "pengingat", o.ReminderID)
			}
			summary = "Pengingat dijeda: " + r.Title
		case "reminder.resume":
			r, err := core.SetReminderActive(c, o.ReminderID, true)
			if err != nil {
				return nil, notFound(err, "pengingat", o.ReminderID)
			}
			summary = "Pengingat dilanjutkan: " + reminderLabel(c, r)
		case "reminder.snooze":
			min := o.Minutes
			if min == 0 {
				min = 10
			}
			r, err := core.SnoozeReminder(c, o.ReminderID, min)
			if err != nil {
				return nil, notFound(err, "pengingat", o.ReminderID)
			}
			summary = fmt.Sprintf("Ditunda %d menit: %s", min, r.Title)
		case "reminder.delete":
			r, err := core.DeleteReminder(c, o.ReminderID)
			if err != nil {
				return nil, notFound(err, "pengingat", o.ReminderID)
			}
			summary = "Pengingat dihapus: " + r.Title
		case "memory.add":
			m, err := core.AddMemory(c, o.Target, deref(o.Content))
			if err != nil {
				return nil, err
			}
			summary = "Diingat: " + m.Content
		case "memory.update":
			m, err := core.UpdateMemory(c, o.MemoryID, deref(o.Content))
			if err != nil {
				return nil, notFound(err, "ingatan", o.MemoryID)
			}
			summary = "Ingatan diubah: " + m.Content
		case "memory.remove":
			m, err := core.DeleteMemory(c, o.MemoryID)
			if err != nil {
				return nil, notFound(err, "ingatan", o.MemoryID)
			}
			summary = "Ingatan dihapus: " + m.Content
		default:
			return nil, fmt.Errorf("op %q tidak didukung", o.Op)
		}
		items = append(items, Item{Op: o.Op, Summary: summary})
	}
	return items, nil
}

func notFound(err error, what string, id int64) error {
	if errors.Is(err, db.ErrNotFound) {
		return &core.ValidationError{Msg: fmt.Sprintf("%s #%d tidak ditemukan", what, id)}
	}
	return err
}

// preview menulis ringkasan aksi tanpa menjalankannya (untuk kartu konfirmasi).
func preview(c *core.Ctx, ops []Op) ([]Item, error) {
	items := []Item{}
	for _, o := range ops {
		if o.isList() {
			continue
		}
		var s string
		todoTitle := func() (string, error) {
			t, err := db.GetTodo(c.Q, c.UserID, o.TodoID)
			if err != nil {
				return "", notFound(err, "todo", o.TodoID)
			}
			return t.Title, nil
		}
		remTitle := func() (string, error) {
			r, err := db.GetReminder(c.Q, c.UserID, o.ReminderID)
			if err != nil {
				return "", notFound(err, "pengingat", o.ReminderID)
			}
			return r.Title, nil
		}
		var title string
		var err error
		switch o.Op {
		case "todo.create":
			s = "Tambah todo: " + deref(o.Title)
		case "todo.update":
			title, err = todoTitle()
			s = "Ubah todo: " + title
		case "todo.complete":
			title, err = todoTitle()
			s = "Tandai selesai: " + title
		case "todo.reopen":
			title, err = todoTitle()
			s = "Buka lagi: " + title
		case "todo.delete":
			title, err = todoTitle()
			s = "Hapus todo: " + title
		case "todo.archiveDone":
			done, e := db.ListTodos(c.Q, c.UserID, db.TodoFilter{Status: core.StatusDone})
			err = e
			s = fmt.Sprintf("Arsipkan %d todo yang sudah selesai", len(done))
		case "reminder.create":
			s = "Tambah pengingat: " + deref(o.Title)
		case "reminder.update":
			title, err = remTitle()
			s = "Ubah pengingat: " + title
		case "reminder.pause":
			title, err = remTitle()
			s = "Jeda pengingat: " + title
		case "reminder.resume":
			title, err = remTitle()
			s = "Lanjutkan pengingat: " + title
		case "reminder.snooze":
			title, err = remTitle()
			s = "Tunda pengingat: " + title
		case "reminder.delete":
			title, err = remTitle()
			s = "Hapus pengingat: " + title
		case "memory.add":
			s = "Ingat: " + deref(o.Content)
		case "memory.update", "memory.remove":
			m, e := db.GetMemory(c.Q, c.UserID, o.MemoryID)
			if e != nil {
				err = notFound(e, "ingatan", o.MemoryID)
			}
			if o.Op == "memory.update" {
				s = "Ubah ingatan: " + m.Content + " → " + deref(o.Content)
			} else {
				s = "Lupakan: " + m.Content
			}
		}
		if err != nil {
			return nil, err
		}
		items = append(items, Item{Op: o.Op, Summary: s})
	}
	return items, nil
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return strings.TrimSpace(*s)
}

// --- label tampilan -----------------------------------------------------------------

var shortDays = []string{"Min", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab"}
var shortMonths = []string{"Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"}

// FriendlyDate: "hari ini", "besok", atau "Sab 1 Nov".
func FriendlyDate(date string, now time.Time) string {
	d, err := time.ParseInLocation("2006-01-02", date, now.Location())
	if err != nil {
		return date
	}
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	switch int(d.Sub(today).Hours() / 24) {
	case 0:
		return "hari ini"
	case 1:
		return "besok"
	case -1:
		return "kemarin"
	}
	s := fmt.Sprintf("%s %d %s", shortDays[d.Weekday()], d.Day(), shortMonths[d.Month()-1])
	if d.Year() != now.Year() {
		s += fmt.Sprintf(" %d", d.Year())
	}
	return s
}

func todoLabel(c *core.Ctx, t db.Todo) string {
	s := t.Title
	if t.DueDate != "" {
		s += " · " + FriendlyDate(t.DueDate, c.Now)
		if t.DueTime != "" {
			s += " " + t.DueTime
		}
	}
	return s
}

func reminderLabel(c *core.Ctx, r db.Reminder) string {
	s := r.Title
	if sch, err := core.ParseSchedule(r.Schedule); err == nil && sch.Kind != schedule.KindOnce {
		s += " · " + sch.Describe()
	}
	if t, err := db.ParseStamp(r.NextFireAt); err == nil {
		lt := t.In(c.Loc)
		s += " · " + FriendlyDate(lt.Format("2006-01-02"), c.Now) + " " + lt.Format("15:04")
	}
	return s
}
