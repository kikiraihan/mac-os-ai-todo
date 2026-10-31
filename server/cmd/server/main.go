package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	_ "time/tzdata" // zona waktu tetap ada di container minimal

	"aitodo/server/internal/ai"
	"aitodo/server/internal/db"
	"aitodo/server/internal/httpapi"
	"aitodo/server/internal/push"
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
		default:
			log.Fatalf("perintah tidak dikenal: %s (tersedia: backup, version)", os.Args[1])
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
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sched := &scheduler.Scheduler{DB: database, Push: pushSvc, Loc: func(u db.User) *time.Location { return srv.LoadLocation(u.Timezone) },
		OnChange: srv.Hub.Bump}
	go sched.Run(ctx)
	go housekeeping(ctx, database)

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
}

// bootstrapAdmin membuat akun admin pertama kalau belum ada pengguna sama sekali.
func bootstrapAdmin(d *db.DB) error {
	n, err := d.CountUsers()
	if err != nil || n > 0 {
		return err
	}
	username := getenv("ADMIN_USERNAME", "admin")
	password := os.Getenv("ADMIN_PASSWORD")
	generated := false
	switch {
	case password == "":
		b := make([]byte, 18)
		rand.Read(b)
		password, generated = base64.RawURLEncoding.EncodeToString(b), true
	case password == templatePassword:
		return errors.New("ADMIN_PASSWORD masih password contoh dari .env.example, ganti dengan password acak")
	}
	if err := httpapi.CheckPassword(password); err != nil {
		return err
	}
	hash, err := httpapi.HashPassword(password)
	if err != nil {
		return err
	}
	if _, err := d.CreateUser(db.User{Username: username, DisplayName: "Admin", PasswordHash: hash, Role: db.RoleAdmin}); err != nil {
		return err
	}
	if generated {
		log.Printf("==================================================")
		log.Printf("Akun admin awal dibuat (catat sekarang, hanya tampil sekali):")
		log.Printf("  username: %s", username)
		log.Printf("  password: %s", password)
		log.Printf("==================================================")
	} else {
		log.Printf("Akun admin awal %q dibuat dari ADMIN_USERNAME/ADMIN_PASSWORD", username)
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

func housekeeping(ctx context.Context, d *db.DB) {
	t := time.NewTicker(6 * time.Hour)
	defer t.Stop()
	for {
		if err := d.PruneSessions(); err != nil {
			log.Printf("housekeeping: sesi: %v", err)
		}
		if err := d.PruneChat(500); err != nil {
			log.Printf("housekeeping: chat: %v", err)
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
