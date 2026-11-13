package main

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestChromiumRendererIntegration(t *testing.T) {
	if os.Getenv("RUN_CHROMIUM_INTEGRATION") != "1" {
		t.Skip("set RUN_CHROMIUM_INTEGRATION=1 inside the Chromium image")
	}
	if uid := os.Geteuid(); uid != 10001 {
		t.Fatalf("effective UID = %d, want 10001", uid)
	}

	var externalRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		externalRequests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	argsChannel := make(chan []string, 1)
	renderer := newChromiumRenderer(os.Getenv("CHROMIUM_PATH"), 30*time.Second, maxPDFBytes)
	renderer.observeCommand = func(args []string) {
		select {
		case argsChannel <- args:
		default:
		}
	}

	html := `<!doctype html><html><body><h1>Sandboxed PDF</h1><img src="` + server.URL + `/tracker.png"></body></html>`
	pdf, err := renderer.Render(context.Background(), html)
	if err != nil {
		t.Fatalf("Render() error: %v", err)
	}
	if len(pdf) < 1024 {
		t.Fatalf("PDF length = %d, want at least 1024 bytes", len(pdf))
	}
	if !bytes.HasPrefix(pdf, []byte("%PDF-")) || !bytes.Contains(pdf, []byte("%%EOF")) {
		t.Fatalf("output is not a complete PDF")
	}
	if got := externalRequests.Load(); got != 0 {
		t.Fatalf("external HTTP requests = %d, want 0", got)
	}

	select {
	case args := <-argsChannel:
		for _, arg := range args {
			if strings.HasPrefix(arg, "--no-sandbox") || strings.HasPrefix(arg, "--disable-setuid-sandbox") {
				t.Fatalf("Chromium sandbox disabling argument present: %s", arg)
			}
		}
	case <-time.After(time.Second):
		t.Fatalf("did not observe Chromium command arguments")
	}

	if outputPath := os.Getenv("PDF_OUTPUT_PATH"); outputPath != "" {
		if err := os.WriteFile(outputPath, pdf, 0o600); err != nil {
			t.Fatalf("write PDF evidence: %v", err)
		}
	}
}
