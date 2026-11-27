package core

import (
	"strings"
	"time"
	"unicode/utf8"

	"aitodo/server/internal/db"
)

// Kiriman: teks yang dikirim dari satu perangkat ke perangkat lain (mis. Mac →
// notifikasi HP dengan tombol Salin). Sifatnya sementara, bukan arsip: hanya
// MaxClipsPerUser terbaru yang disimpan, dan semuanya dibuang setelah ClipRetention.

const (
	MaxClipContent  = 20000
	MaxClipsPerUser = 50
	ClipRetention   = 7 * 24 * time.Hour
	maxDeviceName   = 60
)

// CreateClip menyimpan kiriman baru. sessionID = sesi pengirim (perangkat itu tidak ikut diberi notifikasi).
func CreateClip(c *Ctx, content, device string, sessionID int64) (db.Clip, error) {
	// Kiriman sengaja tidak di-trim di tengah: spasi & baris baru bagian dari isi yang mau ditempel.
	content = strings.Map(func(r rune) rune {
		if r < 32 && r != '\n' && r != '\t' && r != '\r' {
			return -1
		}
		return r
	}, content)
	if strings.TrimSpace(content) == "" {
		return db.Clip{}, invalid("kiriman kosong")
	}
	if utf8.RuneCountInString(content) > MaxClipContent {
		return db.Clip{}, invalid("kiriman maksimal %d karakter", MaxClipContent)
	}
	device = strings.ReplaceAll(clean(device), "\n", " ")
	if utf8.RuneCountInString(device) > maxDeviceName {
		device = string([]rune(device)[:maxDeviceName])
	}
	cl, err := db.InsertClip(c.Q, db.Clip{UserID: c.UserID, Content: content, Device: device, SessionID: sessionID})
	if err != nil {
		return cl, err
	}
	return cl, db.TrimClips(c.Q, c.UserID, MaxClipsPerUser)
}

// ClipPreview: potongan pendek isi kiriman untuk badan notifikasi.
func ClipPreview(content string, n int) string {
	s := strings.Join(strings.Fields(content), " ")
	if utf8.RuneCountInString(s) > n {
		s = strings.TrimSpace(string([]rune(s)[:n-1])) + "…"
	}
	return s
}
