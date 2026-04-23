package app

import (
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/spillalamarri/k8s-release-demo/internal/config"
)

type Server struct {
	cfg    config.Config
	logger *log.Logger
}

type versionResponse struct {
	AppName     string `json:"appName"`
	Environment string `json:"environment"`
	Version     string `json:"version"`
	GitSHA      string `json:"gitSha"`
	BuildTime   string `json:"buildTime"`
}

type configResponse struct {
	AppName          string `json:"appName"`
	Environment      string `json:"environment"`
	LogLevel         string `json:"logLevel"`
	FeatureCacheWarm bool   `json:"featureCacheWarm"`
}

type taskResponse struct {
	Status     string `json:"status"`
	Task       string `json:"task"`
	ExecutedAt string `json:"executedAt"`
}

func NewServer(cfg config.Config, logger *log.Logger) *Server {
	return &Server{cfg: cfg, logger: logger}
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/readyz", s.handleReady)
	mux.HandleFunc("/version", s.handleVersion)
	mux.HandleFunc("/config", s.handleConfig)
	mux.HandleFunc("/tasks/cache-warm", s.handleCacheWarm)
	return s.loggingMiddleware(mux)
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleReady(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) handleVersion(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, versionResponse{
		AppName:     s.cfg.AppName,
		Environment: s.cfg.Environment,
		Version:     s.cfg.Version,
		GitSHA:      s.cfg.GitSHA,
		BuildTime:   s.cfg.BuildTime,
	})
}

func (s *Server) handleConfig(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, configResponse{
		AppName:          s.cfg.AppName,
		Environment:      s.cfg.Environment,
		LogLevel:         s.cfg.LogLevel,
		FeatureCacheWarm: s.cfg.FeatureCacheWarm,
	})
}

func (s *Server) handleCacheWarm(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	if !s.cfg.FeatureCacheWarm {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "cache warm task disabled"})
		return
	}

	s.logger.Printf("task=cache-warm env=%s source=api", s.cfg.Environment)
	writeJSON(w, http.StatusAccepted, taskResponse{
		Status:     "accepted",
		Task:       "cache-warm",
		ExecutedAt: time.Now().UTC().Format(time.RFC3339),
	})
}

func (s *Server) loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.logger.Printf("method=%s path=%s remote=%s", r.Method, r.URL.Path, r.RemoteAddr)
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
