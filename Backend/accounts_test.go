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
)

func TestAntigravityAccountAutoDetectsFromKeychain(t *testing.T) {
	cfg := defaultConfig()
	cfg.Accounts = []AccountConfig{}
	cfg.CollectionPaused = true
	s := NewServer(NewStore(cfg), NewCollector(), filepath.Join(t.TempDir(), "config.json"))
	s.authToken = "secret"
	defer s.poller.Stop()

	raw, err := json.Marshal(antigravityCreds{Email: "detected@example.com", Token: struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		Expiry       string `json:"expiry"`
	}{RefreshToken: "detected-refresh"}})
	if err != nil {
		t.Fatal(err)
	}
	s.collector.readKeychain = func(context.Context, string, string) ([]byte, error) {
		return []byte("go-keyring-base64:" + base64.StdEncoding.EncodeToString(raw)), nil
	}

	body := `{"provider":"antigravity","label":"Personal","credentialLocation":{"kind":"daemon_token"},"autoDetect":true}`
	w := p2Request(s, "POST", "/accounts", body, "secret")
	if w.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	accounts := s.store.Config().Accounts
	if len(accounts) != 1 {
		t.Fatalf("expected 1 account, got %d", len(accounts))
	}
	c := s.accountCollectors[accounts[0].ID]
	if c == nil || c.antigravityTokens.refresh != "detected-refresh" || c.antigravityTokens.email != "detected@example.com" {
		t.Fatalf("auto-detected credentials not applied: %+v", c)
	}
}

func TestAntigravityAccountAutoDetectFailsWithoutKeychainEntry(t *testing.T) {
	cfg := defaultConfig()
	cfg.Accounts = []AccountConfig{}
	cfg.CollectionPaused = true
	s := NewServer(NewStore(cfg), NewCollector(), filepath.Join(t.TempDir(), "config.json"))
	s.authToken = "secret"
	defer s.poller.Stop()
	s.collector.readKeychain = func(context.Context, string, string) ([]byte, error) {
		return nil, fmt.Errorf("keychain read failed for service gemini")
	}

	body := `{"provider":"antigravity","label":"Personal","credentialLocation":{"kind":"daemon_token"},"autoDetect":true}`
	w := p2Request(s, "POST", "/accounts", body, "secret")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d %s", w.Code, w.Body.String())
	}
	if len(s.store.Config().Accounts) != 0 {
		t.Fatal("expected no account created on failed auto-detect")
	}
}

func TestAntigravityDuplicateEmail(t *testing.T) {
	for _, restart := range []bool{false, true} {
		t.Run(fmt.Sprintf("restart=%t", restart), func(t *testing.T) {
			cfg := defaultConfig()
			cfg.Accounts = []AccountConfig{}
			cfg.CollectionPaused = true
			path := filepath.Join(t.TempDir(), "config.json")
			s := NewServer(NewStore(cfg), NewCollector(), path)
			s.authToken = "secret"
			defer s.poller.Stop()
			body := func(email string) string {
				return fmt.Sprintf(`{"provider":"antigravity","label":"Personal","credentialLocation":{"kind":"daemon_token"},"oauthBootstrap":{"refreshToken":"test-refresh","email":%q}}`, email)
			}
			if w := p2Request(s, "POST", "/accounts", body("Person@example.com"), "secret"); w.Code != http.StatusCreated {
				t.Fatalf("create: %d %s", w.Code, w.Body.String())
			}
			if restart {
				restored, err := loadConfig(path)
				if err != nil {
					t.Fatal(err)
				}
				s = NewServer(NewStore(restored), NewCollector(), path)
				s.authToken = "secret"
				defer s.poller.Stop()
				if len(s.accountCollectors) != 0 {
					t.Fatal("expected lazy collectors after restart")
				}
			}
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			filesBefore, err := os.ReadDir(filepath.Dir(path))
			if err != nil {
				t.Fatal(err)
			}
			w := p2Request(s, "POST", "/accounts", body("pERSON@EXAMPLE.COM"), "secret")
			if w.Code != http.StatusConflict || w.Body.String() != "duplicate email\n" {
				t.Fatalf("duplicate: %d %s", w.Code, w.Body.String())
			}
			after, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			filesAfter, err := os.ReadDir(filepath.Dir(path))
			if err != nil {
				t.Fatal(err)
			}
			if string(before) != string(after) || len(s.store.Config().Accounts) != 1 || len(filesBefore) != len(filesAfter) {
				t.Fatal("duplicate request changed accounts or persisted files")
			}
			if w := p2Request(s, "POST", "/accounts", body("other@example.com"), "secret"); w.Code != http.StatusCreated {
				t.Fatalf("different email: %d %s", w.Code, w.Body.String())
			}
			if len(s.store.Config().Accounts) != 2 {
				t.Fatal("expected two distinct accounts")
			}
		})
	}
}
