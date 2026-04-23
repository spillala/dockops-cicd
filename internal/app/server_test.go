package app

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/spillalamarri/k8s-release-demo/internal/config"
)

func TestVersionEndpoint(t *testing.T) {
	srv := NewServer(config.Config{
		AppName:     "release-api",
		Environment: "dev",
		Version:     "1.2.3",
		GitSHA:      "abc123",
		BuildTime:   "2026-03-14T10:00:00Z",
	}, log.New(io.Discard, "", 0))

	req := httptest.NewRequest(http.MethodGet, "/version", nil)
	rr := httptest.NewRecorder()

	srv.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rr.Code)
	}

	body := rr.Body.String()
	for _, expected := range []string{"release-api", "1.2.3", "abc123"} {
		if !strings.Contains(body, expected) {
			t.Fatalf("expected response to contain %q, body=%s", expected, body)
		}
	}
}

func TestCacheWarmDisabled(t *testing.T) {
	srv := NewServer(config.Config{
		FeatureCacheWarm: false,
	}, log.New(io.Discard, "", 0))

	req := httptest.NewRequest(http.MethodPost, "/tasks/cache-warm", nil)
	rr := httptest.NewRecorder()

	srv.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusForbidden {
		t.Fatalf("expected status 403, got %d", rr.Code)
	}
}
