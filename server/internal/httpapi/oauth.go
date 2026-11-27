package httpapi

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"aitodo/server/internal/db"
)

// OAuth 2.1 untuk konektor MCP (mis. claude.ai → Settings → Connectors):
//   - metadata RFC 9728 (protected resource) & RFC 8414 (authorization server)
//   - pendaftaran klien dinamis RFC 7591 (klien publik, tanpa secret)
//   - authorization code + PKCE S256 wajib, kode sekali pakai 10 menit
//   - persetujuan selalu oleh pengguna di halaman /izinkan (sesi browser), bisa pilih baca saja
//   - access token = token sesi MCP (dicabut di Pengaturan → Perangkat), refresh token dirotasi

const (
	oauthCodeTTL     = 10 * time.Minute
	oauthRefreshTTL  = 90 * 24 * time.Hour
	oauthMaxClients  = 1000
	oauthMaxBody     = 16 << 10
	oauthRegsPerHour = 20
)

func (s *Server) oauthRoutes() {
	m := s.Mux
	m.HandleFunc("GET /.well-known/oauth-protected-resource", s.oauthResourceMeta)
	m.HandleFunc("GET /.well-known/oauth-protected-resource/mcp", s.oauthResourceMeta)
	m.HandleFunc("GET /.well-known/oauth-authorization-server", s.oauthServerMeta)
	m.HandleFunc("POST /oauth/register", s.oauthRegister)
	m.HandleFunc("GET /oauth/authorize", s.oauthAuthorize)
	m.HandleFunc("POST /oauth/token", s.oauthToken)
	// Dipakai halaman persetujuan (web) — wajib login & header X-AITodo seperti API lain.
	m.HandleFunc("GET /api/oauth/request", s.authed(s.oauthRequestInfo))
	m.HandleFunc("POST /api/oauth/approve", s.authed(s.oauthApprove))
}

func (s *Server) oauthResourceMeta(w http.ResponseWriter, r *http.Request) {
	base := s.baseURL(r)
	writeJSON(w, http.StatusOK, map[string]any{
		"resource":                 base + "/mcp",
		"authorization_servers":    []string{base},
		"scopes_supported":         []string{"read", "write"},
		"bearer_methods_supported": []string{"header"},
		"resource_name":            "AI Todo",
	})
}

func (s *Server) oauthServerMeta(w http.ResponseWriter, r *http.Request) {
	base := s.baseURL(r)
	writeJSON(w, http.StatusOK, map[string]any{
		"issuer":                                base,
		"authorization_endpoint":                base + "/oauth/authorize",
		"token_endpoint":                        base + "/oauth/token",
		"registration_endpoint":                 base + "/oauth/register",
		"response_types_supported":              []string{"code"},
		"grant_types_supported":                 []string{"authorization_code", "refresh_token"},
		"code_challenge_methods_supported":      []string{"S256"},
		"token_endpoint_auth_methods_supported": []string{"none"},
		"scopes_supported":                      []string{"read", "write"},
	})
}

func oauthErr(w http.ResponseWriter, status int, code, desc string) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, status, map[string]string{"error": code, "error_description": desc})
}

// validRedirect: https (tanpa fragment/userinfo), atau http loopback untuk aplikasi desktop.
func validRedirect(raw string) bool {
	if len(raw) > 500 {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || u.Fragment != "" || u.User != nil || u.Host == "" {
		return false
	}
	switch u.Scheme {
	case "https":
		return true
	case "http":
		h := u.Hostname()
		return h == "localhost" || h == "127.0.0.1" || h == "::1"
	}
	return false
}

func randomID(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func (s *Server) oauthRegister(w http.ResponseWriter, r *http.Request) {
	if !s.loginLimit.allow("oauthreg:"+s.clientIP(r), oauthRegsPerHour, time.Hour) {
		oauthErr(w, http.StatusTooManyRequests, "slow_down", "terlalu banyak pendaftaran klien")
		return
	}
	var in struct {
		ClientName   string   `json:"client_name"`
		RedirectURIs []string `json:"redirect_uris"`
		AuthMethod   string   `json:"token_endpoint_auth_method"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, oauthMaxBody)).Decode(&in); err != nil {
		oauthErr(w, http.StatusBadRequest, "invalid_client_metadata", "body JSON tidak valid")
		return
	}
	if len(in.RedirectURIs) == 0 || len(in.RedirectURIs) > 5 {
		oauthErr(w, http.StatusBadRequest, "invalid_redirect_uri", "butuh 1–5 redirect_uris")
		return
	}
	for _, u := range in.RedirectURIs {
		if !validRedirect(u) {
			oauthErr(w, http.StatusBadRequest, "invalid_redirect_uri", "redirect_uri harus https atau http://localhost")
			return
		}
	}
	if in.AuthMethod != "" && in.AuthMethod != "none" {
		oauthErr(w, http.StatusBadRequest, "invalid_client_metadata", "hanya klien publik (token_endpoint_auth_method none)")
		return
	}
	name := strings.Map(func(r rune) rune {
		if r < 32 {
			return -1
		}
		return r
	}, strings.TrimSpace(in.ClientName))
	if name == "" {
		name = "Aplikasi tanpa nama"
	}
	if utf8.RuneCountInString(name) > 60 {
		name = string([]rune(name)[:60])
	}
	if n, err := s.DB.CountOAuthClients(); err != nil || n >= oauthMaxClients {
		oauthErr(w, http.StatusServiceUnavailable, "temporarily_unavailable", "kuota klien penuh")
		return
	}
	c, err := s.DB.CreateOAuthClient(db.OAuthClient{ClientID: "aitc_" + randomID(18), Name: name, RedirectURIs: in.RedirectURIs})
	if err != nil {
		fail(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusCreated, map[string]any{
		"client_id": c.ClientID, "client_name": c.Name, "redirect_uris": c.RedirectURIs,
		"token_endpoint_auth_method": "none", "grant_types": []string{"authorization_code", "refresh_token"},
		"response_types": []string{"code"}, "client_id_issued_at": time.Now().Unix(),
	})
}

// authReq: parameter permintaan otorisasi yang sudah dicek.
type authReq struct {
	Client      db.OAuthClient
	RedirectURI string
	Challenge   string
	State       string
	Scope       string // "read" / "read write" (yang diminta klien)
	Resource    string
}

func (s *Server) parseAuthReq(r *http.Request, q url.Values) (authReq, string) {
	var a authReq
	if q.Get("response_type") != "code" {
		return a, "response_type harus code"
	}
	c, err := s.DB.GetOAuthClient(q.Get("client_id"))
	if err != nil {
		return a, "aplikasi tidak dikenal (client_id)"
	}
	ru := q.Get("redirect_uri")
	if ru == "" && len(c.RedirectURIs) == 1 {
		ru = c.RedirectURIs[0]
	}
	found := false
	for _, x := range c.RedirectURIs {
		found = found || x == ru
	}
	if !found {
		return a, "redirect_uri tidak terdaftar untuk aplikasi ini"
	}
	if q.Get("code_challenge_method") != "S256" || len(q.Get("code_challenge")) < 43 || len(q.Get("code_challenge")) > 128 {
		return a, "PKCE S256 wajib (code_challenge)"
	}
	if res := q.Get("resource"); res != "" {
		base := s.baseURL(r)
		if strings.TrimRight(res, "/") != base+"/mcp" && strings.TrimRight(res, "/") != base {
			return a, "resource bukan server MCP ini"
		}
		a.Resource = res
	}
	scope := scopeWrite
	if sc := q.Get("scope"); sc != "" && !strings.Contains(sc, "write") {
		scope = scopeRead
	}
	if len(q.Get("state")) > 500 {
		return a, "state terlalu panjang"
	}
	a.Client, a.RedirectURI, a.Challenge, a.State, a.Scope = c, ru, q.Get("code_challenge"), q.Get("state"), scope
	return a, ""
}

// oauthAuthorize: cek parameter, lalu tampilkan halaman persetujuan (SPA /izinkan).
// Parameter tidak sah tidak pernah di-redirect ke redirect_uri yang belum terverifikasi.
func (s *Server) oauthAuthorize(w http.ResponseWriter, r *http.Request) {
	if _, msg := s.parseAuthReq(r, r.URL.Query()); msg != "" {
		http.Redirect(w, r, "/izinkan?error="+url.QueryEscape(msg), http.StatusFound)
		return
	}
	http.Redirect(w, r, "/izinkan?"+r.URL.RawQuery, http.StatusFound)
}

func (s *Server) oauthRequestInfo(w http.ResponseWriter, r *http.Request) {
	a, msg := s.parseAuthReq(r, r.URL.Query())
	if msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	host := a.RedirectURI
	if u, err := url.Parse(a.RedirectURI); err == nil {
		host = u.Host
	}
	writeJSON(w, http.StatusOK, map[string]any{"clientName": a.Client.Name, "redirectHost": host,
		"write": strings.Contains(a.Scope, "write")})
}

func (s *Server) oauthApprove(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Query string `json:"query"` // query string asli dari /oauth/authorize
		Allow bool   `json:"allow"`
		Write bool   `json:"write"`
	}
	if !decode(w, r, &in) {
		return
	}
	if sessionOf(r).Kind != db.SessionWeb {
		writeErr(w, http.StatusForbidden, "persetujuan hanya dari browser")
		return
	}
	q, err := url.ParseQuery(in.Query)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "permintaan tidak valid")
		return
	}
	a, msg := s.parseAuthReq(r, q)
	if msg != "" {
		writeErr(w, http.StatusBadRequest, msg)
		return
	}
	dest, _ := url.Parse(a.RedirectURI)
	v := dest.Query()
	if a.State != "" {
		v.Set("state", a.State)
	}
	v.Set("iss", s.baseURL(r))
	if !in.Allow {
		v.Set("error", "access_denied")
		dest.RawQuery = v.Encode()
		writeJSON(w, http.StatusOK, map[string]string{"redirect": dest.String()})
		return
	}
	scope := scopeRead
	if in.Write && strings.Contains(a.Scope, "write") {
		scope = scopeWrite
	}
	code := randomID(32)
	if err := s.DB.InsertOAuthCode(hashToken(code), db.OAuthCode{ClientID: a.Client.ClientID, UserID: userOf(r).ID,
		RedirectURI: a.RedirectURI, Challenge: a.Challenge, Scope: scope, Resource: a.Resource,
		ExpiresAt: db.Stamp(time.Now().Add(oauthCodeTTL))}); err != nil {
		fail(w, err)
		return
	}
	v.Set("code", code)
	dest.RawQuery = v.Encode()
	writeJSON(w, http.StatusOK, map[string]string{"redirect": dest.String()})
}

func pkceOK(verifier, challenge string) bool {
	if len(verifier) < 43 || len(verifier) > 128 {
		return false
	}
	sum := sha256.Sum256([]byte(verifier))
	got := base64.RawURLEncoding.EncodeToString(sum[:])
	return subtle.ConstantTimeCompare([]byte(got), []byte(challenge)) == 1
}

func (s *Server) oauthToken(w http.ResponseWriter, r *http.Request) {
	if !s.loginLimit.allow("oauthtok:"+s.clientIP(r), 60, time.Minute) {
		oauthErr(w, http.StatusTooManyRequests, "slow_down", "terlalu banyak permintaan")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, oauthMaxBody)
	if err := r.ParseForm(); err != nil {
		oauthErr(w, http.StatusBadRequest, "invalid_request", "body form tidak valid")
		return
	}
	f := r.PostForm
	switch f.Get("grant_type") {
	case "authorization_code":
		code, err := s.DB.TakeOAuthCode(hashToken(f.Get("code")))
		if err != nil {
			oauthErr(w, http.StatusBadRequest, "invalid_grant", "kode tidak berlaku")
			return
		}
		if code.ClientID != f.Get("client_id") || code.RedirectURI != f.Get("redirect_uri") || !pkceOK(f.Get("code_verifier"), code.Challenge) {
			oauthErr(w, http.StatusBadRequest, "invalid_grant", "kode tidak cocok (client_id / redirect_uri / code_verifier)")
			return
		}
		client, err := s.DB.GetOAuthClient(code.ClientID)
		if err != nil {
			oauthErr(w, http.StatusBadRequest, "invalid_client", "aplikasi tidak dikenal")
			return
		}
		user, err := s.DB.GetUser(code.UserID)
		if err != nil || user.Disabled {
			oauthErr(w, http.StatusBadRequest, "invalid_grant", "akun tidak aktif")
			return
		}
		token, th := newToken()
		sess, err := s.DB.CreateSession(db.Session{UserID: user.ID, Kind: db.SessionMCP, Name: client.Name, Scope: code.Scope,
			ClientID: client.ClientID, UserAgent: userAgent(r), ExpiresAt: db.Stamp(time.Now().Add(mcpOAuthTTL))}, th)
		if err != nil {
			fail(w, err)
			return
		}
		s.trimSessions(user.ID)
		s.DB.TouchOAuthClient(client.ClientID)
		s.issueTokens(w, sess, token)
	case "refresh_token":
		ref, err := s.DB.TakeOAuthRefresh(hashToken(f.Get("refresh_token")))
		if err != nil || ref.ClientID != f.Get("client_id") {
			oauthErr(w, http.StatusBadRequest, "invalid_grant", "refresh token tidak berlaku")
			return
		}
		sess, user, err := s.DB.SessionByID(ref.SessionID)
		if err != nil || user.Disabled || sess.Kind != db.SessionMCP || sess.ClientID != ref.ClientID {
			oauthErr(w, http.StatusBadRequest, "invalid_grant", "akses sudah dicabut")
			return
		}
		token, th := newToken()
		if err := s.DB.RotateSessionToken(sess.ID, th, db.Stamp(time.Now().Add(mcpOAuthTTL))); err != nil {
			fail(w, err)
			return
		}
		s.DB.TouchOAuthClient(ref.ClientID)
		s.issueTokens(w, sess, token)
	default:
		oauthErr(w, http.StatusBadRequest, "unsupported_grant_type", "grant_type tidak didukung")
	}
}

func (s *Server) issueTokens(w http.ResponseWriter, sess db.Session, access string) {
	refresh := "aitr_" + randomID(32)
	if err := s.DB.InsertOAuthRefresh(hashToken(refresh), db.OAuthRefresh{SessionID: sess.ID, ClientID: sess.ClientID,
		ExpiresAt: db.Stamp(time.Now().Add(oauthRefreshTTL))}); err != nil {
		fail(w, err)
		return
	}
	scope := "read"
	if strings.Contains(sess.Scope, "write") {
		scope = "read write"
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"access_token": access, "token_type": "Bearer",
		"expires_in": int(mcpOAuthTTL.Seconds()), "refresh_token": refresh, "scope": scope})
}
