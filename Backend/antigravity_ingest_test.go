package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Regression test for the Antigravity real-time "Injection" hook path: a
// daemon_token account (Antigravity never has a config_dir) must still be
// matched by ingestAccount, and POST /ingest/antigravity must actually record
// the sample instead of silently dropping it.
func TestIngestAntigravityMatchesDaemonTokenAccount(t *testing.T) {
	cfg := defaultConfig()
	cfg.Accounts = []AccountConfig{legacyAccount(ProviderAntigravity)}
	store := NewStore(cfg)
	server := NewServer(store, nil, "")

	server.authToken = "test-secret"
	body := `{"accountId":"","quota":{"gemini-5h":{"remaining_fraction":0.6,"reset_in_seconds":3600}}}`
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/ingest/antigravity", strings.NewReader(body))
	r.Header.Set("X-Auth-Token", server.authToken)
	server.routes().ServeHTTP(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if errs := store.Errors(50); len(errs) != 0 {
		t.Fatalf("expected no ingest errors, got %+v", errs)
	}

	id := ProviderID(defaultAccountID(ProviderAntigravity))
	sample, ok := store.samples[id][RouteInjection]
	if !ok || sample.data.UsedPercent5H == nil {
		t.Fatalf("sample not recorded for %s: %+v", id, store.samples[id])
	}
	if *sample.data.UsedPercent5H != 40 {
		t.Fatalf("UsedPercent5H = %v, want 40", *sample.data.UsedPercent5H)
	}
}

// Accounts added in Settings get random ids, and the agy hook sends none:
// its pushes must reach the sole Antigravity account, not be dropped for
// not being the default id. With several accounts there's no way to tell,
// so they're dropped with an error saying why.
func TestIngestAntigravityMatchesSoleAddedAccount(t *testing.T) {
	added := AccountConfig{ID: "acct_c19a2fa702d0096d4325b3bc5824bbd0", Provider: ProviderAntigravity, Label: "Prsnl", CredentialLocation: CredentialLocation{Kind: "daemon_token"}}
	body := `{"accountId":"","quota":{"gemini-5h":{"remaining_fraction":0.6,"reset_in_seconds":3600}}}`
	post := func(accounts ...AccountConfig) *Store {
		cfg := defaultConfig()
		cfg.Accounts = accounts
		store := NewStore(cfg)
		server := NewServer(store, nil, "")
		server.authToken = "test-secret"
		r := httptest.NewRequest(http.MethodPost, "/ingest/antigravity", strings.NewReader(body))
		r.Header.Set("X-Auth-Token", server.authToken)
		server.routes().ServeHTTP(httptest.NewRecorder(), r)
		return store
	}

	store := post(added, legacyAccount(ProviderClaude))
	if errs := store.Errors(50); len(errs) != 0 {
		t.Fatalf("expected no ingest errors, got %+v", errs)
	}
	if s, ok := store.samples[ProviderID(added.ID)][RouteInjection]; !ok || s.data.UsedPercent5H == nil || *s.data.UsedPercent5H != 40 {
		t.Fatalf("sample not recorded for the sole account: %+v", store.samples[ProviderID(added.ID)])
	}

	other := added
	other.ID = "acct_second"
	store = post(added, other)
	if _, ok := store.samples[ProviderID(added.ID)][RouteInjection]; ok {
		t.Fatal("ambiguous push must not be recorded")
	}
	if errs := store.Errors(50); len(errs) != 1 || !strings.Contains(errs[0].Message, "several Antigravity accounts") {
		t.Fatalf("expected an ambiguity error, got %+v", errs)
	}
}

// A push carrying an accountId that doesn't match any known Antigravity
// account must be dropped with an ErrorEntry, not silently accepted or
// mis-routed to the default account.
func TestIngestAntigravityUnknownAccountIDDropped(t *testing.T) {
	cfg := defaultConfig()
	cfg.Accounts = []AccountConfig{legacyAccount(ProviderAntigravity)}
	store := NewStore(cfg)
	server := NewServer(store, nil, "")

	server.authToken = "test-secret"
	body := `{"accountId":"acct_does_not_exist","quota":{"gemini-5h":{"remaining_fraction":0.6,"reset_in_seconds":3600}}}`
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/ingest/antigravity", strings.NewReader(body))
	r.Header.Set("X-Auth-Token", server.authToken)
	server.routes().ServeHTTP(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	id := ProviderID(defaultAccountID(ProviderAntigravity))
	if sample, ok := store.samples[id][RouteInjection]; ok {
		t.Fatalf("sample should not have been recorded: %+v", sample)
	}
	errs := store.Errors(50)
	if len(errs) != 1 || !strings.Contains(errs[0].Message, "no matching account") {
		t.Fatalf("expected a dropped-ingest error, got %+v", errs)
	}
}
