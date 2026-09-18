package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

type oauthTokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"`
}

var errWaitingForToken = errors.New("credentials expired, waiting for CLI to refresh")

// A changed source credential supersedes saved tokens after CLI login.
type oauthTokenCache struct {
	daemonOwned   bool
	email         string
	mu            sync.Mutex
	path          string
	loaded        bool
	dirty         bool
	sourceAccess  string
	sourceRefresh string
	access        string
	refresh       string
	expiry        time.Time
}

func (c *oauthTokenCache) token(ctx context.Context, access, refresh string, expiry time.Time) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.loaded && c.path != "" {
		raw, err := os.ReadFile(c.path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return "", fmt.Errorf("read persisted OAuth credentials: %w", err)
		}
		if err == nil {
			var saved persistedOAuth
			if err := json.Unmarshal(raw, &saved); err != nil {
				return "", errors.New("invalid persisted OAuth credentials")
			}
			if c.daemonOwned || saved.Source == oauthSource(access, refresh) {
				c.sourceAccess, c.sourceRefresh = access, refresh
				c.access, c.refresh, c.expiry = saved.Access, saved.Refresh, saved.Expiry
				if c.email == "" {
					c.email = saved.Email
				}
			}
		}
	}
	c.loaded = true
	if c.sourceAccess != access || c.sourceRefresh != refresh {
		c.sourceAccess, c.sourceRefresh = access, refresh
		c.access, c.refresh, c.expiry = access, refresh, expiry
		c.dirty = true
	}
	if c.dirty {
		if err := c.persist(); err != nil {
			return "", err
		}
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if c.access != "" && (c.expiry.IsZero() || time.Until(c.expiry) > time.Minute) {
		return c.access, nil
	}
	return "", errWaitingForToken
}

// JWT expiry is a scheduling hint from trusted local credentials. Opaque
// source tokens without an expiry are usable until the provider rejects them.
func tokenExpiry(token string) time.Time {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return time.Time{}
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return time.Time{}
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if json.Unmarshal(raw, &claims) != nil || claims.Exp == 0 {
		return time.Time{}
	}
	return time.Unix(claims.Exp, 0)
}

// Fingerprint the original CLI credential so a subsequent CLI login supersedes
// the daemon's saved rotation without storing another copy of the old secret.
type persistedOAuth struct {
	Email   string `json:"email,omitempty"`
	Source  string
	Access  string
	Refresh string
	Expiry  time.Time
}

func oauthSource(access, refresh string) string {
	return fmt.Sprintf("%x", sha256.Sum256([]byte(access+"\x00"+refresh)))
}
func (c *oauthTokenCache) persist() error {
	if c.path == "" {
		c.dirty = false
		return nil
	}
	raw, err := json.Marshal(persistedOAuth{Source: oauthSource(c.sourceAccess, c.sourceRefresh), Access: c.access, Refresh: c.refresh, Expiry: c.expiry, Email: c.email})
	if err != nil {
		return err
	}
	if err := atomicPrivateWrite(c.path, raw); err != nil {
		return fmt.Errorf("persist rotated OAuth credentials: %w", err)
	}
	c.dirty = false
	return nil
}

// Remove only the daemon-owned rotation file, never CLI or OS credentials.
func (c *oauthTokenCache) reset() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.path != "" {
		if err := os.Remove(c.path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return errors.New("could not remove daemon OAuth cache")
		}
	}
	c.loaded, c.dirty = false, false
	c.sourceAccess, c.sourceRefresh, c.access, c.refresh = "", "", "", ""
	c.expiry = time.Time{}
	return nil
}

// Read the saved account before looking for a matching CLI credential.
func (c *oauthTokenCache) daemonCredentials() (antigravityCreds, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.loaded {
		raw, err := os.ReadFile(c.path)
		if err != nil {
			return antigravityCreds{}, errors.New("Antigravity account has no daemon credentials")
		}
		var saved persistedOAuth
		if json.Unmarshal(raw, &saved) != nil {
			return antigravityCreds{}, errors.New("invalid daemon OAuth cache")
		}
		c.access, c.refresh, c.expiry, c.email = saved.Access, saved.Refresh, saved.Expiry, saved.Email
		c.loaded = true
	}
	if c.refresh == "" {
		return antigravityCreds{}, errors.New("Antigravity account requires OAuth bootstrap")
	}
	var creds antigravityCreds
	creds.Email = c.email
	creds.Token.AccessToken = c.access
	creds.Token.RefreshToken = c.refresh
	creds.Token.Expiry = c.expiry.Format(time.RFC3339Nano)
	return creds, nil
}

// Account collectors and OAuth credentials are loaded lazily. Read the saved
// email when it is not yet available in memory, without changing token state.
func (c *oauthTokenCache) accountEmail() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.email != "" {
		return c.email, nil
	}
	raw, err := os.ReadFile(c.path)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	var saved persistedOAuth
	if err := json.Unmarshal(raw, &saved); err != nil {
		return "", err
	}
	return saved.Email, nil
}

// Keep the rotated refresh token, but never serve a rejected access token again.
func (c *oauthTokenCache) invalidateAccess() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.access = ""
	c.expiry = time.Time{}
	c.dirty = true
}

func (c *oauthTokenCache) setEmail(email string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if email == "" || c.email == email {
		return nil
	}
	c.email = email
	// Do not overwrite an unloaded rotation file just to update metadata.
	c.dirty = true
	if c.loaded {
		return c.persist()
	}
	return nil
}

func (c *oauthTokenCache) bootstrap(b accountBootstrap, tokens ...oauthTokenResponse) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	// Write the replacement atomically before publishing it to the live cache.
	saved := persistedOAuth{Source: oauthSource("", ""), Refresh: b.RefreshToken, Email: b.Email}
	if len(tokens) > 0 {
		out := tokens[0]
		saved.Access, saved.Expiry = out.AccessToken, tokenExpiry(out.AccessToken)
		if out.RefreshToken != "" {
			saved.Refresh = out.RefreshToken
		}
		if out.ExpiresIn > 0 {
			saved.Expiry = time.Now().Add(time.Duration(out.ExpiresIn) * time.Second)
		}
	}
	raw, err := json.Marshal(saved)
	if err != nil {
		return err
	}
	if c.path != "" {
		if err := atomicPrivateWrite(c.path, raw); err != nil {
			return err
		}
	}
	c.email, c.refresh = b.Email, saved.Refresh
	c.sourceAccess, c.sourceRefresh, c.access = "", "", saved.Access
	c.expiry = saved.Expiry
	c.loaded, c.dirty = true, false
	return nil
}

func (c *oauthTokenCache) needsSourceRead() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.loaded && (c.access == "" || (!c.expiry.IsZero() && time.Until(c.expiry) <= time.Minute))
}
