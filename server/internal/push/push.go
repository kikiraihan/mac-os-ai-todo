// Package push mengirim notifikasi Web Push ke PWA. Kunci VAPID dibuat sekali
// dan disimpan di tabel settings, jadi langganan tetap berlaku setelah restart.
package push

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"strings"

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
	return &Service{DB: database, PublicKey: pub, privateKey: priv, subscriber: subscriber}, nil
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
		if !AllowedEndpoint(sub.Endpoint) {
			s.DB.DeletePushSubByID(sub.ID)
			continue
		}
		resp, err := webpush.SendNotification(payload, &webpush.Subscription{
			Endpoint: sub.Endpoint,
			Keys:     webpush.Keys{P256dh: sub.P256dh, Auth: sub.Auth},
		}, &webpush.Options{
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
		resp.Body.Close()
		switch resp.StatusCode {
		case 401, 403, 404, 410:
			s.DB.DeletePushSubByID(sub.ID)
		default:
			if resp.StatusCode < 300 {
				ok++
			}
		}
	}
	if ok == 0 && lastErr != nil {
		return 0, lastErr
	}
	if len(subs) == 0 {
		return 0, errors.New("belum ada perangkat yang menyalakan notifikasi")
	}
	return ok, nil
}
