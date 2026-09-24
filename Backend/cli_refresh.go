package main

import (
	"context"
	"errors"
	"io"
	"log"
	"time"
)

func runCLI(ctx context.Context, bin string, args ...string) error {
	cmd := providerCommand(ctx, bin, args...)
	cmd.Env = collectorEnv(ctx)
	cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
	return cmd.Run()
}

func (c *Collector) triggerCLILogin(ctx context.Context, provider ProviderID) bool {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	var bin string
	args := []string{"-p", "Hi"}
	switch provider {
	case ProviderClaude:
		bin = claudeBin()
	case ProviderCodex:
		bin, args = codexBin(), []string{"exec", "--skip-git-repo-check", "Hi"}
	case ProviderAntigravity:
		var err error
		bin, err = locateAntigravityBinary()
		if err != nil {
			log.Printf("%s CLI session refresh unavailable: %v", provider, err)
			return false
		}
	}
	if err := c.runCLI(ctx, bin, args...); err != nil {
		log.Printf("%s CLI session refresh failed: %v", provider, err)
		return false
	}
	return true
}

func (c *Collector) fetchWithCLIRefresh(ctx context.Context, provider ProviderID, cache *oauthTokenCache, fetch func() (UsageData, error)) (UsageData, error) {
	data, err := fetch()
	if !errors.Is(err, errWaitingForToken) || ctx.Err() != nil || !cache.beginCLITrigger() {
		return data, err
	}
	c.triggerCLILogin(ctx, provider)
	if ctx.Err() != nil {
		return data, err
	}
	return fetch()
}
