package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

type Server struct {
	store      *Store
	collector  *Collector
	configPath string
	poller     *Poller
	configMu   sync.Mutex
	authToken  string
}

func NewServer(store *Store, collector *Collector, configPath string) *Server {
	s := &Server{store: store, collector: collector, configPath: configPath}
	s.poller = NewPoller(store, collector)
	return s
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", s.handleStatus)
	mux.HandleFunc("GET /history", s.handleHistory)
	mux.HandleFunc("POST /refresh", s.handleRefresh)
	mux.HandleFunc("POST /providers/{name}/reset-credentials", s.handleResetCredentials)
	mux.HandleFunc("POST /test-route", s.handleTestRoute)
	mux.HandleFunc("GET /config", s.handleGetConfig)
	mux.HandleFunc("PUT /config", s.handlePutConfig)
	mux.HandleFunc("GET /errors", s.handleErrors)
	mux.HandleFunc("POST /ingest/claude", s.handleIngestClaude)
	mux.HandleFunc("POST /ingest/antigravity", s.handleIngestAntigravity)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/status" && (s.authToken == "" || subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Auth-Token")), []byte(s.authToken)) != 1) {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func (s *Server) handleStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, s.status())
}

func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	cfg := s.store.Config()
	var wg sync.WaitGroup
	if hasRoute(cfg.Claude.RoutesEnabled, RouteKeychain) {
		wg.Add(1)
		go func() { defer wg.Done(); s.pollProvider(r.Context(), ProviderClaude) }()
	}
	if hasRoute(cfg.Antigravity.RoutesEnabled, RouteKeychain) {
		wg.Add(1)
		go func() { defer wg.Done(); s.pollProvider(r.Context(), ProviderAntigravity) }()
	}
	if hasRoute(cfg.Codex.RoutesEnabled, RouteInjection) || hasRoute(cfg.Codex.RoutesEnabled, RouteKeychain) {
		wg.Add(1)
		go func() { defer wg.Done(); s.pollProvider(r.Context(), ProviderCodex) }()
	}
	wg.Wait()
	writeJSON(w, s.status())
}

type testRouteRequest struct {
	Provider ProviderID `json:"provider"`
	Route    Route      `json:"route"`
}

type testRouteResponse struct {
	OK       bool       `json:"ok"`
	Provider ProviderID `json:"provider"`
	Route    Route      `json:"route"`
	Message  string     `json:"message,omitempty"`
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
	result := testRouteResponse{Provider: req.Provider, Route: req.Route}
	if s.store.Config().CollectionPaused {
		result.Message = "Collection is paused."
		writeJSON(w, result)
		return
	}
	if req.Route == RouteInjection && req.Provider != ProviderCodex {
		result.OK = s.store.RouteFresh(req.Provider, req.Route, time.Now().Unix())
		result.Message = "Push-only route: the daemon cannot trigger a push; no recent quota push has been received."
		if result.OK {
			result.Message = "Push-only route: the daemon cannot trigger a push; a recent quota push has been received."
		}
		writeJSON(w, result)
		return
	}
	started, available := s.store.beginPoll(req.Provider, req.Route)
	if !available {
		result.Message = "Collection paused, credentials resetting, or route poll already in flight."
		writeJSON(w, result)
		return
	}
	defer s.store.endPoll(req.Provider, req.Route)
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	var data UsageData
	var err error
	switch req.Provider {
	case ProviderClaude:
		data, err = s.collector.FetchClaudeWithMode(ctx, s.store.Config().ClaudePollingMode)
	case ProviderAntigravity:
		data, err = s.collector.FetchAntigravity(ctx)
	case ProviderCodex:
		if req.Route == RouteKeychain {
			data, err = s.collector.FetchCodexKeychain(ctx)
		} else {
			data, err = FetchCodex(ctx)
		}
	}
	s.store.recordPoll(req.Provider, data, err)
	if err != nil {
		result.Message = redactMessage(err.Error())
	} else if data.quotaEmpty() {
		result.Message = "Fetch returned no quota data."
	} else {
		result.OK = true
		s.store.SetSampleAt(req.Provider, req.Route, data, started)
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
	data, ok, err := parseClaudeIngest(raw)
	if err != nil {
		s.store.AddError(ProviderClaude, RouteInjection, "claude ingest parse failed: "+err.Error())
	} else if ok {
		s.store.SetSampleAt(ProviderClaude, RouteInjection, data, started)
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handleIngestAntigravity(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	raw, _ := io.ReadAll(io.LimitReader(r.Body, 2<<20))
	data, ok, err := parseAntigravityIngest(raw)
	if err != nil {
		s.store.AddError(ProviderAntigravity, RouteInjection, "antigravity ingest parse failed: "+err.Error())
	} else if ok {
		s.store.SetSampleAt(ProviderAntigravity, RouteInjection, data, started)
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) pollProvider(ctx context.Context, provider ProviderID) {
	if provider == ProviderClaude && s.store.Config().ClaudePollingMode == "disabled" {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	if provider == ProviderCodex {
		cfg := s.store.Config().Codex
		if hasRoute(cfg.RoutesEnabled, RouteInjection) {
			s.pollCodexRoute(ctx, RouteInjection, FetchCodex)
		}
		if hasRoute(cfg.RoutesEnabled, RouteKeychain) {
			s.pollCodexRoute(ctx, RouteKeychain, s.collector.FetchCodexKeychain)
		}
		return
	}

	started, available := s.store.beginPoll(provider, RouteKeychain)
	if !available {
		return
	}
	defer s.store.endPoll(provider, RouteKeychain)
	var data UsageData
	var err error
	switch provider {
	case ProviderClaude:
		data, err = s.collector.FetchClaudeWithMode(ctx, s.store.Config().ClaudePollingMode)
	case ProviderAntigravity:
		data, err = s.collector.FetchAntigravity(ctx)
	default:
		err = errUnknownProvider
	}
	s.store.recordPoll(provider, data, err)
	if err != nil {
		s.store.AddError(provider, RouteKeychain, err.Error())
		return
	}
	s.store.SetSampleAt(provider, RouteKeychain, data, started)
}

func (s *Server) pollCodexRoute(ctx context.Context, route Route, fetch func(context.Context) (UsageData, error)) {
	started, available := s.store.beginPoll(ProviderCodex, route)
	if !available {
		return
	}
	defer s.store.endPoll(ProviderCodex, route)
	data, err := fetch(ctx)
	s.store.recordPoll(ProviderCodex, data, err)
	if err != nil {
		s.store.AddError(ProviderCodex, route, err.Error())
		return
	}
	s.store.SetSampleAt(ProviderCodex, route, data, started)
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
	store     *Store
	collector *Collector
	mu        sync.Mutex
	cancel    context.CancelFunc
}

func NewPoller(store *Store, collector *Collector) *Poller {
	return &Poller{store: store, collector: collector}
}

func (p *Poller) Reschedule(cfg Config) {
	p.mu.Lock()
	if p.cancel != nil {
		p.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	p.cancel = cancel
	p.mu.Unlock()
	if cfg.CollectionPaused {
		return
	}
	p.startProvider(ctx, ProviderClaude, cfg.Claude)
	p.startProvider(ctx, ProviderCodex, cfg.Codex)
	p.startProvider(ctx, ProviderAntigravity, cfg.Antigravity)
}

func (p *Poller) startProvider(ctx context.Context, provider ProviderID, cfg ProviderConfig) {
	shouldPoll := hasRoute(cfg.RoutesEnabled, RouteKeychain) || provider == ProviderCodex && hasRoute(cfg.RoutesEnabled, RouteInjection)
	if !shouldPoll {
		return
	}
	interval := time.Duration(cfg.KeychainPollIntervalSec) * time.Second
	go func() {
		if ctx.Err() != nil {
			return
		}
		p.pollOnce(ctx, provider)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if ctx.Err() != nil {
					return
				}
				p.pollOnce(ctx, provider)
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
	s := Server{store: p.store, collector: p.collector}
	s.pollProvider(context.Background(), provider)
}

func (p *Poller) Stop() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cancel != nil {
		p.cancel()
	}
}

var errUnknownProvider = &providerError{"unknown provider"}

type providerError struct{ message string }

func (e *providerError) Error() string { return e.message }

func run() error {
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
	server.authToken, err = createAuthToken(filepath.Join(filepath.Dir(path), "auth-token"))
	if err != nil {
		return err
	}
	server.collector.codexTokens.path = filepath.Join(filepath.Dir(path), "oauth-codex.json")
	server.collector.antigravityTokens.path = filepath.Join(filepath.Dir(path), "oauth-antigravity.json")
	server.poller.Reschedule(cfg)
	log.Println("aiusaged listening on 127.0.0.1:47831")
	return http.ListenAndServe("127.0.0.1:47831", server.routes())
}

func (s *Server) status() StatusResponse {
	status := s.store.Status(time.Now().Unix())
	if s.collector != nil {
		status = s.collector.decorateStatus(status)
	}
	return status
}
func (s *Server) handleResetCredentials(w http.ResponseWriter, r *http.Request) {
	id := ProviderID(r.PathValue("name"))
	fail := func(code int, message string) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		writeJSON(w, map[string]any{"ok": false, "provider": id, "message": redactMessage(message)})
	}
	if id != ProviderClaude && id != ProviderCodex && id != ProviderAntigravity {
		fail(404, "Unknown provider.")
		return
	}
	if !s.store.beginCredentialReset(id) {
		fail(409, "Provider poll or credential reset already in flight.")
		return
	}
	defer s.store.endCredentialReset(id)
	if s.collector == nil {
		fail(500, "Collector unavailable.")
		return
	}
	if err := s.collector.resetCredentials(id); err != nil {
		fail(500, err.Error())
		return
	}
	writeJSON(w, map[string]any{"ok": true, "provider": id})
}

func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request) {
	provider, route := ProviderID(r.URL.Query().Get("provider")), Route(r.URL.Query().Get("route"))
	if !validSampleKey(provider, route) {
		http.Error(w, "invalid or missing provider/route", http.StatusBadRequest)
		return
	}
	writeJSON(w, struct {
		Points []HistoryPoint `json:"points"`
	}{s.store.History(provider, route, time.Now().Unix())})
}
