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
