package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func probe(t *testing.T, s *Server, body string, status int) testRouteResponse {
	t.Helper()
	w := httptest.NewRecorder()
	s.authToken = "test-secret"
	req := httptest.NewRequest(http.MethodPost, "/test-route", strings.NewReader(body))
	req.Header.Set("X-Auth-Token", s.authToken)
	s.routes().ServeHTTP(w, req)
	if w.Code != status {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var result testRouteResponse
	if status == 200 {
		if w.Header().Get("Content-Type") != "application/json" {
			t.Fatal("not JSON")
		}
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		var fields map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &fields); err != nil {
			t.Fatal(err)
		}
		if _, ok := fields["ok"].(bool); !ok {
			t.Fatal("missing boolean ok")
		}
		if result.Provider == "" || result.Route == "" {
			t.Fatalf("missing response fields: %s", w.Body.String())
		}
	}
	return result
}

func TestTestRouteValidation(t *testing.T) {
	s := NewServer(NewStore(defaultConfig()), nil, "")
	for _, body := range []string{`{"provider":"garbage","route":"keychain"}`, `{"provider":"claude","route":"none"}`, `{"provider":"claude","route":"garbage"}`, `{}`, `null`, `broken`, `{"provider":"claude","route":"keychain"} {}`, `{"provider":1,"route":"keychain"}`, `{"provider":"claude","route":"keychain"}`, `{"accountId":"acct_missing","provider":"claude","route":"keychain"}`, `{"accountId":"acct_codex_default","provider":"claude","route":"keychain"}`} {
		probe(t, s, body, 400)
	}
}

func TestTestRouteSynchronous(t *testing.T) {
	for _, success := range []bool{true, false} {
		c := NewCollector()
		reads, requests := 0, 0
		c.readKeychain = func(ctx context.Context, service, account string) ([]byte, error) {
			reads++
			deadline, ok := ctx.Deadline()
			if !ok || time.Until(deadline) > 8*time.Second {
				t.Error("missing short timeout")
			}
			return []byte(`{"claudeAiOauth":{"accessToken":"test"}}`), nil
		}
		c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
			requests++
			h := make(http.Header)
			h.Set("anthropic-ratelimit-unified-5h-utilization", "0.42")
			status := http.StatusOK
			if !success {
				status = http.StatusUnauthorized
			}
			return &http.Response{StatusCode: status, Header: h, Body: io.NopCloser(strings.NewReader(""))}, nil
		})}
		cfg := defaultConfig()
		cfg.ClaudePollingMode = "inference"
		store := NewStore(cfg)
		store.SetSample(ProviderClaude, RouteInjection, UsageData{UsedPercent5H: f(10)}, time.Now().Unix())
		store.SetSample(ProviderClaude, RouteKeychain, UsageData{UsedPercent5H: f(20)}, time.Now().Unix()-10)
		server := NewServer(store, c, "")
		before := store.Status(time.Now().Unix())
		result := probe(t, server, `{"accountId":"acct_claude_default","provider":"claude","route":"keychain"}`, 200)
		if result.OK != success || result.Provider != ProviderClaude || result.Route != RouteKeychain || reads != 1 || requests != 1 {
			t.Fatalf("unexpected result: %+v reads=%d requests=%d", result, reads, requests)
		}
		if success {
			if *store.samples[ProviderID(defaultAccountID(ProviderClaude))][RouteKeychain].data.UsedPercent5H != 42 {
				t.Fatal("success not stored")
			}
		} else {
			after := store.Status(time.Now().Unix())
			if after.Providers[0].LastFailureAt == nil || after.Providers[0].LastErrorMessage == nil {
				t.Fatal("failed diagnostic did not update poll health")
			}
			// Only the new historical poll-health fields may change on failure.
			after.Accounts[0].LastFailureAt = before.Accounts[0].LastFailureAt
			after.Accounts[0].LastErrorMessage = before.Accounts[0].LastErrorMessage
			after.Accounts[0].State = before.Accounts[0].State
			after.Providers[0].LastFailureAt = before.Providers[0].LastFailureAt
			after.Providers[0].LastErrorMessage = before.Providers[0].LastErrorMessage
			if result.Message == "" || !reflect.DeepEqual(before, after) || len(store.Errors(50)) != 0 {
				t.Fatal("failure modified samples/headline errors or lacked message")
			}
		}
		if *store.samples[ProviderID(defaultAccountID(ProviderClaude))][RouteInjection].data.UsedPercent5H != 10 {
			t.Fatal("other route modified")
		}
	}
}

func TestTestRoutePushFreshness(t *testing.T) {
	for _, provider := range []ProviderID{ProviderClaude, ProviderAntigravity} {
		for _, age := range []int64{-1, 10, 601} {
			cfg := defaultConfig()
			cfg.ClaudePollingMode = "inference"
			store := NewStore(cfg) // Injection disabled: still inspect that route.
			store.SetSample(provider, RouteKeychain, UsageData{UsedPercent5H: f(80)}, time.Now().Unix())
			if age >= 0 {
				store.SetSample(provider, RouteInjection, UsageData{UsedPercent5H: f(30)}, time.Now().Unix()-age)
			}
			server := NewServer(store, nil, "")
			before := store.Status(time.Now().Unix())
			result := probe(t, server, `{"accountId":"`+defaultAccountID(provider)+`","provider":"`+string(provider)+`","route":"injection"}`, 200)
			if result.OK != (age == 10) || !strings.Contains(result.Message, "cannot trigger a push") {
				t.Fatalf("age %d: %+v", age, result)
			}
			if !reflect.DeepEqual(before, store.Status(time.Now().Unix())) {
				t.Fatal("push probe modified status")
			}
		}
	}
}

func panicPollServer() *Server {
	cfg := defaultConfig()
	cfg.ClaudePollingMode = "inference"
	cfg.Accounts = []AccountConfig{legacyAccount(ProviderClaude)}
	cfg.Claude.RoutesEnabled = []Route{RouteKeychain}
	c := NewCollector()
	c.readKeychain = func(context.Context, string, string) ([]byte, error) {
		panic("malformed provider payload")
	}
	return NewServer(NewStore(cfg), c, "")
}

func TestPollPanicCleanupAndDiagnostics(t *testing.T) {
	for _, mode := range []string{"direct", "refresh", "scheduled"} {
		t.Run(mode, func(t *testing.T) {
			s := panicPollServer()
			defer s.poller.Stop()
			switch mode {
			case "direct":
				s.pollProvider(context.Background(), ProviderClaude)
			case "refresh":
				s.handleRefresh(httptest.NewRecorder(), httptest.NewRequest("POST", "/refresh", nil))
			case "scheduled":
				s.poller.Reschedule(s.store.Config())
			}
			deadline := time.After(time.Second)
			for len(s.store.Errors(50)) == 0 {
				select {
				case <-deadline:
					t.Fatal("panic was not reported")
				case <-time.After(time.Millisecond):
				}
			}
			entries := s.store.Errors(50)
			if len(entries) != 1 || entries[0].Provider != ProviderClaude ||
				entries[0].AccountID != defaultAccountID(ProviderClaude) ||
				entries[0].Route != RouteKeychain ||
				!strings.Contains(entries[0].Message, "malformed provider payload") {
				t.Fatalf("unexpected diagnostics: %+v", entries)
			}
			done := make(chan struct{})
			go func() { s.store.SetConfig(s.store.Config()); close(done) }()
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("SetConfig blocked after panic")
			}
			key := ProviderID(defaultAccountID(ProviderClaude))
			if _, ok := s.store.beginPoll(key, RouteKeychain); !ok {
				t.Fatal("route still in flight")
			}
			s.store.endPoll(key, RouteKeychain)
		})
	}
}

func TestServeCancellationDrainsPoll(t *testing.T) {
	s := panicPollServer()
	entered, release := make(chan struct{}), make(chan struct{})
	path := filepath.Join(t.TempDir(), "persisted")
	s.collector.readKeychain = func(ctx context.Context, _, _ string) ([]byte, error) {
		close(entered)
		<-release
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if err := atomicPrivateWrite(path, []byte("complete")); err != nil {
			return nil, err
		}
		return nil, io.EOF
	}
	listener := &shutdownTestListener{closed: make(chan struct{})}
	defer listener.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- s.serve(ctx, listener) }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		close(release)
		t.Fatal("poll did not start")
	}
	cancel()
	select {
	case err := <-done:
		close(release)
		t.Fatalf("returned before persistence: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("server did not shut down")
	}
	raw, err := os.ReadFile(path)
	if err != nil || string(raw) != "complete" {
		t.Fatalf("persistence not drained: %q %v", raw, err)
	}
	// A late settings request must not restart polling after Stop.
	s.poller.Reschedule(s.store.Config())
}

// No socket is needed to exercise Serve/Shutdown and poll draining.
type shutdownTestListener struct {
	closed chan struct{}
	once   sync.Once
}

func (l *shutdownTestListener) Accept() (net.Conn, error) {
	<-l.closed
	return nil, net.ErrClosed
}
func (l *shutdownTestListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return nil
}
func (l *shutdownTestListener) Addr() net.Addr { return &net.TCPAddr{} }
