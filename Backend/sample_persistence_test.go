package main

import (
	"encoding/json"
	"math"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestSampleRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "samples.json")
	cfg := defaultConfig()
	cfg.Claude.RoutesEnabled = []Route{RouteInjection, RouteKeychain}
	s := NewStore(cfg)
	if err := s.enablePersistence(path); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Add(-time.Minute)
	s.SetSampleAt(ProviderClaude, RouteInjection, UsageData{UsedPercent5H: f(42)}, now)
	s.SetSampleAt(ProviderClaude, RouteKeychain, UsageData{UsedPercentWeekly: f(20)}, now.Add(-time.Second))
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatal(info.Mode())
	}
	restored := NewStore(cfg)
	if err := restored.enablePersistence(path); err != nil {
		t.Fatal(err)
	}
	p := restored.Status(time.Now().Unix()).Providers[0]
	if !p.RestoredFromDisk || p.ActiveRoute != RouteInjection || *p.Data.UsedPercent5H != 42 || *p.AsOf != now.Unix() {
		t.Fatalf("%+v", p)
	}
	if restored.RouteFresh(ProviderClaude, RouteInjection, now.Unix()) {
		t.Fatal("restored route considered fresh")
	}
	if points := restored.History(ProviderClaude, RouteKeychain, now.Unix()); len(points) != 1 || points[0].UsedPercent != 20 {
		t.Fatal(points)
	}
	restored.SetSampleAt(ProviderClaude, RouteInjection, UsageData{UsedPercent5H: f(10)}, now.Add(-time.Second))
	if !restored.Status(now.Unix()).Providers[0].RestoredFromDisk {
		t.Fatal("older update cleared marker")
	}
	restored.SetSampleAt(ProviderClaude, RouteKeychain, UsageData{UsedPercent5H: f(30)}, now.Add(time.Second))
	p = restored.Status(now.Unix()).Providers[0]
	if p.RestoredFromDisk || p.ActiveRoute != RouteKeychain {
		t.Fatalf("fresh route must beat restored injection: %+v", p)
	}
	cfg.Claude.RoutesEnabled = []Route{RouteInjection}
	restored.SetConfig(cfg)
	if !restored.Status(now.Unix()).Providers[0].RestoredFromDisk {
		t.Fatal("other route cleared marker")
	}
	restored.SetSampleAt(ProviderClaude, RouteInjection, UsageData{UsedPercent5H: f(50)}, now.Add(2*time.Second))
	if restored.Status(now.Unix()).Providers[0].RestoredFromDisk {
		t.Fatal("new sample still marked restored")
	}
	again := NewStore(cfg)
	if err := again.enablePersistence(path); err != nil {
		t.Fatal(err)
	}
	if points := again.History(ProviderClaude, RouteInjection, now.Unix()); len(points) != 2 || points[1].UsedPercent != 50 {
		t.Fatal(points)
	}
}

func TestHistoryBoundsAndRejectedSamples(t *testing.T) {
	s := NewStore(defaultConfig())
	now := time.Now().Unix()
	for i := 0; i < 250; i++ {
		s.SetSample(ProviderCodex, RouteInjection, UsageData{UsedPercent5H: f(42), UsedPercentWeekly: f(99)}, now-250+int64(i))
	}
	points := s.History(ProviderCodex, RouteInjection, now)
	if len(points) != 200 || points[0].At != now-200 || points[199].UsedPercent != 42 {
		t.Fatal(points)
	}
	points[0].UsedPercent = 1
	if s.History(ProviderCodex, RouteInjection, now)[0].UsedPercent != 42 {
		t.Fatal("history alias")
	}
	s.SetSample(ProviderCodex, RouteInjection, UsageData{UsedPercent5H: f(1)}, now-300)
	s.SetSample(ProviderCodex, RouteInjection, UsageData{ContextWindowUsedPercent: f(1)}, now)
	s.SetSample(ProviderCodex, RouteInjection, UsageData{UsedPercent5H: f(math.NaN())}, now)
	if got := s.History(ProviderCodex, RouteInjection, now); len(got) != 200 || got[199].At != now-1 {
		t.Fatal(got)
	}
	if got := s.History(ProviderCodex, RouteInjection, now-1+historyMaxAge); len(got) != 1 {
		t.Fatal(got)
	}
	if got := s.History(ProviderCodex, RouteInjection, now+historyMaxAge); len(got) != 0 {
		t.Fatal(got)
	}
}

func TestSampleCacheRecoveryAndExpiry(t *testing.T) {
	path := filepath.Join(t.TempDir(), "samples.json")
	if err := os.WriteFile(path, []byte(`{"version":1,"samples":[`), 0600); err != nil {
		t.Fatal(err)
	}
	s := NewStore(defaultConfig())
	if err := s.enablePersistence(path); err == nil {
		t.Fatal("accepted corrupt cache")
	}
	s.SetSample(ProviderClaude, RouteKeychain, UsageData{UsedPercent5H: f(30)}, time.Now().Unix()-historyMaxAge-1)
	restored := NewStore(defaultConfig())
	if err := restored.enablePersistence(path); err != nil {
		t.Fatal(err)
	}
	if len(restored.History(ProviderClaude, RouteKeychain, time.Now().Unix())) != 0 {
		t.Fatal("expired history restored")
	}
	if !restored.Status(time.Now().Unix()).Providers[0].RestoredFromDisk {
		t.Fatal("old sample lost")
	}
	// Failed writes retain live samples; a later update retries the full snapshot.
	bad := filepath.Join(t.TempDir(), "parent")
	if err := os.WriteFile(bad, []byte("file"), 0600); err != nil {
		t.Fatal(err)
	}
	s.persistencePath = filepath.Join(bad, "samples.json")
	s.SetSample(ProviderCodex, RouteInjection, UsageData{UsedPercent5H: f(70)}, time.Now().Unix())
	if len(s.History(ProviderCodex, RouteInjection, time.Now().Unix())) != 1 {
		t.Fatal("write failure lost data")
	}
	s.persistencePath = path
	s.SetSample(ProviderClaude, RouteKeychain, UsageData{UsedPercent5H: f(40)}, time.Now().Unix())
	if err := restored.enablePersistence(path); err != nil {
		t.Fatal(err)
	}
	if len(restored.History(ProviderCodex, RouteInjection, time.Now().Unix())) != 1 {
		t.Fatal("retry omitted sample")
	}
}

func TestHistoryEndpoint(t *testing.T) {
	s := NewServer(NewStore(defaultConfig()), nil, "")
	s.authToken = "test"
	s.store.SetSample(ProviderClaude, RouteKeychain, UsageData{UsedPercentWeekly: f(25)}, time.Now().Unix())
	for _, tc := range []struct {
		query, token string
		code         int
		count        int
	}{
		{"?provider=claude&route=keychain", "", 401, 0},
		{"", "test", 400, 0},
		{"?provider=nope&route=keychain", "test", 400, 0},
		{"?provider=claude&route=none", "test", 400, 0},
		{"?provider=claude&route=keychain", "test", 200, 1},
		{"?provider=codex&route=keychain", "test", 200, 0},
	} {
		req := httptest.NewRequest("GET", "/history"+tc.query, nil)
		req.Header.Set("X-Auth-Token", tc.token)
		w := httptest.NewRecorder()
		s.routes().ServeHTTP(w, req)
		if w.Code != tc.code {
			t.Fatalf("%s: %d", tc.query, w.Code)
		}
		if tc.code == 200 {
			var response struct {
				Points []HistoryPoint `json:"points"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			if response.Points == nil || len(response.Points) != tc.count {
				t.Fatal(w.Body.String())
			}
			if tc.count == 1 && response.Points[0].UsedPercent != 25 {
				t.Fatal(response)
			}
		}
	}
}

func TestConcurrentSamplePersistence(t *testing.T) {
	s := NewStore(defaultConfig())
	path := filepath.Join(t.TempDir(), "samples.json")
	if err := s.enablePersistence(path); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			s.SetSample(ProviderClaude, RouteKeychain, UsageData{UsedPercent5H: f(float64(i))}, time.Now().Unix()+int64(i))
			s.History(ProviderClaude, RouteKeychain, time.Now().Unix())
			s.Status(time.Now().Unix())
		}(i)
	}
	wg.Wait()
	restored := NewStore(defaultConfig())
	if err := restored.enablePersistence(path); err != nil {
		t.Fatal(err)
	}
	if got := restored.Status(time.Now().Unix()).Providers[0]; *got.Data.UsedPercent5H != 19 {
		t.Fatal(got)
	}
}
