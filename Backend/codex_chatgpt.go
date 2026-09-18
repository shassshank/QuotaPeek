package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Reads Codex CLI's own ChatGPT OAuth credentials directly - either from the
// plain ~/.codex/auth.json file, or from the macOS Keychain item Codex writes
// when its own `cli_auth_credentials_store` config is set to "keyring" - and
// calls the same rate-limit endpoint the `codex` binary itself calls
// (https://chatgpt.com/backend-api/wham/usage), instead of spawning a
// `codex app-server` subprocess. Endpoint, header names, and
// JSON shapes below were taken from https://github.com/openai/codex
// (codex-rs/backend-client, codex-rs/login, codex-rs/codex-backend-openapi-models),
// not guessed.

const (
	codexAuthKeyringService  = "Codex Auth"
	codexUsageURL            = "https://chatgpt.com/backend-api/wham/usage"
	codexIDTokenAuthClaimKey = "https://api.openai.com/auth"
)

type codexAuthDotJSON struct {
	Tokens *codexTokenData `json:"tokens"`
}

type codexTokenData struct {
	IDToken      string  `json:"id_token"`
	AccessToken  string  `json:"access_token"`
	RefreshToken string  `json:"refresh_token"`
	AccountID    *string `json:"account_id"`
}

func codexHomeDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".codex"), nil
}

// FetchCodexKeychain reads Codex's own ChatGPT OAuth credential from whichever
// storage Codex is actually using: the macOS Keychain item it writes when its
// own `cli_auth_credentials_store` config is "keyring", falling back to the
// plain ~/.codex/auth.json file (the default, and what's used before you've
// re-run `codex login` after switching to keyring storage).
func (c *Collector) FetchCodexKeychain(ctx context.Context) (UsageData, error) {
	home, err := codexHomeDir()
	if c.configDir != "" {
		home, err = c.configDir, nil
	}
	if err != nil {
		return UsageData{}, err
	}
	ctx = withConfigDir(ctx, "CODEX_HOME", home)
	return c.fetchWithCLIRefresh(ctx, ProviderCodex, &c.codexTokens, func() (UsageData, error) {
		return c.fetchCodexKeychain(ctx, home)
	})
}

func (c *Collector) fetchCodexKeychain(ctx context.Context, home string) (data UsageData, err error) {
	defer func() {
		var authErr *codexAuthError
		if errors.As(err, &authErr) {
			c.credCache.invalidate("codex")
			c.codexTokens.invalidateAccess()
		}
	}()
	cacheKey := "codex"
	if c.codexTokens.needsSourceRead() {
		c.credCache.invalidate(cacheKey)
	}
	if raw, ok := c.credCache.get(cacheKey, 5*time.Minute); ok {
		data, err := c.fetchCodexUsage(ctx, raw, "keychain")
		if !errors.Is(err, errWaitingForToken) {
			return data, err
		}
		c.credCache.invalidate(cacheKey)
	}
	if raw, err := c.readKeychain(ctx, codexAuthKeyringService, codexKeyringAccount(home)); err == nil {
		c.cacheCodexCredential(cacheKey, raw)
		return c.fetchCodexUsage(ctx, raw, "keychain")
	}
	raw, err := os.ReadFile(filepath.Join(home, "auth.json"))
	if err != nil {
		return UsageData{}, errors.New("could not read Codex auth from Keychain or ~/.codex/auth.json")
	}
	c.cacheCodexCredential(cacheKey, raw)
	return c.fetchCodexUsage(ctx, raw, "oauth")
}

// Codex stores expiry in the access-token JWT; opaque tokens use the cache TTL.
func (c *Collector) cacheCodexCredential(key string, raw []byte) {
	var auth codexAuthDotJSON
	var expiry time.Time
	if json.Unmarshal(raw, &auth) == nil && auth.Tokens != nil {
		expiry = tokenExpiry(auth.Tokens.AccessToken)
	}
	c.credCache.put(key, raw, expiry)
}

type codexAuthError struct{ message string }

func (e *codexAuthError) Error() string { return e.message }

// Mirrors codex-rs/login/src/auth/storage.rs::compute_store_key: the Keychain
// account name is "cli|" + the first 16 hex chars of sha256(codex_home path).
func codexKeyringAccount(codexHome string) string {
	canonical, err := filepath.EvalSymlinks(codexHome)
	if err != nil {
		canonical = codexHome
	}
	sum := sha256.Sum256([]byte(canonical))
	hexDigest := fmt.Sprintf("%x", sum)
	return "cli|" + hexDigest[:16]
}

func (c *Collector) fetchCodexUsage(ctx context.Context, rawAuthJSON []byte, sources ...string) (UsageData, error) {
	var auth codexAuthDotJSON
	if err := json.Unmarshal(rawAuthJSON, &auth); err != nil || auth.Tokens == nil || (auth.Tokens.RefreshToken == "" && auth.Tokens.AccessToken == "") {
		return UsageData{}, errors.New("could not parse Codex auth credential")
	}

	accountID := ""
	if auth.Tokens.AccountID != nil {
		accountID = *auth.Tokens.AccountID
	}
	if accountID == "" {
		accountID = codexAccountIDFromIDToken(auth.Tokens.IDToken)
	}

	source := "oauth"
	if len(sources) > 0 {
		source = sources[0]
	}
	c.setCredentialInfo(ProviderCodex, source, accountID)

	accessToken, err := c.codexTokens.token(ctx, auth.Tokens.AccessToken, auth.Tokens.RefreshToken, tokenExpiry(auth.Tokens.AccessToken))
	if err != nil {
		return UsageData{}, err
	}

	return fetchCodexUsageWithToken(ctx, c.client, accessToken, accountID)
}

func fetchCodexUsageWithToken(ctx context.Context, client *http.Client, accessToken, accountID string) (UsageData, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, codexUsageURL, nil)
	if err != nil {
		return UsageData{}, err
	}
	req.Header.Set("User-Agent", "codex-cli")
	req.Header.Set("Authorization", "Bearer "+accessToken)
	if accountID != "" {
		req.Header.Set("ChatGPT-Account-Id", accountID)
	}
	resp, err := client.Do(req)
	if err != nil {
		return UsageData{}, errors.New("codex usage request failed: " + err.Error())
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		preview, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		message := "codex usage endpoint returned status " + resp.Status + ": " + apiErrorMessage(preview)
		if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
			return UsageData{}, &codexAuthError{message}
		}
		return UsageData{}, errors.New(message)
	}

	var payload struct {
		RateLimit *struct {
			PrimaryWindow *struct {
				UsedPercent *float64 `json:"used_percent"`
				ResetAt     *int64   `json:"reset_at"`
			} `json:"primary_window"`
			SecondaryWindow *struct {
				UsedPercent *float64 `json:"used_percent"`
				ResetAt     *int64   `json:"reset_at"`
			} `json:"secondary_window"`
		} `json:"rate_limit"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&payload); err != nil {
		return UsageData{}, errors.New("codex usage endpoint returned unparseable JSON")
	}
	if payload.RateLimit == nil {
		return UsageData{}, errors.New("codex usage endpoint returned no rate_limit field")
	}

	data := UsageData{}
	if w := payload.RateLimit.PrimaryWindow; w != nil {
		if w.UsedPercent != nil {
			used := round1(*w.UsedPercent)
			data.UsedPercent5H = &used
		}
		data.ResetsAt5H = w.ResetAt
	}
	if w := payload.RateLimit.SecondaryWindow; w != nil {
		if w.UsedPercent != nil {
			used := round1(*w.UsedPercent)
			data.UsedPercentWeekly = &used
		}
		data.ResetsAtWeekly = w.ResetAt
	}
	if data.empty() {
		return UsageData{}, errors.New("codex usage endpoint returned no rate-limit windows")
	}
	return data, nil
}

// codexAccountIDFromIDToken pulls the chatgpt_account_id claim out of the
// id_token JWT stored in auth.json, without verifying the signature - we only
// need the claim value, and the token is already trusted local state.
func codexAccountIDFromIDToken(idToken string) string {
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Auth *struct {
			ChatGPTAccountID string `json:"chatgpt_account_id"`
		} `json:"https://api.openai.com/auth"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil || claims.Auth == nil {
		return ""
	}
	return claims.Auth.ChatGPTAccountID
}
