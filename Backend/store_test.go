package main

import "testing"

func f(v float64) *float64 { return &v }

func TestChooseSample(t *testing.T) {
	cfg := ProviderConfig{RoutesEnabled: []Route{RouteInjection, RouteKeychain}, KeychainPollIntervalSec: 60}
	now := int64(1_000)

	if _, route := chooseSample(cfg, nil, now); route != RouteNone {
		t.Fatalf("empty samples route = %s, want none", route)
	}

	injection := routeSample{data: UsageData{UsedPercent5H: f(10)}, asOf: now - 10}
	if got, route := chooseSample(cfg, map[Route]routeSample{RouteInjection: injection}, now); route != RouteInjection || *got.data.UsedPercent5H != 10 {
		t.Fatalf("injection-only = (%v, %s), want injection", got, route)
	}

	keychain := routeSample{data: UsageData{UsedPercent5H: f(20)}, asOf: now - 700}
	if got, route := chooseSample(cfg, map[Route]routeSample{RouteKeychain: keychain}, now); route != RouteKeychain || *got.data.UsedPercent5H != 20 {
		t.Fatalf("keychain-only = (%v, %s), want keychain", got, route)
	}

	if _, route := chooseSample(cfg, map[Route]routeSample{RouteInjection: {data: UsageData{UsedPercent5H: f(30)}, asOf: now - 601}, RouteKeychain: keychain}, now); route != RouteInjection {
		t.Fatalf("stale fallback route = %s, want newer injection", route)
	}

	if _, route := chooseSample(cfg, map[Route]routeSample{RouteInjection: injection, RouteKeychain: keychain}, now); route != RouteInjection {
		t.Fatalf("fresh injection route = %s, want injection", route)
	}
}

// Preference must be by freshness, not by the order routes happen to be listed in
// routes_enabled - the Settings UI appends whichever route a user toggles on last,
// so ["keychain", "injection"] must still prefer fresh injection data over keychain.
func TestChooseSampleOrderIndependent(t *testing.T) {
	cfg := ProviderConfig{RoutesEnabled: []Route{RouteKeychain, RouteInjection}, KeychainPollIntervalSec: 60}
	now := int64(1_000)
	injection := routeSample{data: UsageData{UsedPercent5H: f(10)}, asOf: now - 10}
	keychain := routeSample{data: UsageData{UsedPercent5H: f(20)}, asOf: now - 700}

	if _, route := chooseSample(cfg, map[Route]routeSample{RouteInjection: injection, RouteKeychain: keychain}, now); route != RouteInjection {
		t.Fatalf("keychain-listed-first with fresh injection = %s, want injection", route)
	}

	stale := routeSample{data: UsageData{UsedPercent5H: f(30)}, asOf: now - 601}
	if _, route := chooseSample(cfg, map[Route]routeSample{RouteInjection: stale, RouteKeychain: keychain}, now); route != RouteInjection {
		t.Fatalf("keychain-listed-first stale fallback = %s, want newer injection", route)
	}
}

// With only Injection enabled (no Keychain to fall back to), a stale-but-real
// push should still be shown - the UI already renders "Updated X ago", so a
// stale sample is strictly more useful than blanking to "no data".
func TestChooseSampleStaleInjectionNoFallback(t *testing.T) {
	cfg := ProviderConfig{RoutesEnabled: []Route{RouteInjection}, KeychainPollIntervalSec: 60}
	now := int64(1_000)
	stale := routeSample{data: UsageData{UsedPercent5H: f(40)}, asOf: now - 601}

	got, route := chooseSample(cfg, map[Route]routeSample{RouteInjection: stale}, now)
	if route != RouteInjection || *got.data.UsedPercent5H != 40 {
		t.Fatalf("stale injection-only = (%v, %s), want stale injection data instead of none", got, route)
	}
}
