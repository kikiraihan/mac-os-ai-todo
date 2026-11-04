package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	_ "time/tzdata" // zona waktu tetap ada di container minimal

	"aitodo/server/internal/ai"
	"aitodo/server/internal/applog"
	"aitodo/server/internal/db"
	"aitodo/server/internal/httpapi"
	"aitodo/server/internal/push"
	"aitodo/server/internal/release"
	"aitodo/server/internal/scheduler"
	"aitodo/server/internal/webui"
)

// version diisi saat build: -ldflags "-X main.version=0.1.0".
var version = "dev"

// templatePassword adalah contoh di .env.example — server menolak berjalan
// dengan password ini karena siapa pun bisa membacanya di repo.
const templatePassword = "GANTI-dengan-password-acak"

func getenv(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	// Log server juga disimpan di memori (3000 baris terakhir) supaya bisa dilihat
	// dari Admin → System Log tanpa akses ke container.
	systemLog := applog.NewRing(3000)
	log.SetOutput(io.MultiWriter(os.Stderr, systemLog))
	dataDir := getenv("DATA_DIR", "data")
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "backup":
			// aitodo backup <berkas-tujuan.db> — salinan konsisten walau server
			// sedang berjalan (SQLite VACUUM INTO).
			if len(os.Args) != 3 {
				log.Fatal("pakai: aitodo backup <tujuan.db>")
			}
			if err := backup(filepath.Join(dataDir, "aitodo.db"), os.Args[2]); err != nil {
				log.Fatalf("backup: %v", err)
			}
			log.Printf("backup tersimpan di %s", os.Args[2])
			return
		case "version":
			fmt.Println(version)
			return
		case "admin":
			// aitodo admin <username> — buat akun admin, atau reset password-nya kalau
			// sudah ada (juga mengaktifkan lagi & mengeluarkan semua sesinya). Password
			// dari ADMIN_PASSWORD, atau dibuat acak dan dicetak sekali. Satu-satunya
			// cara membuat admin selain admin awal dan menu Admin → Akun admin.
			if len(os.Args) != 3 {
				log.Fatal("pakai: aitodo admin <username>")
			}
			d, err := db.Open(filepath.Join(dataDir, "aitodo.db"))
			if err != nil {
				log.Fatalf("buka database: %v", err)
			}
			defer d.Close()
			if err := upsertAdmin(d, os.Args[2]); err != nil {
				log.Fatalf("admin: %v", err)
			}
			return
		default:
			log.Fatalf("perintah tidak dikenal: %s (tersedia: backup, version, admin)", os.Args[1])
		}
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		log.Fatalf("buat folder data: %v", err)
	}
	database, err := db.Open(filepath.Join(dataDir, "aitodo.db"))
	if err != nil {
		log.Fatalf("buka database: %v", err)
	}
	defer database.Close()

	if err := bootstrapAdmin(database); err != nil {
		log.Fatalf("admin awal: %v", err)
	}
	if err := seedModels(database); err != nil {
		log.Fatalf("katalog model: %v", err)
	}

	tz := getenv("TIMEZONE", getenv("TZ", "Asia/Jakarta"))
	loc, err := time.LoadLocation(tz)
	if err != nil {
		log.Printf("PERINGATAN: zona waktu %q tidak dikenal, memakai UTC", tz)
		loc = time.UTC
	}

	registry := ai.NewRegistry(os.Getenv)
	registry.Referer = getenv("PUBLIC_URL", "")
	for _, p := range registry.Providers() {
		state := "tanpa key"
		if p.HasKey {
			state = "key terpasang"
		}
		log.Printf("AI provider %s (%s): %s", p.Name, p.BaseURL, state)
	}

	// AI Call Log (tabel ai_calls): ditulis asinkron supaya tidak memperlambat asisten.
	aiCalls := applog.NewAICalls(database)
	registry.Recorder = aiCalls.Record
	logCtx, stopLog := context.WithCancel(context.Background())
	go aiCalls.Run(logCtx)
	retention, err := strconv.Atoi(getenv("AI_CALL_LOG_RETENTION_DAYS", "30"))
	if err != nil || retention < 0 {
		log.Printf("PERINGATAN: AI_CALL_LOG_RETENTION_DAYS tidak valid, memakai 30")
		retention = 30
	}

	pushSvc, err := push.New(database, getenv("VAPID_SUBSCRIBER", "mailto:admin@localhost"))
	if err != nil {
		log.Fatalf("web push: %v", err)
	}

	secure := getenv("SECURE_COOKIES", "true") == "true"
	srv := httpapi.New(database, registry, pushSvc, httpapi.Config{
		Version:       version,
		SecureCookies: secure,
		TrustProxy:    getenv("TRUST_PROXY", "false") == "true",
		DefaultTZ:     loc,

		AICallRetentionDays: retention,
	})
	srv.SystemLog = systemLog

	// Pembaruan aplikasi Mac lewat server (repo GitHub boleh private). Token hanya dari env.
	// GITHUB_RELEASE_REPO tidak ada → repo bawaan; diisi kosong → fitur dimatikan.
	releaseRepo, ok := os.LookupEnv("GITHUB_RELEASE_REPO")
	if !ok {
		releaseRepo = "kikiraihan/mac-os-ai-todo"
	}
	rel, err := release.New(strings.TrimSpace(releaseRepo), strings.TrimSpace(os.Getenv("GITHUB_RELEASE_TOKEN")))
	if err != nil {
		log.Fatalf("rilis: %v", err)
	}
	if rel.Repo != "" {
		state := "tanpa token (hanya repo publik)"
		if rel.HasToken() {
			state = "token terpasang"
		}
		log.Printf("Rilis aplikasi Mac dari github.com/%s: %s", rel.Repo, state)
	}
	srv.Release = rel

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sched := &scheduler.Scheduler{DB: database, Push: pushSvc, Loc: func(u db.User) *time.Location { return srv.LoadLocation(u.Timezone) },
		OnChange: srv.Hub.Bump}
	go sched.Run(ctx)
	go housekeeping(ctx, database, retention)

	mux := http.NewServeMux()
	mux.Handle("/api/", srv.Mux)
	mux.Handle("/", webui.Handler())

	addr := getenv("ADDR", "127.0.0.1:8080")
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           httpapi.SecurityHeaders(secure, mux),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		// Long-poll 25 detik + panggilan AI sampai ±75 detik.
		WriteTimeout: 100 * time.Second,
		IdleTimeout:  120 * time.Second,
	}
	go func() {
		log.Printf("AI Todo server %s di %s (zona %s)", version, addr, loc)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	log.Println("berhenti...")
	cancel()
	shutdown, done := context.WithTimeout(context.Background(), 10*time.Second)
	defer done()
	httpServer.Shutdown(shutdown)
	stopLog()
	aiCalls.Wait(5 * time.Second)
}

// bootstrapAdmin membuat akun admin pertama kalau belum ada admin sama sekali.
// Akun admin terpisah dari akun pengguna (tabel admins): untuk memakai todo,
// buat akun pengguna di Admin → Pengguna (boleh dengan username yang sama).
func bootstrapAdmin(d *db.DB) error {
	n, err := d.CountAdmins()
	if err != nil || n > 0 {
		return err
	}
	username := getenv("ADMIN_USERNAME", "admin")
	password, generated, err := adminPassword()
	if err != nil {
		return err
	}
	hash, err := httpapi.HashPassword(password)
	if err != nil {
		return err
	}
	if _, err := d.CreateAdmin(db.Admin{Username: username, DisplayName: "Admin", PasswordHash: hash}); err != nil {
		return err
	}
	if generated {
		printPassword("Akun admin awal dibuat", username, password)
	} else {
		log.Printf("Akun admin awal %q dibuat dari ADMIN_USERNAME/ADMIN_PASSWORD", username)
	}
	return nil
}

// adminPassword: ADMIN_PASSWORD bila diisi (bukan password contoh), selain itu acak.
func adminPassword() (password string, generated bool, err error) {
	password = os.Getenv("ADMIN_PASSWORD")
	switch {
	case password == "":
		b := make([]byte, 18)
		rand.Read(b)
		password, generated = base64.RawURLEncoding.EncodeToString(b), true
	case password == templatePassword:
		return "", false, errors.New("ADMIN_PASSWORD masih password contoh dari .env.example, ganti dengan password acak")
	}
	return password, generated, httpapi.CheckPassword(password)
}

func printPassword(title, username, password string) {
	log.Printf("==================================================")
	log.Printf("%s (catat sekarang, hanya tampil sekali):", title)
	log.Printf("  username: %s", username)
	log.Printf("  password: %s", password)
	log.Printf("==================================================")
}

// upsertAdmin dipakai perintah `aitodo admin <username>` (dari server saja).
func upsertAdmin(d *db.DB, username string) error {
	username = strings.TrimSpace(username)
	if !httpapi.ValidUsername(username) {
		return errors.New("username 3–32 karakter: huruf, angka, titik, minus, garis bawah")
	}
	password, generated, err := adminPassword()
	if err != nil {
		return err
	}
	hash, err := httpapi.HashPassword(password)
	if err != nil {
		return err
	}
	title := "Akun admin dibuat"
	a, err := d.GetAdminByUsername(username)
	switch {
	case errors.Is(err, db.ErrNotFound):
		if _, err := d.CreateAdmin(db.Admin{Username: username, DisplayName: username, PasswordHash: hash}); err != nil {
			return err
		}
	case err != nil:
		return err
	default:
		title = "Password admin direset"
		if err := d.SetAdminPassword(a.ID, hash); err != nil {
			return err
		}
		a.Disabled = false
		if err := d.UpdateAdmin(a); err != nil {
			return err
		}
		if err := d.DeleteAdminSessions(a.ID, 0); err != nil {
			return err
		}
	}
	if generated {
		printPassword(title, username, password)
	} else {
		log.Printf("%s: %q (password dari ADMIN_PASSWORD)", title, username)
	}
	return nil
}

// seedModels mengisi katalog model bawaan sekali saja (penanda di settings),
// sehingga model yang dihapus admin tidak muncul lagi setelah restart.
func seedModels(d *db.DB) error {
	const key = "models_seeded"
	if v, err := d.GetSetting(key); err != nil || v == "1" {
		return err
	}
	for _, b := range ai.Builtins {
		exists, err := d.ModelExists(b.Provider, b.ModelID)
		if err != nil {
			return err
		}
		if exists {
			continue
		}
		if _, err := d.InsertModel(db.AIModel{Provider: b.Provider, ModelID: b.ModelID, Label: b.Label, ExtraBody: b.ExtraBody,
			Builtin: true, Free: b.Free}); err != nil {
			return err
		}
	}
	return d.SetSetting(key, "1")
}

func housekeeping(ctx context.Context, d *db.DB, aiCallRetentionDays int) {
	t := time.NewTicker(6 * time.Hour)
	defer t.Stop()
	for {
		if err := d.PruneSessions(); err != nil {
			log.Printf("housekeeping: sesi: %v", err)
		}
		if err := d.PruneChat(500); err != nil {
			log.Printf("housekeeping: chat: %v", err)
		}
		if aiCallRetentionDays > 0 {
			if err := d.PruneAICalls(time.Now().AddDate(0, 0, -aiCallRetentionDays)); err != nil {
				log.Printf("housekeeping: ai call log: %v", err)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func backup(src, dst string) error {
	if _, err := os.Stat(dst); err == nil {
		return fmt.Errorf("%s sudah ada", dst)
	}
	d, err := db.Open(src)
	if err != nil {
		return err
	}
	defer d.Close()
	_, err = d.Exec(`VACUUM INTO ?`, dst)
	return err
}
