package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
)

func probe(t *testing.T, s *Server, body string, status int) testRouteResponse {
	t.Helper()
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/test-route", strings.NewReader(body)))
	if w.Code != status {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var result testRouteResponse
	if status == 200 {
		if w.Header().Get("Content-Type") != "application/json" {
			t.Fatal("not JSON")
		}
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		var fields map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &fields); err != nil {
			t.Fatal(err)
		}
		if _, ok := fields["ok"].(bool); !ok {
			t.Fatal("missing boolean ok")
		}
		if result.Provider == "" || result.Route == "" {
			t.Fatalf("missing response fields: %s", w.Body.String())
		}
	}
	return result
}

func TestTestRouteValidation(t *testing.T) {
	s := NewServer(NewStore(defaultConfig()), nil, "")
	for _, body := range []string{`{"provider":"garbage","route":"keychain"}`, `{"provider":"claude","route":"none"}`, `{"provider":"claude","route":"garbage"}`, `{}`, `null`, `broken`, `{"provider":"claude","route":"keychain"} {}`, `{"provider":1,"route":"keychain"}`} {
		probe(t, s, body, 400)
	}
}

func TestTestRouteSynchronous(t *testing.T) {
	for _, success := range []bool{true, false} {
		c := NewCollector()
		reads, requests := 0, 0
		c.readKeychain = func(ctx context.Context, service, account string) ([]byte, error) {
			reads++
			deadline, ok := ctx.Deadline()
			if !ok || time.Until(deadline) > 8*time.Second {
				t.Error("missing short timeout")
			}
			return []byte(`{"claudeAiOauth":{"accessToken":"test"}}`), nil
		}
		c.client = &http.Client{Transport: oauthTestTransport(func(r *http.Request) (*http.Response, error) {
			requests++
			h := make(http.Header)
			h.Set("anthropic-ratelimit-unified-5h-utilization", "0.42")
			status := http.StatusOK
			if !success {
				status = http.StatusUnauthorized
			}
			return &http.Response{StatusCode: status, Header: h, Body: io.NopCloser(strings.NewReader(""))}, nil
		})}
		store := NewStore(defaultConfig())
		store.SetSample(ProviderClaude, RouteInjection, UsageData{UsedPercent5H: f(10)}, time.Now().Unix())
		store.SetSample(ProviderClaude, RouteKeychain, UsageData{UsedPercent5H: f(20)}, time.Now().Unix()-10)
		before := store.Status(time.Now().Unix())
		result := probe(t, NewServer(store, c, ""), `{"provider":"claude","route":"keychain"}`, 200)
		if result.OK != success || result.Provider != ProviderClaude || result.Route != RouteKeychain || reads != 1 || requests != 1 {
			t.Fatalf("unexpected result: %+v reads=%d requests=%d", result, reads, requests)
		}
		if success {
			if *store.samples[ProviderClaude][RouteKeychain].data.UsedPercent5H != 42 {
				t.Fatal("success not stored")
			}
		} else if result.Message == "" || !reflect.DeepEqual(before, store.Status(time.Now().Unix())) || len(store.Errors(50)) != 0 {
			t.Fatal("failure modified status/errors or lacked message")
		}
		if *store.samples[ProviderClaude][RouteInjection].data.UsedPercent5H != 10 {
			t.Fatal("other route modified")
		}
	}
}

func TestTestRoutePushFreshness(t *testing.T) {
	for _, provider := range []ProviderID{ProviderClaude, ProviderAntigravity} {
		for _, age := range []int64{-1, 10, 601} {
			store := NewStore(defaultConfig()) // Injection disabled: still inspect that route.
			store.SetSample(provider, RouteKeychain, UsageData{UsedPercent5H: f(80)}, time.Now().Unix())
			if age >= 0 {
				store.SetSample(provider, RouteInjection, UsageData{UsedPercent5H: f(30)}, time.Now().Unix()-age)
			}
			before := store.Status(time.Now().Unix())
			result := probe(t, NewServer(store, nil, ""), `{"provider":"`+string(provider)+`","route":"injection"}`, 200)
			if result.OK != (age == 10) || !strings.Contains(result.Message, "cannot trigger a push") {
				t.Fatalf("age %d: %+v", age, result)
			}
			if !reflect.DeepEqual(before, store.Status(time.Now().Unix())) {
				t.Fatal("push probe modified status")
			}
		}
	}
}
