package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCodexPullsFreshSource(t *testing.T) {
	for _, keychain := range []bool{true, false} {
		t.Run(fmt.Sprint(keychain), func(t *testing.T) {
			c := NewCollector()
			c.runCLI = func(context.Context, string, ...string) error { return os.ErrNotExist }
			c.configDir = t.TempDir()
			token := func(exp int64) string {
				return "e30." + base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d}`, exp))) + ".sig"
			}
			raw := func(access string) []byte {
				b, _ := json.Marshal(map[string]any{"tokens": map[string]string{"access_token": access, "refresh_token": "source"}})
				return b
			}
			current := raw(token(time.Now().Add(-time.Hour).Unix()))
			c.readKeychain = func(context.Context, string, string) ([]byte, error) {
				if keychain {
					return current, nil
				}
				return nil, os.ErrNotExist
			}
			write := func() {
				if err := os.WriteFile(filepath.Join(c.configDir, "auth.json"), current, 0600); err != nil {
					t.Fatal(err)
				}
			}
			write()
			calls := 0
			c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.URL.String() != codexUsageURL {
					t.Fatal("unexpected token endpoint")
				}
				return reviewResponse(200, `{"rate_limit":{"primary_window":{"used_percent":12}}}`), nil
			})}
			for i := 0; i < 2; i++ {
				if _, err := c.FetchCodexKeychain(context.Background()); err != errWaitingForToken {
					t.Fatal(err)
				}
			}
			if calls != 0 {
				t.Fatal(calls)
			}
			current = raw(token(time.Now().Add(time.Hour).Unix()))
			write()
			if _, err := c.FetchCodexKeychain(context.Background()); err != nil {
				t.Fatal(err)
			}
			if calls != 1 {
				t.Fatal(calls)
			}
		})
	}
}

func TestAntigravityOwnedAccountPullsMatchingSource(t *testing.T) {
	c := NewCollector()
	c.runCLI = func(context.Context, string, ...string) error {
		t.Fatal("daemon-owned account triggered CLI")
		return nil
	}
	c.antigravityTokens.daemonOwned = true
	if err := c.antigravityTokens.bootstrap(accountBootstrap{"old", "me@example.com"}); err != nil {
		t.Fatal(err)
	}
	email := "other@example.com"
	c.readKeychain = func(context.Context, string, string) ([]byte, error) {
		raw := fmt.Sprintf(`{"email":%q,"token":{"access_token":"fresh","refresh_token":"cli","expiry":%q}}`, email, time.Now().Add(time.Hour).Format(time.RFC3339Nano))
		return []byte("go-keyring-base64:" + base64.StdEncoding.EncodeToString([]byte(raw))), nil
	}
	c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() == c.tokenURL {
			t.Fatal("poll refreshed token")
		}
		if r.Header.Get("Authorization") != "Bearer fresh" {
			t.Fatal("wrong token")
		}
		if r.URL.String() == c.discoveryURL {
			return reviewResponse(200, `{"cloudaicompanionProject":"project"}`), nil
		}
		return reviewResponse(200, `{"gemini-weekly":{"remainingFraction":0.3}}`), nil
	})}
	if _, err := c.FetchAntigravity(context.Background()); err != errWaitingForToken {
		t.Fatal(err)
	}
	email = "me@example.com"
	if _, err := c.FetchAntigravity(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestWaitingIsNotFailure(t *testing.T) {
	s := NewStore(defaultConfig())
	s.recordPoll(ProviderCodex, UsageData{}, errWaitingForToken)
	h := s.health[ProviderCodex]
	if h.failure != nil || h.message == nil || *h.message != errWaitingForToken.Error() {
		t.Fatal(h)
	}
	s.recordPoll(ProviderCodex, UsageData{UsedPercent5H: f(10)}, nil)
	if s.health[ProviderCodex].message != nil {
		t.Fatal("waiting survived recovery")
	}
}
