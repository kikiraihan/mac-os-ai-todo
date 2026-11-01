package applog

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"aitodo/server/internal/ai"
	"aitodo/server/internal/db"
)

func TestRing(t *testing.T) {
	r := NewRing(3)
	fmt.Fprint(r, "2026/10/12 10:00:00 assistant: model kenari/x gagal: HTTP 429\n2026/10/12 10:00:01 api: database is locked\n")
	fmt.Fprint(r, "PERINGATAN: zona waktu ")
	fmt.Fprint(r, "\"X\" tidak dikenal\n  password: rahasia-sekali-123\n")

	items, last := r.Lines(RingQuery{})
	if last != 4 || len(items) != 3 {
		t.Fatalf("last=%d len=%d (ring harus menyimpan 3 baris terakhir)", last, len(items))
	}
	if strings.Contains(items[0].Msg, "rahasia") || items[0].Level != "info" {
		t.Errorf("password harus disembunyikan: %+v", items[0])
	}
	if items[1].Msg != `PERINGATAN: zona waktu "X" tidak dikenal` || items[1].Level != "warn" || items[1].Source != "app" {
		t.Errorf("baris gabungan dari dua Write salah: %+v", items[1])
	}
	if items[2].Source != "api" || items[2].Level != "error" || items[2].Msg != "api: database is locked" {
		t.Errorf("error api salah: %+v", items[2])
	}
	if got, _ := r.Lines(RingQuery{Level: "error"}); len(got) != 1 {
		t.Errorf("filter error: %d baris", len(got))
	}
	if got, _ := r.Lines(RingQuery{Level: "warn"}); len(got) != 2 {
		t.Errorf("filter warn (+error): %d baris", len(got))
	}
	if got, _ := r.Lines(RingQuery{Source: "api"}); len(got) != 1 {
		t.Errorf("filter sumber: %d baris", len(got))
	}
	if got, _ := r.Lines(RingQuery{Text: "LOCKED"}); len(got) != 1 {
		t.Errorf("cari teks: %d baris", len(got))
	}
	if got, _ := r.Lines(RingQuery{After: 3}); len(got) != 1 || got[0].Seq != 4 {
		t.Errorf("after: %+v", got)
	}
}

func TestAICallsQueue(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	u, err := d.CreateUser(db.User{Username: "budi", PasswordHash: "x", Role: db.RoleUser})
	if err != nil {
		t.Fatal(err)
	}
	q := NewAICalls(d)
	ctx, cancel := context.WithCancel(context.Background())
	go q.Run(ctx)
	old := time.Now().AddDate(0, 0, -40)
	q.Record(ai.CallRecord{UserID: u.ID, Feature: "asisten", Provider: "kenari", Model: "m", Operation: ai.OpChat, HTTPStatus: 200, OK: true,
		Latency: 1500 * time.Millisecond, PromptTokens: 10, CompletionTokens: 5, At: time.Now()})
	q.Record(ai.CallRecord{Provider: "openrouter", Model: "q", Operation: ai.OpChat, HTTPStatus: 429, Error: "penuh", At: time.Now()})
	q.Record(ai.CallRecord{Provider: "kenari", Model: "lama", OK: true, At: old})
	cancel()
	q.Wait(5 * time.Second)

	items, total, err := d.ListAICalls(db.AICallFilter{})
	if err != nil || total != 3 || len(items) != 3 {
		t.Fatalf("list: %v total=%d", err, total)
	}
	// Urut terbaru dulu; baris "lama" (40 hari lalu) paling bawah.
	if items[2].Model != "lama" || items[1].Username != "budi" || items[1].LatencyMs != 1500 || !items[1].OK {
		t.Errorf("urutan / isi salah: %+v", items)
	}
	if _, n, _ := d.ListAICalls(db.AICallFilter{Status: "error"}); n != 1 {
		t.Errorf("filter error: %d", n)
	}
	if _, n, _ := d.ListAICalls(db.AICallFilter{Text: "bud"}); n != 1 {
		t.Errorf("cari username: %d", n)
	}
	if _, n, _ := d.ListAICalls(db.AICallFilter{Text: "%"}); n != 0 {
		t.Errorf("wildcard LIKE harus di-escape: %d", n)
	}
	if _, n, _ := d.ListAICalls(db.AICallFilter{From: time.Now().AddDate(0, 0, -1)}); n != 2 {
		t.Errorf("filter tanggal: %d", n)
	}
	sum, err := d.SummarizeAICalls(time.Now().AddDate(0, 0, -7))
	if err != nil || len(sum) != 2 {
		t.Fatalf("summary: %v %+v", err, sum)
	}
	if err := d.PruneAICalls(time.Now().AddDate(0, 0, -30)); err != nil {
		t.Fatal(err)
	}
	if _, n, _ := d.ListAICalls(db.AICallFilter{}); n != 2 {
		t.Errorf("prune: sisa %d", n)
	}
	// Pengguna dihapus → log tetap ada, user_id jadi NULL.
	if err := d.DeleteUser(u.ID); err != nil {
		t.Fatal(err)
	}
	items, n, _ := d.ListAICalls(db.AICallFilter{})
	if n != 2 || items[1].UserID != 0 {
		t.Errorf("setelah hapus user: %d %+v", n, items)
	}
	if n, err := d.DeleteAICalls([]int64{items[0].ID}); err != nil || n != 1 {
		t.Errorf("hapus terpilih: %d %v", n, err)
	}
	if n, err := d.DeleteAICalls(nil); err != nil || n != 1 {
		t.Errorf("hapus semua: %d %v", n, err)
	}
}
