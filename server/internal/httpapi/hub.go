package httpapi

import (
	"context"
	"sync"
	"time"
)

// Hub menyimpan nomor revisi data per pengguna untuk long-poll
// (GET /api/changes?since=<rev>&wait=1): perubahan di satu perangkat langsung
// membangunkan perangkat lain, seperti PasteLAN.
type Hub struct {
	mu      sync.Mutex
	base    int64
	rev     map[int64]int64
	waiters map[int64][]chan struct{}
}

func NewHub() *Hub {
	// Revisi awal = waktu start, jadi klien tidak salah mengira tidak ada
	// perubahan setelah server restart.
	return &Hub{base: time.Now().UnixMilli(), rev: map[int64]int64{}, waiters: map[int64][]chan struct{}{}}
}

func (h *Hub) Rev(userID int64) int64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	if r, ok := h.rev[userID]; ok {
		return r
	}
	return h.base
}

func (h *Hub) Bump(userID int64) {
	h.mu.Lock()
	cur, ok := h.rev[userID]
	if !ok {
		cur = h.base
	}
	h.rev[userID] = cur + 1
	ws := h.waiters[userID]
	delete(h.waiters, userID)
	h.mu.Unlock()
	for _, w := range ws {
		close(w)
	}
}

// Wait menunggu sampai revisi > since, ctx selesai, atau timeout.
func (h *Hub) Wait(ctx context.Context, userID, since int64, timeout time.Duration) int64 {
	h.mu.Lock()
	cur, ok := h.rev[userID]
	if !ok {
		cur = h.base
	}
	if cur != since {
		h.mu.Unlock()
		return cur
	}
	ch := make(chan struct{})
	h.waiters[userID] = append(h.waiters[userID], ch)
	h.mu.Unlock()

	t := time.NewTimer(timeout)
	defer t.Stop()
	select {
	case <-ch:
	case <-t.C:
	case <-ctx.Done():
	}
	h.mu.Lock()
	// Bersihkan channel kalau belum ditutup oleh Bump.
	ws := h.waiters[userID]
	for i, w := range ws {
		if w == ch {
			h.waiters[userID] = append(ws[:i], ws[i+1:]...)
			break
		}
	}
	h.mu.Unlock()
	return h.Rev(userID)
}
