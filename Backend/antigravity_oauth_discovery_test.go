package main

import (
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
