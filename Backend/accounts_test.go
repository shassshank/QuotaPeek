package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

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
