package main

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"
)

type Server struct {
	store      *Store
	collector  *Collector
	configPath string
	poller     *Poller
}

func NewServer(store *Store, collector *Collector, configPath string) *Server {
	s := &Server{store: store, collector: collector, configPath: configPath}
	s.poller = NewPoller(store, collector)
	return s
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", s.handleStatus)
	mux.HandleFunc("POST /refresh", s.handleRefresh)
	mux.HandleFunc("GET /config", s.handleGetConfig)
	mux.HandleFunc("PUT /config", s.handlePutConfig)
	mux.HandleFunc("GET /errors", s.handleErrors)
	mux.HandleFunc("POST /ingest/claude", s.handleIngestClaude)
	mux.HandleFunc("POST /ingest/antigravity", s.handleIngestAntigravity)
	return mux
}

func (s *Server) handleStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, s.store.Status(time.Now().Unix()))
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
	writeJSON(w, s.store.Status(time.Now().Unix()))
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
	raw, _ := io.ReadAll(io.LimitReader(r.Body, 2<<20))
	data, ok, err := parseClaudeIngest(raw)
	if err != nil {
		s.store.AddError(ProviderClaude, RouteInjection, "claude ingest parse failed: "+err.Error())
	} else if ok {
		s.store.SetSample(ProviderClaude, RouteInjection, data, time.Now().Unix())
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handleIngestAntigravity(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(io.LimitReader(r.Body, 2<<20))
	data, ok, err := parseAntigravityIngest(raw)
	if err != nil {
		s.store.AddError(ProviderAntigravity, RouteInjection, "antigravity ingest parse failed: "+err.Error())
	} else if ok {
		s.store.SetSample(ProviderAntigravity, RouteInjection, data, time.Now().Unix())
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) pollProvider(ctx context.Context, provider ProviderID) {
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

	var data UsageData
	var err error
	switch provider {
	case ProviderClaude:
		data, err = s.collector.FetchClaude(ctx)
	case ProviderAntigravity:
		data, err = s.collector.FetchAntigravity(ctx)
	default:
		err = errUnknownProvider
	}
	if err != nil {
		s.store.AddError(provider, RouteKeychain, err.Error())
		return
	}
	s.store.SetSample(provider, RouteKeychain, data, time.Now().Unix())
}

func (s *Server) pollCodexRoute(ctx context.Context, route Route, fetch func(context.Context) (UsageData, error)) {
	data, err := fetch(ctx)
	if err != nil {
		s.store.AddError(ProviderCodex, route, err.Error())
		return
	}
	s.store.SetSample(ProviderCodex, route, data, time.Now().Unix())
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
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
		p.pollOnce(ctx, provider)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				p.pollOnce(ctx, provider)
			}
		}
	}()
}

func (p *Poller) pollOnce(ctx context.Context, provider ProviderID) {
	s := Server{store: p.store, collector: p.collector}
	s.pollProvider(ctx, provider)
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
	server := NewServer(store, NewCollector(), path)
	server.poller.Reschedule(cfg)
	log.Println("aiusaged listening on 127.0.0.1:47831")
	return http.ListenAndServe("127.0.0.1:47831", server.routes())
}
