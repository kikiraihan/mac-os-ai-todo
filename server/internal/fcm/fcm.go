// Package fcm membangunkan aplikasi Android lewat Firebase Cloud Messaging (HTTP v1).
//
// Pesan yang dikirim hanya berisi nomor notifikasi ("nid"): judul, isi, dan teks
// untuk tombol Salin diambil aplikasi langsung dari server AI Todo
// (GET /api/notifications), jadi isi todo/kiriman pengguna tidak pernah lewat Google.
//
// Kredensial (service account) hanya dari environment (FCM_CREDENTIALS), tidak
// pernah disimpan di database, dikirim ke klien, atau dicatat di log. Host yang
// dihubungi tetap: oauth2.googleapis.com dan fcm.googleapis.com.
package fcm

import (
	"bytes"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"aitodo/server/internal/push"
)

const (
	tokenURL = "https://oauth2.googleapis.com/token"
	sendURL  = "https://fcm.googleapis.com/v1/projects/%s/messages:send"
	scope    = "https://www.googleapis.com/auth/firebase.messaging"
)

var projectPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{4,61}[a-z0-9]$`)

// ClientConfig: pengenal Firebase untuk aplikasi Android (setara isi google-services.json —
// bukan rahasia, memang tertanam di setiap APK). Dikirim ke aplikasi yang sudah login.
type ClientConfig struct {
	ProjectID string `json:"projectId"`
	AppID     string `json:"appId"`
	APIKey    string `json:"apiKey"`
	SenderID  string `json:"senderId"`
}

type Client struct {
	ProjectID string
	Android   ClientConfig

	email string
	key   *rsa.PrivateKey
	http  *http.Client
	// tokenURL & sendURL bisa diganti di tes.
	tokenURL string
	sendURL  string

	mu      sync.Mutex
	access  string
	expires time.Time
}

type serviceAccount struct {
	Type        string `json:"type"`
	ProjectID   string `json:"project_id"`
	PrivateKey  string `json:"private_key"`
	ClientEmail string `json:"client_email"`
}

// LoadCredentials membaca nilai FCM_CREDENTIALS: isi JSON langsung, path berkas, atau base64 JSON.
func LoadCredentials(v string) ([]byte, error) {
	v = strings.TrimSpace(v)
	switch {
	case v == "":
		return nil, nil
	case strings.HasPrefix(v, "{"):
		return []byte(v), nil
	}
	if b, err := os.ReadFile(v); err == nil {
		return b, nil
	}
	b, err := base64.StdEncoding.DecodeString(v)
	if err != nil || !bytes.HasPrefix(bytes.TrimSpace(b), []byte("{")) {
		return nil, errors.New("FCM_CREDENTIALS harus berisi JSON service account, path berkasnya, atau base64-nya")
	}
	return b, nil
}

// New membuat klien dari JSON service account. android: pengenal aplikasi Android (boleh
// kosong sebagian; tanpa AppID & APIKey aplikasi tidak bisa mendaftar ke FCM).
func New(credJSON []byte, android ClientConfig) (*Client, error) {
	var sa serviceAccount
	if err := json.Unmarshal(credJSON, &sa); err != nil {
		return nil, errors.New("FCM_CREDENTIALS bukan JSON yang valid")
	}
	if sa.Type != "service_account" || sa.ClientEmail == "" || sa.PrivateKey == "" {
		return nil, errors.New("FCM_CREDENTIALS bukan service account (butuh type, client_email, private_key)")
	}
	if !projectPattern.MatchString(sa.ProjectID) {
		return nil, errors.New("project_id service account tidak valid")
	}
	key, err := jwt.ParseRSAPrivateKeyFromPEM([]byte(sa.PrivateKey))
	if err != nil {
		return nil, errors.New("private_key service account tidak bisa dibaca")
	}
	android.ProjectID = sa.ProjectID
	return &Client{ProjectID: sa.ProjectID, Android: android, email: sa.ClientEmail, key: key,
		http: &http.Client{Timeout: 15 * time.Second}, tokenURL: tokenURL, sendURL: fmt.Sprintf(sendURL, sa.ProjectID)}, nil
}

// Ready: aplikasi Android punya cukup pengenal untuk mendaftar ke FCM.
func (c *Client) Ready() bool {
	return c != nil && c.Android.AppID != "" && c.Android.APIKey != "" && c.Android.SenderID != ""
}

func (c *Client) accessToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.access != "" && time.Until(c.expires) > 2*time.Minute {
		return c.access, nil
	}
	now := time.Now()
	assertion, err := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"iss": c.email, "scope": scope, "aud": tokenURL, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
	}).SignedString(c.key)
	if err != nil {
		return "", err
	}
	form := "grant_type=" + "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer" + "&assertion=" + assertion
	resp, err := c.http.Post(c.tokenURL, "application/x-www-form-urlencoded", strings.NewReader(form))
	if err != nil {
		return "", fmt.Errorf("FCM: minta token akses: %w", err)
	}
	defer resp.Body.Close()
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
	}
	json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&out)
	if resp.StatusCode != http.StatusOK || out.AccessToken == "" {
		return "", fmt.Errorf("FCM: token akses ditolak (HTTP %d %s)", resp.StatusCode, out.Error)
	}
	if out.ExpiresIn <= 0 {
		out.ExpiresIn = 3600
	}
	c.access, c.expires = out.AccessToken, now.Add(time.Duration(out.ExpiresIn)*time.Second)
	return c.access, nil
}

// Wake mengirim pesan data prioritas tinggi berisi nomor notifikasi saja.
func (c *Client) Wake(token string, nid int64) error {
	access, err := c.accessToken()
	if err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]any{"message": map[string]any{
		"token":   token,
		"data":    map[string]string{"nid": strconv.FormatInt(nid, 10)},
		"android": map[string]any{"priority": "HIGH", "ttl": "1800s"},
	}})
	req, _ := http.NewRequest(http.MethodPost, c.sendURL, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("FCM: %w", err)
	}
	defer resp.Body.Close()
	detail, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
	switch {
	case resp.StatusCode < 300:
		return nil
	case resp.StatusCode == http.StatusNotFound || bytes.Contains(detail, []byte("UNREGISTERED")):
		return push.ErrTokenGone
	case resp.StatusCode == http.StatusUnauthorized:
		c.mu.Lock()
		c.access = ""
		c.mu.Unlock()
	}
	return fmt.Errorf("FCM menolak (HTTP %d)", resp.StatusCode)
}

// ValidToken: bentuk token pendaftaran FCM yang wajar (mencegah sampah masuk database).
func ValidToken(t string) bool {
	if len(t) < 20 || len(t) > 4096 {
		return false
	}
	for _, r := range t {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("-_:.", r)) {
			return false
		}
	}
	return true
}
