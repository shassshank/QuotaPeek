package main

import (
	"sync"
	"time"
)

// keychainCache caches raw keychain reads (and similar credential lookups) to
// avoid re-spawning /usr/bin/security or other subprocess-based credential
// fetches on every poll tick. Entries are keyed by a string (e.g.
// "claude:keychain-service" or "antigravity:keychain") and evicted when their
// TTL expires, the credential's own expiry is near, or a credential reset
// invalidates the entry.
type keychainCache struct {
	mu      sync.Mutex
	entries map[string]*keychainEntry
}

type keychainEntry struct {
	raw       []byte
	fetchedAt time.Time
	expiresAt time.Time // zero means use TTL only
}

// get returns a cached credential if it exists and is still valid. A zero
// expiresAt means the entry has no intrinsic expiry and relies solely on the
// TTL. We consider a credential "near expiry" if it expires within 2 minutes.
func (kc *keychainCache) get(key string, ttl time.Duration) ([]byte, bool) {
	kc.mu.Lock()
	defer kc.mu.Unlock()
	e, ok := kc.entries[key]
	if !ok {
		return nil, false
	}
	now := time.Now()
	// Evict if past the TTL.
	if now.Sub(e.fetchedAt) > ttl {
		delete(kc.entries, key)
		return nil, false
	}
	// Evict if the credential's own expiry is near (within 2 minutes).
	if !e.expiresAt.IsZero() && now.Add(2*time.Minute).After(e.expiresAt) {
		delete(kc.entries, key)
		return nil, false
	}
	return e.raw, true
}

// put stores a credential in the cache. expiresAt may be zero if the
// credential has no intrinsic expiry.
func (kc *keychainCache) put(key string, raw []byte, expiresAt time.Time) {
	kc.mu.Lock()
	defer kc.mu.Unlock()
	if kc.entries == nil {
		kc.entries = make(map[string]*keychainEntry)
	}
	kc.entries[key] = &keychainEntry{
		raw:       raw,
		fetchedAt: time.Now(),
		expiresAt: expiresAt,
	}
}

// invalidate removes a cached credential by key.
func (kc *keychainCache) invalidate(key string) {
	kc.mu.Lock()
	defer kc.mu.Unlock()
	delete(kc.entries, key)
}

// invalidateAll removes all cached credentials.
func (kc *keychainCache) invalidateAll() {
	kc.mu.Lock()
	defer kc.mu.Unlock()
	kc.entries = nil
}

// codexSubprocessCache caches the result of a FetchCodexAt call to avoid
// respawning the codex app-server subprocess on every poll tick.
type codexSubprocessCache struct {
	mu        sync.Mutex
	data      UsageData
	fetchedAt time.Time
	configDir string
	valid     bool
}

const codexSubprocessTTL = 5 * time.Minute

func (cc *codexSubprocessCache) get(configDir string) (UsageData, bool) {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	if !cc.valid || cc.configDir != configDir {
		return UsageData{}, false
	}
	if time.Since(cc.fetchedAt) > codexSubprocessTTL {
		cc.valid = false
		return UsageData{}, false
	}
	return cc.data, true
}

func (cc *codexSubprocessCache) put(configDir string, data UsageData) {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	cc.data = data
	cc.fetchedAt = time.Now()
	cc.configDir = configDir
	cc.valid = true
}

func (cc *codexSubprocessCache) invalidate() {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	cc.valid = false
}
