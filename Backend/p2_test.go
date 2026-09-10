package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func p2Request(s *Server, method, path, body, token string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("X-Auth-Token", token)
	s.routes().ServeHTTP(w, r)
	return w
}

func TestFreshnessPolicy(t *testing.T) {
	cfg := defaultConfig()
	cfg.Claude.RoutesEnabled = []Route{RouteInjection, RouteKeychain}
	s := NewStore(cfg)
	s.SetSample(ProviderClaude, RouteInjection, UsageData{UsedPercent5H: f(10)}, 800)
	s.SetSample(ProviderClaude, RouteKeychain, UsageData{UsedPercent5H: f(20)}, 990)
	for _, tc := range []struct {
		age      int64
		interval int
		fresh    bool
		route    Route
	}{
		{600, 60, true, RouteKeychain}, {150, 60, false, RouteKeychain},
		{1, 100, true, RouteKeychain}, {1, 99, false, RouteKeychain},
	} {
		cfg.StaleAfterSeconds, cfg.Claude.KeychainPollIntervalSec = tc.age, tc.interval
		s.SetConfig(cfg)
		if got := s.RouteFresh(ProviderClaude, RouteInjection, 1000); got != tc.fresh {
			t.Fatalf("%+v: fresh=%v", tc, got)
		}
		if got := s.Status(1000).Providers[0].ActiveRoute; got != tc.route {
			t.Fatalf("%+v: route=%s", tc, got)
		}
	}
	if sampleMaxAge(ProviderConfig{KeychainPollIntervalSec: int(^uint(0) >> 1)}, 1) <= 0 {
		t.Fatal("overflowed freshness floor")
	}
	path := filepath.Join(t.TempDir(), "legacy.json")
	if err := os.WriteFile(path, []byte(`{}`), 0600); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadConfig(path)
	if err != nil || loaded.StaleAfterSeconds != 600 || loaded.CollectionPaused {
		t.Fatalf("legacy defaults: %+v %v", loaded, err)
	}
}

func TestFreshnessAndPauseConfigAPI(t *testing.T) {
	cfg := defaultConfig()
	cfg.Claude.RoutesEnabled, cfg.Codex.RoutesEnabled, cfg.Antigravity.RoutesEnabled = nil, nil, nil
	s := NewServer(NewStore(cfg), NewCollector(), filepath.Join(t.TempDir(), "config.json"))
	s.authToken = "secret"
	defer s.poller.Stop()
	if w := p2Request(s, "PUT", "/config", `{"collectionPaused":true}`, ""); w.Code != 401 || s.store.Config().CollectionPaused {
		t.Fatal("pause bypassed auth")
	}
	for _, body := range []string{`{"staleAfterSeconds":0}`, `{"staleAfterSeconds":-1}`, `{"staleAfterSeconds":1.5}`, `{"collectionPaused":"true"}`} {
		if w := p2Request(s, "PUT", "/config", body, "secret"); w.Code != 400 {
			t.Fatalf("accepted %s: %s", body, w.Body.String())
		}
	}
	for _, body := range []string{`{"staleAfterSeconds":45,"collectionPaused":true}`, `{"collectionPaused":false}`} {
		w := p2Request(s, "PUT", "/config", body, "secret")
		if w.Code != 200 {
			t.Fatal(w.Body.String())
		}
		loaded, err := loadConfig(s.configPath)
		if err != nil || loaded.StaleAfterSeconds != 45 || loaded.CollectionPaused != s.store.Config().CollectionPaused {
			t.Fatalf("persistence: %+v %v", loaded, err)
		}
	}
}

func TestPauseDrainsPollAndResume(t *testing.T) {
	cfg := defaultConfig()
	cfg.ClaudePollingMode = "inference"
	cfg.Accounts = []AccountConfig{legacyAccount(ProviderClaude), legacyAccount(ProviderCodex), legacyAccount(ProviderAntigravity)}
	cfg.Claude.RoutesEnabled = []Route{RouteKeychain}
	cfg.Codex.RoutesEnabled, cfg.Antigravity.RoutesEnabled = nil, nil
	s := NewServer(NewStore(cfg), NewCollector(), filepath.Join(t.TempDir(), "config.json"))
	s.authToken = "secret"
	defer s.poller.Stop()
	entered, release := make(chan struct{}), make(chan struct{})
	var reads atomic.Int32
	s.collector.readKeychain = func(context.Context, string, string) ([]byte, error) {
		if reads.Add(1) == 1 {
			close(entered)
			<-release
		}
		return []byte(`{"claudeAiOauth":{"accessToken":"test"}}`), nil
	}
	s.collector.client = &http.Client{Transport: oauthTestTransport(func(*http.Request) (*http.Response, error) {
		h := make(http.Header)
		h.Set("anthropic-ratelimit-unified-5h-utilization", "0.42")
		return &http.Response{StatusCode: 200, Header: h, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	go s.pollProvider(context.Background(), ProviderClaude)
	<-entered
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- p2Request(s, "PUT", "/config", `{"collectionPaused":true}`, "secret") }()
	select {
	case <-done:
		t.Fatal("pause returned during active poll")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	select {
	case w := <-done:
		if w.Code != 200 {
			t.Fatal(w.Body.String())
		}
	case <-time.After(time.Second):
		t.Fatal("pause did not drain")
	}
	for _, id := range []ProviderID{ProviderClaude, ProviderCodex, ProviderAntigravity} {
		s.poller.pollOnce(context.Background(), id)
	}
	p2Request(s, "POST", "/refresh", "", "secret")
	for _, id := range []string{"claude", "codex", "antigravity"} {
		for _, route := range []string{"keychain", "injection"} {
			w := p2Request(s, "POST", "/test-route", `{"accountId":"acct_`+id+`_default","provider":"`+id+`","route":"`+route+`"}`, "secret")
			if !strings.Contains(w.Body.String(), "Collection is paused.") {
				t.Fatal(w.Body.String())
			}
		}
	}
	if reads.Load() != 1 {
		t.Fatal("credential read while paused")
	}
	if w := p2Request(s, "PUT", "/config", `{"collectionPaused":false}`, "secret"); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	deadline := time.Now().Add(time.Second)
	for reads.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if reads.Load() < 2 {
		t.Fatal("resume did not schedule immediate poll")
	}
	// Drain resumed work before test teardown.
	cfg = s.store.Config()
	cfg.CollectionPaused = true
	s.store.SetConfig(cfg)
}

func TestCredentialReset(t *testing.T) {
	for _, id := range []ProviderID{ProviderClaude, ProviderCodex, ProviderAntigravity} {
		t.Run(string(id), func(t *testing.T) {
			c := NewCollector()
			cfg := defaultConfig()
			cfg.Accounts = []AccountConfig{legacyAccount(ProviderClaude), legacyAccount(ProviderCodex), legacyAccount(ProviderAntigravity)}
			s := NewServer(NewStore(cfg), c, "")
			s.authToken = "secret"
			a, _ := s.store.account(defaultAccountID(id))
			c = s.collectorFor(a)
			cache := &c.codexTokens
			if id == ProviderAntigravity {
				cache = &c.antigravityTokens
			}
			cache.path = filepath.Join(t.TempDir(), "oauth.json")
			if err := os.WriteFile(cache.path, []byte(`cached`), 0600); err != nil {
				t.Fatal(err)
			}
			cache.access, cache.refresh, cache.loaded = "access", "refresh", true
			c.cachedDiscovery = &antigravityDiscovery{project: "old"}
			c.cachedAntigravityPair = &oauthPair{}
			c.setCredentialInfo(id, "keychain", "old-account")
			path := "/accounts/" + defaultAccountID(id) + "/reset-credentials"
			if w := p2Request(s, "POST", path, "", ""); w.Code != 401 {
				t.Fatal("reset bypassed auth")
			}
			if cache.access != "access" {
				t.Fatal("unauthorized reset changed cache")
			}
			for _, route := range []Route{RouteKeychain, RouteInjection} {
				if _, ok := s.store.beginPoll(id, route); !ok {
					t.Fatal("could not start poll")
				}
				if w := p2Request(s, "POST", path, "", "secret"); w.Code != 409 {
					t.Fatalf("busy reset: %s", w.Body.String())
				}
				s.store.endPoll(id, route)
			}
			cfg = s.store.Config()
			cfg.CollectionPaused = true
			s.store.SetConfig(cfg)
			w := p2Request(s, "POST", path, "", "secret")
			if w.Code != 200 || !strings.Contains(w.Body.String(), `"ok":true`) {
				t.Fatal(w.Body.String())
			}
			if _, ok := c.credentials[id]; ok {
				t.Fatal("identity not cleared")
			}
			if id != ProviderClaude {
				if cache.access != "" || cache.refresh != "" || cache.loaded {
					t.Fatal("token cache not cleared")
				}
				if _, err := os.Stat(cache.path); !os.IsNotExist(err) {
					t.Fatal("persisted rotation not removed")
				}
			}
			if id == ProviderAntigravity && (c.cachedDiscovery != nil || c.cachedAntigravityPair != nil) {
				t.Fatal("discovery not cleared")
			}
			if w := p2Request(s, "POST", path, "", "secret"); w.Code != 200 {
				t.Fatal("reset not idempotent")
			}
		})
	}
}

func TestCredentialResetFailure(t *testing.T) {
	c := NewCollector()
	cfg := defaultConfig()
	cfg.Accounts = []AccountConfig{legacyAccount(ProviderClaude), legacyAccount(ProviderCodex), legacyAccount(ProviderAntigravity)}
	s := NewServer(NewStore(cfg), c, "")
	s.authToken = "secret"
	if w := p2Request(s, "POST", "/accounts/nope/reset-credentials", "", "secret"); w.Code != 404 {
		t.Fatal(w.Body.String())
	}
	a, _ := s.store.account(defaultAccountID(ProviderCodex))
	c = s.collectorFor(a)
	c.codexTokens.path = t.TempDir()
	if err := os.WriteFile(filepath.Join(c.codexTokens.path, "keep"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	c.codexTokens.access = "retained"
	w := p2Request(s, "POST", "/accounts/acct_codex_default/reset-credentials", "", "secret")
	var result map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if w.Code != 500 || result["ok"] != false || c.codexTokens.access != "retained" {
		t.Fatal(w.Body.String())
	}
	if _, ok := s.store.beginPoll(ProviderCodex, RouteKeychain); !ok {
		t.Fatal("failed reset left provider reserved")
	}
	s.store.endPoll(ProviderCodex, RouteKeychain)
}

func TestProviderHealth(t *testing.T) {
	c := NewCollector()
	cfg := defaultConfig()
	cfg.Accounts = []AccountConfig{legacyAccount(ProviderClaude), legacyAccount(ProviderCodex), legacyAccount(ProviderAntigravity)}
	s := NewServer(NewStore(cfg), c, "")
	a, _ := s.store.account(defaultAccountID(ProviderCodex))
	c = s.collectorFor(a)
	p := s.status().Accounts[1]
	if p.CredentialSource != "unknown" || p.EffectiveAccount != nil || p.LastSuccessAt != nil || p.LastFailureAt != nil || p.LastErrorMessage != nil {
		t.Fatalf("initial health: %+v", p)
	}
	c.setCredentialInfo(ProviderCodex, "oauth", "account-123")
	s.store.recordPoll(ProviderCodex, UsageData{}, errors.New("authorization: Bearer sk-secret"))
	s.store.recordPoll(ProviderCodex, UsageData{UsedPercent5H: f(10)}, nil)
	for i := 0; i < 210; i++ {
		s.store.AddError(ProviderClaude, RouteInjection, "other")
	}
	p = s.status().Accounts[1]
	if p.CredentialSource != "oauth" || p.EffectiveAccount == nil || *p.EffectiveAccount != "account-123" || p.LastSuccessAt == nil || p.LastFailureAt == nil || p.LastErrorMessage == nil || strings.Contains(*p.LastErrorMessage, "sk-secret") {
		t.Fatalf("health: %+v", p)
	}
	s.authToken = "secret"
	w := p2Request(s, "GET", "/status", "", "secret")
	for _, key := range []string{"credentialSource", "effectiveAccount", "lastSuccessAt", "lastFailureAt", "lastError"} {
		if !strings.Contains(w.Body.String(), `"`+key+`":`) {
			t.Fatalf("missing %s", key)
		}
	}
}
