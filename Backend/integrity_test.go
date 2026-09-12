package main

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// pollCodexRoute is a test-only helper mirroring the production poll path
// for Codex routes, used to exercise single-flight and staleness behavior.
func (s *Server) pollCodexRoute(ctx context.Context, route Route, fetch func(context.Context) (UsageData, error)) {
	started, available := s.store.beginPoll(ProviderCodex, route)
	if !available {
		return
	}
	defer s.store.endPoll(ProviderCodex, route)
	data, err := fetch(ctx)
	if err == nil && !s.store.SetSampleAt(ProviderCodex, route, data, started) {
		err = errors.New("Fetch returned invalid, empty, or older quota data.")
	}
	s.store.recordPoll(ProviderCodex, data, err)
	if err != nil {
		s.store.AddError(ProviderCodex, route, err.Error())
		return
	}
}

func TestPollSingleFlightAndStartTimestamp(t *testing.T) {
	cfg := defaultConfig()
	cfg.Accounts = []AccountConfig{legacyAccount(ProviderCodex)}
	store := NewStore(cfg)
	server := NewServer(store, nil, "")
	entered, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	start := time.Now()
	go func() {
		defer close(done)
		server.pollCodexRoute(context.Background(), RouteInjection, func(context.Context) (UsageData, error) {
			close(entered)
			<-release
			return UsageData{UsedPercent5H: f(10)}, nil
		})
	}()
	<-entered
	server.pollCodexRoute(context.Background(), RouteInjection, func(context.Context) (UsageData, error) {
		t.Error("overlapping fetch started")
		return UsageData{}, nil
	})
	newer := time.Now().Add(time.Millisecond)
	store.SetSampleAt(ProviderCodex, RouteInjection, UsageData{UsedPercent5H: f(90)}, newer)
	close(release)
	<-done
	got := store.samples[ProviderID(defaultAccountID(ProviderCodex))][RouteInjection]
	if *got.data.UsedPercent5H != 90 {
		t.Fatal("stale response overwrote newer sample")
	}
	server.pollCodexRoute(context.Background(), RouteKeychain, func(context.Context) (UsageData, error) { return UsageData{UsedPercent5H: f(20)}, nil })
	if store.samples[ProviderID(defaultAccountID(ProviderCodex))][RouteKeychain].started.Before(start) {
		t.Fatal("missing request timestamp")
	}
	if _, ok := store.beginPoll(ProviderCodex, RouteInjection); !ok {
		t.Fatal("flight not released")
	}
}

func TestNonFiniteIngestAndStatusEncodeFailure(t *testing.T) {
	for _, value := range []any{"NaN", "Inf", "-Inf", "Infinity", "1e999", math.NaN(), math.Inf(1), json.Number("NaN")} {
		if _, ok := numberFromAny(value); ok {
			t.Fatalf("accepted %v", value)
		}
	}
	for _, raw := range []string{
		`{"rate_limits":{"five_hour":{"used_percent":"NaN"}}}`,
		`{"rate_limits":{"five_hour":{"used_percent":"Inf"}},"context_window":{"used_percentage":"-Inf"}}`,
	} {
		data, _, err := parseClaudeIngest([]byte(raw))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := json.Marshal(data); err != nil {
			t.Fatal(err)
		}
	}
	data, _, _ := parseAntigravityIngest([]byte(`{"quota":{"weekly":{"remaining_fraction":"1e308"}}}`))
	if _, err := json.Marshal(data); err != nil {
		t.Fatal(err)
	}
	cfg := defaultConfig()
	cfg.Claude.RoutesEnabled = []Route{RouteKeychain}
	store := NewStore(cfg)
	// Bypass sample validation to exercise the response encoder failure guard.
	store.samples[ProviderClaude][RouteKeychain] = routeSample{data: UsageData{UsedPercent5H: f(math.NaN())}, asOf: time.Now().Unix()}
	w := httptest.NewRecorder()
	NewServer(store, nil, "").handleStatus(w, httptest.NewRequest("GET", "/status", nil))
	if w.Code != 500 || !json.Valid(w.Body.Bytes()) || !strings.Contains(w.Body.String(), "error") {
		t.Fatalf("bad error response: %d %s", w.Code, w.Body.String())
	}
}

func TestLocalAuthentication(t *testing.T) {
	path := filepath.Join(t.TempDir(), "auth-token")
	token, err := createAuthToken(path)
	if err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("token not private")
	}
	s := NewServer(NewStore(defaultConfig()), nil, "")
	s.authToken = token
	for _, endpoint := range []struct{ method, path string }{{"POST", "/refresh"}, {"POST", "/test-route"}, {"PUT", "/config"}, {"GET", "/config"}, {"GET", "/errors"}, {"POST", "/ingest/claude"}, {"POST", "/ingest/antigravity"}} {
		w := httptest.NewRecorder()
		s.routes().ServeHTTP(w, httptest.NewRequest(endpoint.method, endpoint.path, nil))
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("unprotected %s", endpoint.path)
		}
	}
	for _, endpoint := range []string{"/config", "/status", "/accounts"} {
		for _, tc := range []struct {
			name, serverToken, requestToken string
			want                            int
		}{
			{"missing", token, "", http.StatusUnauthorized},
			{"incorrect", token, "wrong-token", http.StatusUnauthorized},
			{"valid", token, token, http.StatusOK},
			{"uninitialized", "", "", http.StatusUnauthorized},
		} {
			t.Run(endpoint+"/"+tc.name, func(t *testing.T) {
				s.authToken = tc.serverToken
				req := httptest.NewRequest("GET", endpoint, nil)
				req.Header.Set("X-Auth-Token", tc.requestToken)
				w := httptest.NewRecorder()
				s.routes().ServeHTTP(w, req)
				if w.Code != tc.want {
					t.Fatalf("got HTTP %d, want %d", w.Code, tc.want)
				}
				if tc.want == http.StatusUnauthorized && strings.TrimSpace(w.Body.String()) != `{"error":"unauthorized"}` {
					t.Fatalf("unexpected unauthorized response: %s", w.Body.String())
				}
			})
		}
	}
}

func TestOAuthRotationSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oauth.json")
	c := oauthTokenCache{path: path}
	_, err := c.token(context.Background(), "", "original", time.Time{}, func(context.Context, string) (oauthTokenResponse, error) {
		return oauthTokenResponse{AccessToken: "a", RefreshToken: "rotated", ExpiresIn: 1}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	restarted := oauthTokenCache{path: path}
	_, err = restarted.token(context.Background(), "", "original", time.Time{}, func(_ context.Context, refresh string) (oauthTokenResponse, error) {
		if refresh != "rotated" {
			t.Fatal("rotation lost on restart")
		}
		return oauthTokenResponse{AccessToken: "b", ExpiresIn: 3600}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("credentials not private")
	}
}

func TestClaudePollingDisabled(t *testing.T) {
	c := NewCollector()
	c.readKeychain = func(context.Context, string, string) ([]byte, error) {
		t.Fatal("disabled polling accessed credentials")
		return nil, nil
	}
	if _, err := c.FetchClaudeWithMode(context.Background(), "disabled"); err == nil {
		t.Fatal("missing disabled result")
	}
}
