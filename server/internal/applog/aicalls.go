// Package applog berisi dua log untuk panel admin (pola dari Racik):
//
//   - AICalls: antrean penulisan AI Call Log (request keluar ke provider AI) ke
//     tabel ai_calls, supaya pencatatan tidak memperlambat jawaban asisten.
//   - Ring: N baris terakhir log server (package log) di memori untuk menu
//     System Log, tanpa perlu akses ke container.
package applog

import (
	"context"
	"log"
	"sync/atomic"
	"time"

	"aitodo/server/internal/ai"
	"aitodo/server/internal/db"
)

// AICalls menulis ai.CallRecord ke database secara asinkron.
type AICalls struct {
	db      *db.DB
	ch      chan ai.CallRecord
	dropped atomic.Int64
	done    chan struct{}
}

func NewAICalls(d *db.DB) *AICalls {
	return &AICalls{db: d, ch: make(chan ai.CallRecord, 1000), done: make(chan struct{})}
}

// Record (dipasang sebagai ai.Registry.Recorder) tidak pernah memblokir: kalau
// antrean penuh, baris dibuang dan dihitung.
func (a *AICalls) Record(rec ai.CallRecord) {
	select {
	case a.ch <- rec:
	default:
		if n := a.dropped.Add(1); n%100 == 1 {
			log.Printf("PERINGATAN applog: antrean AI call log penuh, %d baris dibuang", n)
		}
	}
}

// Run menulis antrean sampai ctx selesai, lalu menulis sisanya. Panggil di goroutine.
func (a *AICalls) Run(ctx context.Context) {
	defer close(a.done)
	for {
		select {
		case rec := <-a.ch:
			a.write(rec)
		case <-ctx.Done():
			for {
				select {
				case rec := <-a.ch:
					a.write(rec)
				default:
					return
				}
			}
		}
	}
}

// Wait menunggu Run selesai menulis sisa antrean (saat shutdown).
func (a *AICalls) Wait(timeout time.Duration) {
	select {
	case <-a.done:
	case <-time.After(timeout):
	}
}

func (a *AICalls) write(rec ai.CallRecord) {
	at := rec.At
	if at.IsZero() {
		at = time.Now()
	}
	err := a.db.InsertAICall(db.AICall{
		UserID: rec.UserID, Feature: rec.Feature, Provider: rec.Provider, Model: rec.Model, Endpoint: rec.Endpoint,
		Operation: rec.Operation, HTTPStatus: rec.HTTPStatus, OK: rec.OK, LatencyMs: int(rec.Latency.Milliseconds()),
		PromptTokens: rec.PromptTokens, CompletionTokens: rec.CompletionTokens, Error: rec.Error, CreatedAt: db.Stamp(at),
	})
	if err != nil {
		log.Printf("applog: gagal menyimpan AI call log: %v", err)
	}
}
