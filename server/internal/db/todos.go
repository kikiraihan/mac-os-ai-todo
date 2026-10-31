package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
)

type Todo struct {
	ID            int64  `json:"id"`
	UserID        int64  `json:"-"`
	Title         string `json:"title"`
	Notes         string `json:"notes"`
	Status        string `json:"status"`
	Priority      string `json:"priority"`
	List          string `json:"list"`
	DueDate       string `json:"dueDate"`
	DueTime       string `json:"dueTime"`
	Source        string `json:"source"`
	CompletedAt   string `json:"completedAt"`
	DueNotifiedAt string `json:"-"`
	CreatedAt     string `json:"createdAt"`
	UpdatedAt     string `json:"updatedAt"`
}

// TodoSnapshot menyimpan seluruh kolom (termasuk user_id) untuk undo.
type TodoSnapshot struct {
	Todo
	UserID        int64  `json:"userId"`
	DueNotifiedAt string `json:"dueNotifiedAt"`
}

type Reminder struct {
	ID          int64           `json:"id"`
	UserID      int64           `json:"-"`
	TodoID      *int64          `json:"todoId"`
	Title       string          `json:"title"`
	Message     string          `json:"message"`
	Schedule    json.RawMessage `json:"schedule"`
	NextFireAt  string          `json:"nextFireAt"`
	LastFiredAt string          `json:"lastFiredAt"`
	FireCount   int             `json:"fireCount"`
	Active      bool            `json:"active"`
	CreatedAt   string          `json:"createdAt"`
	UpdatedAt   string          `json:"updatedAt"`
}

type ReminderSnapshot struct {
	Reminder
	UserID int64 `json:"userId"`
}

const todoCols = `id, user_id, title, notes, status, priority, list, due_date, due_time, source, completed_at, due_notified_at, created_at, updated_at`

func scanTodo(row interface{ Scan(...any) error }) (Todo, error) {
	var t Todo
	err := row.Scan(&t.ID, &t.UserID, &t.Title, &t.Notes, &t.Status, &t.Priority, &t.List, &t.DueDate, &t.DueTime,
		&t.Source, &t.CompletedAt, &t.DueNotifiedAt, &t.CreatedAt, &t.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return t, ErrNotFound
	}
	return t, err
}

// TodoFilter memilih todo untuk daftar. Status "" atau "all" = semua kecuali arsip.
type TodoFilter struct {
	Status string
	From   string // due_date >= From
	To     string // due_date <= To
	List   string
	Query  string
	Limit  int
}

func ListTodos(q Q, userID int64, f TodoFilter) ([]Todo, error) {
	where := []string{"user_id = ?"}
	args := []any{userID}
	switch f.Status {
	case "", "all":
		where = append(where, "status != 'archived'")
	case "open", "done", "archived":
		where = append(where, "status = ?")
		args = append(args, f.Status)
	}
	if f.From != "" {
		where = append(where, "due_date != '' AND due_date >= ?")
		args = append(args, f.From)
	}
	if f.To != "" {
		where = append(where, "due_date != '' AND due_date <= ?")
		args = append(args, f.To)
	}
	if f.List != "" {
		where = append(where, "list = ? COLLATE NOCASE")
		args = append(args, f.List)
	}
	if f.Query != "" {
		where = append(where, "(title LIKE ? ESCAPE '\\' OR notes LIKE ? ESCAPE '\\')")
		like := "%" + escapeLike(f.Query) + "%"
		args = append(args, like, like)
	}
	limit := f.Limit
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	args = append(args, limit)
	rows, err := q.Query(`SELECT `+todoCols+` FROM todos WHERE `+strings.Join(where, " AND ")+`
		ORDER BY CASE status WHEN 'open' THEN 0 ELSE 1 END,
			CASE WHEN due_date = '' THEN 1 ELSE 0 END, due_date, due_time,
			CASE priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END,
			CASE WHEN status = 'open' THEN 0 ELSE -id END, id
		LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Todo{}
	for rows.Next() {
		t, err := scanTodo(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

func GetTodo(q Q, userID, id int64) (Todo, error) {
	return scanTodo(q.QueryRow(`SELECT `+todoCols+` FROM todos WHERE id = ? AND user_id = ?`, id, userID))
}

func InsertTodo(q Q, t Todo) (Todo, error) {
	now := Now()
	t.CreatedAt, t.UpdatedAt = now, now
	res, err := q.Exec(`INSERT INTO todos (user_id, title, notes, status, priority, list, due_date, due_time, source, completed_at, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, t.UserID, t.Title, t.Notes, t.Status, t.Priority, t.List, t.DueDate, t.DueTime,
		t.Source, t.CompletedAt, now, now)
	if err != nil {
		return t, err
	}
	t.ID, _ = res.LastInsertId()
	return t, nil
}

func UpdateTodo(q Q, t Todo) (Todo, error) {
	t.UpdatedAt = Now()
	_, err := q.Exec(`UPDATE todos SET title = ?, notes = ?, status = ?, priority = ?, list = ?, due_date = ?, due_time = ?,
		completed_at = ?, due_notified_at = ?, updated_at = ? WHERE id = ? AND user_id = ?`,
		t.Title, t.Notes, t.Status, t.Priority, t.List, t.DueDate, t.DueTime, t.CompletedAt, t.DueNotifiedAt, t.UpdatedAt, t.ID, t.UserID)
	return t, err
}

func DeleteTodo(q Q, userID, id int64) error {
	_, err := q.Exec(`DELETE FROM todos WHERE id = ? AND user_id = ?`, id, userID)
	return err
}

// RestoreTodo menulis ulang baris persis seperti snapshot (dipakai undo).
func RestoreTodo(q Q, s TodoSnapshot) error {
	_, err := q.Exec(`INSERT OR REPLACE INTO todos (`+todoCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		s.ID, s.UserID, s.Title, s.Notes, s.Status, s.Priority, s.List, s.DueDate, s.DueTime, s.Source, s.CompletedAt,
		s.DueNotifiedAt, s.CreatedAt, s.UpdatedAt)
	return err
}

func SnapshotTodo(t Todo) TodoSnapshot {
	return TodoSnapshot{Todo: t, UserID: t.UserID, DueNotifiedAt: t.DueNotifiedAt}
}

func (s TodoSnapshot) Restore() Todo {
	t := s.Todo
	t.UserID, t.DueNotifiedAt = s.UserID, s.DueNotifiedAt
	return t
}

// DueTodosToNotify: todo terbuka berjam yang belum diberi notifikasi tenggat.
func (d *DB) DueTodosToNotify(fromDate, toDate string) ([]Todo, error) {
	rows, err := d.Query(`SELECT `+todoCols+` FROM todos WHERE status = 'open' AND due_time != '' AND due_notified_at = ''
		AND due_date >= ? AND due_date <= ?`, fromDate, toDate)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Todo{}
	for rows.Next() {
		t, err := scanTodo(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (d *DB) ClaimDueNotification(id int64) (bool, error) {
	res, err := d.Exec(`UPDATE todos SET due_notified_at = ? WHERE id = ? AND due_notified_at = ''`, Now(), id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// --- reminders ----------------------------------------------------------------

const reminderCols = `id, user_id, todo_id, title, message, schedule, next_fire_at, last_fired_at, fire_count, active, created_at, updated_at`

func scanReminder(row interface{ Scan(...any) error }) (Reminder, error) {
	var r Reminder
	var todoID sql.NullInt64
	var sched string
	var active int
	err := row.Scan(&r.ID, &r.UserID, &todoID, &r.Title, &r.Message, &sched, &r.NextFireAt, &r.LastFiredAt, &r.FireCount,
		&active, &r.CreatedAt, &r.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return r, ErrNotFound
	}
	if todoID.Valid {
		id := todoID.Int64
		r.TodoID = &id
	}
	r.Schedule = json.RawMessage(sched)
	r.Active = active == 1
	return r, err
}

func nullID(id *int64) any {
	if id == nil {
		return nil
	}
	return *id
}

func ListReminders(q Q, userID int64) ([]Reminder, error) {
	rows, err := q.Query(`SELECT `+reminderCols+` FROM reminders WHERE user_id = ?
		ORDER BY active DESC, CASE WHEN next_fire_at = '' THEN 1 ELSE 0 END, next_fire_at, id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Reminder{}
	for rows.Next() {
		r, err := scanReminder(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func RemindersForTodo(q Q, userID, todoID int64) ([]Reminder, error) {
	rows, err := q.Query(`SELECT `+reminderCols+` FROM reminders WHERE user_id = ? AND todo_id = ?`, userID, todoID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Reminder{}
	for rows.Next() {
		r, err := scanReminder(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func CountActiveReminders(q Q, userID int64) (int, error) {
	var n int
	err := q.QueryRow(`SELECT COUNT(*) FROM reminders WHERE user_id = ? AND active = 1`, userID).Scan(&n)
	return n, err
}

func GetReminder(q Q, userID, id int64) (Reminder, error) {
	return scanReminder(q.QueryRow(`SELECT `+reminderCols+` FROM reminders WHERE id = ? AND user_id = ?`, id, userID))
}

func InsertReminder(q Q, r Reminder) (Reminder, error) {
	now := Now()
	r.CreatedAt, r.UpdatedAt = now, now
	res, err := q.Exec(`INSERT INTO reminders (user_id, todo_id, title, message, schedule, next_fire_at, last_fired_at, fire_count, active, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, r.UserID, nullID(r.TodoID), r.Title, r.Message, string(r.Schedule),
		r.NextFireAt, r.LastFiredAt, r.FireCount, boolInt(r.Active), now, now)
	if err != nil {
		return r, err
	}
	r.ID, _ = res.LastInsertId()
	return r, nil
}

func UpdateReminder(q Q, r Reminder) (Reminder, error) {
	r.UpdatedAt = Now()
	_, err := q.Exec(`UPDATE reminders SET todo_id = ?, title = ?, message = ?, schedule = ?, next_fire_at = ?, last_fired_at = ?,
		fire_count = ?, active = ?, updated_at = ? WHERE id = ? AND user_id = ?`, nullID(r.TodoID), r.Title, r.Message,
		string(r.Schedule), r.NextFireAt, r.LastFiredAt, r.FireCount, boolInt(r.Active), r.UpdatedAt, r.ID, r.UserID)
	return r, err
}

func DeleteReminder(q Q, userID, id int64) error {
	_, err := q.Exec(`DELETE FROM reminders WHERE id = ? AND user_id = ?`, id, userID)
	return err
}

func RestoreReminder(q Q, s ReminderSnapshot) error {
	_, err := q.Exec(`INSERT OR REPLACE INTO reminders (`+reminderCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		s.ID, s.UserID, nullID(s.TodoID), s.Title, s.Message, string(s.Schedule), s.NextFireAt, s.LastFiredAt, s.FireCount,
		boolInt(s.Active), s.CreatedAt, s.UpdatedAt)
	return err
}

func SnapshotReminder(r Reminder) ReminderSnapshot {
	return ReminderSnapshot{Reminder: r, UserID: r.UserID}
}

func (s ReminderSnapshot) Restore() Reminder {
	r := s.Reminder
	r.UserID = s.UserID
	return r
}

// DueReminders: pengingat aktif yang waktunya sudah tiba (semua pengguna).
func (d *DB) DueReminders(now string) ([]Reminder, error) {
	rows, err := d.Query(`SELECT `+reminderCols+` FROM reminders WHERE active = 1 AND next_fire_at != '' AND next_fire_at <= ?
		ORDER BY next_fire_at LIMIT 500`, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Reminder{}
	for rows.Next() {
		r, err := scanReminder(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// AdvanceReminder memindahkan pengingat ke kemunculan berikutnya hanya kalau
// next_fire_at masih sama dengan oldNext (klaim atomik, anti kirim ganda).
func (d *DB) AdvanceReminder(id int64, oldNext, newNext string, active bool) (bool, error) {
	res, err := d.Exec(`UPDATE reminders SET next_fire_at = ?, last_fired_at = ?, fire_count = fire_count + 1, active = ?, updated_at = ?
		WHERE id = ? AND next_fire_at = ?`, newNext, oldNext, boolInt(active), Now(), id, oldNext)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}
