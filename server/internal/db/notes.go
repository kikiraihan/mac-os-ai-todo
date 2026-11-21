package db

import (
	"database/sql"
	"errors"
	"strings"
)

// Note adalah catatan umum (teks, kumpulan link) — setara todo tapi tanpa
// tenggat, status, maupun pengingat.
type Note struct {
	ID        int64  `json:"id"`
	UserID    int64  `json:"-"`
	Title     string `json:"title"`
	Content   string `json:"content"`
	List      string `json:"list"`
	Pinned    bool   `json:"pinned"`
	Source    string `json:"source"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

// NoteSnapshot menyimpan seluruh kolom (termasuk user_id) untuk undo.
type NoteSnapshot struct {
	Note
	UserID int64 `json:"userId"`
}

const noteCols = `id, user_id, title, content, list, pinned, source, created_at, updated_at`

func scanNote(row interface{ Scan(...any) error }) (Note, error) {
	var n Note
	var pinned int
	err := row.Scan(&n.ID, &n.UserID, &n.Title, &n.Content, &n.List, &pinned, &n.Source, &n.CreatedAt, &n.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return n, ErrNotFound
	}
	n.Pinned = pinned == 1
	return n, err
}

// NoteFilter memilih catatan untuk daftar.
type NoteFilter struct {
	List   string
	Query  string
	Pinned bool // true = hanya yang disematkan
	Limit  int
}

// ListNotes: yang disematkan dulu, lalu yang paling baru diubah.
func ListNotes(q Q, userID int64, f NoteFilter) ([]Note, error) {
	where := []string{"user_id = ?"}
	args := []any{userID}
	if f.List != "" {
		where = append(where, "list = ? COLLATE NOCASE")
		args = append(args, f.List)
	}
	if f.Pinned {
		where = append(where, "pinned = 1")
	}
	if f.Query != "" {
		where = append(where, "(title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\' OR list LIKE ? ESCAPE '\\')")
		like := "%" + escapeLike(f.Query) + "%"
		args = append(args, like, like, like)
	}
	limit := f.Limit
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	args = append(args, limit)
	rows, err := q.Query(`SELECT `+noteCols+` FROM notes WHERE `+strings.Join(where, " AND ")+`
		ORDER BY pinned DESC, updated_at DESC, id DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Note{}
	for rows.Next() {
		n, err := scanNote(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

func GetNote(q Q, userID, id int64) (Note, error) {
	return scanNote(q.QueryRow(`SELECT `+noteCols+` FROM notes WHERE id = ? AND user_id = ?`, id, userID))
}

func InsertNote(q Q, n Note) (Note, error) {
	now := Now()
	n.CreatedAt, n.UpdatedAt = now, now
	res, err := q.Exec(`INSERT INTO notes (user_id, title, content, list, pinned, source, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, n.UserID, n.Title, n.Content, n.List, boolInt(n.Pinned), n.Source, now, now)
	if err != nil {
		return n, err
	}
	n.ID, _ = res.LastInsertId()
	return n, nil
}

func UpdateNote(q Q, n Note) (Note, error) {
	n.UpdatedAt = Now()
	_, err := q.Exec(`UPDATE notes SET title = ?, content = ?, list = ?, pinned = ?, updated_at = ? WHERE id = ? AND user_id = ?`,
		n.Title, n.Content, n.List, boolInt(n.Pinned), n.UpdatedAt, n.ID, n.UserID)
	return n, err
}

func DeleteNote(q Q, userID, id int64) error {
	_, err := q.Exec(`DELETE FROM notes WHERE id = ? AND user_id = ?`, id, userID)
	return err
}

// RestoreNote menulis ulang baris persis seperti snapshot (dipakai undo).
func RestoreNote(q Q, s NoteSnapshot) error {
	_, err := q.Exec(`INSERT OR REPLACE INTO notes (`+noteCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		s.ID, s.UserID, s.Title, s.Content, s.List, boolInt(s.Pinned), s.Source, s.CreatedAt, s.UpdatedAt)
	return err
}

func SnapshotNote(n Note) NoteSnapshot { return NoteSnapshot{Note: n, UserID: n.UserID} }

func (s NoteSnapshot) Restore() Note {
	n := s.Note
	n.UserID = s.UserID
	return n
}
