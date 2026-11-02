// Package push mengirim notifikasi Web Push ke PWA. Kunci VAPID dibuat sekali
// dan disimpan di tabel settings, jadi langganan tetap berlaku setelah restart.
package push

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"

	"aitodo/server/internal/db"
)

const (
	settingPublic  = "vapid_public_key"
	settingPrivate = "vapid_private_key"
)

// pushHosts: hanya layanan push yang dikenal yang boleh dihubungi server
// (mencegah server dipakai mengirim request ke alamat sembarang / SSRF).
var pushHosts = []string{"fcm.googleapis.com", "updates.push.services.mozilla.com", ".push.apple.com", ".notify.windows.com"}

func AllowedEndpoint(endpoint string) bool {
	if len(endpoint) > 1024 {
		return false
	}
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "https" || u.User != nil {
		return false
	}
	host := strings.ToLower(u.Hostname())
	// Chrome versi baru memberi endpoint FCM di subdomain google.com (mis. jmt17.google.com/fcm/send/…);
	// diizinkan hanya untuk jalur FCM itu, bukan seluruh google.com.
	if strings.HasSuffix(host, ".google.com") && strings.HasPrefix(u.EscapedPath(), "/fcm/send/") && u.Port() == "" {
		return true
	}
	for _, h := range pushHosts {
		if host == h || (strings.HasPrefix(h, ".") && strings.HasSuffix(host, h)) {
			return true
		}
	}
	return false
}

type Service struct {
	DB         *db.DB
	PublicKey  string
	privateKey string
	subscriber string
	// allow & client bisa diganti di tes (layanan push tiruan); bawaannya allowlist & http.Client biasa.
	allow  func(string) bool
	client webpush.HTTPClient
}

// subscriberClaim menyiapkan nilai `sub` JWT VAPID. webpush-go sendiri menambahkan "mailto:" kalau
// nilainya bukan URL https, jadi "mailto:a@b.c" dari .env harus dikirim tanpa awalan itu — kalau tidak,
// klaimnya jadi "mailto:mailto:a@b.c" dan Apple (iPhone/iPad/Safari) menolak dengan 403 BadJwtToken.
func subscriberClaim(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 7 && strings.EqualFold(s[:7], "mailto:") {
		s = strings.TrimSpace(s[7:])
	}
	return s
}

func New(database *db.DB, subscriber string) (*Service, error) {
	pub, err := database.GetSetting(settingPublic)
	if err != nil {
		return nil, err
	}
	priv, err := database.GetSetting(settingPrivate)
	if err != nil {
		return nil, err
	}
	if pub == "" || priv == "" {
		priv, pub, err = webpush.GenerateVAPIDKeys()
		if err != nil {
			return nil, fmt.Errorf("generate VAPID keys: %w", err)
		}
		if err := database.SetSetting(settingPublic, pub); err != nil {
			return nil, err
		}
		if err := database.SetSetting(settingPrivate, priv); err != nil {
			return nil, err
		}
		log.Println("push: kunci VAPID baru dibuat")
	}
	sub := subscriberClaim(subscriber)
	if sub == "" || strings.Contains(strings.ToLower(sub), "localhost") {
		// Apple menolak `sub` yang bukan alamat/URL sungguhan; FCM (Chrome/Android) lebih longgar.
		log.Printf("push: VAPID_SUBSCRIBER %q bukan alamat sungguhan; notifikasi di iPhone/Safari bisa ditolak Apple", subscriber)
	}
	return &Service{DB: database, PublicKey: pub, privateKey: priv, subscriber: sub,
		allow: AllowedEndpoint, client: &http.Client{Timeout: 15 * time.Second}}, nil
}

// Notification adalah isi yang dibaca service worker PWA (public/push-sw.js).
type Notification struct {
	Title      string `json:"title"`
	Body       string `json:"body"`
	URL        string `json:"url"`
	Tag        string `json:"tag"`
	TodoID     int64  `json:"todoId,omitempty"`
	ReminderID int64  `json:"reminderId,omitempty"`
}

// SendToUser mengirim ke semua perangkat PWA milik pengguna. Mengembalikan
// jumlah yang berhasil.
func (s *Service) SendToUser(userID int64, n Notification) (int, error) {
	subs, err := s.DB.PushSubsForUser(userID)
	if err != nil {
		return 0, err
	}
	payload, err := json.Marshal(n)
	if err != nil {
		return 0, err
	}
	ok := 0
	var lastErr error
	for _, sub := range subs {
		if !s.allow(sub.Endpoint) {
			s.DB.DeletePushSubByID(sub.ID)
			continue
		}
		resp, err := webpush.SendNotification(payload, &webpush.Subscription{
			Endpoint: sub.Endpoint,
			Keys:     webpush.Keys{P256dh: sub.P256dh, Auth: sub.Auth},
		}, &webpush.Options{
			HTTPClient:      s.client,
			Subscriber:      s.subscriber,
			VAPIDPublicKey:  s.PublicKey,
			VAPIDPrivateKey: s.privateKey,
			TTL:             30 * 60,
			Urgency:         webpush.UrgencyHigh,
		})
		if err != nil {
			lastErr = err
			log.Printf("push: kirim ke langganan %d: %v", sub.ID, err)
			continue
		}
		detail, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		resp.Body.Close()
		switch {
		case resp.StatusCode < 300:
			ok++
		case resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone:
			// Langganan sudah tidak berlaku (izin dicabut, app dihapus): buang.
			s.DB.DeletePushSubByID(sub.ID)
		default:
			// 400/401/403/413/429/5xx = masalah kunci VAPID, isi, atau layanan push — bukan langganan
			// yang mati. Jangan dihapus (dulu 401/403 ikut dihapus sehingga notifikasi diam-diam berhenti).
			lastErr = fmt.Errorf("layanan push menolak (HTTP %d): %s", resp.StatusCode, strings.TrimSpace(string(detail)))
			log.Printf("push: kirim ke langganan %d: %v", sub.ID, lastErr)
		}
	}
	if ok == 0 && lastErr != nil {
		return 0, lastErr
	}
	if len(subs) == 0 {
		return 0, errors.New("belum ada perangkat yang menyalakan notifikasi")
	}
	if ok == 0 {
		// Semua langganan ternyata kedaluwarsa (404/410) dan sudah dibuang.
		return 0, errors.New("belum ada perangkat yang menyalakan notifikasi (langganan lama sudah kedaluwarsa, nyalakan ulang)")
	}
	return ok, nil
}
