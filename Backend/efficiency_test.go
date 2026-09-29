package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestCodexAuthFailureRefetchesCredential(t *testing.T) {
	for _, status := range []int{401, 403} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			c := NewCollector()
			c.configDir = t.TempDir()
			expiry := time.Now().Add(time.Hour).Unix()
			reads, requests := 0, 0
			c.readKeychain = func(context.Context, string, string) ([]byte, error) {
				reads++
				token := fmt.Sprintf("header.%s.signature%d", base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d}`, expiry))), reads)
				return json.Marshal(codexAuthDotJSON{Tokens: &codexTokenData{AccessToken: token, RefreshToken: "refresh"}})
			}
			c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
				requests++
				code := 200
				if requests == 2 {
					code = status
				}
				if requests == 3 && !strings.HasSuffix(r.Header.Get("Authorization"), "signature2") {
					t.Error("next call reused rejected credential")
				}
				return &http.Response{StatusCode: code, Status: fmt.Sprint(code), Body: io.NopCloser(strings.NewReader(`{"rate_limit":{"primary_window":{"used_percent":12}}}`))}, nil
			})}
			if _, err := c.FetchCodexKeychain(context.Background()); err != nil {
				t.Fatal(err)
			}
			if got := c.credCache.entries["codex"].expiresAt.Unix(); got != expiry {
				t.Fatalf("cache expiry = %d, want %d", got, expiry)
			}
			if _, err := c.FetchCodexKeychain(context.Background()); err == nil {
				t.Fatal("expected auth failure")
			}
			if _, ok := c.credCache.get("codex", 5*time.Minute); ok {
				t.Fatal("rejected credential remains cached")
			}
			if _, err := c.FetchCodexKeychain(context.Background()); err != nil {
				t.Fatal(err)
			}
			if reads != 2 || requests != 3 {
				t.Fatalf("reads=%d requests=%d", reads, requests)
			}
		})
	}
}

func TestCodexExpiredCredentialWaits(t *testing.T) {
	c := NewCollector()
	c.runCLI = func(context.Context, string, ...string) error { return os.ErrNotExist }
	c.configDir = t.TempDir()
	c.readKeychain = func(context.Context, string, string) ([]byte, error) {
		return []byte(`{"tokens":{"refresh_token":"expired"}}`), nil
	}
	c.client = &http.Client{Transport: oauthTestTransport(func(*http.Request) (*http.Response, error) { t.Fatal("waiting contacted endpoint"); return nil, nil })}
	if _, err := c.FetchCodexKeychain(context.Background()); err != errWaitingForToken {
		t.Fatal(err)
	}
}

func TestAppPresencePollDelay(t *testing.T) {
	s := NewStore(defaultConfig())
	now := time.Unix(10000, 0)
	s.noteAppPresence(now)
	last := now.Add(9*time.Minute + 30*time.Second)
	if delay, _ := s.pollDelay(last, last, time.Minute); delay != 30*time.Second {
		t.Fatalf("idle boundary delay = %v", delay)
	}
	idle := now.Add(appIdleWindow)
	delay, wake := s.pollDelay(idle, last, time.Minute)
	if delay != 14*time.Minute+30*time.Second {
		t.Fatalf("idle delay = %v", delay)
	}
	resume := idle.Add(time.Minute)
	s.noteAppPresence(resume)
	select {
	case <-wake:
	default:
		t.Fatal("idle scheduler was not woken")
	}
	if delay, _ := s.pollDelay(resume, last, time.Minute); delay > 0 {
		t.Fatalf("overdue poll not immediately resumed: %v", delay)
	}
	if delay, _ := s.pollDelay(resume, resume, time.Minute); delay != time.Minute {
		t.Fatalf("normal cadence not restored: %v", delay)
	}
	if delay, _ := s.pollDelay(resume.Add(appIdleWindow), resume, 30*time.Minute); delay != 20*time.Minute {
		t.Fatalf("slow configured interval shortened: %v", delay)
	}
}

func TestAppPresenceRoutes(t *testing.T) {
	for _, path := range []string{"/status", "/accounts"} {
		for _, authorized := range []bool{false, true} {
			s := NewServer(NewStore(defaultConfig()), nil, "")
			s.authToken = "test"
			old := time.Now().Add(-time.Hour)
			s.store.noteAppPresence(old)
			req := httptest.NewRequest("GET", path, nil)
			if authorized {
				req.Header.Set("X-Auth-Token", "test")
			}
			s.routes().ServeHTTP(httptest.NewRecorder(), req)
			if updated := s.store.lastAppSeen.After(old); updated != authorized {
				t.Fatalf("%s authorized=%v presence updated=%v", path, authorized, updated)
			}
		}
	}
}
