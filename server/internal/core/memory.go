package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"

	"aitodo/server/internal/db"
)

// Ingatan asisten mengikuti pola Hermes Agent (MEMORY.md + USER.md):
//
//   - dua wadah berbatas karakter: "profile" (siapa pengguna) dan "notes"
//     (catatan asisten), selalu ikut masuk prompt sehingga asisten tidak lupa;
//   - ditulis lewat aksi add/update/remove yang divalidasi server; wadah penuh
//     → ditolak, asisten harus merangkum/menghapus yang usang dulu;
//   - setiap tulisan dipindai: isi yang mirip prompt injection atau rahasia
//     (password, API key, nomor kartu) ditolak, karena ingatan masuk ke prompt
//     di setiap percakapan berikutnya dan tidak boleh dikirim ke provider AI.
//
// Bedanya dengan Hermes: entri disimpan sebagai baris SQLite per pengguna
// (punya id, jadi dirujuk dengan id, bukan pencocokan substring), dan bisa
// dilihat/diubah/dihapus manual oleh pemiliknya dari Pengaturan → Ingatan AI.

const (
	MemoryProfileLimit = 1200
	MemoryNotesLimit   = 2000
	MaxMemoryEntry     = 400
)

func MemoryLimit(target string) int {
	if target == db.MemoryProfile {
		return MemoryProfileLimit
	}
	return MemoryNotesLimit
}

func validTarget(t string) bool { return t == db.MemoryProfile || t == db.MemoryNotes }

type threat struct {
	re  *regexp.Regexp
	msg string
}

var memoryThreats = []threat{
	{regexp.MustCompile(`(?i)(ignore|abaikan|lupakan)\s+(?:\S+\s+){0,6}(previous|all|above|prior|semua|sebelumnya)\s+(?:\S+\s+){0,6}(instructions?|instruksi|perintah|aturan)`),
		"berisi instruksi untuk mengabaikan aturan"},
	{regexp.MustCompile(`(?i)system\s*prompt|prompt\s+sistem`), "menyebut system prompt"},
	{regexp.MustCompile(`(?i)(you\s+are\s+now|kamu\s+sekarang\s+adalah|mulai\s+sekarang\s+kamu\s+(adalah|bukan))`), "mencoba mengganti identitas asisten"},
	{regexp.MustCompile(`(?i)(tanpa|without)\s+(konfirmasi|confirmation)`), "meminta melewati konfirmasi"},
	{regexp.MustCompile(`(?i)(disregard|bypass|jailbreak|developer\s+mode)`), "berisi pola jailbreak"},
	{regexp.MustCompile(`(?i)\b(password|passwd|kata\s*sandi|sandi|pin|otp|cvv)\b(?:\s+\S+){0,3}?\s*(?:adalah|is|=|:)\s*\S+`), "berisi password/PIN"},
	{regexp.MustCompile(`(?i)\b(sk|kn|or|pk|rk)-[a-z0-9_\-]{12,}|\bghp_[A-Za-z0-9]{20,}|\bAKIA[0-9A-Z]{16}\b|-----BEGIN [A-Z ]*PRIVATE KEY`), "berisi API key / kunci rahasia"},
	{regexp.MustCompile(`(?i)\b(api[\s_-]*key|token|secret|bearer)\b\s*(?:adalah|is|=|:)\s*\S{8,}`), "berisi token/secret"},
	{regexp.MustCompile(`\b(?:\d[ -]?){13,19}\b`), "berisi deretan angka panjang (mirip nomor kartu/rekening)"},
	{regexp.MustCompile(`(?i)https?://\S+\?\S*(token|key|sig|auth)=`), "berisi tautan dengan kredensial"},
}

// ScanMemory mengembalikan alasan penolakan, atau "" bila aman.
func ScanMemory(content string) string {
	for _, t := range memoryThreats {
		if t.re.MatchString(content) {
			return t.msg
		}
	}
	return ""
}

func cleanMemoryContent(s string) (string, error) {
	s = strings.Join(strings.Fields(clean(s)), " ")
	if s == "" {
		return "", invalid("isi ingatan kosong")
	}
	if utf8.RuneCountInString(s) > MaxMemoryEntry {
		return "", invalid("satu ingatan maksimal %d karakter, buat lebih ringkas", MaxMemoryEntry)
	}
	if why := ScanMemory(s); why != "" {
		return "", invalid("ingatan ditolak karena %s — data sensitif tidak boleh disimpan di ingatan AI", why)
	}
	return s, nil
}

// MemoryUsage menghitung jumlah karakter per wadah.
func MemoryUsage(ms []db.Memory) map[string]int {
	u := map[string]int{db.MemoryProfile: 0, db.MemoryNotes: 0}
	for _, m := range ms {
		u[m.Target] += utf8.RuneCountInString(m.Content)
	}
	return u
}

func checkBudget(c *Ctx, target string, delta int) error {
	ms, err := db.ListMemories(c.Q, c.UserID)
	if err != nil {
		return err
	}
	used := MemoryUsage(ms)[target]
	limit := MemoryLimit(target)
	if used+delta > limit {
		return invalid("ingatan %s penuh (%d/%d karakter, kurang %d): rangkum atau hapus entri yang usang dulu",
			target, used, limit, used+delta-limit)
	}
	return nil
}

func AddMemory(c *Ctx, target, content string) (db.Memory, error) {
	if !validTarget(target) {
		return db.Memory{}, invalid("target ingatan harus profile atau notes")
	}
	content, err := cleanMemoryContent(content)
	if err != nil {
		return db.Memory{}, err
	}
	ms, err := db.ListMemories(c.Q, c.UserID)
	if err != nil {
		return db.Memory{}, err
	}
	for _, m := range ms {
		if m.Target == target && strings.EqualFold(m.Content, content) {
			return m, nil // sudah ada persis sama, tidak perlu dobel
		}
	}
	if err := checkBudget(c, target, utf8.RuneCountInString(content)); err != nil {
		return db.Memory{}, err
	}
	src := c.Source
	if src == "" {
		src = "manual"
	}
	m, err := db.InsertMemory(c.Q, db.Memory{UserID: c.UserID, Target: target, Content: content, Source: src})
	if err != nil {
		return m, err
	}
	c.Rec.add("memory", m.ID, nil, db.SnapshotMemory(m))
	return m, nil
}

func UpdateMemory(c *Ctx, id int64, content string) (db.Memory, error) {
	before, err := db.GetMemory(c.Q, c.UserID, id)
	if err != nil {
		return before, err
	}
	content, err = cleanMemoryContent(content)
	if err != nil {
		return before, err
	}
	delta := utf8.RuneCountInString(content) - utf8.RuneCountInString(before.Content)
	if delta > 0 {
		if err := checkBudget(c, before.Target, delta); err != nil {
			return before, err
		}
	}
	m := before
	m.Content = content
	m, err = db.UpdateMemory(c.Q, m)
	if err != nil {
		return m, err
	}
	c.Rec.add("memory", m.ID, db.SnapshotMemory(before), db.SnapshotMemory(m))
	return m, nil
}

func DeleteMemory(c *Ctx, id int64) (db.Memory, error) {
	m, err := db.GetMemory(c.Q, c.UserID, id)
	if err != nil {
		return m, err
	}
	if err := db.DeleteMemory(c.Q, c.UserID, id); err != nil {
		return m, err
	}
	c.Rec.add("memory", m.ID, db.SnapshotMemory(m), nil)
	return m, nil
}

func undoMemory(q db.Q, userID int64, ch Change) error {
	cur, err := db.GetMemory(q, userID, ch.ID)
	if err := checkCurrent(err, ch.After, func(s db.MemorySnapshot) string { return s.UpdatedAt }, cur.UpdatedAt); err != nil {
		return err
	}
	if ch.Before == nil {
		return db.DeleteMemory(q, userID, ch.ID)
	}
	var snap db.MemorySnapshot
	if err := json.Unmarshal(ch.Before, &snap); err != nil || snap.UserID != userID {
		return errors.New("data undo rusak")
	}
	return db.RestoreMemory(q, snap)
}

// RenderMemory menulis ingatan untuk prompt, dengan id dan pemakaian kapasitas
// (supaya asisten tahu kapan harus merangkum).
func RenderMemory(ms []db.Memory) string {
	usage := MemoryUsage(ms)
	var b strings.Builder
	for _, target := range []string{db.MemoryProfile, db.MemoryNotes} {
		title := "PROFIL PENGGUNA (siapa pengguna ini)"
		if target == db.MemoryNotes {
			title = "CATATAN ASISTEN (hal yang perlu kamu ingat)"
		}
		limit := MemoryLimit(target)
		fmt.Fprintf(&b, "%s [%d%% — %d/%d karakter]\n", title, usage[target]*100/limit, usage[target], limit)
		n := 0
		for _, m := range ms {
			if m.Target == target {
				fmt.Fprintf(&b, "- [m%d] %s\n", m.ID, m.Content)
				n++
			}
		}
		if n == 0 {
			b.WriteString("- (kosong)\n")
		}
	}
	return b.String()
}

// ExportMemoryMarkdown menulis ingatan sebagai dua berkas Markdown dalam satu
// dokumen (PROFIL.md + CATATAN.md), untuk diunduh pemiliknya.
func ExportMemoryMarkdown(ms []db.Memory) string {
	var b strings.Builder
	for _, target := range []string{db.MemoryProfile, db.MemoryNotes} {
		if target == db.MemoryProfile {
			b.WriteString("# PROFIL.md — siapa saya\n\n")
		} else {
			b.WriteString("\n# CATATAN.md — catatan asisten\n\n")
		}
		for _, m := range ms {
			if m.Target == target {
				b.WriteString("- " + m.Content + "\n")
			}
		}
	}
	return b.String()
}
