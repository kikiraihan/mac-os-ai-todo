package core

import (
	"strings"
	"unicode/utf8"

	"aitodo/server/internal/db"
)

// Catatan: setara todo tapi tidak terkait waktu — teks umum, kumpulan link,
// rincian yang ingin disimpan. Form manual dan asisten memakai fungsi yang
// sama di sini (validasi & undo yang sama).

const (
	MaxNoteContent = 20000
	// MaxNotesPerUser: batas jumlah catatan per pengguna (mencegah database dibanjiri, mis. lewat skrip).
	MaxNotesPerUser = 5000
	// autoTitleLen: judul otomatis dari baris pertama isi bila judul dikosongkan.
	autoTitleLen = 80
)

// NoteInput: field nil berarti "tidak diubah".
type NoteInput struct {
	Title   *string `json:"title"`
	Content *string `json:"content"`
	// AppendContent menambah baris di bawah isi yang sudah ada, tanpa menimpanya.
	AppendContent *string `json:"appendContent"`
	List          *string `json:"list"`
	Pinned        *bool   `json:"pinned"`
}

func applyNoteInput(n *db.Note, in NoteInput) {
	if in.Title != nil {
		n.Title = strings.ReplaceAll(clean(*in.Title), "\n", " ")
	}
	if in.Content != nil {
		n.Content = clean(*in.Content)
	}
	if in.AppendContent != nil {
		if add := clean(*in.AppendContent); add != "" {
			if n.Content == "" {
				n.Content = add
			} else {
				n.Content += "\n" + add
			}
		}
	}
	if in.List != nil {
		n.List = strings.ReplaceAll(clean(*in.List), "\n", " ")
	}
	if in.Pinned != nil {
		n.Pinned = *in.Pinned
	}
}

// AutoNoteTitle: baris pertama yang berisi (tanpa penanda daftar "- "),
// dipotong supaya tetap ringkas. Dipakai bila judul dikosongkan.
func AutoNoteTitle(content string) string {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		line = strings.TrimSpace(strings.TrimLeft(line, "-*•"))
		if line == "" {
			continue
		}
		if utf8.RuneCountInString(line) > autoTitleLen {
			line = strings.TrimSpace(string([]rune(line)[:autoTitleLen-1])) + "…"
		}
		return line
	}
	return ""
}

func validateNote(n *db.Note) error {
	if n.Title == "" {
		n.Title = AutoNoteTitle(n.Content)
	}
	if n.Title == "" {
		return invalid("catatan kosong: isi judul atau isinya")
	}
	if utf8.RuneCountInString(n.Title) > MaxTitle {
		return invalid("judul maksimal %d karakter", MaxTitle)
	}
	if utf8.RuneCountInString(n.Content) > MaxNoteContent {
		return invalid("isi catatan maksimal %d karakter", MaxNoteContent)
	}
	if utf8.RuneCountInString(n.List) > MaxList {
		return invalid("nama kategori maksimal %d karakter", MaxList)
	}
	return nil
}

func CreateNote(c *Ctx, in NoteInput) (db.Note, error) {
	n := db.Note{UserID: c.UserID, Source: c.Source}
	if n.Source == "" {
		n.Source = "manual"
	}
	applyNoteInput(&n, in)
	if err := validateNote(&n); err != nil {
		return n, err
	}
	count, err := db.CountNotes(c.Q, c.UserID)
	if err != nil {
		return n, err
	}
	if count >= MaxNotesPerUser {
		return n, invalid("sudah ada %d catatan (batas), hapus yang tidak terpakai dulu", count)
	}
	n, err = db.InsertNote(c.Q, n)
	if err != nil {
		return n, err
	}
	c.Rec.add("note", n.ID, nil, db.SnapshotNote(n))
	return n, nil
}

func UpdateNote(c *Ctx, id int64, in NoteInput) (db.Note, error) {
	before, err := db.GetNote(c.Q, c.UserID, id)
	if err != nil {
		return before, err
	}
	n := before
	applyNoteInput(&n, in)
	if err := validateNote(&n); err != nil {
		return n, err
	}
	n, err = db.UpdateNote(c.Q, n)
	if err != nil {
		return n, err
	}
	c.Rec.add("note", n.ID, db.SnapshotNote(before), db.SnapshotNote(n))
	return n, nil
}

func SetNotePinned(c *Ctx, id int64, pinned bool) (db.Note, error) {
	return UpdateNote(c, id, NoteInput{Pinned: &pinned})
}

func DeleteNote(c *Ctx, id int64) (db.Note, error) {
	n, err := db.GetNote(c.Q, c.UserID, id)
	if err != nil {
		return n, err
	}
	if err := db.DeleteNote(c.Q, c.UserID, id); err != nil {
		return n, err
	}
	c.Rec.add("note", n.ID, db.SnapshotNote(n), nil)
	return n, nil
}
