package main

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestRedactMessage(t *testing.T) {
	tests := []struct{ name, input, want string }{
		{"google refresh", "token 1//0fake._~+/- end", "token <redacted> end"},
		{"raw JWT", "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.fake_signature-123 end", "token <redacted> end"},
		{"bearer", "bEaReR abc.DEF_~+/-=", "Bearer <redacted>"},
		{"google access", "token ya29.fake_A-1.2 end", "token <redacted> end"},
		{"API key", "token sk-fake_A-1.2 end", "token <redacted> end"},
		{"quoted JSON", `{"access_token": "fake"}`, `{"access_token":<redacted>"}`},
		{"passthrough", "Service temporarily unavailable.", "Service temporarily unavailable."},
		{"empty", "", ""},
		{"trim", "  unavailable\n", "unavailable"},
	}
	for _, key := range []string{"access_token", "refresh_token", "id_token", "apikey", "api_key", "api-key", "client_secret", "authorization"} {
		tests = append(tests, struct{ name, input, want string }{key, key + "=fake", key + ":<redacted>"})
	}
	tests = append(tests, struct{ name, input, want string }{"case insensitive field", "ACCESS_TOKEN = fake", "ACCESS_TOKEN :<redacted>"})
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := redactMessage(tt.input); got != tt.want {
				t.Fatalf("redactMessage() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestRedactMessageTruncation(t *testing.T) {
	for _, r := range []string{"é", "界", "🙂"} {
		for prefixLen := 197; prefixLen <= 200; prefixLen++ {
			input := strings.Repeat("a", prefixLen) + strings.Repeat(r, 10)
			got := redactMessage(input)
			want := strings.Repeat("a", prefixLen) + strings.Repeat(r, (200-prefixLen)/len(r))
			if !utf8.ValidString(got) || got != want {
				t.Fatalf("rune %q, prefix %d: got %q, want %q", r, prefixLen, got, want)
			}
		}
	}
}

func TestAPIErrorMessage(t *testing.T) {
	tests := []struct{ name, body, want string }{
		{"message", `{"error":{"message":"Service unavailable"}}`, "Service unavailable"},
		{"redacted message", `{"error":{"message":"expired 1//0fake"}}`, "expired <redacted>"},
		{"invalid JSON fallback", "failed sk-fake", "failed <redacted>"},
		{"missing message fallback", `{"detail":"ya29.fake"}`, `{"detail":"<redacted>"}`},
		{"empty message fallback", `{"error":{"message":""}}`, `{"error":{"message":""}}`},
		{"wrong shape fallback", `{"error":"sk-fake"}`, `{"error":"<redacted>"}`},
		{"empty body", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := apiErrorMessage([]byte(tt.body)); got != tt.want {
				t.Fatalf("apiErrorMessage() = %q, want %q", got, tt.want)
			}
		})
	}
}
