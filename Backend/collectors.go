package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const antigravityUserAgent = "antigravity/cli/1.1.26 (aidev_client; os_type=darwin; arch=arm64; cl=976013059; auth_method=consumer)"

type Collector struct {
	configDir         string
	readKeychain      func(context.Context, string, string) ([]byte, error)
	client            *http.Client
	codexTokens       oauthTokenCache
	antigravityTokens oauthTokenCache

	mu                    sync.Mutex
	credentials           map[ProviderID]credentialInfo
	cachedAntigravityPair *oauthPair
	cachedDiscovery       *antigravityDiscovery

	credCache keychainCache
	codexCache codexSubprocessCache

	anthropicURL string
	tokenURL     string
	discoveryURL string
	quotaURLs    []string
}

type oauthPair struct {
	clientID     string
	clientSecret string
}

type antigravityDiscovery struct {
	project  string
	planType string
}

func NewCollector() *Collector {
	return &Collector{
		readKeychain: readKeychain,
		client:       &http.Client{Timeout: 10 * time.Second},
		anthropicURL: "https://api.anthropic.com/v1/messages",
		tokenURL:     "https://oauth2.googleapis.com/token",
		discoveryURL: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
		quotaURLs: []string{
			"https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
			"https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
		},
	}
}

func readKeychain(ctx context.Context, service string, account string) ([]byte, error) {
	args := []string{"find-generic-password", "-s", service}
	if account != "" {
		args = append(args, "-a", account)
	}
	args = append(args, "-w")
	cmd := exec.CommandContext(ctx, "/usr/bin/security", args...)
	cmd.Env = collectorEnv(ctx)
	out, err := cmd.Output()
	if err != nil {
		return nil, errors.New("keychain read failed for service " + service)
	}
	return bytes.TrimRight(out, "\r\n"), nil
}

func (c *Collector) FetchClaude(ctx context.Context) (UsageData, error) {
	return c.FetchClaudeWithMode(ctx, "inference")
}

func (c *Collector) FetchClaudeWithMode(ctx context.Context, mode string) (UsageData, error) {
	if mode == "disabled" {
		return UsageData{}, errors.New("Claude inference polling is disabled; enable injection for passive updates")
	}
	service, err := claudeService(c.configDir)
	if err != nil {
		return UsageData{}, err
	}
	ctx = withConfigDir(ctx, "CLAUDE_CONFIG_DIR", c.configDir)

	cacheKey := "claude:" + service
	raw, cached := c.credCache.get(cacheKey, 5*time.Minute)
	if !cached {
		raw, err = c.readKeychain(ctx, service, os.Getenv("USER"))
		if err != nil {
			return UsageData{}, err
		}
	}

	var creds struct {
		ClaudeAIOAuth struct {
			AccessToken      string `json:"accessToken"`
			ExpiresAt        int64  `json:"expiresAt"`
			SubscriptionType string `json:"subscriptionType"`
			RateLimitTier    string `json:"rateLimitTier"`
		} `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal(raw, &creds); err != nil || creds.ClaudeAIOAuth.AccessToken == "" {
		return UsageData{}, errors.New("could not parse Claude Code Keychain credentials")
	}
	c.setCredentialInfo(ProviderClaude, "keychain", "")
	if creds.ClaudeAIOAuth.ExpiresAt > 0 && time.Now().UnixMilli() >= creds.ClaudeAIOAuth.ExpiresAt {
		c.credCache.invalidate(cacheKey)
		return UsageData{}, errors.New("Claude credentials expired, run claude CLI to refresh")
	}

	// Cache the raw keychain read on success, with the credential's own expiry.
	if !cached {
		var expiresAt time.Time
		if creds.ClaudeAIOAuth.ExpiresAt > 0 {
			expiresAt = time.UnixMilli(creds.ClaudeAIOAuth.ExpiresAt)
		}
		c.credCache.put(cacheKey, raw, expiresAt)
	}

	body := map[string]any{
		"model":      "claude-haiku-4-5-20251001",
		"max_tokens": 1,
		"messages":   []map[string]string{{"role": "user", "content": "hi"}},
	}
	b, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.anthropicURL, bytes.NewReader(b))
	if err != nil {
		return UsageData{}, err
	}
	req.Header.Set("Authorization", "Bearer "+creds.ClaudeAIOAuth.AccessToken)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	resp, err := c.client.Do(req)
	if err != nil {
		return UsageData{}, errors.New("anthropic request failed: " + err.Error())
	}
	defer resp.Body.Close()
	data := UsageData{}
	if v, ok := parseHeaderFloat(resp.Header, "anthropic-ratelimit-unified-5h-utilization"); ok {
		used := round1(v * 100)
		data.UsedPercent5H = &used
	}
	if v, ok := parseHeaderInt(resp.Header, "anthropic-ratelimit-unified-5h-reset"); ok {
		data.ResetsAt5H = &v
	}
	if v, ok := parseHeaderFloat(resp.Header, "anthropic-ratelimit-unified-7d-utilization"); ok {
		used := round1(v * 100)
		data.UsedPercentWeekly = &used
	}
	if v, ok := parseHeaderInt(resp.Header, "anthropic-ratelimit-unified-7d-reset"); ok {
		data.ResetsAtWeekly = &v
	}
	if resp.StatusCode == http.StatusUnauthorized {
		c.credCache.invalidate(cacheKey)
		return data, errors.New("Claude credentials expired, run claude CLI to refresh")
	}
	// Quota headers remain useful on errors (especially 429). Return the
	// snapshot as a successful collection so the poller actually stores it.
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		if !data.quotaEmpty() {
			return data, nil
		}
		preview, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return data, errors.New("anthropic API returned status " + resp.Status + ": " + apiErrorMessage(preview))
	}
	if data.empty() {
		return UsageData{}, errors.New("anthropic response had no rate-limit headers")
	}
	return data, nil
}

func parseHeaderFloat(h http.Header, name string) (float64, bool) {
	return numberFromAny(h.Get(name))
}

func parseHeaderInt(h http.Header, name string) (int64, bool) {
	f, ok := numberFromAny(h.Get(name))
	return int64(f), ok
}

type antigravityCreds struct {
	Email string `json:"email"`
	Token struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		Expiry       string `json:"expiry"`
	} `json:"token"`
	AccessToken string `json:"access_token"`
	PlanTier    string `json:"plan_tier"`
}

func (c *Collector) FetchAntigravity(ctx context.Context) (UsageData, error) {
	var creds antigravityCreds
	var err error
	if c.antigravityTokens.daemonOwned {
		creds, err = c.antigravityTokens.daemonCredentials()
	} else {
		creds, err = c.loadAntigravityCredsCached(ctx)
	}
	if err != nil {
		return UsageData{}, err
	}
	source := "keychain"
	if c.antigravityTokens.daemonOwned {
		source = "oauth"
	}
	c.setCredentialInfo(ProviderAntigravity, source, creds.Email)
	token := creds.Token.AccessToken
	if token == "" {
		token = creds.AccessToken
	}
	if creds.Token.RefreshToken != "" {
		expiry, _ := time.Parse(time.RFC3339Nano, creds.Token.Expiry)
		refreshed, err := c.antigravityTokens.token(ctx, token, creds.Token.RefreshToken, expiry, c.refreshAntigravityToken)
		if err != nil {
			return UsageData{}, err
		}
		token = refreshed
	}
	if token == "" {
		return UsageData{}, errors.New("could not find Antigravity OAuth access token in Keychain credential")
	}
	discovery, err := c.antigravityDiscovery(ctx, token, creds.PlanTier)
	if err != nil {
		return UsageData{}, err
	}
	var lastErr error
	for _, endpoint := range c.quotaURLs {
		body := map[string]any{}
		if strings.TrimSpace(discovery.project) != "" {
			body["project"] = discovery.project
		}
		respBody, status, err := c.postJSON(ctx, endpoint, token, body)
		if err != nil {
			lastErr = err
			continue
		}
		if status < 200 || status > 299 {
			if status == http.StatusUnauthorized || status == http.StatusForbidden {
				c.invalidateAntigravityDiscovery()
				c.credCache.invalidate("antigravity")
			}
			lastErr = errors.New(filepath.Base(endpoint) + " returned status " + http.StatusText(status) + ": " + apiErrorMessage(respBody))
			continue
		}
		data, ok := ParseAntigravityQuota(respBody)
		if !ok {
			lastErr = errors.New(filepath.Base(endpoint) + " returned no parseable quota buckets")
			continue
		}
		return data, nil
	}
	if lastErr == nil {
		lastErr = errors.New("no quota endpoint attempted")
	}
	return UsageData{}, errors.New("antigravity quota failed: " + lastErr.Error())
}

func (c *Collector) loadAntigravityCredsCached(ctx context.Context) (antigravityCreds, error) {
	cacheKey := "antigravity"
	if raw, ok := c.credCache.get(cacheKey, 5*time.Minute); ok {
		var creds antigravityCreds
		if json.Unmarshal(raw, &creds) == nil {
			return creds, nil
		}
	}
	creds, err := loadAntigravityCreds(ctx)
	if err != nil {
		return antigravityCreds{}, err
	}
	// Cache the parsed credentials as JSON. Use the token expiry for eviction.
	var expiresAt time.Time
	if creds.Token.Expiry != "" {
		expiresAt, _ = time.Parse(time.RFC3339Nano, creds.Token.Expiry)
	}
	if raw, err := json.Marshal(creds); err == nil {
		c.credCache.put(cacheKey, raw, expiresAt)
	}
	return creds, nil
}

func loadAntigravityCreds(ctx context.Context) (antigravityCreds, error) {
	raw, err := readKeychain(ctx, "gemini", "antigravity")
	if err != nil {
		return antigravityCreds{}, err
	}
	const prefix = "go-keyring-base64:"
	s := string(raw)
	if !strings.HasPrefix(s, prefix) {
		return antigravityCreds{}, errors.New("Antigravity Keychain credential did not have expected go-keyring-base64 prefix")
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(s, prefix))
	if err != nil {
		return antigravityCreds{}, errors.New("could not base64-decode Antigravity Keychain credential")
	}
	var creds antigravityCreds
	if err := json.Unmarshal(decoded, &creds); err != nil {
		return antigravityCreds{}, errors.New("could not parse Antigravity Keychain credential JSON")
	}
	return creds, nil
}

var antigravityOAuthPairs = []oauthPair{
	{"REDACTED-GOOGLE-OAUTH-CLIENT-ID", "REDACTED-GOOGLE-OAUTH-CLIENT-SECRET"},
	{"REDACTED-GOOGLE-OAUTH-CLIENT-ID", "REDACTED-GOOGLE-OAUTH-CLIENT-SECRET"},
}

func (c *Collector) refreshAntigravityToken(ctx context.Context, refreshToken string) (oauthTokenResponse, error) {
	c.mu.Lock()
	cached := c.cachedAntigravityPair
	c.mu.Unlock()
	if cached != nil {
		if token, err := c.tryRefreshPair(ctx, refreshToken, *cached); err == nil {
			return token, nil
		}
		c.mu.Lock()
		c.cachedAntigravityPair = nil
		c.mu.Unlock()
	}
	for _, pair := range antigravityOAuthPairs {
		token, err := c.tryRefreshPair(ctx, refreshToken, pair)
		if err == nil {
			c.mu.Lock()
			c.cachedAntigravityPair = &pair
			c.mu.Unlock()
			return token, nil
		}
	}
	return oauthTokenResponse{}, errors.New("antigravity token refresh failed")
}

func (c *Collector) tryRefreshPair(ctx context.Context, refreshToken string, pair oauthPair) (oauthTokenResponse, error) {
	form := url.Values{}
	form.Set("grant_type", "refresh_token")
	form.Set("refresh_token", refreshToken)
	form.Set("client_id", pair.clientID)
	form.Set("client_secret", pair.clientSecret)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return oauthTokenResponse{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.client.Do(req)
	if err != nil {
		return oauthTokenResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return oauthTokenResponse{}, errors.New("token endpoint status " + resp.Status)
	}
	var out oauthTokenResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil || out.AccessToken == "" {
		return oauthTokenResponse{}, errors.New("token endpoint returned no access token")
	}
	return out, nil
}

func (c *Collector) antigravityDiscovery(ctx context.Context, token string, fallbackPlan string) (antigravityDiscovery, error) {
	c.mu.Lock()
	cached := c.cachedDiscovery
	c.mu.Unlock()
	if cached != nil {
		return *cached, nil
	}
	body := map[string]any{"metadata": map[string]string{"ideType": "ANTIGRAVITY"}}
	respBody, status, err := c.postJSON(ctx, c.discoveryURL, token, body)
	if err != nil {
		return antigravityDiscovery{}, errors.New("Antigravity discovery failed: " + err.Error())
	}
	if status < 200 || status > 299 {
		return antigravityDiscovery{}, errors.New("Antigravity discovery failed: loadCodeAssist returned status " + http.StatusText(status) + ": " + apiErrorMessage(respBody))
	}
	var jsonObj map[string]any
	if err := json.Unmarshal(respBody, &jsonObj); err != nil {
		return antigravityDiscovery{}, errors.New("loadCodeAssist returned non-JSON response")
	}
	discovery := antigravityDiscovery{
		project:  stringValue(jsonObj["cloudaicompanionProject"]),
		planType: tierDescription(jsonObj["paidTier"]),
	}
	if discovery.project == "" {
		if nested, ok := jsonObj["cloudaicompanionProject"].(map[string]any); ok {
			discovery.project = stringValue(nested["id"])
		}
	}
	if discovery.planType == "" {
		discovery.planType = tierDescription(jsonObj["currentTier"])
	}
	if discovery.planType == "" {
		discovery.planType = fallbackPlan
	}
	c.mu.Lock()
	c.cachedDiscovery = &discovery
	c.mu.Unlock()
	return discovery, nil
}

func (c *Collector) invalidateAntigravityDiscovery() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.cachedDiscovery = nil
}

func (c *Collector) postJSON(ctx context.Context, endpoint, token string, body map[string]any) ([]byte, int, error) {
	b, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(b))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", antigravityUserAgent)
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return respBody, resp.StatusCode, nil
}

func tierDescription(v any) string {
	m, ok := v.(map[string]any)
	if !ok {
		return ""
	}
	if s := stringValue(m["name"]); s != "" {
		return s
	}
	return stringValue(m["id"])
}

func stringValue(v any) string {
	s, ok := v.(string)
	if !ok {
		return ""
	}
	return strings.TrimSpace(s)
}

func codexBin() string {
	home, err := os.UserHomeDir()
	if err == nil {
		p := filepath.Join(home, ".local", "bin", "codex")
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return "codex"
}

// Only metadata explicitly read by a collector is exposed; never infer identity
// from an access token or perform credential reads to serve GET /status.
type credentialInfo struct{ source, account string }

func (c *Collector) setCredentialInfo(id ProviderID, source, account string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.credentials == nil {
		c.credentials = make(map[ProviderID]credentialInfo)
	}
	c.credentials[id] = credentialInfo{source, account}
}

// Caller reserves both provider routes so an older fetch cannot refill caches.
func (c *Collector) resetCredentials(id ProviderID) error {
	var err error
	switch id {
	case ProviderCodex:
		err = c.codexTokens.reset()
		c.codexCache.invalidate()
		c.credCache.invalidate("codex")
	case ProviderAntigravity:
		err = c.antigravityTokens.reset()
		c.credCache.invalidate("antigravity")
	case ProviderClaude:
		c.credCache.invalidateAll()
	default:
		return errUnknownProvider
	}
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.credentials, id)
	if id == ProviderAntigravity {
		c.cachedAntigravityPair = nil
		c.cachedDiscovery = nil
	}
	return nil
}
