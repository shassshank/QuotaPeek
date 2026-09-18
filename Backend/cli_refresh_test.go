package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCLIRefreshProviders(t *testing.T) {
	for _, provider := range []ProviderID{ProviderClaude, ProviderCodex, ProviderAntigravity} {
		for _, recover := range []bool{false, true} {
			t.Run(fmt.Sprint(provider, recover), func(t *testing.T) {
				home := t.TempDir()
				t.Setenv("HOME", home)
				binDir := filepath.Join(home, ".local", "bin")
				if err := os.MkdirAll(binDir, 0700); err != nil {
					t.Fatal(err)
				}
				for _, bin := range []string{"claude", "codex", "agy"} {
					if err := os.WriteFile(filepath.Join(binDir, bin), []byte("unused mock"), 0700); err != nil {
						t.Fatal(err)
					}
				}
				c := NewCollector()
				c.configDir = t.TempDir()
				fresh, triggers, reads, requests := false, 0, 0, 0
				c.readKeychain = func(ctx context.Context, service, account string) ([]byte, error) {
					reads++
					expiry, access := time.Now().Add(-time.Hour), "old"
					if fresh {
						expiry, access = time.Now().Add(time.Hour), "fresh"
					}
					switch provider {
					case ProviderClaude:
						return []byte(fmt.Sprintf(`{"claudeAiOauth":{"accessToken":%q,"expiresAt":%d}}`, access, expiry.UnixMilli())), nil
					case ProviderCodex:
						jwt := "e30." + base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d}`, expiry.Unix()))) + ".sig"
						return []byte(fmt.Sprintf(`{"tokens":{"access_token":%q,"refresh_token":"source"}}`, jwt)), nil
					default:
						raw := fmt.Sprintf(`{"token":{"access_token":%q,"expiry":%q}}`, access, expiry.Format(time.RFC3339Nano))
						return []byte("go-keyring-base64:" + base64.StdEncoding.EncodeToString([]byte(raw))), nil
					}
				}
				c.runCLI = func(ctx context.Context, bin string, args ...string) error {
					triggers++
					wantBin, wantArgs, envKey := "claude", "-p Hi", "CLAUDE_CONFIG_DIR"
					if provider == ProviderCodex {
						wantBin, wantArgs, envKey = "codex", "exec Hi", "CODEX_HOME"
					}
					if provider == ProviderAntigravity {
						wantBin, envKey = "agy", ""
					}
					if bin != filepath.Join(binDir, wantBin) || strings.Join(args, " ") != wantArgs {
						t.Fatalf("command %s %v", bin, args)
					}
					if envKey != "" && !strings.Contains(strings.Join(collectorEnv(ctx), "\n"), envKey+"="+c.configDir) {
						t.Fatal("missing account scope")
					}
					if provider == ProviderAntigravity && ctx.Value(configEnvKey{}) != nil {
						t.Fatal("scoped agy")
					}
					deadline, ok := ctx.Deadline()
					if !ok || time.Until(deadline) > 45*time.Second {
						t.Fatal("unbounded trigger")
					}
					fresh = recover
					return os.ErrPermission // Re-read even when the CLI exits unsuccessfully.
				}
				c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
					requests++
					if !fresh {
						t.Fatal("used expired token")
					}
					switch provider {
					case ProviderClaude:
						resp := reviewResponse(200, "{}")
						resp.Header.Set("anthropic-ratelimit-unified-5h-utilization", "0.2")
						return resp, nil
					case ProviderCodex:
						return reviewResponse(200, `{"rate_limit":{"primary_window":{"used_percent":12}}}`), nil
					default:
						if r.URL.String() == c.discoveryURL {
							return reviewResponse(200, `{"cloudaicompanionProject":"project"}`), nil
						}
						return reviewResponse(200, `{"gemini-weekly":{"remainingFraction":0.3}}`), nil
					}
				})}
				fetch := c.FetchClaude
				if provider == ProviderCodex {
					fetch = c.FetchCodexKeychain
				}
				if provider == ProviderAntigravity {
					fetch = c.FetchAntigravity
				}
				for i := 0; i < 2; i++ {
					_, err := fetch(context.Background())
					if recover && err != nil || !recover && err != errWaitingForToken {
						t.Fatal(err)
					}
				}
				if triggers != 1 || reads < 2 {
					t.Fatalf("triggers=%d reads=%d", triggers, reads)
				}
				if !recover && requests != 0 {
					t.Fatal("waiting made request")
				}
			})
		}
	}
}

func TestCLIRefreshEpisodeAndCooldown(t *testing.T) {
	var cache oauthTokenCache
	ctx := context.Background()
	expired := time.Now().Add(-time.Hour)
	cache.token(ctx, "old", "", expired)
	var wg sync.WaitGroup
	var attempts atomic.Int32
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if cache.beginCLITrigger() {
				attempts.Add(1)
			}
		}()
	}
	wg.Wait()
	if attempts.Load() != 1 {
		t.Fatal(attempts.Load())
	}
	cache.lastTriggerAttempt = time.Now().Add(-11 * time.Minute)
	if cache.beginCLITrigger() {
		t.Fatal("same episode retriggered after cooldown")
	}
	cache.token(ctx, "fresh", "", time.Now().Add(time.Hour))
	if cache.triggeredForExpiry {
		t.Fatal("valid credential did not reset episode")
	}
	if !cache.beginCLITrigger() {
		t.Fatal("new episode blocked after cooldown")
	}
	cache.token(ctx, "changed", "", expired)
	if cache.triggeredForExpiry {
		t.Fatal("source change did not reset episode")
	}
	if cache.beginCLITrigger() {
		t.Fatal("source change bypassed cooldown")
	}
	if err := cache.reset(); err != nil {
		t.Fatal(err)
	}
	if cache.beginCLITrigger() {
		t.Fatal("reset bypassed cooldown")
	}
	var other oauthTokenCache
	if !other.beginCLITrigger() {
		t.Fatal("accounts share cooldown")
	}
}

func TestRunCLI(t *testing.T) {
	ctx := withConfigDir(context.Background(), "CLAUDE_CONFIG_DIR", "test-account")
	if err := runCLI(ctx, "/bin/sh", "-c", `test "$CLAUDE_CONFIG_DIR" = test-account`); err != nil {
		t.Fatal(err)
	}
	if err := runCLI(ctx, "/bin/sh", "-c", "exit 1"); err == nil {
		t.Fatal("missing exit error")
	}
	if err := runCLI(ctx, filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("missing exec error")
	}
	ctx, cancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer cancel()
	if err := runCLI(ctx, "/bin/sh", "-c", "exec sleep 30"); err == nil || ctx.Err() != context.DeadlineExceeded {
		t.Fatalf("timeout: %v %v", err, ctx.Err())
	}
}

func TestCLIRefreshCodexFileRecovery(t *testing.T) {
	c := NewCollector()
	c.configDir = t.TempDir()
	c.readKeychain = func(context.Context, string, string) ([]byte, error) { return nil, os.ErrNotExist }
	write := func(expiry time.Time) {
		jwt := "e30." + base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d}`, expiry.Unix()))) + ".sig"
		raw := fmt.Sprintf(`{"tokens":{"access_token":%q,"refresh_token":"source"}}`, jwt)
		if err := os.WriteFile(filepath.Join(c.configDir, "auth.json"), []byte(raw), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(time.Now().Add(-time.Hour))
	c.runCLI = func(context.Context, string, ...string) error { write(time.Now().Add(time.Hour)); return nil }
	c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() != codexUsageURL {
			t.Fatal("unexpected token endpoint")
		}
		return reviewResponse(200, `{"rate_limit":{"primary_window":{"used_percent":12}}}`), nil
	})}
	if _, err := c.FetchCodexKeychain(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestCLIRefreshCanceledAttemptStillWaits(t *testing.T) {
	c := NewCollector()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c.runCLI = func(context.Context, string, ...string) error { cancel(); return context.Canceled }
	var cache oauthTokenCache
	reads := 0
	_, err := c.fetchWithCLIRefresh(ctx, ProviderClaude, &cache, func() (UsageData, error) {
		reads++
		return UsageData{}, errWaitingForToken
	})
	if err != errWaitingForToken || reads != 1 {
		t.Fatalf("error=%v reads=%d", err, reads)
	}
	if cache.beginCLITrigger() {
		t.Fatal("canceled attempt repeated")
	}
}
