package main

import (
	"net/http"
	"os"
	"time"

	"github.com/azure/azure-functions-golang-worker/sdk"
	"github.com/azure/azure-functions-golang-worker/worker"
)

const (
	defaultChromiumPath = "/usr/bin/chromium-headless-shell"
	renderTimeout       = 20 * time.Second
	maxPDFBytes         = 8 << 20
)

func main() {
	app := sdk.FunctionApp()
	app.HTTP("Hello", hello,
		sdk.WithRoute("hello"),
		sdk.WithMethods("GET", "POST"),
		sdk.WithAuth("anonymous"),
	)

	chromiumPath := os.Getenv("CHROMIUM_PATH")
	if chromiumPath == "" {
		chromiumPath = defaultChromiumPath
	}
	renderer := newChromiumRenderer(chromiumPath, renderTimeout, maxPDFBytes)
	app.HTTP("HtmlToPdf", htmlToPDFHandler(renderer),
		sdk.WithRoute("html-to-pdf"),
		sdk.WithMethods("GET", "POST"),
		sdk.WithAuth("anonymous"),
	)

	worker.Start(app)
}

func hello(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("Hello from the Go worker."))
}
