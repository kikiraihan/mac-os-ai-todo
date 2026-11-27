package httpapi

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"aitodo/server/internal/core"
	"aitodo/server/internal/db"
	"aitodo/server/internal/schedule"
)

// MCP (Model Context Protocol) — AI lain (Claude, dsb.) bisa membaca & menambah
// todo, pengingat, catatan, dan mengirim teks ke perangkat pengguna.
//
// Transport: Streamable HTTP tanpa SSE (POST /mcp → satu jawaban JSON), stateless.
// Keamanan:
//   - Hanya Bearer token sesi jenis "mcp" (token manual dari Pengaturan, atau OAuth).
//     Cookie tidak dibaca sama sekali → tidak ada celah CSRF; token MCP ditolak di /api/.
//   - Semua aksi lewat internal/core (validasi sama dengan form manual), Source "mcp",
//     selalu per user_id pemilik token.
//   - Tidak ada tool hapus, tidak ada akses ke chat, Ingatan AI, atau pengaturan.
//   - Scope "read" hanya mendapat tool baca.

const (
	mcpTokenTTL      = 365 * 24 * time.Hour // token manual (Claude Code / Desktop)
	mcpOAuthTTL      = 30 * 24 * time.Hour  // akses OAuth (diperpanjang lewat refresh token)
	mcpMaxBody       = 256 << 10
	mcpCallsPerMin   = 120
	mcpWritesPerMin  = 30
	mcpMaxListResult = 200

	scopeRead  = "read"
	scopeWrite = "read write"
)

var mcpVersions = []string{"2025-06-18", "2025-03-26", "2024-11-05"}

func (s *Server) mcpRoutes() {
	m := s.Mux
	m.HandleFunc("POST /mcp", s.mcp)
	m.HandleFunc("GET /mcp", mcpNoStream)
	m.HandleFunc("DELETE /mcp", mcpNoStream)
	m.HandleFunc("POST /api/mcp/tokens", s.authed(s.createMCPToken))
}

func mcpNoStream(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Allow", "POST")
	writeErr(w, http.StatusMethodNotAllowed, "server ini tidak memakai SSE; kirim JSON-RPC lewat POST")
}

// createMCPToken: token MCP manual (untuk klien yang menerima header Authorization).
// Hanya dari sesi browser yang sedang login, ditampilkan sekali.
func (s *Server) createMCPToken(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Name  string `json:"name"`
		Write bool   `json:"write"`
	}
	if !decode(w, r, &in) {
		return
	}
	if sessionOf(r).Kind != db.SessionWeb {
		writeErr(w, http.StatusForbidden, "token MCP hanya bisa dibuat dari web")
		return
	}
	name := strings.ReplaceAll(strings.TrimSpace(in.Name), "\n", " ")
	if name == "" {
		name = "AI lain (MCP)"
	}
	if utf8.RuneCountInString(name) > 60 {
		writeErr(w, http.StatusBadRequest, "nama maksimal 60 karakter")
		return
	}
	scope := scopeRead
	if in.Write {
		scope = scopeWrite
	}
	u := userOf(r)
	token, th := newToken()
	sess, err := s.DB.CreateSession(db.Session{UserID: u.ID, Kind: db.SessionMCP, Name: name, Scope: scope,
		ExpiresAt: db.Stamp(time.Now().Add(mcpTokenTTL))}, th)
	if err != nil {
		fail(w, err)
		return
	}
	s.trimSessions(u.ID)
	writeJSON(w, http.StatusCreated, map[string]any{"token": token, "session": sess, "url": s.baseURL(r) + "/mcp"})
}

// baseURL: alamat publik server (PUBLIC_URL), atau ditebak dari request.
func (s *Server) baseURL(r *http.Request) string {
	if s.Cfg.PublicURL != "" {
		return strings.TrimRight(s.Cfg.PublicURL, "/")
	}
	scheme := "http"
	if r.TLS != nil || (s.Cfg.TrustProxy && strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")) || s.Cfg.SecureCookies {
		scheme = "https"
	}
	return scheme + "://" + r.Host
}

// mcpAuth: hanya sesi MCP lewat Bearer. ok=false berarti 401 sudah ditulis.
func (s *Server) mcpAuth(w http.ResponseWriter, r *http.Request) (db.Session, db.User, bool) {
	token := bearer(r)
	if strings.HasPrefix(token, tokenPrefix) && len(token) <= 100 {
		sess, user, err := s.DB.SessionByTokenHash(hashToken(token))
		if err == nil && !user.Disabled && user.Role == db.RoleUser && sess.Kind == db.SessionMCP {
			if last, err := db.ParseStamp(sess.LastSeenAt); err == nil && time.Since(last) > touchEvery {
				ttl := mcpTokenTTL
				if sess.ClientID != "" {
					ttl = mcpOAuthTTL
				}
				s.DB.TouchSession(sess.ID, db.Stamp(time.Now().Add(ttl)))
			}
			return sess, user, true
		}
	}
	w.Header().Set("WWW-Authenticate", `Bearer resource_metadata="`+s.baseURL(r)+`/.well-known/oauth-protected-resource"`)
	writeErr(w, http.StatusUnauthorized, "butuh token MCP AI Todo (Pengaturan → Integrasi AI)")
	return db.Session{}, db.User{}, false
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

func (s *Server) mcp(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	// Perlindungan DNS rebinding (wajib menurut spesifikasi MCP): Origin asing ditolak.
	if o := r.Header.Get("Origin"); o != "" && o != s.baseURL(r) {
		writeErr(w, http.StatusForbidden, "origin tidak diizinkan")
		return
	}
	sess, user, ok := s.mcpAuth(w, r)
	if !ok {
		return
	}
	key := "mcp:" + strconv.FormatInt(sess.ID, 10)
	if !s.chatLimit.allow(key, mcpCallsPerMin, time.Minute) {
		writeErr(w, http.StatusTooManyRequests, "terlalu banyak permintaan MCP, tunggu sebentar")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, mcpMaxBody))
	if err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "body terlalu besar")
		return
	}
	body = bytes.TrimSpace(body)
	var reqs []rpcRequest
	batch := len(body) > 0 && body[0] == '['
	if batch {
		err = json.Unmarshal(body, &reqs)
	} else {
		var one rpcRequest
		err = json.Unmarshal(body, &one)
		reqs = []rpcRequest{one}
	}
	if err != nil || len(reqs) == 0 || len(reqs) > 20 {
		writeJSON(w, http.StatusBadRequest, rpcResponse{JSONRPC: "2.0", ID: json.RawMessage("null"),
			Error: &rpcError{Code: -32700, Message: "JSON-RPC tidak valid"}})
		return
	}
	c := &mcpCall{s: s, user: user, sess: sess, key: key}
	var out []rpcResponse
	for _, req := range reqs {
		if len(req.ID) == 0 || string(req.ID) == "null" {
			continue // notifikasi (mis. notifications/initialized): tidak dijawab
		}
		res, rerr := c.handle(req)
		resp := rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: res, Error: rerr}
		if rerr == nil && res == nil {
			resp.Result = map[string]any{}
		}
		out = append(out, resp)
	}
	switch {
	case len(out) == 0:
		w.WriteHeader(http.StatusAccepted)
	case batch:
		writeJSON(w, http.StatusOK, out)
	default:
		writeJSON(w, http.StatusOK, out[0])
	}
}

type mcpCall struct {
	s    *Server
	user db.User
	sess db.Session
	key  string
}

func (c *mcpCall) canWrite() bool { return strings.Contains(c.sess.Scope, "write") }

func (c *mcpCall) handle(req rpcRequest) (any, *rpcError) {
	switch req.Method {
	case "initialize":
		var p struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		json.Unmarshal(req.Params, &p)
		version := mcpVersions[0]
		for _, v := range mcpVersions {
			if v == p.ProtocolVersion {
				version = v
			}
		}
		return map[string]any{
			"protocolVersion": version,
			"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
			"serverInfo":      map[string]any{"name": "aitodo", "title": "AI Todo", "version": c.s.Cfg.Version},
			"instructions":    c.instructions(),
		}, nil
	case "ping":
		return map[string]any{}, nil
	case "tools/list":
		var tools []mcpTool
		for _, t := range mcpTools {
			if !t.write || c.canWrite() {
				tools = append(tools, t)
			}
		}
		return map[string]any{"tools": tools}, nil
	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return nil, &rpcError{Code: -32602, Message: "params tidak valid"}
		}
		return c.callTool(p.Name, p.Arguments), nil
	case "resources/list":
		return map[string]any{"resources": []any{}}, nil
	case "prompts/list":
		return map[string]any{"prompts": []any{}}, nil
	}
	return nil, &rpcError{Code: -32601, Message: "method tidak dikenal: " + req.Method}
}

func (c *mcpCall) loc() *time.Location { return c.s.loc(c.user) }

func (c *mcpCall) instructions() string {
	now := time.Now().In(c.loc())
	access := "read-only"
	if c.canWrite() {
		access = "read & write (no delete)"
	}
	return fmt.Sprintf("AI Todo is the user's personal todo, reminder and notes app (Indonesian UI). "+
		"The user's timezone is %s; now is %s (%s). All dates/times you send or receive are in that local timezone "+
		"(dates YYYY-MM-DD, times HH:MM, reminder 'at' YYYY-MM-DDTHH:MM). The AI Todo server schedules reminders and "+
		"notifies the user's phone/computer itself — to remind the user, call create_reminder. Use send_to_devices to put "+
		"text on the user's devices with a Copy button. Access: %s. Write the user's content in the user's language.",
		c.loc().String(), now.Format("2006-01-02 15:04"), now.Weekday(), access)
}

// --- definisi tool -------------------------------------------------------------------

type mcpTool struct {
	Name        string         `json:"name"`
	Title       string         `json:"title"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	Annotations map[string]any `json:"annotations"`
	write       bool
}

func obj(required []string, props map[string]any) map[string]any {
	o := map[string]any{"type": "object", "properties": props, "additionalProperties": false}
	if len(required) > 0 {
		o["required"] = required
	}
	return o
}

func str(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }
func integer(desc string) map[string]any {
	return map[string]any{"type": "integer", "description": desc}
}
func enum(desc string, vals ...string) map[string]any {
	return map[string]any{"type": "string", "description": desc, "enum": vals}
}

func readTool(name, title, desc string, schema map[string]any) mcpTool {
	return mcpTool{Name: name, Title: title, Description: desc, InputSchema: schema,
		Annotations: map[string]any{"readOnlyHint": true, "openWorldHint": false}}
}

func writeTool(name, title, desc string, schema map[string]any) mcpTool {
	return mcpTool{Name: name, Title: title, Description: desc, InputSchema: schema, write: true,
		Annotations: map[string]any{"readOnlyHint": false, "destructiveHint": false, "openWorldHint": false}}
}

var mcpTools = []mcpTool{
	readTool("get_context", "Waktu & ringkasan", "Current local date/time, timezone, and counts of the user's open/overdue/today todos. Call this first when dates matter.", obj(nil, map[string]any{})),
	readTool("list_todos", "Daftar todo", "List the user's todos.", obj(nil, map[string]any{
		"status":   enum("open (default), done, or all", "open", "done", "all"),
		"due_from": str("Only todos due on/after this date (YYYY-MM-DD)"),
		"due_to":   str("Only todos due on/before this date (YYYY-MM-DD)"),
		"query":    str("Text search in title & notes"),
		"list":     str("Category/list name"),
		"limit":    integer("Max results (default 50, max 200)"),
	})),
	writeTool("create_todo", "Tambah todo", "Create a todo. due_time needs due_date.", obj([]string{"title"}, map[string]any{
		"title":    str("Short title (max 200 chars)"),
		"notes":    str("Details, links, checklist (max 5000 chars)"),
		"list":     str("Category/list name (optional)"),
		"priority": enum("Priority (default normal)", "low", "normal", "high"),
		"due_date": str("Due date YYYY-MM-DD (local)"),
		"due_time": str("Due time HH:MM (local, 24h)"),
	})),
	writeTool("update_todo", "Ubah todo", "Update fields of a todo. Omitted fields stay unchanged; empty string clears due_date/due_time.", obj([]string{"id"}, map[string]any{
		"id":           integer("Todo id"),
		"title":        str("New title"),
		"notes":        str("Replace notes"),
		"append_notes": str("Append a line to notes without replacing them"),
		"list":         str("Category/list name"),
		"priority":     enum("Priority", "low", "normal", "high"),
		"due_date":     str("Due date YYYY-MM-DD, or empty to clear"),
		"due_time":     str("Due time HH:MM, or empty to clear"),
	})),
	writeTool("complete_todo", "Selesaikan todo", "Mark a todo as done.", obj([]string{"id"}, map[string]any{"id": integer("Todo id")})),
	writeTool("reopen_todo", "Buka lagi todo", "Mark a done todo as open again.", obj([]string{"id"}, map[string]any{"id": integer("Todo id")})),
	readTool("list_reminders", "Daftar pengingat", "List the user's reminders with their next fire time (local).", obj(nil, map[string]any{
		"include_inactive": map[string]any{"type": "boolean", "description": "Also include finished/paused reminders"},
	})),
	writeTool("create_reminder", "Buat pengingat", "Schedule a reminder; the AI Todo server sends a push notification to the user's devices at that time. "+
		"Give either 'at' (one-time) or 'schedule' (repeating).", obj([]string{"title"}, map[string]any{
		"title":   str("What to remind about (shown as the notification title)"),
		"message": str("Optional extra text in the notification (max 500 chars)"),
		"at":      str("One-time local time YYYY-MM-DDTHH:MM, e.g. 2026-11-28T15:00"),
		"schedule": map[string]any{"type": "object", "description": "Repeating schedule instead of 'at'. kind: daily|weekly|monthly|yearly|interval; " +
			"time HH:MM; every N (days/weeks); weekdays [1=Mon..7=Sun]; monthDay 1-31; month 1-12; everyMinutes (>=15) with optional window {from,to}; " +
			"startDate/until YYYY-MM-DD; count. Example: {\"kind\":\"weekly\",\"weekdays\":[1,3],\"time\":\"08:00\"}"},
		"todo_id": integer("Optional: attach to an existing todo (its notification gets a Done button)"),
	})),
	writeTool("snooze_reminder", "Tunda pengingat", "Push a reminder's next notification to now + minutes.", obj([]string{"id"}, map[string]any{
		"id": integer("Reminder id"), "minutes": integer("5–1440, default 10"),
	})),
	readTool("list_notes", "Daftar catatan", "List or search the user's notes (pinned first).", obj(nil, map[string]any{
		"query":  str("Text search in title & content"),
		"pinned": map[string]any{"type": "boolean", "description": "Only pinned notes"},
		"list":   str("Category name"),
		"limit":  integer("Max results (default 30, max 200)"),
	})),
	writeTool("create_note", "Tambah catatan", "Save a note (text, links). Empty title = first line of content.", obj(nil, map[string]any{
		"title": str("Title"), "content": str("Content (max 20000 chars)"), "list": str("Category"),
		"pinned": map[string]any{"type": "boolean", "description": "Pin to top"},
	})),
	writeTool("append_to_note", "Tambah ke catatan", "Append text to an existing note without replacing it.", obj([]string{"id", "content"}, map[string]any{
		"id": integer("Note id"), "content": str("Text to append"),
	})),
	writeTool("send_to_devices", "Kirim ke perangkat", "Send text to the user's phone & other devices right now as a notification with a Copy button "+
		"(e.g. a command, address, or message to paste). Kept for 7 days in Kiriman.", obj([]string{"text"}, map[string]any{
		"text": str("Text to send (max 20000 chars)"),
	})),
}

// --- eksekusi tool ---------------------------------------------------------------------

func toolText(v any) map[string]any {
	b, _ := json.MarshalIndent(v, "", " ")
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": string(b)}}}
}

func toolError(msg string) map[string]any {
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": msg}}, "isError": true}
}

func (c *mcpCall) callTool(name string, raw json.RawMessage) map[string]any {
	var tool *mcpTool
	for i := range mcpTools {
		if mcpTools[i].Name == name {
			tool = &mcpTools[i]
		}
	}
	if tool == nil {
		return toolError("tool tidak dikenal: " + name)
	}
	if tool.write {
		if !c.canWrite() {
			return toolError("token ini hanya boleh membaca (scope read)")
		}
		if !c.s.chatLimit.allow(c.key+":w", mcpWritesPerMin, time.Minute) {
			return toolError("terlalu banyak perubahan, tunggu sebentar")
		}
	}
	if len(raw) == 0 || string(raw) == "null" {
		raw = json.RawMessage("{}")
	}
	res, err := c.run(name, raw)
	status := "ok"
	if err != nil {
		status = "gagal"
	}
	// Metadata saja — isi argumen bisa berisi data pribadi pengguna.
	log.Printf("mcp: pengguna %d sesi %d tool %s %s", c.user.ID, c.sess.ID, name, status)
	if err != nil {
		var ve *core.ValidationError
		switch {
		case errors.As(err, &ve):
			return toolError(ve.Msg)
		case errors.Is(err, db.ErrNotFound):
			return toolError("tidak ditemukan")
		case errors.Is(err, errBadArgs):
			return toolError(err.Error())
		}
		log.Printf("mcp: %s: %v", name, err)
		return toolError("terjadi kesalahan di server")
	}
	return toolText(res)
}

var errBadArgs = errors.New("argumen tidak valid")

func badArgs(format string, a ...any) error {
	return fmt.Errorf("%w: %s", errBadArgs, fmt.Sprintf(format, a...))
}

// mutate menjalankan aksi tulis dalam transaksi lewat core, lalu membangunkan perangkat pengguna.
func (c *mcpCall) mutate(f func(cc *core.Ctx) (any, error)) (any, error) {
	var out any
	err := c.s.DB.Tx(func(tx *sql.Tx) error {
		var err error
		out, err = f(&core.Ctx{Q: tx, UserID: c.user.ID, Loc: c.loc(), Source: "mcp"})
		return err
	})
	if err == nil {
		c.s.Hub.Bump(c.user.ID)
	}
	return out, err
}

func strict(raw json.RawMessage, v any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return badArgs("%s", strings.TrimPrefix(err.Error(), "json: "))
	}
	return nil
}

// Tampilan ringkas untuk AI: waktu dalam zona pengguna, tanpa kolom internal.
type mcpTodo struct {
	ID       int64  `json:"id"`
	Title    string `json:"title"`
	Notes    string `json:"notes,omitempty"`
	Status   string `json:"status"`
	Priority string `json:"priority,omitempty"`
	List     string `json:"list,omitempty"`
	DueDate  string `json:"due_date,omitempty"`
	DueTime  string `json:"due_time,omitempty"`
}

func viewTodo(t db.Todo) mcpTodo {
	p := t.Priority
	if p == "normal" {
		p = ""
	}
	return mcpTodo{ID: t.ID, Title: t.Title, Notes: t.Notes, Status: t.Status, Priority: p, List: t.List, DueDate: t.DueDate, DueTime: t.DueTime}
}

type mcpReminder struct {
	ID       int64  `json:"id"`
	Title    string `json:"title"`
	Message  string `json:"message,omitempty"`
	Schedule string `json:"schedule"`
	NextFire string `json:"next_fire,omitempty"`
	Active   bool   `json:"active"`
	TodoID   *int64 `json:"todo_id,omitempty"`
}

func (c *mcpCall) viewReminder(r db.Reminder) mcpReminder {
	v := core.ViewReminder(r)
	out := mcpReminder{ID: r.ID, Title: r.Title, Message: r.Message, Schedule: v.ScheduleText, Active: r.Active, TodoID: r.TodoID}
	if t, err := db.ParseStamp(r.NextFireAt); err == nil {
		out.NextFire = t.In(c.loc()).Format("2006-01-02 15:04")
	}
	return out
}

type mcpNote struct {
	ID      int64  `json:"id"`
	Title   string `json:"title"`
	Content string `json:"content,omitempty"`
	List    string `json:"list,omitempty"`
	Pinned  bool   `json:"pinned,omitempty"`
	Updated string `json:"updated"`
}

func (c *mcpCall) viewNote(n db.Note) mcpNote {
	out := mcpNote{ID: n.ID, Title: n.Title, Content: n.Content, List: n.List, Pinned: n.Pinned}
	if t, err := db.ParseStamp(n.UpdatedAt); err == nil {
		out.Updated = t.In(c.loc()).Format("2006-01-02 15:04")
	}
	return out
}

func limitOf(v, def int) int {
	if v <= 0 {
		return def
	}
	if v > mcpMaxListResult {
		return mcpMaxListResult
	}
	return v
}

func (c *mcpCall) run(name string, raw json.RawMessage) (any, error) {
	uid := c.user.ID
	switch name {
	case "get_context":
		if err := strict(raw, &struct{}{}); err != nil {
			return nil, err
		}
		now := time.Now().In(c.loc())
		today := now.Format("2006-01-02")
		todos, err := db.ListTodos(c.s.DB, uid, db.TodoFilter{Status: core.StatusOpen})
		if err != nil {
			return nil, err
		}
		dueToday, overdue := 0, 0
		for _, t := range todos {
			switch {
			case t.DueDate == today:
				dueToday++
			case t.DueDate != "" && t.DueDate < today:
				overdue++
			}
		}
		return map[string]any{"now": now.Format("2006-01-02 15:04"), "weekday": now.Weekday().String(), "timezone": c.loc().String(),
			"open_todos": len(todos), "due_today": dueToday, "overdue": overdue, "can_write": c.canWrite()}, nil

	case "list_todos":
		var a struct {
			Status  string `json:"status"`
			DueFrom string `json:"due_from"`
			DueTo   string `json:"due_to"`
			Query   string `json:"query"`
			List    string `json:"list"`
			Limit   int    `json:"limit"`
		}
		if err := strict(raw, &a); err != nil {
			return nil, err
		}
		switch a.Status {
		case "":
			a.Status = "open"
		case "open", "done", "all":
		default:
			return nil, badArgs("status harus open, done, atau all")
		}
		todos, err := db.ListTodos(c.s.DB, uid, db.TodoFilter{Status: a.Status, From: a.DueFrom, To: a.DueTo, Query: a.Query, List: a.List})
		if err != nil {
			return nil, err
		}
		n := limitOf(a.Limit, 50)
		out := []mcpTodo{}
		for i, t := range todos {
			if i == n {
				break
			}
			out = append(out, viewTodo(t))
		}
		return map[string]any{"todos": out, "total": len(todos)}, nil

	case "create_todo", "update_todo":
		var a struct {
			ID          int64   `json:"id"`
			Title       *string `json:"title"`
			Notes       *string `json:"notes"`
			AppendNotes *string `json:"append_notes"`
			List        *string `json:"list"`
			Priority    *string `json:"priority"`
			DueDate     *string `json:"due_date"`
			DueTime     *string `json:"due_time"`
		}
		if err := strict(raw, &a); err != nil {
			return nil, err
		}
		in := core.TodoInput{Title: a.Title, Notes: a.Notes, AppendNotes: a.AppendNotes, List: a.List, Priority: a.Priority,
			DueDate: a.DueDate, DueTime: a.DueTime}
		if name == "create_todo" {
			if a.ID != 0 {
				return nil, badArgs("create_todo tidak menerima id")
			}
			if a.Title == nil {
				return nil, badArgs("title wajib diisi")
			}
			return c.mutate(func(cc *core.Ctx) (any, error) {
				t, err := core.CreateTodo(cc, in)
				return map[string]any{"todo": viewTodo(t)}, err
			})
		}
		if a.ID <= 0 {
			return nil, badArgs("id wajib diisi")
		}
		return c.mutate(func(cc *core.Ctx) (any, error) {
			t, err := core.UpdateTodo(cc, a.ID, in)
			return map[string]any{"todo": viewTodo(t)}, err
		})

	case "complete_todo", "reopen_todo":
		var a struct {
			ID int64 `json:"id"`
		}
		if err := strict(raw, &a); err != nil {
			return nil, err
		}
		f := core.CompleteTodo
		if name == "reopen_todo" {
			f = core.ReopenTodo
		}
		return c.mutate(func(cc *core.Ctx) (any, error) {
			t, err := f(cc, a.ID)
			return map[string]any{"todo": viewTodo(t)}, err
		})

	case "list_reminders":
		var a struct {
			IncludeInactive bool `json:"include_inactive"`
		}
		if err := strict(raw, &a); err != nil {
			return nil, err
		}
		rs, err := db.ListReminders(c.s.DB, uid)
		if err != nil {
			return nil, err
		}
		out := []mcpReminder{}
		for _, r := range rs {
			if r.Active || a.IncludeInactive {
				out = append(out, c.viewReminder(r))
			}
		}
		return map[string]any{"reminders": out}, nil

	case "create_reminder":
		var a struct {
			Title    string             `json:"title"`
			Message  string             `json:"message"`
			At       string             `json:"at"`
			Schedule *schedule.Schedule `json:"schedule"`
			TodoID   int64              `json:"todo_id"`
		}
		if err := strict(raw, &a); err != nil {
			return nil, err
		}
		sched := a.Schedule
		switch {
		case a.At != "" && sched != nil:
			return nil, badArgs("isi salah satu: at atau schedule")
		case a.At != "":
			sched = &schedule.Schedule{Kind: schedule.KindOnce, At: strings.Replace(strings.TrimSpace(a.At), " ", "T", 1)}
		case sched == nil:
			return nil, badArgs("isi at (sekali) atau schedule (berulang)")
		}
		in := core.ReminderInput{Title: &a.Title, Message: &a.Message, Schedule: sched}
		if a.TodoID != 0 {
			in.TodoID = &a.TodoID
		}
		return c.mutate(func(cc *core.Ctx) (any, error) {
			r, err := core.CreateReminder(cc, in)
			return map[string]any{"reminder": c.viewReminder(r)}, err
		})

	case "snooze_reminder":
		var a struct {
			ID      int64 `json:"id"`
			Minutes int   `json:"minutes"`
		}
		if err := strict(raw, &a); err != nil {
			return nil, err
		}
		if a.Minutes == 0 {
			a.Minutes = 10
		}
		return c.mutate(func(cc *core.Ctx) (any, error) {
			r, err := core.SnoozeReminder(cc, a.ID, a.Minutes)
			return map[string]any{"reminder": c.viewReminder(r)}, err
		})

	case "list_notes":
		var a struct {
			Query  string `json:"query"`
			Pinned bool   `json:"pinned"`
			List   string `json:"list"`
			Limit  int    `json:"limit"`
		}
		if err := strict(raw, &a); err != nil {
			return nil, err
		}
		notes, err := db.ListNotes(c.s.DB, uid, db.NoteFilter{Query: a.Query, Pinned: a.Pinned, List: a.List, Limit: limitOf(a.Limit, 30)})
		if err != nil {
			return nil, err
		}
		out := []mcpNote{}
		for _, n := range notes {
			out = append(out, c.viewNote(n))
		}
		return map[string]any{"notes": out}, nil

	case "create_note":
		var a struct {
			Title   *string `json:"title"`
			Content *string `json:"content"`
			List    *string `json:"list"`
			Pinned  *bool   `json:"pinned"`
		}
		if err := strict(raw, &a); err != nil {
			return nil, err
		}
		return c.mutate(func(cc *core.Ctx) (any, error) {
			n, err := core.CreateNote(cc, core.NoteInput{Title: a.Title, Content: a.Content, List: a.List, Pinned: a.Pinned})
			return map[string]any{"note": c.viewNote(n)}, err
		})

	case "append_to_note":
		var a struct {
			ID      int64  `json:"id"`
			Content string `json:"content"`
		}
		if err := strict(raw, &a); err != nil {
			return nil, err
		}
		return c.mutate(func(cc *core.Ctx) (any, error) {
			n, err := core.UpdateNote(cc, a.ID, core.NoteInput{AppendContent: &a.Content})
			return map[string]any{"note": c.viewNote(n)}, err
		})

	case "send_to_devices":
		var a struct {
			Text string `json:"text"`
		}
		if err := strict(raw, &a); err != nil {
			return nil, err
		}
		clip, sent, err := c.s.sendClip(c.user, c.sess.ID, c.sess.Name, a.Text)
		if err != nil {
			return nil, err
		}
		return map[string]any{"clip_id": clip.ID, "devices_notified": sent}, nil
	}
	return nil, badArgs("tool tidak dikenal")
}
