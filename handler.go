package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"mime"
	"net/http"
	"strings"
)

const maxHTMLBytes = 256 << 10

type pdfRenderer interface {
	Render(context.Context, string) ([]byte, error)
}

func htmlToPDFHandler(renderer pdfRenderer) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var html string

		switch r.Method {
		case http.MethodGet:
			html = builtInInvoiceHTML
		case http.MethodPost:
			if encoding := strings.TrimSpace(r.Header.Get("Content-Encoding")); encoding != "" && !strings.EqualFold(encoding, "identity") {
				http.Error(w, "content encoding is not supported", http.StatusUnsupportedMediaType)
				return
			}

			if contentType := strings.TrimSpace(r.Header.Get("Content-Type")); contentType != "" {
				mediaType, _, err := mime.ParseMediaType(contentType)
				if err != nil || !strings.EqualFold(mediaType, "text/html") {
					http.Error(w, "Content-Type must be text/html", http.StatusUnsupportedMediaType)
					return
				}
			}

			r.Body = http.MaxBytesReader(w, r.Body, maxHTMLBytes)
			body, err := io.ReadAll(r.Body)
			if err != nil {
				var maxBytesError *http.MaxBytesError
				if errors.As(err, &maxBytesError) {
					http.Error(w, "HTML body exceeds 256 KiB", http.StatusRequestEntityTooLarge)
					return
				}
				http.Error(w, "failed to read HTML body", http.StatusBadRequest)
				return
			}
			if len(bytes.TrimSpace(body)) == 0 {
				http.Error(w, "HTML body must not be empty", http.StatusBadRequest)
				return
			}
			html = string(body)
		default:
			w.Header().Set("Allow", "GET, POST")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		pdf, err := renderer.Render(r.Context(), html)
		if err != nil {
			log.Printf("HTML-to-PDF render failed: %v", err)
			if errors.Is(err, context.Canceled) {
				return
			}
			if errors.Is(err, context.DeadlineExceeded) {
				http.Error(w, "PDF rendering timed out", http.StatusGatewayTimeout)
				return
			}
			http.Error(w, "PDF rendering failed", http.StatusInternalServerError)
			return
		}
		if len(pdf) == 0 || !bytes.HasPrefix(pdf, []byte("%PDF-")) {
			log.Printf("HTML-to-PDF renderer returned invalid output")
			http.Error(w, "PDF rendering failed", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Disposition", `inline; filename="invoice.pdf"`)
		w.Header().Set("Content-Type", "application/pdf")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write(pdf); err != nil {
			log.Printf("failed to write PDF response: %v", err)
		}
	}
}

const builtInInvoiceHTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Contoso Invoice</title>
  <style>
    @page { size: A4; margin: 14mm; }
    * { box-sizing: border-box; }
    body {
      color: #172033;
      font: 14px/1.45 "Liberation Sans", Arial, sans-serif;
      margin: 0;
    }
    header {
      align-items: flex-start;
      border-bottom: 3px solid #2563eb;
      display: flex;
      justify-content: space-between;
      padding-bottom: 18px;
    }
    h1 { color: #1d4ed8; font-size: 30px; margin: 0; }
    h2 { font-size: 16px; margin: 26px 0 8px; }
    .muted { color: #64748b; }
    .meta { text-align: right; }
    table {
      border-collapse: collapse;
      margin-top: 20px;
      width: 100%;
    }
    th, td {
      border-bottom: 1px solid #cbd5e1;
      padding: 10px 8px;
      text-align: left;
    }
    th { background: #eff6ff; }
    .number { text-align: right; }
    .total {
      font-size: 18px;
      font-weight: 700;
    }
    footer {
      color: #64748b;
      margin-top: 36px;
      text-align: center;
    }
  </style>
</head>
<body>
  <header>
    <div>
      <h1>INVOICE</h1>
      <div class="muted">Contoso Cloud Services</div>
    </div>
    <div class="meta">
      <strong>Invoice INV-2026-1109</strong><br>
      Issued: November 9, 2026<br>
      Due: November 23, 2026
    </div>
  </header>

  <h2>Bill to</h2>
  <div>Fabrikam Engineering<br>1 Serverless Way<br>Redmond, WA 98052</div>

  <table>
    <thead>
      <tr>
        <th>Description</th>
        <th class="number">Quantity</th>
        <th class="number">Unit price</th>
        <th class="number">Amount</th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td>Containerized function validation</td>
        <td class="number">1</td>
        <td class="number">$420.00</td>
        <td class="number">$420.00</td>
      </tr>
      <tr>
        <td>Chromium PDF rendering setup</td>
        <td class="number">2</td>
        <td class="number">$90.00</td>
        <td class="number">$180.00</td>
      </tr>
      <tr class="total">
        <td colspan="3" class="number">Total</td>
        <td class="number">$600.00</td>
      </tr>
    </tbody>
  </table>

  <footer>Thank you for validating Azure Functions containers.</footer>
</body>
</html>`
