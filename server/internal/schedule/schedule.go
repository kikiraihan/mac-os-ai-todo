// Package schedule menghitung kapan sebuah pengingat berbunyi.
//
// Jadwal selalu berbentuk JSON terstruktur (bukan teks bebas atau cron) supaya
// AI tidak pernah menghitung waktu sendiri: AI hanya mengisi bentuknya, server
// yang menentukan kemunculan berikutnya secara deterministik di zona waktu
// pemilik.
package schedule

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

const (
	KindOnce     = "once"
	KindDaily    = "daily"
	KindWeekly   = "weekly"
	KindMonthly  = "monthly"
	KindYearly   = "yearly"
	KindInterval = "interval"

	// MinIntervalMinutes mencegah pengingat yang membanjiri notifikasi.
	MinIntervalMinutes = 15

	dateLayout  = "2006-01-02"
	localLayout = "2006-01-02T15:04"

	// Batas pencarian hari ke depan. 1500 hari cukup untuk jadwal tahunan
	// 29 Februari dan jadwal "tiap 4 minggu" sekalipun.
	searchDays = 1500
)

// Window membatasi jadwal interval pada rentang jam tertentu tiap hari.
type Window struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// Schedule adalah bentuk JSON jadwal pengingat (lihat docs/PRD.md §5.2).
type Schedule struct {
	Kind         string  `json:"kind"`
	At           string  `json:"at,omitempty"`           // once: YYYY-MM-DDTHH:MM
	Time         string  `json:"time,omitempty"`         // daily/weekly/monthly/yearly: HH:MM
	Every        int     `json:"every,omitempty"`        // daily: tiap N hari, weekly: tiap N minggu
	Weekdays     []int   `json:"weekdays,omitempty"`     // 1=Senin … 7=Minggu
	MonthDay     int     `json:"monthDay,omitempty"`     // monthly/yearly: 1–31
	Month        int     `json:"month,omitempty"`        // yearly: 1–12
	EveryMinutes int     `json:"everyMinutes,omitempty"` // interval
	Window       *Window `json:"window,omitempty"`       // interval
	StartDate    string  `json:"startDate,omitempty"`    // jangkar & tanggal mulai
	Until        string  `json:"until,omitempty"`        // tanggal terakhir (ikut)
	Count        int     `json:"count,omitempty"`        // maksimal berapa kali berbunyi
}

// Normalize memvalidasi jadwal dan mengisi nilai bawaan. today dipakai sebagai
// startDate kalau kosong, supaya "tiap 2 hari" punya titik awal yang tetap.
func (s *Schedule) Normalize(today string) error {
	s.Kind = strings.TrimSpace(strings.ToLower(s.Kind))
	switch s.Kind {
	case KindOnce:
		if _, err := time.Parse(localLayout, s.At); err != nil {
			return errors.New("jadwal sekali butuh 'at' berformat YYYY-MM-DDTHH:MM")
		}
		s.Time, s.Every, s.Weekdays, s.MonthDay, s.Month, s.EveryMinutes, s.Window = "", 0, nil, 0, 0, 0, nil
		s.StartDate, s.Until, s.Count = "", "", 0
		return nil
	case KindDaily, KindWeekly, KindMonthly, KindYearly, KindInterval:
	default:
		return fmt.Errorf("jenis jadwal %q tidak dikenal", s.Kind)
	}
	s.At = ""

	if s.StartDate == "" {
		s.StartDate = today
	}
	if !ValidDate(s.StartDate) {
		return errors.New("startDate harus YYYY-MM-DD")
	}
	if s.Until != "" {
		if !ValidDate(s.Until) {
			return errors.New("until harus YYYY-MM-DD")
		}
		if s.Until < s.StartDate {
			return errors.New("until tidak boleh sebelum startDate")
		}
	}
	if s.Count < 0 || s.Count > 10000 {
		return errors.New("count harus 0–10000")
	}
	if s.Every < 0 || s.Every > 365 {
		return errors.New("every harus 1–365")
	}
	if s.Every == 0 {
		s.Every = 1
	}
	if err := normalizeWeekdays(&s.Weekdays); err != nil {
		return err
	}

	switch s.Kind {
	case KindInterval:
		if s.EveryMinutes < MinIntervalMinutes || s.EveryMinutes > 24*60 {
			return fmt.Errorf("everyMinutes harus %d–1440", MinIntervalMinutes)
		}
		if s.Window == nil {
			s.Window = &Window{From: "00:00", To: "23:59"}
		}
		if !ValidTime(s.Window.From) || !ValidTime(s.Window.To) || s.Window.To < s.Window.From {
			return errors.New("window harus {from, to} berformat HH:MM dengan to ≥ from")
		}
		s.Time, s.MonthDay, s.Month, s.Every = "", 0, 0, 1
		return nil
	default:
		if !ValidTime(s.Time) {
			return errors.New("time harus HH:MM")
		}
		s.EveryMinutes, s.Window = 0, nil
	}

	switch s.Kind {
	case KindDaily:
		s.MonthDay, s.Month = 0, 0
	case KindWeekly:
		if len(s.Weekdays) == 0 {
			start, _ := time.Parse(dateLayout, s.StartDate)
			s.Weekdays = []int{isoWeekday(start)}
		}
		s.MonthDay, s.Month = 0, 0
	case KindMonthly:
		if s.MonthDay < 1 || s.MonthDay > 31 {
			return errors.New("monthDay harus 1–31")
		}
		s.Weekdays, s.Month, s.Every = nil, 0, 1
	case KindYearly:
		if s.Month < 1 || s.Month > 12 || s.MonthDay < 1 || s.MonthDay > 31 {
			return errors.New("jadwal tahunan butuh month 1–12 dan monthDay 1–31")
		}
		s.Weekdays, s.Every = nil, 1
	}
	return nil
}

func normalizeWeekdays(w *[]int) error {
	seen := map[int]bool{}
	out := []int{}
	for _, d := range *w {
		if d < 1 || d > 7 {
			return errors.New("weekdays berisi 1 (Senin) sampai 7 (Minggu)")
		}
		if !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	sort.Ints(out)
	if len(out) == 0 {
		out = nil
	}
	*w = out
	return nil
}

// Next mengembalikan kemunculan pertama yang lebih besar dari after, dalam zona
// loc. fired = sudah berapa kali pengingat berbunyi (untuk Count). false berarti
// jadwal sudah habis.
func (s Schedule) Next(after time.Time, loc *time.Location, fired int) (time.Time, bool) {
	after = after.In(loc)
	if s.Kind == KindOnce {
		at, err := time.ParseInLocation(localLayout, s.At, loc)
		if err != nil || !at.After(after) {
			return time.Time{}, false
		}
		return at, true
	}
	if s.Count > 0 && fired >= s.Count {
		return time.Time{}, false
	}
	start, err := time.ParseInLocation(dateLayout, s.StartDate, loc)
	if err != nil {
		return time.Time{}, false
	}
	var until time.Time
	if s.Until != "" {
		if until, err = time.ParseInLocation(dateLayout, s.Until, loc); err != nil {
			return time.Time{}, false
		}
	}

	day := dateOf(after)
	if day.Before(start) {
		day = start
	}
	for i := 0; i < searchDays; i++ {
		if !until.IsZero() && day.After(until) {
			return time.Time{}, false
		}
		if s.matchesDay(day, start) {
			for _, t := range s.timesOn(day, loc) {
				if t.After(after) {
					return t, true
				}
			}
		}
		day = day.AddDate(0, 0, 1)
	}
	return time.Time{}, false
}

func (s Schedule) matchesDay(day, start time.Time) bool {
	switch s.Kind {
	case KindDaily:
		return daysBetween(start, day)%s.Every == 0
	case KindWeekly:
		if !contains(s.Weekdays, isoWeekday(day)) {
			return false
		}
		weeks := daysBetween(mondayOf(start), mondayOf(day)) / 7
		return weeks%s.Every == 0
	case KindMonthly:
		return day.Day() == clampDay(day.Year(), day.Month(), s.MonthDay)
	case KindYearly:
		return int(day.Month()) == s.Month && day.Day() == clampDay(day.Year(), day.Month(), s.MonthDay)
	case KindInterval:
		return len(s.Weekdays) == 0 || contains(s.Weekdays, isoWeekday(day))
	}
	return false
}

func (s Schedule) timesOn(day time.Time, loc *time.Location) []time.Time {
	if s.Kind != KindInterval {
		return []time.Time{atClock(day, s.Time, loc)}
	}
	from := atClock(day, s.Window.From, loc)
	to := atClock(day, s.Window.To, loc)
	var out []time.Time
	for t := from; !t.After(to); t = t.Add(time.Duration(s.EveryMinutes) * time.Minute) {
		out = append(out, t)
	}
	return out
}

// Describe menuliskan jadwal dalam Bahasa Indonesia, mis. "Tiap Senin & Rabu 19:00".
func (s Schedule) Describe() string {
	var b strings.Builder
	switch s.Kind {
	case KindOnce:
		if t, err := time.Parse(localLayout, s.At); err == nil {
			return "Sekali, " + FormatDate(t) + " " + t.Format("15:04")
		}
		return "Sekali"
	case KindDaily:
		if s.Every > 1 {
			fmt.Fprintf(&b, "Tiap %d hari %s", s.Every, s.Time)
		} else {
			b.WriteString("Tiap hari " + s.Time)
		}
	case KindWeekly:
		prefix := "Tiap "
		if s.Every > 1 {
			prefix = fmt.Sprintf("Tiap %d minggu, ", s.Every)
		}
		b.WriteString(prefix + weekdayNames(s.Weekdays) + " " + s.Time)
	case KindMonthly:
		fmt.Fprintf(&b, "Tiap tanggal %d, %s", s.MonthDay, s.Time)
	case KindYearly:
		fmt.Fprintf(&b, "Tiap %d %s, %s", s.MonthDay, monthNames[s.Month-1], s.Time)
	case KindInterval:
		fmt.Fprintf(&b, "Tiap %s", minutesText(s.EveryMinutes))
		if s.Window != nil && !(s.Window.From == "00:00" && s.Window.To == "23:59") {
			fmt.Fprintf(&b, " pukul %s–%s", s.Window.From, s.Window.To)
		}
		if len(s.Weekdays) > 0 {
			b.WriteString(", " + weekdayNames(s.Weekdays))
		}
	default:
		return s.Kind
	}
	if s.Until != "" {
		if t, err := time.Parse(dateLayout, s.Until); err == nil {
			b.WriteString(" sampai " + FormatDate(t))
		}
	}
	if s.Count > 0 {
		fmt.Fprintf(&b, " (%d kali)", s.Count)
	}
	return b.String()
}

func minutesText(m int) string {
	if m%60 == 0 {
		return fmt.Sprintf("%d jam", m/60)
	}
	return fmt.Sprintf("%d menit", m)
}

var dayNames = []string{"Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu"}

var monthNames = []string{"Januari", "Februari", "Maret", "April", "Mei", "Juni", "Juli",
	"Agustus", "September", "Oktober", "November", "Desember"}

func weekdayNames(days []int) string {
	if len(days) == 7 {
		return "hari"
	}
	if len(days) == 5 && days[0] == 1 && days[4] == 5 {
		return "hari kerja"
	}
	names := make([]string, len(days))
	for i, d := range days {
		names[i] = dayNames[d-1]
	}
	if len(names) <= 2 {
		return strings.Join(names, " & ")
	}
	return strings.Join(names[:len(names)-1], ", ") + " & " + names[len(names)-1]
}

// DayName mengembalikan nama hari Indonesia untuk t.
func DayName(t time.Time) string { return dayNames[isoWeekday(t)-1] }

// FormatDate menulis tanggal seperti "31 Oktober 2026".
func FormatDate(t time.Time) string {
	return fmt.Sprintf("%d %s %d", t.Day(), monthNames[t.Month()-1], t.Year())
}

// ValidDate memastikan s berformat YYYY-MM-DD dan tanggalnya benar-benar ada.
func ValidDate(s string) bool {
	t, err := time.Parse(dateLayout, s)
	return err == nil && t.Format(dateLayout) == s
}

// ValidTime memastikan s berformat HH:MM 24 jam.
func ValidTime(s string) bool {
	t, err := time.Parse("15:04", s)
	return err == nil && t.Format("15:04") == s
}

func atClock(day time.Time, hm string, loc *time.Location) time.Time {
	t, _ := time.Parse("15:04", hm)
	return time.Date(day.Year(), day.Month(), day.Day(), t.Hour(), t.Minute(), 0, 0, loc)
}

func dateOf(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, t.Location())
}

// daysBetween menghitung selisih hari kalender (aman terhadap DST karena
// memakai tanggal UTC).
func daysBetween(a, b time.Time) int {
	ua := time.Date(a.Year(), a.Month(), a.Day(), 0, 0, 0, 0, time.UTC)
	ub := time.Date(b.Year(), b.Month(), b.Day(), 0, 0, 0, 0, time.UTC)
	return int(ub.Sub(ua).Hours() / 24)
}

func mondayOf(t time.Time) time.Time { return t.AddDate(0, 0, 1-isoWeekday(t)) }

func isoWeekday(t time.Time) int {
	wd := int(t.Weekday())
	if wd == 0 {
		return 7
	}
	return wd
}

// clampDay: tanggal 29–31 di bulan yang lebih pendek jatuh ke hari terakhir bulan itu.
func clampDay(year int, month time.Month, day int) int {
	last := time.Date(year, month+1, 0, 0, 0, 0, 0, time.UTC).Day()
	if day > last {
		return last
	}
	return day
}

func contains(xs []int, x int) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
