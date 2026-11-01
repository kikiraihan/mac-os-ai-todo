package schedule

import (
	"testing"
	"time"
)

var jkt, _ = time.LoadLocation("Asia/Jakarta")

func at(s string) time.Time {
	t, err := time.ParseInLocation("2006-01-02 15:04", s, jkt)
	if err != nil {
		panic(err)
	}
	return t
}

func next(t *testing.T, s Schedule, after string, fired int) string {
	t.Helper()
	if err := s.Normalize("2026-10-30"); err != nil {
		t.Fatalf("normalize: %v", err)
	}
	n, ok := s.Next(at(after), jkt, fired)
	if !ok {
		return "-"
	}
	return n.Format("2006-01-02 15:04")
}

func TestNext(t *testing.T) {
	cases := []struct {
		name  string
		s     Schedule
		after string
		fired int
		want  string
	}{
		{"once future", Schedule{Kind: "once", At: "2026-10-31T09:00"}, "2026-10-30 14:00", 0, "2026-10-31 09:00"},
		{"once past", Schedule{Kind: "once", At: "2026-10-30T09:00"}, "2026-10-30 14:00", 0, "-"},
		{"daily later today", Schedule{Kind: "daily", Time: "20:00"}, "2026-10-30 14:00", 0, "2026-10-30 20:00"},
		{"daily tomorrow", Schedule{Kind: "daily", Time: "08:00"}, "2026-10-30 14:00", 0, "2026-10-31 08:00"},
		{"every 2 days", Schedule{Kind: "daily", Time: "08:00", Every: 2}, "2026-10-30 14:00", 0, "2026-11-01 08:00"},
		{"weekly mon wed fri", Schedule{Kind: "weekly", Time: "19:00", Weekdays: []int{1, 3, 5}}, "2026-10-30 20:00", 0, "2026-11-02 19:00"},
		{"biweekly", Schedule{Kind: "weekly", Time: "09:00", Weekdays: []int{5}, Every: 2}, "2026-10-30 10:00", 0, "2026-11-13 09:00"},
		{"monthly 25", Schedule{Kind: "monthly", Time: "08:00", MonthDay: 25}, "2026-10-30 14:00", 0, "2026-11-25 08:00"},
		{"monthly 31 short month", Schedule{Kind: "monthly", Time: "08:00", MonthDay: 31}, "2026-10-31 09:00", 0, "2026-11-30 08:00"},
		{"yearly feb 29", Schedule{Kind: "yearly", Time: "07:00", Month: 2, MonthDay: 29}, "2026-10-30 14:00", 0, "2027-02-28 07:00"},
		{"interval window", Schedule{Kind: "interval", EveryMinutes: 120, Window: &Window{"09:00", "17:00"}, Weekdays: []int{1, 2, 3, 4, 5}}, "2026-10-30 14:30", 0, "2026-10-30 15:00"},
		{"interval after window skips weekend", Schedule{Kind: "interval", EveryMinutes: 120, Window: &Window{"09:00", "17:00"}, Weekdays: []int{1, 2, 3, 4, 5}}, "2026-10-30 17:00", 0, "2026-11-02 09:00"},
		{"until reached", Schedule{Kind: "daily", Time: "08:00", Until: "2026-10-31"}, "2026-10-31 09:00", 0, "-"},
		{"count reached", Schedule{Kind: "daily", Time: "08:00", Count: 3}, "2026-10-30 14:00", 3, "-"},
		{"start in future", Schedule{Kind: "daily", Time: "08:00", StartDate: "2026-11-10"}, "2026-10-30 14:00", 0, "2026-11-10 08:00"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := next(t, c.s, c.after, c.fired); got != c.want {
				t.Fatalf("got %s, want %s", got, c.want)
			}
		})
	}
}

func TestNormalizeRejects(t *testing.T) {
	bad := []Schedule{
		{Kind: "cron"},
		{Kind: "once", At: "besok"},
		{Kind: "daily", Time: "25:00"},
		{Kind: "monthly", Time: "08:00", MonthDay: 32},
		{Kind: "interval", EveryMinutes: 5},
		{Kind: "weekly", Time: "08:00", Weekdays: []int{8}},
		{Kind: "daily", Time: "08:00", StartDate: "2026-02-30"},
		{Kind: "daily", Time: "08:00", StartDate: "2026-11-10", Until: "2026-11-01"},
	}
	for _, s := range bad {
		if err := s.Normalize("2026-10-30"); err == nil {
			t.Errorf("expected error for %+v", s)
		}
	}
}

func TestDescribe(t *testing.T) {
	s := Schedule{Kind: "weekly", Time: "19:00", Weekdays: []int{3, 1}}
	_ = s.Normalize("2026-10-30")
	if got := s.Describe(); got != "Tiap Senin & Rabu 19:00" {
		t.Fatalf("got %q", got)
	}
	s = Schedule{Kind: "interval", EveryMinutes: 120, Window: &Window{"09:00", "17:00"}, Weekdays: []int{1, 2, 3, 4, 5}}
	_ = s.Normalize("2026-10-30")
	if got := s.Describe(); got != "Tiap 2 jam pukul 09:00–17:00, hari kerja" {
		t.Fatalf("got %q", got)
	}
}
