package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type CredentialLocation struct {
	Kind      string  `json:"kind"`
	ConfigDir *string `json:"configDir"`
}
type AccountConfig struct {
	ID                 string             `json:"id"`
	Provider           ProviderID         `json:"provider"`
	Label              string             `json:"label"`
	CredentialLocation CredentialLocation `json:"credentialLocation"`
}
type Account struct {
	AccountConfig
	ProviderStatus `json:"-"` // MarshalJSON flattens status with the account ID.
	State string `json:"state"`
}

// Explicit outer id overrides the legacy embedded status id in JSON.
func (a Account) MarshalJSON() ([]byte, error) {
	type status ProviderStatus
	return json.Marshal(struct {
		status
		ID                 string             `json:"id"`
		Provider           ProviderID         `json:"provider"`
		Label              string             `json:"label"`
		CredentialLocation CredentialLocation `json:"credentialLocation"`
		State              string             `json:"state"`
	}{status(a.ProviderStatus), a.AccountConfig.ID, a.Provider, a.Label, a.CredentialLocation, a.State})
}
func defaultAccountID(p ProviderID) string { return "acct_" + string(p) + "_default" }
func defaultDir(p ProviderID) string {
	env, name := "CLAUDE_CONFIG_DIR", ".claude"
	if p == ProviderCodex {
		env, name = "CODEX_HOME", ".codex"
	}
	if v := os.Getenv(env); v != "" {
		if abs, e := filepath.Abs(v); e == nil {
			return abs
		}
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, name)
}
func legacyAccount(p ProviderID) AccountConfig {
	a := AccountConfig{ID: defaultAccountID(p), Provider: p, Label: "Default", CredentialLocation: CredentialLocation{Kind: "daemon_token"}}
	if p != ProviderAntigravity {
		d := defaultDir(p)
		a.CredentialLocation = CredentialLocation{Kind: "config_dir", ConfigDir: &d}
	}
	return a
}
func providerConfig(cfg Config, p ProviderID) ProviderConfig {
	switch p {
	case ProviderClaude:
		return cfg.Claude
	case ProviderCodex:
		return cfg.Codex
	default:
		return cfg.Antigravity
	}
}
func (s *Store) keyLocked(p ProviderID) ProviderID {
	for _, a := range s.cfg.Accounts {
		if a.ID == defaultAccountID(p) {
			return ProviderID(a.ID)
		}
	}
	return p
}
func (s *Store) providerLocked(id ProviderID) ProviderID {
	for _, a := range s.cfg.Accounts {
		if a.ID == string(id) {
			return a.Provider
		}
	}
	return id
}
func (s *Store) account(id string) (AccountConfig, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, a := range s.cfg.Accounts {
		if a.ID == id {
			return a, true
		}
	}
	return AccountConfig{}, false
}
func (s *Store) migrateAccounts() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cfg.Accounts != nil {
		return
	}
	s.cfg.Accounts = []AccountConfig{}
	for _, p := range []ProviderID{ProviderClaude, ProviderCodex, ProviderAntigravity} {
		if len(providerConfig(s.cfg, p).RoutesEnabled) == 0 && len(s.samples[p]) == 0 {
			continue
		}
		a := legacyAccount(p)
		s.cfg.Accounts = append(s.cfg.Accounts, a)
		s.samples[ProviderID(a.ID)] = s.samples[p]
		delete(s.samples, p)
		s.history[ProviderID(a.ID)] = s.history[p]
		delete(s.history, p)
		s.health[ProviderID(a.ID)] = s.health[p]
		delete(s.health, p)
	}
}
func trustState(p ProviderStatus, cfg ProviderConfig, stale, now int64) string {
	if p.Data == nil {
		if p.LastErrorMessage != nil {
			return "error"
		}
		return "unknown"
	}
	cutoff := sampleMaxAge(cfg, stale)
	hard := int64(1<<63 - 1)
	if cutoff <= hard/4 {
		hard = cutoff * 4
	}
	if p.AsOf == nil || now-*p.AsOf > hard {
		return "unknown"
	}
	if p.RestoredFromDisk {
		return "restored"
	}
	if now-*p.AsOf <= cutoff {
		return "fresh"
	}
	return "stale"
}
func accountStatus(a AccountConfig, p ProviderStatus, cfg Config, now int64) Account {
	state := trustState(p, providerConfig(cfg, a.Provider), cfg.StaleAfterSeconds, now)
	if state == "unknown" {
		p.Data = nil
		p.AsOf = nil
		p.RestoredFromDisk = false
	}
	return Account{a, p, state}
}
func (s *Server) accountView(a AccountConfig) Account {
	st := s.status()
	for _, v := range st.Accounts {
		if v.AccountConfig.ID == a.ID {
			return v
		}
	}
	return Account{}
}
func decodeAccountBody(w http.ResponseWriter, r *http.Request, v any) bool {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	d.DisallowUnknownFields()
	if d.Decode(v) != nil || d.Decode(new(any)) != io.EOF {
		http.Error(w, "invalid JSON", 400)
		return false
	}
	return true
}
func (s *Server) handleAccounts(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		writeJSON(w, map[string]any{"accounts": s.store.Config().Accounts})
		return
	}
	var req struct {
		Provider           ProviderID         `json:"provider"`
		Label              string             `json:"label"`
		CredentialLocation CredentialLocation `json:"credentialLocation"`
		OAuthBootstrap     *struct {
			RefreshToken string `json:"refreshToken"`
			Email        string `json:"email"`
		} `json:"oauthBootstrap"`
	}
	if !decodeAccountBody(w, r, &req) {
		return
	}
	if !validSampleKey(req.Provider, RouteKeychain) || strings.TrimSpace(req.Label) == "" {
		http.Error(w, "invalid provider or label", 400)
		return
	}
	loc := req.CredentialLocation
	if req.Provider == ProviderAntigravity {
		if loc.Kind != "daemon_token" || loc.ConfigDir != nil || req.OAuthBootstrap == nil || strings.TrimSpace(req.OAuthBootstrap.RefreshToken) == "" {
			http.Error(w, "daemon_token requires oauthBootstrap.refreshToken", 400)
			return
		}
	} else {
		if loc.Kind != "config_dir" || loc.ConfigDir == nil || !filepath.IsAbs(*loc.ConfigDir) || req.OAuthBootstrap != nil {
			http.Error(w, "config_dir requires an absolute configDir", 400)
			return
		}
		d := filepath.Clean(*loc.ConfigDir)
		loc.ConfigDir = &d
	}
	s.configMu.Lock()
	defer s.configMu.Unlock()
	cfg := s.store.Config()
	for _, a := range cfg.Accounts {
		if a.Provider == req.Provider && loc.ConfigDir != nil && a.CredentialLocation.ConfigDir != nil && *loc.ConfigDir == *a.CredentialLocation.ConfigDir {
			http.Error(w, "duplicate configDir", 409)
			return
		}
		if req.Provider == ProviderAntigravity && a.Provider == ProviderAntigravity {
			email, err := s.collectorFor(a).antigravityTokens.accountEmail()
			if err != nil {
				http.Error(w, "could not read account email", 500)
				return
			}
			if email != "" && strings.EqualFold(email, req.OAuthBootstrap.Email) {
				http.Error(w, "duplicate email", 409)
				return
			}
		}
	}
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		http.Error(w, "account id generation failed", 500)
		return
	}
	a := AccountConfig{ID: "acct_" + hex.EncodeToString(b), Provider: req.Provider, Label: req.Label, CredentialLocation: loc}
	c := s.newAccountCollector(a)
	if req.OAuthBootstrap != nil {
		c.antigravityTokens.daemonOwned = true
		c.antigravityTokens.email = req.OAuthBootstrap.Email
		c.antigravityTokens.refresh = req.OAuthBootstrap.RefreshToken
		c.antigravityTokens.loaded = true
		if err := c.antigravityTokens.persist(); err != nil {
			http.Error(w, "could not persist OAuth bootstrap", 500)
			return
		}
	}
	cfg.Accounts = append(append([]AccountConfig{}, cfg.Accounts...), a)
	if err := saveConfig(s.configPath, cfg); err != nil {
		if req.OAuthBootstrap != nil {
			_ = c.antigravityTokens.reset()
		}
		http.Error(w, "could not save accounts", 500)
		return
	}
	s.accountMu.Lock()
	s.accountCollectors[a.ID] = c
	s.accountMu.Unlock()
	s.store.SetConfig(cfg)
	// Return the promised empty snapshot before admitting the first scheduled poll.
	result := s.accountView(a)
	s.poller.Reschedule(cfg)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(201)
	writeJSON(w, result)
}
func (s *Server) handleAccount(w http.ResponseWriter, r *http.Request) {
	s.configMu.Lock()
	defer s.configMu.Unlock()
	id := r.PathValue("id")
	a, ok := s.store.account(id)
	if !ok {
		http.Error(w, "unknown account", 404)
		return
	}
	cfg := s.store.Config()
	cfg.Accounts = append([]AccountConfig{}, cfg.Accounts...)
	if r.Method == http.MethodPatch {
		var patch struct {
			Label *string `json:"label"`
		}
		if !decodeAccountBody(w, r, &patch) {
			return
		}
		if patch.Label == nil || strings.TrimSpace(*patch.Label) == "" {
			http.Error(w, "label required", 400)
			return
		}
		for i := range cfg.Accounts {
			if cfg.Accounts[i].ID == id {
				cfg.Accounts[i].Label = *patch.Label
				a = cfg.Accounts[i]
			}
		}
		if saveConfig(s.configPath, cfg) != nil {
			http.Error(w, "could not save accounts", 500)
			return
		}
		s.store.SetConfig(cfg)
		writeJSON(w, s.accountView(a))
		return
	}
	key := ProviderID(id)
	if !s.store.beginCredentialReset(key) {
		http.Error(w, "account poll or reset in flight", 409)
		return
	}
	defer s.store.endCredentialReset(key)
	c := s.collectorFor(a)
	if c != nil {
		if err := c.resetCredentials(a.Provider); err != nil {
			http.Error(w, redactMessage(err.Error()), 500)
			return
		}
	}
	for i, v := range cfg.Accounts {
		if v.ID == id {
			cfg.Accounts = append(cfg.Accounts[:i], cfg.Accounts[i+1:]...)
			break
		}
	}
	if saveConfig(s.configPath, cfg) != nil {
		http.Error(w, "could not save accounts", 500)
		return
	}
	s.store.SetConfig(cfg)
	s.store.mu.Lock()
	delete(s.store.samples, key)
	delete(s.store.history, key)
	delete(s.store.health, key)
	err := s.store.persistLocked()
	s.store.mu.Unlock()
	s.accountMu.Lock()
	delete(s.accountCollectors, id)
	s.accountMu.Unlock()
	s.poller.Reschedule(cfg)
	if err != nil {
		http.Error(w, "could not persist sample removal", 500)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}
func (s *Server) newAccountCollector(a AccountConfig) *Collector {
	c := NewCollector()
	if s.collector != nil {
		c.readKeychain = s.collector.readKeychain
		c.client = s.collector.client
		c.anthropicURL = s.collector.anthropicURL
		c.tokenURL = s.collector.tokenURL
		c.discoveryURL = s.collector.discoveryURL
		c.quotaURLs = append([]string{}, s.collector.quotaURLs...)
	}
	if a.CredentialLocation.ConfigDir != nil {
		c.configDir = *a.CredentialLocation.ConfigDir
	}
	dir := filepath.Dir(s.configPath)
	suffix := "-" + a.ID
	if a.ID == defaultAccountID(a.Provider) {
		suffix = ""
	}
	c.codexTokens.path = filepath.Join(dir, "oauth-codex"+suffix+".json")
	c.antigravityTokens.path = filepath.Join(dir, "oauth-antigravity"+suffix+".json")
	c.antigravityTokens.daemonOwned = a.Provider == ProviderAntigravity && a.ID != defaultAccountID(a.Provider)
	return c
}
func (s *Server) collectorFor(a AccountConfig) *Collector {
	s.accountMu.Lock()
	defer s.accountMu.Unlock()
	if c, ok := s.accountCollectors[a.ID]; ok {
		return c
	}
	c := s.newAccountCollector(a)
	s.accountCollectors[a.ID] = c
	return c
}

// NFC is supplied by the system's Unicode implementation without adding a module
// dependency. The path is passed as argv, never interpolated into shell code.
func claudeService(configDir string) (string, error) {
	home, _ := os.UserHomeDir()
	if configDir == "" || filepath.Clean(configDir) == filepath.Join(home, ".claude") {
		return "Claude Code-credentials", nil
	}
	normalized := configDir
	if !isASCII(configDir) {
		out, err := exec.Command("/usr/bin/python3", "-c", "import sys,unicodedata;sys.stdout.write(unicodedata.normalize('NFC',sys.argv[1]))", configDir).Output()
		if err != nil {
			return "", errors.New("could not normalize Claude configDir")
		}
		normalized = string(out)
	}
	sum := sha256.Sum256([]byte(normalized))
	return "Claude Code-credentials-" + hex.EncodeToString(sum[:])[:8], nil
}
func isASCII(s string) bool {
	for _, c := range s {
		if c > 127 {
			return false
		}
	}
	return true
}
func (s *Server) ingestAccount(provider ProviderID, raw []byte) (ProviderID, bool) {
	var envelope struct {
		ConfigDir string `json:"configDir"`
		AccountID string `json:"accountId"`
	}
	if json.Unmarshal(raw, &envelope) != nil {
		s.store.AddError(provider, RouteInjection, "invalid ingest JSON")
		return "", false
	}
	// Antigravity accounts are daemon_token, not config_dir: the CLI has no
	// profile concept the hook process could report, so it stamps the account
	// id directly (falling back to the default account when it has none).
	if provider == ProviderAntigravity {
		id := envelope.AccountID
		if id == "" {
			id = defaultAccountID(provider)
		}
		for _, a := range s.store.Config().Accounts {
			if a.Provider == provider && a.ID == id {
				return ProviderID(a.ID), true
			}
		}
		s.store.AddError(provider, RouteInjection, "ingest dropped: no matching account")
		return "", false
	}
	d := envelope.ConfigDir
	if d == "" {
		home, _ := os.UserHomeDir()
		d = filepath.Join(home, ".claude")
	}
	for _, a := range s.store.Config().Accounts {
		if a.Provider == provider && a.CredentialLocation.Kind == "config_dir" && a.CredentialLocation.ConfigDir != nil && filepath.Clean(*a.CredentialLocation.ConfigDir) == filepath.Clean(d) {
			return ProviderID(a.ID), true
		}
	}
	s.store.AddError(provider, RouteInjection, "ingest dropped: no matching config_dir account")
	return "", false
}

type configEnvKey struct{}

func withConfigDir(ctx context.Context, key, value string) context.Context {
	return context.WithValue(ctx, configEnvKey{}, [2]string{key, value})
}
func collectorEnv(ctx context.Context) []string {
	env := os.Environ()
	pair, ok := ctx.Value(configEnvKey{}).([2]string)
	if !ok || pair[1] == "" {
		return env
	}
	out := make([]string, 0, len(env)+1)
	for _, v := range env {
		if !strings.HasPrefix(v, pair[0]+"=") {
			out = append(out, v)
		}
	}
	return append(out, pair[0]+"="+pair[1])
}
