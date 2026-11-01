package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"aitodo/server/internal/ai"
	"aitodo/server/internal/assistant"
	"aitodo/server/internal/db"
)

var usernamePattern = regexp.MustCompile(`^[a-zA-Z0-9._-]{3,32}$`)

func (s *Server) assistantSettings() assistant.Settings { return assistant.LoadSettings(s.DB) }

func (s *Server) adminStats(w http.ResponseWriter, r *http.Request) {
	var users, todos, open, reminders, chats int
	q := func(sql string, dst *int) {
		s.DB.QueryRow(sql).Scan(dst)
	}
	q(`SELECT COUNT(*) FROM users`, &users)
	q(`SELECT COUNT(*) FROM todos WHERE status != 'archived'`, &todos)
	q(`SELECT COUNT(*) FROM todos WHERE status = 'open'`, &open)
	q(`SELECT COUNT(*) FROM reminders WHERE active = 1`, &reminders)
	s.DB.QueryRow(`SELECT COUNT(*) FROM chat_messages WHERE role = 'user' AND created_at >= ?`,
		db.Stamp(time.Now().Add(-24*time.Hour))).Scan(&chats)
	models, _ := s.DB.ListModels()
	ready := 0
	for _, m := range models {
		if m.Status == db.ModelActive && s.AI.HasKey(m.Provider) {
			ready++
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users, "todos": todos, "openTodos": open, "activeReminders": reminders,
		"chats24h": chats, "modelsReady": ready, "providers": s.AI.Providers(), "version": s.Cfg.Version})
}

// --- pengguna ----------------------------------------------------------------------

func (s *Server) adminListUsers(w http.ResponseWriter, r *http.Request) {
	users, err := s.DB.ListUsers()
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
}

func validRole(role string) bool { return role == db.RoleAdmin || role == db.RoleUser }

func (s *Server) adminCreateUser(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Username    string `json:"username"`
		DisplayName string `json:"displayName"`
		Password    string `json:"password"`
		Role        string `json:"role"`
		Timezone    string `json:"timezone"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.Username = strings.TrimSpace(in.Username)
	if !usernamePattern.MatchString(in.Username) {
		writeErr(w, http.StatusBadRequest, "username 3–32 karakter: huruf, angka, titik, minus, garis bawah")
		return
	}
	if in.Role == "" {
		in.Role = db.RoleUser
	}
	if !validRole(in.Role) {
		writeErr(w, http.StatusBadRequest, "role harus admin atau user")
		return
	}
	if in.Timezone != "" {
		if _, err := time.LoadLocation(in.Timezone); err != nil {
			writeErr(w, http.StatusBadRequest, "zona waktu tidak dikenal")
			return
		}
	}
	if utf8.RuneCountInString(in.DisplayName) > maxDisplayNameChars {
		writeErr(w, http.StatusBadRequest, "nama tampilan maksimal 60 karakter")
		return
	}
	if err := CheckPassword(in.Password); err != nil {
		fail(w, err)
		return
	}
	if _, err := s.DB.GetUserByUsername(in.Username); err == nil {
		writeErr(w, http.StatusConflict, "username sudah dipakai")
		return
	}
	hash, err := HashPassword(in.Password)
	if err != nil {
		fail(w, err)
		return
	}
	u, err := s.DB.CreateUser(db.User{Username: in.Username, DisplayName: strings.TrimSpace(in.DisplayName), PasswordHash: hash,
		Role: in.Role, Timezone: in.Timezone})
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"user": u})
}

// lastAdminGuard menolak perubahan yang membuat tidak ada admin aktif tersisa.
func (s *Server) lastAdminGuard(target db.User, stillActiveAdmin bool) error {
	if target.Role != db.RoleAdmin || target.Disabled || stillActiveAdmin {
		return nil
	}
	n, err := s.DB.CountActiveAdmins()
	if err != nil {
		return err
	}
	if n <= 1 {
		return errors.New("harus ada minimal satu admin aktif")
	}
	return nil
}

func (s *Server) adminUpdateUser(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	var in struct {
		DisplayName *string `json:"displayName"`
		Role        *string `json:"role"`
		Disabled    *bool   `json:"disabled"`
		Timezone    *string `json:"timezone"`
		Password    *string `json:"password"`
	}
	if !decode(w, r, &in) {
		return
	}
	u, err := s.DB.GetUser(id)
	if err != nil {
		fail(w, err)
		return
	}
	next := u
	if in.DisplayName != nil {
		if utf8.RuneCountInString(*in.DisplayName) > maxDisplayNameChars {
			writeErr(w, http.StatusBadRequest, "nama tampilan maksimal 60 karakter")
			return
		}
		next.DisplayName = strings.TrimSpace(*in.DisplayName)
	}
	if in.Role != nil {
		if !validRole(*in.Role) {
			writeErr(w, http.StatusBadRequest, "role harus admin atau user")
			return
		}
		next.Role = *in.Role
	}
	if in.Disabled != nil {
		next.Disabled = *in.Disabled
	}
	if in.Timezone != nil {
		if *in.Timezone != "" {
			if _, err := time.LoadLocation(*in.Timezone); err != nil {
				writeErr(w, http.StatusBadRequest, "zona waktu tidak dikenal")
				return
			}
		}
		next.Timezone = *in.Timezone
	}
	if id == userOf(r).ID && (next.Disabled || next.Role != db.RoleAdmin) {
		writeErr(w, http.StatusBadRequest, "tidak bisa menonaktifkan atau menurunkan akun sendiri")
		return
	}
	if err := s.lastAdminGuard(u, next.Role == db.RoleAdmin && !next.Disabled); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.Password != nil && *in.Password != "" {
		if err := CheckPassword(*in.Password); err != nil {
			fail(w, err)
			return
		}
		hash, err := HashPassword(*in.Password)
		if err != nil {
			fail(w, err)
			return
		}
		if err := s.DB.SetPassword(id, hash); err != nil {
			fail(w, err)
			return
		}
	}
	if err := s.DB.UpdateUser(next); err != nil {
		fail(w, err)
		return
	}
	// Password direset atau akun dinonaktifkan → keluarkan dari semua perangkat.
	if (in.Password != nil && *in.Password != "") || (next.Disabled && !u.Disabled) {
		s.DB.DeleteUserSessions(id, 0)
	}
	writeJSON(w, http.StatusOK, map[string]any{"user": next})
}

func (s *Server) adminDeleteUser(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	if id == userOf(r).ID {
		writeErr(w, http.StatusBadRequest, "tidak bisa menghapus akun sendiri")
		return
	}
	u, err := s.DB.GetUser(id)
	if err != nil {
		fail(w, err)
		return
	}
	if err := s.lastAdminGuard(u, false); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.DB.DeleteUser(id); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// --- AI & katalog model ----------------------------------------------------------------

func (s *Server) adminAI(w http.ResponseWriter, r *http.Request) {
	models, err := s.DB.ListModels()
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"settings": s.assistantSettings(), "providers": s.AI.Providers(), "models": models})
}

func (s *Server) adminAISettings(w http.ResponseWriter, r *http.Request) {
	in := s.assistantSettings()
	if !decode(w, r, &in) {
		return
	}
	if err := assistant.SaveSettings(s.DB, in); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"settings": s.assistantSettings()})
}

var modelIDPattern = regexp.MustCompile(`^[A-Za-z0-9._:/@+-]{1,200}$`)

// cleanExtraBody memastikan extra body adalah objek JSON kecil dan dirapikan.
func cleanExtraBody(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if len(raw) > 2000 {
		return "", errors.New("extra body maksimal 2000 karakter")
	}
	var obj map[string]any
	if err := json.Unmarshal([]byte(raw), &obj); err != nil {
		return "", errors.New("extra body harus objek JSON, mis. {\"reasoning_effort\":\"low\"}")
	}
	for _, k := range []string{"model", "messages", "stream"} {
		if _, ok := obj[k]; ok {
			return "", fmt.Errorf("extra body tidak boleh berisi %q", k)
		}
	}
	b, _ := json.Marshal(obj)
	return string(b), nil
}

type modelInput struct {
	Provider  string  `json:"provider"`
	ModelID   string  `json:"modelId"`
	Label     *string `json:"label"`
	Status    *string `json:"status"`
	ExtraBody *string `json:"extraBody"`
	Free      *bool   `json:"free"`
}

func (s *Server) adminCreateModel(w http.ResponseWriter, r *http.Request) {
	var in modelInput
	if !decode(w, r, &in) {
		return
	}
	in.ModelID = strings.TrimSpace(in.ModelID)
	if !s.AI.Known(in.Provider) {
		writeErr(w, http.StatusBadRequest, "provider tidak dikenal")
		return
	}
	if !modelIDPattern.MatchString(in.ModelID) {
		writeErr(w, http.StatusBadRequest, "id model tidak valid (salin persis dari daftar provider)")
		return
	}
	m := db.AIModel{Provider: in.Provider, ModelID: in.ModelID, Label: in.ModelID, Free: strings.HasSuffix(in.ModelID, ":free")}
	if in.Label != nil && strings.TrimSpace(*in.Label) != "" {
		m.Label = truncateRunes(strings.TrimSpace(*in.Label), 100)
	}
	if in.ExtraBody != nil {
		eb, err := cleanExtraBody(*in.ExtraBody)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		m.ExtraBody = eb
	}
	if in.Free != nil {
		m.Free = *in.Free
	}
	if exists, err := s.DB.ModelExists(m.Provider, m.ModelID); err != nil || exists {
		if err != nil {
			fail(w, err)
			return
		}
		writeErr(w, http.StatusConflict, "model ini sudah ada di katalog")
		return
	}
	m, err := s.DB.InsertModel(m)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"model": m})
}

func (s *Server) adminUpdateModel(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	var in modelInput
	if !decode(w, r, &in) {
		return
	}
	m, err := s.DB.GetModel(id)
	if err != nil {
		fail(w, err)
		return
	}
	if in.Label != nil {
		m.Label = truncateRunes(strings.TrimSpace(*in.Label), 100)
		if m.Label == "" {
			m.Label = m.ModelID
		}
	}
	if in.Status != nil {
		switch *in.Status {
		case db.ModelActive, db.ModelDisabled:
			if m.Status != *in.Status {
				m.Status, m.StatusNote = *in.Status, ""
			}
		default:
			writeErr(w, http.StatusBadRequest, "status harus active atau disabled")
			return
		}
	}
	if in.ExtraBody != nil {
		eb, err := cleanExtraBody(*in.ExtraBody)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		m.ExtraBody = eb
	}
	if in.Free != nil {
		m.Free = *in.Free
	}
	if err := s.DB.UpdateModel(m); err != nil {
		fail(w, err)
		return
	}
	m, _ = s.DB.GetModel(id)
	writeJSON(w, http.StatusOK, map[string]any{"model": m})
}

func (s *Server) adminDeleteModel(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	if err := s.DB.DeleteModel(id); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) adminReorderModels(w http.ResponseWriter, r *http.Request) {
	var in struct {
		IDs []int64 `json:"ids"`
	}
	if !decode(w, r, &in) {
		return
	}
	if len(in.IDs) > 500 {
		writeErr(w, http.StatusBadRequest, "terlalu banyak id")
		return
	}
	if err := s.DB.ReorderModels(in.IDs); err != nil {
		fail(w, err)
		return
	}
	models, _ := s.DB.ListModels()
	writeJSON(w, http.StatusOK, map[string]any{"models": models})
}

// adminTestModel mengirim satu permintaan nyata ke model. Model yang ditolak
// provider (400/404/410/422) ditandai "unavailable"; gangguan sementara (429,
// 5xx, timeout) tidak mengubah status. Model yang dimatikan admin tetap mati.
func (s *Server) adminTestModel(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeErr(w, http.StatusBadRequest, "id tidak valid")
		return
	}
	m, err := s.DB.GetModel(id)
	if err != nil {
		fail(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	res, err := s.AI.Chat(ctx, ai.ChatRequest{Provider: m.Provider, Model: m.ModelID, ExtraBody: m.ExtraBody, MaxTokens: 400, JSON: true,
		Messages: []ai.Message{
			{Role: "system", Content: `Balas hanya dengan objek JSON {"reply": "...", "actions": []}.`},
			{Role: "user", Content: "Tes koneksi. Balas reply berisi kata: siap"},
		}})
	status, note := m.Status, ""
	out := map[string]any{"ok": err == nil}
	if err != nil {
		out["error"] = err.Error()
		var ae *ai.Error
		if errors.As(err, &ae) && ae.Rejected() && m.Status != db.ModelDisabled {
			status, note = db.ModelUnavailable, truncateRunes(ae.Msg, 200)
		} else {
			note = "tes gagal: " + truncateRunes(err.Error(), 180)
		}
	} else {
		if m.Status == db.ModelUnavailable {
			status = db.ModelActive
		}
		out["latencyMs"] = res.Latency.Milliseconds()
		out["sample"] = truncateRunes(res.Content, 300)
	}
	latency := 0
	if err == nil {
		latency = int(res.Latency.Milliseconds())
	}
	if err := s.DB.RecordModelCheck(id, status, note, latency); err != nil {
		fail(w, err)
		return
	}
	m, _ = s.DB.GetModel(id)
	out["model"] = m
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) adminRemoteModels(w http.ResponseWriter, r *http.Request) {
	provider := r.PathValue("provider")
	if !s.AI.Known(provider) {
		writeErr(w, http.StatusNotFound, "provider tidak dikenal")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	list, err := s.AI.ListModels(ctx, provider)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	existing, _ := s.DB.ListModels()
	in := map[string]bool{}
	for _, m := range existing {
		if m.Provider == provider {
			in[m.ModelID] = true
		}
	}
	type row struct {
		ai.RemoteModel
		InCatalog bool `json:"inCatalog"`
	}
	out := make([]row, 0, len(list))
	for _, m := range list {
		out = append(out, row{RemoteModel: m, InCatalog: in[m.ID]})
	}
	writeJSON(w, http.StatusOK, map[string]any{"models": out})
}

func (s *Server) adminImportModels(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Provider string           `json:"provider"`
		Models   []ai.RemoteModel `json:"models"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !s.AI.Known(in.Provider) {
		writeErr(w, http.StatusBadRequest, "provider tidak dikenal")
		return
	}
	if len(in.Models) == 0 || len(in.Models) > 50 {
		writeErr(w, http.StatusBadRequest, "pilih 1–50 model")
		return
	}
	added := []db.AIModel{}
	for _, rm := range in.Models {
		id := strings.TrimSpace(rm.ID)
		if !modelIDPattern.MatchString(id) {
			continue
		}
		if exists, _ := s.DB.ModelExists(in.Provider, id); exists {
			continue
		}
		label := truncateRunes(strings.TrimSpace(rm.Name), 100)
		if label == "" {
			label = id
		}
		m, err := s.DB.InsertModel(db.AIModel{Provider: in.Provider, ModelID: id, Label: label, Free: rm.Free})
		if err != nil {
			fail(w, err)
			return
		}
		added = append(added, m)
	}
	writeJSON(w, http.StatusOK, map[string]any{"added": added})
}

func truncateRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}
