package httpapi

import (
	"net/http"
	"time"

	"aitodo/server/internal/core"
	"aitodo/server/internal/db"
)

// Ingatan AI hanya bisa dibaca & diubah oleh pemiliknya — admin pun tidak
// punya endpoint untuk membaca ingatan pengguna lain.

func (s *Server) memoryRoutes() {
	m := s.Mux
	m.HandleFunc("GET /api/memory", s.authed(s.listMemory))
	m.HandleFunc("GET /api/memory/export", s.authed(s.exportMemory))
	m.HandleFunc("POST /api/memory", s.authed(s.createMemory))
	m.HandleFunc("PUT /api/memory/{id}", s.authed(s.updateMemory))
	m.HandleFunc("DELETE /api/memory/{id}", s.authed(s.deleteMemory))
}

func (s *Server) listMemory(w http.ResponseWriter, r *http.Request) {
	ms, err := db.ListMemories(s.DB, userOf(r).ID)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"memories": ms,
		"usage":    core.MemoryUsage(ms),
		"limits":   map[string]int{db.MemoryProfile: core.MemoryProfileLimit, db.MemoryNotes: core.MemoryNotesLimit},
		"maxEntry": core.MaxMemoryEntry,
	})
}

func (s *Server) exportMemory(w http.ResponseWriter, r *http.Request) {
	ms, err := db.ListMemories(s.DB, userOf(r).ID)
	if err != nil {
		fail(w, err)
		return
	}
	name := "ingatan-ai-" + time.Now().Format("2006-01-02") + ".md"
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	w.Write([]byte(core.ExportMemoryMarkdown(ms)))
}

func (s *Server) createMemory(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Target  string `json:"target"`
		Content string `json:"content"`
	}
	if !decode(w, r, &in) {
		return
	}
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		m, err := core.AddMemory(c, in.Target, in.Content)
		return map[string]any{"memory": m}, err
	})
}

func (s *Server) updateMemory(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	var in struct {
		Content string `json:"content"`
	}
	if !decode(w, r, &in) {
		return
	}
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		m, err := core.UpdateMemory(c, id, in.Content)
		return map[string]any{"memory": m}, err
	})
}

func (s *Server) deleteMemory(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	s.mutate(w, r, func(c *core.Ctx) (any, error) {
		_, err := core.DeleteMemory(c, id)
		return map[string]bool{"ok": true}, err
	})
}
