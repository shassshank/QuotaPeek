package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
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
	mu            sync.Mutex
	sourceAccess  string
	sourceRefresh string
	access        string
	refresh       string
	expiry        time.Time
}

func (c *oauthTokenCache) token(ctx context.Context, access, refresh string, expiry time.Time, fetch func(context.Context, string) (oauthTokenResponse, error)) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.sourceAccess != access || c.sourceRefresh != refresh {
		c.sourceAccess, c.sourceRefresh = access, refresh
		c.access, c.refresh, c.expiry = access, refresh, expiry
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
