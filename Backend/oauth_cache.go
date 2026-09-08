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

// Each provider serializes refreshes and retains rotated refresh tokens across
// polls. A changed source credential invalidates the cache after CLI login.
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

func (c *oauthTokenCache) token(ctx context.Context, access, refresh string, expiry time.Time, fetch func(context.Context, string) (oauthTokenResponse, error)) (string, error) {
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
			}
		}
		c.loaded = true
	}
	if c.sourceAccess != access || c.sourceRefresh != refresh {
		c.sourceAccess, c.sourceRefresh = access, refresh
		c.access, c.refresh, c.expiry = access, refresh, expiry
		c.dirty = false
	}
	if c.dirty {
		if err := c.persist(); err != nil {
			return "", err
		}
	}
	if c.access != "" && (time.Until(c.expiry) > time.Minute || c.refresh == "") {
		return c.access, nil
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	out, err := fetch(ctx, c.refresh)
	if err != nil {
		return "", err
	}
	c.access = out.AccessToken
	if out.RefreshToken != "" {
		c.refresh = out.RefreshToken
	}
	c.expiry = tokenExpiry(out.AccessToken)
	if out.ExpiresIn > 0 {
		c.expiry = time.Now().Add(time.Duration(out.ExpiresIn) * time.Second)
	}
	c.dirty = true
	if err := c.persist(); err != nil {
		return "", err
	}
	return c.access, nil
}

// JWT expiry is a scheduling hint from trusted local credentials, not an
// authentication decision. Opaque tokens need expires_in from the refresh API.
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

// Daemon-owned accounts use the current rotated token as their source; no CLI lookup.
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
	c.sourceAccess, c.sourceRefresh = c.access, c.refresh
	var creds antigravityCreds
	creds.Email = c.email
	creds.Token.AccessToken = c.access
	creds.Token.RefreshToken = c.refresh
	creds.Token.Expiry = c.expiry.Format(time.RFC3339Nano)
	return creds, nil
}
