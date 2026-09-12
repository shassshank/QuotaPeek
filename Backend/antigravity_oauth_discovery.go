package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"time"
)

// Go binaries pack string constants back-to-back in .rodata with no
// separators between them, so adjacent strings can run directly into each
// other (no whitespace/NUL to anchor a \b word boundary on). These patterns
// intentionally avoid \b and instead match Google's fixed-length formats
// exactly, so a match can't overrun into a neighboring packed string. Any
// wrong extraction just fails to redeem against Google's token endpoint and
// is discarded — see tryRefreshPair, which only ever persists a
// pair once it has actually redeemed a token.
var (
	antigravityClientIDPattern     = regexp.MustCompile(`[0-9]{6,}-[a-z0-9]{20,40}\.apps\.googleusercontent\.com`)
	antigravityClientSecretPattern = regexp.MustCompile(`GOCSPX-[A-Za-z0-9_-]{28}`)
)

// locateAntigravityBinary finds the locally installed Antigravity CLI
// (`agy`), in the same place install.sh finds the other provider CLIs
// before falling back to PATH.
func locateAntigravityBinary() (string, error) {
	if home, err := os.UserHomeDir(); err == nil {
		if p := filepath.Join(home, ".local", "bin", "agy"); fileExists(p) {
			return p, nil
		}
	}
	if p, err := exec.LookPath("agy"); err == nil {
		return p, nil
	}
	return "", errors.New("antigravity CLI (agy) not found locally")
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

// discoverAntigravityOAuthPairs scans the locally installed agy binary for
// its own embedded Google OAuth "installed app" client id/secret strings —
// the same credential every copy of Antigravity ships with. Reading it
// locally, per user, means QuotaPeek never embeds, distributes, or
// maintains this credential itself, and it self-heals if Google/Antigravity
// ever rotates it (refreshAntigravityToken rescans on failure).
func discoverAntigravityOAuthPairs() ([]oauthPair, error) {
	bin, err := locateAntigravityBinary()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(bin)
	if err != nil {
		return nil, errors.New("could not read local antigravity CLI binary")
	}
	return extractAntigravityOAuthPairs(data)
}

// extractAntigravityOAuthPairs returns candidate pairs from embedded binary strings.
func extractAntigravityOAuthPairs(data []byte) ([]oauthPair, error) {
	ids := uniqueMatches(antigravityClientIDPattern, data)
	secrets := uniqueMatches(antigravityClientSecretPattern, data)
	if len(ids) == 0 || len(secrets) == 0 {
		return nil, errors.New("no OAuth client credentials found in local antigravity CLI binary")
	}
	pairs := make([]oauthPair, 0, len(ids)*len(secrets))
	for _, id := range ids {
		for _, secret := range secrets {
			pairs = append(pairs, oauthPair{clientID: id, clientSecret: secret})
		}
	}
	return pairs, nil
}

func uniqueMatches(re *regexp.Regexp, data []byte) []string {
	seen := map[string]struct{}{}
	var out []string
	for _, m := range re.FindAll(data, -1) {
		s := string(m)
		if _, ok := seen[s]; !ok {
			seen[s] = struct{}{}
			out = append(out, s)
		}
	}
	return out
}

// antigravityOAuthCachePath stores the last successfully redeemed pair, so a
// normal poll doesn't rescan the (~180MB) agy binary on every refresh.
func antigravityOAuthCachePath(configDir string) (string, error) {
	if configDir != "" {
		return filepath.Join(configDir, "antigravity-oauth-cache.json"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "Application Support", "QuotaPeek", "antigravity-oauth-cache.json"), nil
}

type persistedAntigravityOAuthPairs struct {
	Pairs [][2]string `json:"pairs"`
	At    time.Time   `json:"discoveredAt"`
}

func loadCachedAntigravityOAuthPairs(path string) ([]oauthPair, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var saved persistedAntigravityOAuthPairs
	if err := json.Unmarshal(raw, &saved); err != nil {
		return nil, err
	}
	pairs := make([]oauthPair, 0, len(saved.Pairs))
	for _, p := range saved.Pairs {
		pairs = append(pairs, oauthPair{clientID: p[0], clientSecret: p[1]})
	}
	return pairs, nil
}

func saveAntigravityOAuthPairs(path string, pairs []oauthPair) error {
	saved := persistedAntigravityOAuthPairs{At: time.Now()}
	for _, p := range pairs {
		saved.Pairs = append(saved.Pairs, [2]string{p.clientID, p.clientSecret})
	}
	raw, err := json.Marshal(saved)
	if err != nil {
		return err
	}
	return atomicPrivateWrite(path, raw)
}
