package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func reviewServer(t *testing.T, provider ProviderID) (*Server, AccountConfig) {
	t.Helper()
	cfg := defaultConfig()
	a := legacyAccount(provider)
	cfg.Accounts = []AccountConfig{a}
	cfg.CollectionPaused = true
	s := NewServer(NewStore(cfg), NewCollector(), filepath.Join(t.TempDir(), "config.json"))
	s.authToken = "secret"
	t.Cleanup(s.poller.Stop)
	return s, a
}

func TestReviewAccountMethods(t *testing.T) {
	for _, tt := range []struct {
		name, method, body string
		code               int
		removed            bool
	}{
		{"rename", "PATCH", `{"label":"Work"}`, 200, false},
		{"empty label", "PATCH", `{"label":" "}`, 400, false},
		{"missing label", "PATCH", `{}`, 400, false},
		{"unknown field", "PATCH", `{"other":1}`, 400, false},
		{"trailing JSON", "PATCH", `{"label":"Work"}{}`, 400, false},
		{"delete", "DELETE", ``, 200, true},
		{"get", "GET", ``, 405, false},
		{"post", "POST", ``, 405, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			s, a := reviewServer(t, ProviderAntigravity)
			r := httptest.NewRequest(tt.method, "/accounts/"+a.ID, strings.NewReader(tt.body))
			r.SetPathValue("id", a.ID)
			w := httptest.NewRecorder()
			s.handleAccount(w, r)
			if w.Code != tt.code {
				t.Fatalf("status %d: %s", w.Code, w.Body.String())
			}
			_, exists := s.store.account(a.ID)
			if exists == tt.removed {
				t.Fatal("unexpected account removal")
			}
			if tt.name == "rename" {
				got, _ := s.store.account(a.ID)
				if got.Label != "Work" {
					t.Fatal(got)
				}
			}
		})
	}
	for _, method := range []string{"PATCH", "DELETE"} {
		t.Run(method+" save failure", func(t *testing.T) {
			s, a := reviewServer(t, ProviderAntigravity)
			c := s.collectorFor(a)
			if err := c.antigravityTokens.bootstrap(accountBootstrap{"refresh", "email"}); err != nil {
				t.Fatal(err)
			}
			before, _ := os.ReadFile(c.antigravityTokens.path)
			s.configPath = t.TempDir() // Atomic rename onto a directory must fail.
			w := p2Request(s, method, "/accounts/"+a.ID, `{"label":"Work"}`, "secret")
			if w.Code != 500 {
				t.Fatal(w.Code, w.Body.String())
			}
			after, _ := os.ReadFile(c.antigravityTokens.path)
			if string(before) != string(after) {
				t.Fatal("credentials changed after failed config save")
			}
			if _, ok := s.store.account(a.ID); !ok {
				t.Fatal("account removed")
			}
		})
	}
	s, _ := reviewServer(t, ProviderClaude)
	if w := p2Request(s, "DELETE", "/accounts/missing", "", "secret"); w.Code != 404 {
		t.Fatal(w.Code)
	}
}

func TestReviewReauthenticate(t *testing.T) {
	for _, auto := range []bool{false, true} {
		t.Run(fmt.Sprint(auto), func(t *testing.T) {
			s, _ := reviewServer(t, ProviderAntigravity)
			cfg := s.store.Config()
			a := cfg.Accounts[0]
			a.ID = "acct_personal"
			a.Label = "Personal"
			cfg.Accounts = []AccountConfig{a}
			s.store.SetConfig(cfg)
			s.collector.readKeychain = func(context.Context, string, string) ([]byte, error) {
				return []byte("go-keyring-base64:" + base64.StdEncoding.EncodeToString([]byte(`{"email":"me@example.com","token":{"refresh_token":"new"}}`))), nil
			}
			c := s.collectorFor(a)
			if err := c.antigravityTokens.bootstrap(accountBootstrap{"old", "me@example.com"}); err != nil {
				t.Fatal(err)
			}
			if w := p2Request(s, "POST", "/accounts/"+a.ID+"/reset-credentials", "", "secret"); w.Code != 200 {
				t.Fatal(w.Body.String())
			}
			body := `{"oauthBootstrap":{"refreshToken":"new","email":"me@example.com"}}`
			if auto {
				body = `{"autoDetect":true}`
			}
			if w := p2Request(s, "POST", "/accounts/"+a.ID+"/reauthenticate", body, "secret"); w.Code != 200 {
				t.Fatal(w.Code, w.Body.String())
			}
			fresh := s.newAccountCollector(a)
			creds, err := fresh.antigravityTokens.daemonCredentials()
			if err != nil || creds.Token.RefreshToken != "new" {
				t.Fatal(creds, err)
			}
			got, _ := s.store.account(a.ID)
			if got.Label != a.Label || got.ID != a.ID {
				t.Fatal(got)
			}
		})
	}
}

func TestReviewClaudeIngestHTTP(t *testing.T) {
	for _, tt := range []struct {
		name, reset string
		want        *int64
	}{
		{"unix", `1700000000`, intPtr(1700000000, true)},
		{"numeric string", `"1700000000"`, intPtr(1700000000, true)},
		{"RFC3339", `"2023-11-14T22:13:20Z"`, intPtr(1700000000, true)},
		{"fractional", `"2023-11-14T23:13:20.123+01:00"`, intPtr(1700000000, true)},
		{"invalid", `"bad"`, nil},
	} {
		t.Run(tt.name, func(t *testing.T) {
			s, a := reviewServer(t, ProviderClaude)
			body := fmt.Sprintf(`{"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":%s},"seven_day":{"used_percentage":40,"resets_at":%s}}}`, tt.reset, tt.reset)
			w := p2Request(s, "POST", "/ingest/claude", body, "secret")
			if w.Code != 200 {
				t.Fatal(w.Code)
			}
			sample := s.store.samples[ProviderID(a.ID)][RouteInjection].data
			for _, got := range []*int64{sample.ResetsAt5H, sample.ResetsAtWeekly} {
				if (got == nil) != (tt.want == nil) || (got != nil && *got != *tt.want) {
					t.Fatalf("reset %v, want %v", got, tt.want)
				}
			}
		})
	}
	for _, body := range []string{`{`, `{}`, `{"configDir":"/unregistered","rate_limits":{"five_hour":{"used_percentage":30}}}`} {
		s, a := reviewServer(t, ProviderClaude)
		w := p2Request(s, "POST", "/ingest/claude", body, "secret")
		if w.Code != 200 {
			t.Fatal(w.Code)
		}
		if len(s.store.samples[ProviderID(a.ID)]) != 0 {
			t.Fatal("unexpected sample")
		}
	}
}

func TestReviewErrorsHTTP(t *testing.T) {
	for _, tt := range []struct {
		query string
		want  int
	}{{"", 3}, {"?limit=2", 2}, {"?limit=bad", 3}, {"?limit=100", 3}} {
		t.Run(tt.query, func(t *testing.T) {
			s, a := reviewServer(t, ProviderClaude)
			for i := 0; i < 3; i++ {
				s.store.AddError(ProviderID(a.ID), RouteInjection, fmt.Sprint(i))
			}
			w := p2Request(s, "GET", "/errors"+tt.query, "", "secret")
			var out struct {
				Errors []json.RawMessage `json:"errors"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
				t.Fatal(err)
			}
			if w.Code != 200 || len(out.Errors) != tt.want {
				t.Fatal(w.Code, w.Body.String())
			}
		})
	}
}

func TestReviewDaemonCredentials(t *testing.T) {
	for _, tt := range []struct {
		name, raw string
		wantErr   bool
	}{
		{"missing", "", true}, {"corrupt", "{", true}, {"no refresh", `{"Access":"access"}`, true},
		{"valid", `{"Access":"access","Refresh":"rotated","email":"me@example.com","Expiry":"2030-01-01T00:00:00Z"}`, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "oauth.json")
			if tt.raw != "" {
				if err := os.WriteFile(path, []byte(tt.raw), 0600); err != nil {
					t.Fatal(err)
				}
			}
			c := oauthTokenCache{path: path, daemonOwned: true}
			got, err := c.daemonCredentials()
			if (err != nil) != tt.wantErr {
				t.Fatal(err)
			}
			if !tt.wantErr {
				if got.Email != "me@example.com" || got.Token.RefreshToken != "rotated" {
					t.Fatal(got)
				}
				os.Remove(path)
				if _, err := c.daemonCredentials(); err != nil {
					t.Fatal("memory load", err)
				}
			}
		})
	}
}

func TestReviewGeminiMaximumAndStableTies(t *testing.T) {
	for _, window := range []string{"weekly", "5h"} {
		for _, remaining := range []float64{0.2, 0.8} {
			t.Run(fmt.Sprint(window, remaining), func(t *testing.T) {
				raw := []byte(fmt.Sprintf(`{"a-gemini-%s":{"remainingFraction":0.2,"resetTime":111},"z-gemini-%s":{"remainingFraction":%g,"resetTime":222}}`, window, window, remaining))
				for i := 0; i < 100; i++ {
					d, ok := ParseAntigravityQuota(raw)
					used, reset := d.UsedPercent5H, d.ResetsAt5H
					if window == "weekly" {
						used, reset = d.UsedPercentWeekly, d.ResetsAtWeekly
					}
					if !ok || used == nil || *used != 80 || reset == nil || *reset != 111 {
						t.Fatal(d)
					}
				}
			})
		}
	}
}

func TestReviewLegacyV2Restore(t *testing.T) {
	cfg := defaultConfig()
	cfg.Accounts = nil
	path := filepath.Join(t.TempDir(), "samples.json")
	raw, _ := json.Marshal(sampleSnapshot{Version: 2, Samples: []persistedSample{{AccountID: defaultAccountID(ProviderClaude), Provider: ProviderClaude, Route: RouteInjection, Data: UsageData{UsedPercent5H: floatPtr(42, true)}, Started: time.Now()}}})
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	store := NewStore(cfg)
	if err := store.enablePersistence(path); err != nil {
		t.Fatal(err)
	}
	s := NewServer(store, NewCollector(), filepath.Join(t.TempDir(), "config.json"))
	defer s.poller.Stop()
	sample := store.samples[ProviderID(defaultAccountID(ProviderClaude))][RouteInjection]
	if sample.data.UsedPercent5H == nil || *sample.data.UsedPercent5H != 42 || !sample.restored {
		t.Fatal(sample)
	}
}

func TestReviewJSONStatusMarshalFailure(t *testing.T) {
	for _, code := range []int{200, 201, 400} {
		w := httptest.NewRecorder()
		writeJSONStatus(w, code, math.NaN())
		if w.Code != 500 || w.Header().Get("Content-Type") != "application/json" {
			t.Fatal(w.Code, w.Header())
		}
	}
}

func TestReviewASCIIAndClaudeService(t *testing.T) {
	for _, tt := range []struct {
		path  string
		ascii bool
	}{{"", true}, {"/tmp/claude", true}, {"/tmp/café", false}, {"/tmp/cafe\u0301", false}, {"/tmp/日本語", false}} {
		t.Run(tt.path, func(t *testing.T) {
			if isASCII(tt.path) != tt.ascii {
				t.Fatal("ASCII classification")
			}
			service, err := claudeService(tt.path)
			if err != nil {
				if !tt.ascii {
					if _, statErr := os.Stat("/usr/bin/python3"); statErr != nil {
						t.Skip("system python unavailable")
					}
				}
				t.Fatal(err)
			}
			if !strings.HasPrefix(service, "Claude Code-credentials") {
				t.Fatal(service)
			}
		})
	}
	composed, err := claudeService("/tmp/café")
	if err == nil {
		decomposed, err := claudeService("/tmp/cafe\u0301")
		if err != nil || composed != decomposed {
			t.Fatal("NFC mismatch", composed, decomposed, err)
		}
	}
}

func TestReviewRefreshSurvivesDisconnect(t *testing.T) {
	s, a := reviewServer(t, ProviderClaude)
	cfg := s.store.Config()
	cfg.CollectionPaused = false
	cfg.ClaudePollingMode = "inference"
	cfg.Claude.RoutesEnabled = []Route{RouteKeychain}
	s.store.SetConfig(cfg)
	entered, release, finished := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	c := s.collectorFor(a)
	c.readKeychain = func(ctx context.Context, _, _ string) ([]byte, error) {
		close(entered)
		<-release
		finished <- ctx.Err()
		return nil, errors.New("test complete")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r := httptest.NewRequest("POST", "/refresh", strings.NewReader(`{}`)).WithContext(ctx)
	done := make(chan struct{})
	go func() { s.handleRefresh(httptest.NewRecorder(), r); close(done) }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("poll not started")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("handler did not return")
	}
	close(release)
	if err := <-finished; err != nil {
		t.Fatal("provider canceled by disconnect", err)
	}
}

func reviewResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Status: http.StatusText(status), Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}

func TestReviewAntigravityPollAndDiscovery(t *testing.T) {
	for _, tt := range []struct {
		name                         string
		discoveryStatus, quotaStatus int
		quota                        string
		wantErr                      bool
	}{
		{"success", 200, 200, `{"gemini-5h":{"remainingFraction":0.4}}`, false},
		{"discovery unauthorized", 401, 200, `{}`, true},
		{"discovery forbidden", 403, 200, `{}`, true},
		{"quota unauthorized", 200, 401, `{}`, true},
		{"quota forbidden", 200, 403, `{}`, true},
		{"quota server error", 200, 500, `{}`, true},
		{"empty quota", 200, 200, `{}`, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			c := NewCollector()
			c.configDir = t.TempDir()
			c.antigravityTokens.path = filepath.Join(c.configDir, "tokens.json")
			c.discoveryURL = "https://test/discovery"
			c.quotaURLs = []string{"https://test/quota"}
			reads, discoveryCalls := 0, 0
			raw := fmt.Sprintf(`{"email":"me@example.com","token":{"access_token":"access","refresh_token":"refresh","expiry":%q}}`, time.Now().Add(time.Hour).Format(time.RFC3339))
			c.readKeychain = func(context.Context, string, string) ([]byte, error) {
				reads++
				return []byte("go-keyring-base64:" + base64.StdEncoding.EncodeToString([]byte(raw))), nil
			}
			c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
				if r.Header.Get("Authorization") != "Bearer access" {
					t.Error("missing bearer")
				}
				if r.URL.Path == "/discovery" {
					discoveryCalls++
					return reviewResponse(tt.discoveryStatus, `{"cloudaicompanionProject":{"id":"project"},"paidTier":{"name":"Pro"}}`), nil
				}
				var body map[string]string
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body["project"] != "project" {
					t.Error("missing project", body, err)
				}
				return reviewResponse(tt.quotaStatus, tt.quota), nil
			})}
			d, err := c.FetchAntigravity(context.Background())
			if (err != nil) != tt.wantErr {
				t.Fatal(d, err)
			}
			if !tt.wantErr {
				if d.UsedPercent5H == nil || *d.UsedPercent5H != 60 {
					t.Fatal(d)
				}
				if _, err := c.FetchAntigravity(context.Background()); err != nil {
					t.Fatal(err)
				}
				if reads != 1 || discoveryCalls != 1 {
					t.Fatal("cache miss", reads, discoveryCalls)
				}
			}
			saved := oauthTokenCache{path: c.antigravityTokens.path}
			email, err := saved.accountEmail()
			if err != nil || email != "me@example.com" {
				t.Fatal("email not persisted", email, err)
			}
			if tt.discoveryStatus == 401 || tt.discoveryStatus == 403 || tt.quotaStatus == 401 || tt.quotaStatus == 403 {
				calls := 0
				_, err := c.antigravityTokens.token(context.Background(), "access", "refresh", time.Now().Add(time.Hour), func(_ context.Context, refresh string) (oauthTokenResponse, error) {
					calls++
					if refresh != "refresh" {
						t.Error(refresh)
					}
					return oauthTokenResponse{AccessToken: "replacement", ExpiresIn: 3600}, nil
				})
				if err != nil || calls != 1 {
					t.Fatal("rejected access reused", calls, err)
				}
				if _, ok := c.credCache.get("antigravity", time.Hour); ok {
					t.Fatal("keychain cache retained")
				}
			}
		})
	}
	for _, raw := range []string{"invalid prefix", "go-keyring-base64:!", "go-keyring-base64:" + base64.StdEncoding.EncodeToString([]byte("{"))} {
		t.Run(raw, func(t *testing.T) {
			c := NewCollector()
			c.readKeychain = func(context.Context, string, string) ([]byte, error) { return []byte(raw), nil }
			if _, err := c.FetchAntigravity(context.Background()); err == nil {
				t.Fatal("invalid credentials accepted")
			}
		})
	}
}

func TestReviewCodexRejectedTokenRefresh(t *testing.T) {
	for _, status := range []int{401, 403} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			c := NewCollector()
			c.configDir = t.TempDir()
			c.readKeychain = func(context.Context, string, string) ([]byte, error) {
				return []byte(`{"tokens":{"access_token":"original","refresh_token":"source"}}`), nil
			}
			c.codexTokens = oauthTokenCache{loaded: true, sourceAccess: "original", sourceRefresh: "source", access: "rejected", refresh: "rotated", expiry: time.Now().Add(time.Hour)}
			refreshed := false
			c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
				if r.URL.String() == codexOAuthRefreshURL {
					var body map[string]string
					json.NewDecoder(r.Body).Decode(&body)
					if body["refresh_token"] != "rotated" {
						t.Error(body)
					}
					refreshed = true
					return reviewResponse(200, `{"access_token":"new","expires_in":3600}`), nil
				}
				if !refreshed {
					return reviewResponse(status, `{}`), nil
				}
				return reviewResponse(200, `{"rate_limit":{"primary_window":{"used_percent":12}}}`), nil
			})}
			if _, err := c.FetchCodexKeychain(context.Background()); err == nil {
				t.Fatal("expected rejection")
			}
			if _, err := c.FetchCodexKeychain(context.Background()); err != nil {
				t.Fatal(err)
			}
			if !refreshed {
				t.Fatal("token was not refreshed")
			}
		})
	}
}

func TestReviewCodexSubprocessCache(t *testing.T) {
	for _, tt := range []struct {
		name                          string
		expire, different, invalidate bool
		want                          bool
	}{
		{"hit", false, false, false, true}, {"expired", true, false, false, false}, {"different directory", false, true, false, false}, {"invalidated", false, false, true, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			var cache codexSubprocessCache
			if _, ok := cache.get("a"); ok {
				t.Fatal("empty cache hit")
			}
			cache.put("a", UsageData{UsedPercent5H: floatPtr(13, true)})
			if tt.expire {
				cache.fetchedAt = time.Now().Add(-codexSubprocessTTL - time.Second)
			}
			if tt.invalidate {
				cache.invalidate()
			}
			dir := "a"
			if tt.different {
				dir = "b"
			}
			d, ok := cache.get(dir)
			if ok != tt.want || (ok && *d.UsedPercent5H != 13) {
				t.Fatal(d, ok)
			}
		})
	}
	for _, success := range []bool{true, false} {
		t.Run(fmt.Sprint("subprocess ", success), func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			bin := filepath.Join(home, ".local", "bin")
			if err := os.MkdirAll(bin, 0700); err != nil {
				t.Fatal(err)
			}
			response := `{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12}}}}`
			if !success {
				response = `{"id":2,"error":{"message":"failure"}}`
			}
			path := filepath.Join(bin, "codex")
			if err := os.WriteFile(path, []byte("#!/bin/sh\nread first\nread second\nprintf '%s\\n' '"+response+"'\n"), 0700); err != nil {
				t.Fatal(err)
			}
			c := NewCollector()
			_, err := c.FetchCodexAtCached(context.Background(), home)
			if (err == nil) != success {
				t.Fatal(err)
			}
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			// A cached success works even when the executable is no longer available.
			t.Setenv("PATH", t.TempDir())
			_, err = c.FetchCodexAtCached(context.Background(), home)
			if (err == nil) != success {
				t.Fatal("cache result", err)
			}
			if !success {
				if _, ok := c.codexCache.get(home); ok {
					t.Fatal("cached failure")
				}
			}
		})
	}
}

func TestReviewAutoDetectNilCollector(t *testing.T) {
	s, _ := reviewServer(t, ProviderAntigravity)
	s.collector = nil
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := httptest.NewRequest("POST", "/accounts", strings.NewReader(`{"provider":"antigravity","label":"Personal","credentialLocation":{"kind":"daemon_token"},"autoDetect":true}`)).WithContext(ctx)
	w := httptest.NewRecorder()
	s.handleAccounts(w, r)
	if w.Code != 422 {
		t.Fatal(w.Code, w.Body.String())
	}
}

func TestReviewDaemonFullPollAfterReauthenticate(t *testing.T) {
	s, _ := reviewServer(t, ProviderAntigravity)
	cfg := s.store.Config()
	a := cfg.Accounts[0]
	a.ID = "acct_personal"
	cfg.Accounts = []AccountConfig{a}
	s.store.SetConfig(cfg)
	w := p2Request(s, "POST", "/accounts/"+a.ID+"/reauthenticate", `{"oauthBootstrap":{"refreshToken":"bootstrap","email":"me@example.com"}}`, "secret")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	c := s.collectorFor(a)
	c.configDir = t.TempDir()
	c.cachedAntigravityPair = &oauthPair{"client", "secret"}
	c.readKeychain = func(context.Context, string, string) ([]byte, error) {
		t.Error("daemon account consulted Keychain")
		return nil, errors.New("unexpected")
	}
	calls := 0
	c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() == c.tokenURL {
			calls++
			r.ParseForm()
			if r.Form.Get("refresh_token") != "bootstrap" {
				t.Error("incorrect refresh token")
			}
			return reviewResponse(200, `{"access_token":"access","refresh_token":"rotated","expires_in":3600}`), nil
		}
		if r.Header.Get("Authorization") != "Bearer access" {
			t.Error("wrong bearer")
		}
		if r.URL.String() == c.discoveryURL {
			return reviewResponse(200, `{"cloudaicompanionProject":"project"}`), nil
		}
		return reviewResponse(200, `{"gemini-weekly":{"remainingFraction":0.3}}`), nil
	})}
	for i := 0; i < 2; i++ {
		d, err := c.FetchAntigravity(context.Background())
		if err != nil || d.UsedPercentWeekly == nil || *d.UsedPercentWeekly != 70 {
			t.Fatal(d, err)
		}
	}
	if calls != 1 {
		t.Fatal("unnecessary refresh", calls)
	}
	restarted := s.newAccountCollector(a)
	creds, err := restarted.antigravityTokens.daemonCredentials()
	if err != nil || creds.Token.RefreshToken != "rotated" || creds.Email != "me@example.com" {
		t.Fatal(creds, err)
	}
}
