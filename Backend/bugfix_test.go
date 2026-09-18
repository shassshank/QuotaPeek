package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestStatusDisabledRoutesEncodeArray(t *testing.T) {
	cfg := defaultConfig()
	cfg.Accounts = []AccountConfig{legacyAccount(ProviderClaude), legacyAccount(ProviderCodex), legacyAccount(ProviderAntigravity)}
	cfg.Claude.RoutesEnabled = nil
	cfg.Codex.RoutesEnabled = nil
	cfg.Antigravity.RoutesEnabled = nil
	raw, err := json.Marshal(NewStore(cfg).Status(1000))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), `"routes_enabled":null`) || strings.Count(string(raw), `"routes_enabled":[]`) != 3 {
		t.Fatal(string(raw))
	}
}

func TestHeadlineErrorMatchesRoute(t *testing.T) {
	cfg := Config{Claude: ProviderConfig{RoutesEnabled: []Route{RouteKeychain}}}
	s := NewStore(cfg)
	s.SetSample(ProviderClaude, RouteKeychain, UsageData{UsedPercent5H: f(20)}, 1000)
	s.errors = []ErrorEntry{{Provider: ProviderClaude, Route: RouteKeychain, At: 1001, Message: "active"}, {Provider: ProviderClaude, Route: RouteInjection, At: 1002, Message: "disabled"}}
	if got := s.Status(1003).Providers[0].LastError; got == nil || got.Message != "active" {
		t.Fatalf("wrong headline: %+v", got)
	}
	s.SetSample(ProviderClaude, RouteKeychain, UsageData{UsedPercent5H: f(30)}, 1003)
	if got := s.Status(1003).Providers[0].LastError; got != nil {
		t.Fatalf("old error survived success: %+v", got)
	}
	delete(s.samples[ProviderClaude], RouteKeychain)
	if got := s.Status(1003).Providers[0].LastError; got == nil || got.Message != "active" {
		t.Fatalf("wrong would-be route: %+v", got)
	}
}

func TestQuotaFallbackFreshness(t *testing.T) {
	cfg := ProviderConfig{RoutesEnabled: []Route{RouteInjection, RouteKeychain}, KeychainPollIntervalSec: 60}
	for _, tc := range []struct {
		name                string
		injection, keychain int64
		want                Route
	}{
		{"fresh keychain", 300, 990, RouteKeychain},
		{"newer stale keychain", 100, 300, RouteKeychain},
		{"newer stale injection", 300, 100, RouteInjection},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, got := chooseSample(cfg, map[Route]routeSample{RouteInjection: {data: UsageData{UsedPercent5H: f(10)}, asOf: tc.injection}, RouteKeychain: {data: UsageData{UsedPercent5H: f(20)}, asOf: tc.keychain}})
			if got != tc.want {
				t.Fatalf("got %s want %s", got, tc.want)
			}
		})
	}
	s := NewStore(Config{Claude: cfg})
	s.SetSample(ProviderClaude, RouteInjection, UsageData{UsedPercent5H: f(25)}, 900)
	s.SetSample(ProviderClaude, RouteInjection, UsageData{ContextWindowUsedPercent: f(90)}, 1000)
	got := s.Status(1000).Providers[0]
	if got.Data.UsedPercent5H == nil || *got.Data.UsedPercent5H != 25 || *got.AsOf != 900 {
		t.Fatalf("context replaced quota: %+v", got)
	}
	_, route := chooseSample(cfg, map[Route]routeSample{RouteInjection: {data: UsageData{ContextWindowUsedPercent: f(90)}, asOf: 1000}, RouteKeychain: {data: UsageData{UsedPercent5H: f(20)}, asOf: 900}})
	if route != RouteKeychain {
		t.Fatal("context displaced keychain quota")
	}
}

func TestIngestAliasesAndRelativeReset(t *testing.T) {
	for _, field := range []string{"used_percent", "used_percentage"} {
		data, ok, err := parseClaudeIngest([]byte(`{"rate_limits":{"five_hour":{"` + field + `":42},"seven_day":{"` + field + `":17}}}`))
		if err != nil || !ok || data.UsedPercent5H == nil || *data.UsedPercent5H != 42 || data.UsedPercentWeekly == nil || *data.UsedPercentWeekly != 17 {
			t.Fatalf("alias %s: %+v %v", field, data, err)
		}
	}
	before := time.Now().Unix()
	data, ok, err := parseAntigravityIngest([]byte(`{"quota":{"gemini-weekly":{"remaining_fraction":0.5,"reset_in_seconds":3600}}}`))
	if err != nil || !ok || data.ResetsAtWeekly == nil || *data.ResetsAtWeekly < before+3600 || *data.ResetsAtWeekly > time.Now().Unix()+3600 {
		t.Fatalf("relative reset: %+v %v", data, err)
	}
}

func TestOAuthCacheConcurrentWaiting(t *testing.T) {
	var cache oauthTokenCache
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := cache.token(context.Background(), "", "original", time.Time{}); err != errWaitingForToken {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if _, err := cache.token(context.Background(), "near", "original", time.Now().Add(30*time.Second)); err != errWaitingForToken {
		t.Fatal(err)
	}
	if got, err := cache.token(context.Background(), "cli-access", "cli-refresh", time.Now().Add(time.Hour)); err != nil || got != "cli-access" {
		t.Fatal(got, err)
	}
}

type oauthTestTransport func(*http.Request) (*http.Response, error)

func (f oauthTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAntigravityRefreshRetainsResponseFields(t *testing.T) {
	c := NewCollector()
	c.configDir = t.TempDir()
	cachePath, err := antigravityOAuthCachePath(c.configDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveAntigravityOAuthPairs(cachePath, []oauthPair{{clientID: "test-client-id", clientSecret: "test-client-secret"}}); err != nil {
		t.Fatal(err)
	}

	c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		if r.Form.Get("refresh_token") != "old" {
			t.Error("missing refresh token")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"access_token":"new-access","refresh_token":"replacement","expires_in":3600}`)), Header: make(http.Header)}, nil
	})}
	out, err := c.refreshAntigravityToken(context.Background(), "old")
	if err != nil || out.RefreshToken != "replacement" || out.ExpiresIn != 3600 || out.AccessToken != "new-access" {
		t.Fatalf("response fields lost: %+v %v", out, err)
	}
}
