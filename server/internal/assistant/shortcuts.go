package assistant

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"aitodo/server/internal/core"
	"aitodo/server/internal/db"
)

const helpText = `Perintah tanpa AI (selalu bisa dipakai):
/todo <judul> — tambah todo
/selesai <nomor> — tandai todo #nomor selesai
/hari-ini — todo hari ini & yang terlambat
/undo — batalkan aksi terakhir
/bantuan — tampilkan bantuan ini

Selebihnya cukup ngobrol biasa, mis. "besok jam 9 ingetin telpon bengkel".`

// shortcut menjalankan perintah garis miring tanpa memanggil AI.
func (a *Assistant) shortcut(user db.User, loc *time.Location, text string) answer {
	cmd, arg, _ := strings.Cut(text, " ")
	arg = strings.TrimSpace(arg)
	switch strings.ToLower(cmd) {
	case "/todo", "/tambah":
		if arg == "" {
			return answer{text: "Tulis judulnya, mis. /todo beli galon"}
		}
		return a.shortcutOps(user, loc, []Op{{Op: "todo.create", Title: &arg}}, "Oke, sudah kucatat.")
	case "/selesai", "/done":
		id, err := strconv.ParseInt(strings.TrimPrefix(arg, "#"), 10, 64)
		if err != nil || id <= 0 {
			return answer{text: "Tulis nomor todonya, mis. /selesai 12 (nomor ada di daftar Todo)."}
		}
		return a.shortcutOps(user, loc, []Op{{Op: "todo.complete", TodoID: id}}, "Sip, sudah selesai.")
	case "/hari-ini", "/hariini", "/today":
		return answer{text: a.todayText(user, loc)}
	case "/undo", "/batal":
		b, err := a.DB.LastAppliedBatch(user.ID)
		if errors.Is(err, db.ErrNotFound) {
			return answer{text: "Tidak ada aksi yang bisa di-undo."}
		}
		if err != nil {
			return answer{text: "Maaf, terjadi kesalahan di server."}
		}
		view, err := a.Undo(user, b.ID)
		if err != nil {
			if core.IsValidation(err) {
				return answer{text: "Tidak bisa undo: " + err.Error()}
			}
			return answer{text: "Maaf, terjadi kesalahan di server."}
		}
		return answer{text: "Aksi terakhir sudah dibatalkan.", batch: view}
	default:
		return answer{text: helpText}
	}
}

func (a *Assistant) shortcutOps(user db.User, loc *time.Location, ops []Op, ok string) answer {
	view, err := a.submit(user, loc, ops)
	if err != nil {
		if core.IsValidation(err) {
			return answer{text: "Gagal: " + err.Error()}
		}
		return answer{text: "Maaf, terjadi kesalahan di server."}
	}
	return answer{text: ok, batch: view}
}

func (a *Assistant) todayText(user db.User, loc *time.Location) string {
	today := time.Now().In(loc).Format("2006-01-02")
	open, err := db.ListTodos(a.DB, user.ID, db.TodoFilter{Status: core.StatusOpen})
	if err != nil {
		return "Maaf, terjadi kesalahan di server."
	}
	var overdue, now []string
	for _, t := range open {
		line := fmt.Sprintf("#%d %s", t.ID, t.Title)
		if t.DueTime != "" {
			line += " (" + t.DueTime + ")"
		}
		switch {
		case t.DueDate != "" && t.DueDate < today:
			overdue = append(overdue, line+" — "+t.DueDate)
		case t.DueDate == today:
			now = append(now, line)
		}
	}
	if len(overdue) == 0 && len(now) == 0 {
		return "Tidak ada todo untuk hari ini. 🎉"
	}
	var b strings.Builder
	if len(now) > 0 {
		b.WriteString("Hari ini:\n• " + strings.Join(now, "\n• "))
	}
	if len(overdue) > 0 {
		if b.Len() > 0 {
			b.WriteString("\n\n")
		}
		b.WriteString("Terlambat:\n• " + strings.Join(overdue, "\n• "))
	}
	return b.String()
}

// ApplyManual menjalankan satu aksi dari tombol notifikasi / klien lain tanpa
// lewat chat, tetap dengan undo tercatat.
func (a *Assistant) ApplyManual(user db.User, loc *time.Location, op Op) (*BatchView, error) {
	return a.submit(user, loc, []Op{op})
}
