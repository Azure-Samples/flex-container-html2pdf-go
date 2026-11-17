package main

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type fakeRenderer struct {
	pdf   []byte
	err   error
	html  string
	calls int
}

func (f *fakeRenderer) Render(_ context.Context, html string) ([]byte, error) {
	f.calls++
	f.html = html
	return f.pdf, f.err
}

func TestHello(t *testing.T) {
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		t.Run(method, func(t *testing.T) {
			request := httptest.NewRequest(method, "/api/hello", nil)
			response := httptest.NewRecorder()

			hello(response, request)

			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
			}
			if got := response.Body.String(); got != "Hello from the Go worker." {
				t.Fatalf("body = %q, want exact greeting", got)
			}
		})
	}
}

func TestHTMLToPDFGetUsesBuiltInInvoice(t *testing.T) {
	renderer := &fakeRenderer{pdf: []byte("%PDF-1.7\nunit test\n%%EOF")}
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/html-to-pdf", nil)

	htmlToPDFHandler(renderer)(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d: %s", response.Code, http.StatusOK, response.Body.String())
	}
	if !strings.Contains(renderer.html, "INV-2026-1109") {
		t.Fatalf("built-in invoice was not rendered")
	}
	if got := response.Header().Get("Content-Type"); got != "application/pdf" {
		t.Fatalf("Content-Type = %q, want application/pdf", got)
	}
	if !bytes.HasPrefix(response.Body.Bytes(), []byte("%PDF-")) {
		t.Fatalf("response does not start with PDF signature")
	}
}

func TestHTMLToPDFPostUsesRawHTML(t *testing.T) {
	renderer := &fakeRenderer{pdf: []byte("%PDF-1.7\nunit test\n%%EOF")}
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/html-to-pdf", strings.NewReader("<html><body>Posted invoice</body></html>"))
	request.Header.Set("Content-Type", "text/html; charset=utf-8")

	htmlToPDFHandler(renderer)(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d: %s", response.Code, http.StatusOK, response.Body.String())
	}
	if renderer.html != "<html><body>Posted invoice</body></html>" {
		t.Fatalf("renderer HTML = %q", renderer.html)
	}
}

func TestHTMLToPDFPostAcceptsMissingContentTypeForWorkerCompatibility(t *testing.T) {
	renderer := &fakeRenderer{pdf: []byte("%PDF-1.7\nunit test\n%%EOF")}
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/html-to-pdf", strings.NewReader("<html><body>Worker compatibility</body></html>"))

	htmlToPDFHandler(renderer)(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d: %s", response.Code, http.StatusOK, response.Body.String())
	}
	if renderer.calls != 1 {
		t.Fatalf("renderer calls = %d, want 1", renderer.calls)
	}
}

func TestHTMLToPDFRejectsInvalidRequests(t *testing.T) {
	tests := []struct {
		name        string
		method      string
		contentType string
		body        string
		wantStatus  int
	}{
		{name: "method", method: http.MethodPut, wantStatus: http.StatusMethodNotAllowed},
		{name: "media type", method: http.MethodPost, contentType: "application/json", body: "{}", wantStatus: http.StatusUnsupportedMediaType},
		{name: "empty", method: http.MethodPost, contentType: "text/html", body: "  ", wantStatus: http.StatusBadRequest},
		{name: "compressed", method: http.MethodPost, contentType: "text/html", body: "<html></html>", wantStatus: http.StatusUnsupportedMediaType},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			renderer := &fakeRenderer{pdf: []byte("%PDF-1.7\n%%EOF")}
			response := httptest.NewRecorder()
			request := httptest.NewRequest(test.method, "/api/html-to-pdf", strings.NewReader(test.body))
			if test.contentType != "" {
				request.Header.Set("Content-Type", test.contentType)
			}
			if test.name == "compressed" {
				request.Header.Set("Content-Encoding", "gzip")
			}

			htmlToPDFHandler(renderer)(response, request)

			if response.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d", response.Code, test.wantStatus)
			}
			if renderer.calls != 0 {
				t.Fatalf("renderer calls = %d, want 0", renderer.calls)
			}
		})
	}
}

func TestHTMLToPDFRejectsOversizedBody(t *testing.T) {
	renderer := &fakeRenderer{pdf: []byte("%PDF-1.7\n%%EOF")}
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/html-to-pdf", strings.NewReader(strings.Repeat("x", maxHTMLBytes+1)))
	request.Header.Set("Content-Type", "text/html")

	htmlToPDFHandler(renderer)(response, request)

	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusRequestEntityTooLarge)
	}
	if renderer.calls != 0 {
		t.Fatalf("renderer calls = %d, want 0", renderer.calls)
	}
}

func TestHTMLToPDFSurfacesRenderTimeout(t *testing.T) {
	renderer := &fakeRenderer{err: context.DeadlineExceeded}
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/html-to-pdf", nil)

	htmlToPDFHandler(renderer)(response, request)

	if response.Code != http.StatusGatewayTimeout {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusGatewayTimeout)
	}
}

func TestHTMLToPDFRejectsInvalidRendererOutput(t *testing.T) {
	renderer := &fakeRenderer{pdf: []byte("not a PDF")}
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/html-to-pdf", nil)

	htmlToPDFHandler(renderer)(response, request)

	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusInternalServerError)
	}
}

func TestHTMLToPDFSurfacesRendererFailure(t *testing.T) {
	renderer := &fakeRenderer{err: errors.New("browser failed")}
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/html-to-pdf", nil)

	htmlToPDFHandler(renderer)(response, request)

	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusInternalServerError)
	}
}
