package main

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

func TestExtractAntigravityOAuthPairs(t *testing.T) {
	// Match the actual formats: at least six digits, 20–40 lowercase
	// alphanumerics, and exactly 28 base64url characters after GOCSPX-.
	id1 := "123456-" + strings.Repeat("a", 20) + ".apps.googleusercontent.com"
	id2 := "987654321-" + strings.Repeat("b", 40) + ".apps.googleusercontent.com"
	secret1 := "GOCSPX-" + strings.Repeat("A", 26) + "_-"
	secret2 := "GOCSPX-" + strings.Repeat("9", 28)
	tests := []struct {
		name    string
		blob    []byte
		want    []oauthPair
		wantErr bool
	}{
		{"packed strings", []byte("prefix" + id1 + "neighbor" + secret1 + "trailer"), []oauthPair{{id1, secret1}}, false},
		{"duplicates and multiple candidates", []byte(strings.Join([]string{id1, secret1, id2, secret2, id1, secret1}, "\x00")), []oauthPair{{id1, secret1}, {id1, secret2}, {id2, secret1}, {id2, secret2}}, false},
		{"nil", nil, nil, true},
		{"empty", []byte{}, nil, true},
		{"no matches", []byte("ordinary binary strings\x00"), nil, true},
		{"ID only", []byte(id1), nil, true},
		{"secret only", []byte(secret1), nil, true},
		{"short formats", []byte("12345-" + strings.Repeat("a", 19) + ".apps.googleusercontent.com\x00GOCSPX-" + strings.Repeat("a", 27)), nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := extractAntigravityOAuthPairs(tt.blob)
			if (err != nil) != tt.wantErr {
				t.Fatalf("error = %v, want error: %v", err, tt.wantErr)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("pairs = %#v, want %#v", got, tt.want)
			}
		})
	}
}

func TestUniqueMatches(t *testing.T) {
	for _, tt := range []struct {
		name          string
		pattern       *regexp.Regexp
		first, second string
	}{
		{"client IDs", antigravityClientIDPattern, "123456-" + strings.Repeat("a", 20) + ".apps.googleusercontent.com", "654321-" + strings.Repeat("z", 40) + ".apps.googleusercontent.com"},
		{"client secrets", antigravityClientSecretPattern, "GOCSPX-" + strings.Repeat("A", 28), "GOCSPX-" + strings.Repeat("_", 28)},
	} {
		t.Run(tt.name, func(t *testing.T) {
			blob := []byte(tt.second + "\x00" + tt.first + "\x00" + tt.second + "\x00" + tt.first)
			if got := uniqueMatches(tt.pattern, blob); !reflect.DeepEqual(got, []string{tt.second, tt.first}) {
				t.Fatalf("uniqueMatches() = %q, want distinct matches in first-seen order", got)
			}
			for _, empty := range [][]byte{nil, {}, []byte("no credentials")} {
				if got := uniqueMatches(tt.pattern, empty); len(got) != 0 {
					t.Fatalf("uniqueMatches(%q) = %q, want no matches", empty, got)
				}
			}
		})
	}
}

func TestLocateAndDiscoverAntigravity(t *testing.T) {
	id := "123456-" + strings.Repeat("a", 20) + ".apps.googleusercontent.com"
	secret := "GOCSPX-" + strings.Repeat("b", 28)
	for _, tt := range []struct {
		name               string
		local, path, valid bool
	}{
		{"local preferred", true, true, true}, {"PATH fallback", false, true, true}, {"missing", false, false, false}, {"invalid binary", true, false, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			home, pathDir := t.TempDir(), t.TempDir()
			t.Setenv("HOME", home)
			t.Setenv("PATH", pathDir)
			local := filepath.Join(home, ".local", "bin", "agy")
			fallback := filepath.Join(pathDir, "agy")
			payload := []byte(id + "\x00" + secret)
			if !tt.valid {
				payload = []byte("no credentials")
			}
			for path, create := range map[string]bool{local: tt.local, fallback: tt.path} {
				if create {
					if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
						t.Fatal(err)
					}
					if err := os.WriteFile(path, payload, 0700); err != nil {
						t.Fatal(err)
					}
				}
			}
			got, err := locateAntigravityBinary()
			if !tt.local && !tt.path {
				if err == nil {
					t.Fatal(got)
				}
			} else {
				want := fallback
				if tt.local {
					want = local
				}
				if err != nil || got != want {
					t.Fatal(got, err)
				}
			}
			pairs, err := discoverAntigravityOAuthPairs()
			if (err == nil) != tt.valid {
				t.Fatal(pairs, err)
			}
			if tt.valid && (len(pairs) != 1 || pairs[0] != (oauthPair{id, secret})) {
				t.Fatal(pairs)
			}
		})
	}
}

func TestAntigravityOnlyPersistsRedeemedPair(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	bin := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(bin, 0700); err != nil {
		t.Fatal(err)
	}
	id := "123456-" + strings.Repeat("a", 20) + ".apps.googleusercontent.com"
	bad, good := "GOCSPX-"+strings.Repeat("b", 28), "GOCSPX-"+strings.Repeat("c", 28)
	if err := os.WriteFile(filepath.Join(bin, "agy"), []byte(strings.Join([]string{id, bad, good}, "\x00")), 0700); err != nil {
		t.Fatal(err)
	}
	c := NewCollector()
	c.configDir = t.TempDir()
	path, _ := antigravityOAuthCachePath(c.configDir)
	pairs, _, err := c.antigravityOAuthCandidates(false)
	if err != nil || len(pairs) != 2 {
		t.Fatal(pairs, err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("unverified candidates persisted", err)
	}
	attempts := 0
	c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
		attempts++
		r.ParseForm()
		if r.Form.Get("client_secret") == bad {
			return reviewResponse(401, `{}`), nil
		}
		return reviewResponse(200, `{"access_token":"access","refresh_token":"rotated","expires_in":3600}`), nil
	})}
	if _, err := c.refreshAntigravityToken(context.Background(), "refresh"); err != nil {
		t.Fatal(err)
	}
	saved, err := loadCachedAntigravityOAuthPairs(path)
	if err != nil || len(saved) != 1 || saved[0].clientSecret != good || attempts != 2 {
		t.Fatal(saved, attempts, err)
	}
	restarted := NewCollector()
	restarted.configDir = c.configDir
	restarted.client = c.client
	if _, err := restarted.refreshAntigravityToken(context.Background(), "rotated"); err != nil {
		t.Fatal(err)
	}
	if attempts != 3 {
		t.Fatal("restart retried rejected pair", attempts)
	}
}
