package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

type Server struct {
	accountMu         sync.Mutex
	accountCollectors map[string]*Collector
	store             *Store
	collector         *Collector
	configPath        string
	poller            *Poller
	configMu          sync.Mutex
	authToken         string
}

func NewServer(store *Store, collector *Collector, configPath string) *Server {
	store.migrateAccounts()
	s := &Server{store: store, collector: collector, configPath: configPath, accountCollectors: map[string]*Collector{}}
	s.poller = NewPoller(store, collector)
	s.poller.server = s
	return s
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", s.handleStatus)
	mux.HandleFunc("GET /history", s.handleHistory)
	mux.HandleFunc("POST /refresh", s.handleRefresh)
	mux.HandleFunc("GET /accounts", s.handleAccounts)
	mux.HandleFunc("POST /accounts", s.handleAccounts)
	mux.HandleFunc("PATCH /accounts/{id}", s.handleAccount)
	mux.HandleFunc("DELETE /accounts/{id}", s.handleAccount)
	mux.HandleFunc("POST /accounts/{id}/reset-credentials", s.handleResetCredentials)
	mux.HandleFunc("POST /test-route", s.handleTestRoute)
	mux.HandleFunc("GET /config", s.handleGetConfig)
	mux.HandleFunc("PUT /config", s.handlePutConfig)
	mux.HandleFunc("GET /errors", s.handleErrors)
	mux.HandleFunc("POST /ingest/claude", s.handleIngestClaude)
	mux.HandleFunc("POST /ingest/antigravity", s.handleIngestAntigravity)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.authToken == "" || subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Auth-Token")), []byte(s.authToken)) != 1 {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		if r.Method == http.MethodGet && (r.URL.Path == "/status" || r.URL.Path == "/accounts") {
			s.store.noteAppPresence(time.Now())
		}
		mux.ServeHTTP(w, r)
	})
}

func (s *Server) handleStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, s.status())
}

func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	var req struct {
		AccountID string `json:"accountId"`
	}
	if r.Body != nil {
		d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
		d.DisallowUnknownFields()
		err := d.Decode(&req)
		if err != io.EOF && (err != nil || d.Decode(new(any)) != io.EOF) {
			http.Error(w, "invalid JSON", 400)
			return
		}
	}
	if req.AccountID != "" {
		if _, ok := s.store.account(req.AccountID); !ok {
			http.Error(w, "unknown account", 404)
			return
		}
	}
	var wg sync.WaitGroup
	for _, a := range s.store.Config().Accounts {
		if req.AccountID == "" || a.ID == req.AccountID {
			wg.Add(1)
			go func(a AccountConfig) {
				defer wg.Done()
				defer s.store.recoverPollPanic(ProviderID(a.ID), "")
				s.pollProvider(r.Context(), ProviderID(a.ID))
			}(a)
		}
	}
	wg.Wait()
	writeJSON(w, s.status())
}

type testRouteRequest struct {
	AccountID string     `json:"accountId"`
	Provider  ProviderID `json:"provider"`
	Route     Route      `json:"route"`
}

type testRouteResponse struct {
	AccountID string     `json:"accountId,omitempty"`
	OK        bool       `json:"ok"`
	Provider  ProviderID `json:"provider"`
	Route     Route      `json:"route"`
	Message   string     `json:"message,omitempty"`
}

func (s *Server) handleTestRoute(w http.ResponseWriter, r *http.Request) {
	var req testRouteRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		http.Error(w, "expected one JSON object", http.StatusBadRequest)
		return
	}
	if req.Provider != ProviderClaude && req.Provider != ProviderCodex && req.Provider != ProviderAntigravity {
		http.Error(w, "invalid provider", http.StatusBadRequest)
		return
	}
	if req.Route != RouteKeychain && req.Route != RouteInjection {
		http.Error(w, "invalid route", http.StatusBadRequest)
		return
	}
	a, ok := s.store.account(req.AccountID)
	if !ok || a.Provider != req.Provider {
		http.Error(w, "invalid or mismatched accountId", 400)
		return
	}
	key := ProviderID(a.ID)
	result := testRouteResponse{AccountID: a.ID, Provider: req.Provider, Route: req.Route}
	if s.store.Config().CollectionPaused {
		result.Message = "Collection is paused."
		writeJSON(w, result)
		return
	}
	if req.Route == RouteInjection && req.Provider != ProviderCodex {
		result.OK = s.store.RouteFresh(key, req.Route, time.Now().Unix())
		result.Message = "Push-only route: the daemon cannot trigger a push; no recent quota push has been received."
		if result.OK {
			result.Message = "Push-only route: the daemon cannot trigger a push; a recent quota push has been received."
		}
		writeJSON(w, result)
		return
	}
	started, available := s.store.beginPoll(key, req.Route)
	if !available {
		result.Message = "Collection paused, credentials resetting, or route poll already in flight."
		writeJSON(w, result)
		return
	}
	defer s.store.endPoll(key, req.Route)
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	data, err := s.fetchAccount(ctx, a, req.Route)
	if err == nil && !s.store.SetSampleAt(key, req.Route, data, started) {
		err = errors.New("Fetch returned invalid, empty, or older quota data.")
	}
	s.store.recordPoll(key, data, err)
	if err != nil {
		result.Message = redactMessage(err.Error())
	} else {
		result.OK = true
	}
	// Failed diagnostics update health, but never alter samples or headline errors.
	writeJSON(w, result)
}

func (s *Server) handleGetConfig(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, s.store.Config())
}

func (s *Server) handlePutConfig(w http.ResponseWriter, r *http.Request) {
	var patch partialConfig
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&patch); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	s.configMu.Lock()
	defer s.configMu.Unlock()
	cfg, err := mergePartialConfig(s.store.Config(), patch)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := saveConfig(s.configPath, cfg); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	s.store.SetConfig(cfg)
	s.poller.Reschedule(cfg)
	writeJSON(w, cfg)
}

func (s *Server) handleErrors(w http.ResponseWriter, r *http.Request) {
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil {
			limit = n
		}
	}
	writeJSON(w, map[string]any{"errors": s.store.Errors(limit)})
}

func (s *Server) handleIngestClaude(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	raw, _ := io.ReadAll(io.LimitReader(r.Body, 2<<20))
	key, matched := s.ingestAccount(ProviderClaude, raw)
	if !matched {
		writeJSON(w, map[string]bool{"ok": true})
		return
	}
	data, ok, err := parseClaudeIngest(raw)
	if err != nil {
		s.store.AddError(key, RouteInjection, "claude ingest parse failed: "+err.Error())
	} else if ok {
		s.store.SetSampleAt(key, RouteInjection, data, started)
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handleIngestAntigravity(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	raw, _ := io.ReadAll(io.LimitReader(r.Body, 2<<20))
	key, matched := s.ingestAccount(ProviderAntigravity, raw)
	if !matched {
		writeJSON(w, map[string]bool{"ok": true})
		return
	}
	data, ok, err := parseAntigravityIngest(raw)
	if err != nil {
		s.store.AddError(key, RouteInjection, "antigravity ingest parse failed: "+err.Error())
	} else if ok {
		s.store.SetSampleAt(key, RouteInjection, data, started)
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) fetchAccount(ctx context.Context, a AccountConfig, route Route) (UsageData, error) {
	c := s.collectorFor(a)
	switch a.Provider {
	case ProviderClaude:
		return c.FetchClaudeWithMode(ctx, s.store.Config().ClaudePollingMode)
	case ProviderAntigravity:
		return c.FetchAntigravity(ctx)
	case ProviderCodex:
		if route == RouteInjection {
			return c.FetchCodexAtCached(ctx, c.configDir)
		}
		return c.FetchCodexKeychain(ctx)
	}
	return UsageData{}, errUnknownProvider
}
func (s *Server) pollProvider(ctx context.Context, key ProviderID) {
	a, ok := s.store.account(string(key))
	if !ok {
		a, ok = s.store.account(defaultAccountID(key))
	}
	if !ok {
		return
	}
	if a.Provider == ProviderClaude && s.store.Config().ClaudePollingMode == "disabled" {
		return
	}
	key = ProviderID(a.ID)
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	for _, route := range providerConfig(s.store.Config(), a.Provider).RoutesEnabled {
		if route == RouteInjection && a.Provider != ProviderCodex {
			continue
		}
		func() {
			defer s.store.recoverPollPanic(key, route)
			started, ok := s.store.beginPoll(key, route)
			if !ok {
				return
			}
			defer s.store.endPoll(key, route)
			data, err := s.fetchAccount(ctx, a, route)
			if err == nil && !s.store.SetSampleAt(key, route, data, started) {
				err = errors.New("Fetch returned invalid, empty, or older quota data.")
			}
			s.store.recordPoll(key, data, err)
			if err != nil {
				s.store.AddError(key, route, err.Error())
			}
		}()
	}
}

// Recover at the route boundary so a bad payload does not stop future ticks.
// Goroutine boundaries also guard panics outside an individual route.
func (s *Store) recoverPollPanic(key ProviderID, route Route) {
	if r := recover(); r != nil {
		s.AddError(key, route, fmt.Sprintf("collector panic: %v", r))
	}
}

func (s *Server) pollCodexRoute(ctx context.Context, route Route, fetch func(context.Context) (UsageData, error)) {
	started, available := s.store.beginPoll(ProviderCodex, route)
	if !available {
		return
	}
	defer s.store.endPoll(ProviderCodex, route)
	data, err := fetch(ctx)
	if err == nil && !s.store.SetSampleAt(ProviderCodex, route, data, started) {
		err = errors.New("Fetch returned invalid, empty, or older quota data.")
	}
	s.store.recordPoll(ProviderCodex, data, err)
	if err != nil {
		s.store.AddError(ProviderCodex, route, err.Error())
		return
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	raw, err := json.Marshal(v)
	if err != nil {
		log.Printf("JSON response encoding failed: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"response encoding failed"}`))
		return
	}
	if _, err := w.Write(append(raw, '\n')); err != nil {
		log.Printf("JSON response write failed: %v", err)
	}
}

func hasRoute(routes []Route, route Route) bool {
	for _, r := range routes {
		if r == route {
			return true
		}
	}
	return false
}

type Poller struct {
	server    *Server
	store     *Store
	collector *Collector
	mu        sync.Mutex
	cancel    context.CancelFunc
	root      context.Context
	stopped   bool
	wg        sync.WaitGroup
}

func NewPoller(store *Store, collector *Collector) *Poller {
	return &Poller{store: store, collector: collector, root: context.Background()}
}

func (p *Poller) Reschedule(cfg Config) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stopped {
		return
	}
	if p.cancel != nil {
		p.cancel()
	}
	ctx, cancel := context.WithCancel(p.root)
	p.cancel = cancel
	if cfg.CollectionPaused {
		return
	}
	for _, a := range cfg.Accounts {
		p.startProvider(ctx, ProviderID(a.ID), providerConfig(cfg, a.Provider))
	}
}

func (p *Poller) startProvider(ctx context.Context, provider ProviderID, cfg ProviderConfig) {
	shouldPoll := hasRoute(cfg.RoutesEnabled, RouteKeychain) || (provider == ProviderCodex || func() bool { a, ok := p.store.account(string(provider)); return ok && a.Provider == ProviderCodex }()) && hasRoute(cfg.RoutesEnabled, RouteInjection)
	if !shouldPoll {
		return
	}
	interval := time.Duration(cfg.KeychainPollIntervalSec) * time.Second
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		defer p.store.recoverPollPanic(provider, "")
		if ctx.Err() != nil {
			return
		}
		p.pollOnce(ctx, provider)
		lastPoll := time.Now()
		for {
			delay, wake := p.store.pollDelay(time.Now(), lastPoll, interval)
			if ctx.Err() != nil {
				return
			}
			if delay <= 0 {
				p.pollOnce(ctx, provider)
				lastPoll = time.Now()
				continue
			}
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-wake:
				timer.Stop()
			case <-timer.C:
			}
		}
	}()
}

func (p *Poller) pollOnce(_ context.Context, provider ProviderID) {
	// Deliberately not derived from the scheduling ctx: Reschedule() cancels
	// that ctx on every config save (even one touching a different provider),
	// which would otherwise abort an in-flight fetch mid-request. The
	// scheduling ctx should only stop future ticks, never abort a fetch
	// that's already running.
	if p.server != nil {
		p.server.pollProvider(context.Background(), provider)
	}
}

func (p *Poller) Stop() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.stopped = true
	if p.cancel != nil {
		p.cancel()
	}
}

var errUnknownProvider = &providerError{"unknown provider"}

type providerError struct{ message string }

func (e *providerError) Error() string { return e.message }

func run(ctx context.Context) error {
	listener, err := net.Listen("tcp", "127.0.0.1:47831")
	if err != nil {
		return err
	}
	defer listener.Close()
	path, err := configPath()
	if err != nil {
		return err
	}
	cfg, err := loadConfig(path)
	if err != nil {
		return err
	}
	if err := saveConfig(path, cfg); err != nil {
		return err
	}
	store := NewStore(cfg)
	if err := store.enablePersistence(filepath.Join(filepath.Dir(path), "samples.json")); err != nil {
		log.Printf("sample restore failed: %v", err)
	}
	server := NewServer(store, NewCollector(), path)
	cfg = store.Config()
	if err := saveConfig(path, cfg); err != nil {
		return err
	}
	store.mu.Lock()
	err = store.persistLocked()
	store.mu.Unlock()
	if err != nil {
		log.Printf("sample migration save failed: %v", err)
	}
	server.authToken, err = createAuthToken(filepath.Join(filepath.Dir(path), "auth-token"))
	if err != nil {
		return err
	}
	server.collector.codexTokens.path = filepath.Join(filepath.Dir(path), "oauth-codex.json")
	server.collector.antigravityTokens.path = filepath.Join(filepath.Dir(path), "oauth-antigravity.json")
	log.Println("quotapeekd listening on 127.0.0.1:47831")
	return server.serve(ctx, listener)
}

// Stop scheduling immediately, then drain HTTP handlers and active polls together.
// Fetch contexts deliberately remain independent of scheduling cancellation so
// token rotation responses can be persisted before exit.
func (s *Server) serve(ctx context.Context, listener net.Listener) error {
	s.poller.root = ctx
	s.poller.Reschedule(s.store.Config())
	httpServer := &http.Server{Handler: s.routes()}
	served := make(chan error, 1)
	go func() { served <- httpServer.Serve(listener) }()
	var serveErr error
	select {
	case <-ctx.Done():
	case serveErr = <-served:
	}
	s.poller.Stop()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pollsDone := make(chan struct{})
	go func() { s.poller.wg.Wait(); close(pollsDone) }()
	shutdownErr := httpServer.Shutdown(shutdownCtx)
	if shutdownErr != nil {
		_ = httpServer.Close()
	}
	select {
	case <-pollsDone:
	case <-shutdownCtx.Done():
		if shutdownErr == nil {
			shutdownErr = shutdownCtx.Err()
		}
	}
	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		return serveErr
	}
	return shutdownErr
}

func (s *Server) status() StatusResponse {
	status := s.store.Status(time.Now().Unix())
	for i := range status.Accounts {
		a := &status.Accounts[i]
		c := s.collectorFor(a.AccountConfig)
		c.mu.Lock()
		info, ok := c.credentials[a.Provider]
		c.mu.Unlock()
		if ok {
			a.CredentialSource = info.source
			if info.account != "" {
				v := info.account
				a.EffectiveAccount = &v
			}
		}
	}
	return status
}

func (s *Server) handleResetCredentials(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	a, ok := s.store.account(id)
	fail := func(code int, message string) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		writeJSON(w, map[string]any{"ok": false, "accountId": id, "provider": a.Provider, "message": redactMessage(message)})
	}
	if !ok {
		fail(404, "Unknown account.")
		return
	}
	key := ProviderID(id)
	if !s.store.beginCredentialReset(key) {
		fail(409, "Account poll or credential reset already in flight.")
		return
	}
	defer s.store.endCredentialReset(key)
	if s.collector == nil {
		fail(500, "Collector unavailable.")
		return
	}
	if err := s.collectorFor(a).resetCredentials(a.Provider); err != nil {
		fail(500, err.Error())
		return
	}
	out := map[string]any{"ok": true, "accountId": id, "provider": a.Provider}
	if a.Provider == ProviderClaude {
		out["message"] = "Claude has no daemon-cached credentials; run the claude CLI to refresh."
	}
	writeJSON(w, out)
}

func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request) {
	id, route := r.URL.Query().Get("accountId"), Route(r.URL.Query().Get("route"))
	a, ok := s.store.account(id)
	if !ok || !validSampleKey(a.Provider, route) {
		http.Error(w, "invalid or missing accountId/route", http.StatusBadRequest)
		return
	}
	writeJSON(w, struct {
		Points []HistoryPoint `json:"points"`
	}{s.store.History(ProviderID(id), route, time.Now().Unix())})
}
