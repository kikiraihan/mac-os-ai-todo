package applog

import (
	"regexp"
	"strings"
	"sync"
	"time"

	"aitodo/server/internal/ai"
)

// Ring menyimpan N baris log server terakhir (output package `log`: peringatan,
// error API, kegagalan model AI, penjadwal, push) di memori supaya admin bisa
// melihatnya dari menu System Log. Dipasang lewat
// log.SetOutput(io.MultiWriter(os.Stderr, ring)). Isinya hilang saat restart.
//
// Sebelum disimpan, baris dibersihkan dari password dan apa pun yang mirip
// API key / token (mis. password admin awal yang dicetak sekali saat bootstrap).
type Ring struct {
	mu      sync.Mutex
	buf     []RingLine
	next    int // posisi tulis berikutnya
	full    bool
	seq     int64
	partial string // potongan baris tanpa newline dari Write sebelumnya
	started time.Time
	now     func() time.Time
}

// RingLine adalah satu baris log server.
type RingLine struct {
	Seq    int64     `json:"seq"`
	Time   time.Time `json:"time"`
	Level  string    `json:"level"`  // info | warn | error
	Source string    `json:"source"` // awalan "xxx:" (api, assistant, ai, ...) atau "app"
	Msg    string    `json:"msg"`
}

// RingQuery adalah filter pembacaan log server.
type RingQuery struct {
	Text   string // cari teks (tidak peka huruf besar/kecil)
	Level  string // info | warn | error (kosong = semua); "warn" juga menampilkan error
	Source string
	After  int64 // hanya baris dengan seq > After (untuk auto refresh)
	Limit  int
}

func NewRing(size int) *Ring {
	if size <= 0 {
		size = 2000
	}
	return &Ring{buf: make([]RingLine, size), started: time.Now(), now: time.Now}
}

// Write memecah input per baris. Aman dipanggil dari banyak goroutine.
func (r *Ring) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.partial + string(p)
	lines := strings.Split(s, "\n")
	r.partial = lines[len(lines)-1]
	if len(r.partial) > 16<<10 {
		// Jaga-jaga: tulisan tanpa newline yang sangat panjang tidak menumpuk.
		r.add(r.partial)
		r.partial = ""
	}
	for _, ln := range lines[:len(lines)-1] {
		r.add(ln)
	}
	return len(p), nil
}

var (
	// Prefix bawaan package log (LstdFlags): "2006/01/02 15:04:05 ".
	stdPrefix = regexp.MustCompile(`^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? `)
	// Sumber: awalan "assistant:", "api:", "ai:", "http:" dst.
	sourcePrefix = regexp.MustCompile(`^(?:PERINGATAN:?\s*)?([a-z][a-z0-9_-]{1,20}):`)
	// Password yang tercetak (mis. "  password: xxx" saat admin awal dibuat).
	passwordLike = regexp.MustCompile(`(?i)(pass(?:word)?\s*[:=]\s*)\S+`)
)

func (r *Ring) add(ln string) {
	ln = strings.TrimRight(stdPrefix.ReplaceAllString(ln, ""), "\r ")
	if strings.TrimSpace(ln) == "" {
		return
	}
	ln = ai.Scrub(passwordLike.ReplaceAllString(ln, "${1}[disembunyikan]"))
	r.seq++
	level, source := classify(ln)
	r.buf[r.next] = RingLine{Seq: r.seq, Time: r.now(), Level: level, Source: source, Msg: truncate(ln, 4000)}
	r.next = (r.next + 1) % len(r.buf)
	if r.next == 0 {
		r.full = true
	}
}

// classify menebak level & sumber dari isi baris (log AI Todo tidak memakai level eksplisit).
func classify(ln string) (level, source string) {
	source = "app"
	if m := sourcePrefix.FindStringSubmatch(strings.TrimSpace(ln)); m != nil {
		source = m[1]
	}
	low := strings.ToLower(ln)
	switch {
	case strings.Contains(low, "panic"), strings.Contains(low, "fatal"), strings.Contains(low, "gagal"),
		strings.Contains(low, "error"), strings.Contains(low, "ditolak"), source == "api":
		// "api:" hanya dicetak fail() untuk error 500.
		return "error", source
	case strings.Contains(low, "peringatan"), strings.Contains(low, "warn"), strings.Contains(low, "dibuang"):
		return "warn", source
	}
	return "info", source
}

// Lines mengembalikan baris terbaru lebih dulu yang cocok dengan filter, beserta seq
// terakhir yang tercatat.
func (r *Ring) Lines(q RingQuery) (items []RingLine, lastSeq int64) {
	if q.Limit <= 0 || q.Limit > 1000 {
		q.Limit = 300
	}
	text := strings.ToLower(strings.TrimSpace(q.Text))
	r.mu.Lock()
	defer r.mu.Unlock()
	n := r.next
	if r.full {
		n = len(r.buf)
	}
	items = []RingLine{}
	for i := 0; i < n && len(items) < q.Limit; i++ {
		l := r.buf[(r.next-1-i+len(r.buf))%len(r.buf)]
		if l.Seq <= q.After {
			break
		}
		if q.Level == "error" && l.Level != "error" || q.Level == "warn" && l.Level == "info" || q.Level == "info" && l.Level != "info" {
			continue
		}
		if q.Source != "" && l.Source != q.Source {
			continue
		}
		if text != "" && !strings.Contains(strings.ToLower(l.Msg), text) {
			continue
		}
		items = append(items, l)
	}
	return items, r.seq
}

// Stats: jumlah baris per level & sumber yang masih tersimpan di buffer.
func (r *Ring) Stats() map[string]any {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := r.next
	if r.full {
		n = len(r.buf)
	}
	levels := map[string]int{"info": 0, "warn": 0, "error": 0}
	sources := map[string]int{}
	for i := 0; i < n; i++ {
		levels[r.buf[i].Level]++
		sources[r.buf[i].Source]++
	}
	return map[string]any{"capacity": len(r.buf), "stored": n, "total": r.seq, "levels": levels, "sources": sources, "startedAt": r.started}
}

func truncate(s string, n int) string {
	if len(s) > n {
		return strings.ToValidUTF8(s[:n], "") + "…"
	}
	return s
}
