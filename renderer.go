package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
)

var blockedURLPatterns = []*network.BlockPattern{
	{URLPattern: "http://*:*/*", Block: true},
	{URLPattern: "https://*:*/*", Block: true},
	{URLPattern: "file://*/*", Block: true},
	{URLPattern: "ftp://*:*/*", Block: true},
	{URLPattern: "ws://*:*/*", Block: true},
	{URLPattern: "wss://*:*/*", Block: true},
}

type chromiumRenderer struct {
	executablePath string
	timeout        time.Duration
	maxOutputBytes int
	slots          chan struct{}
	observeCommand func([]string)
}

func newChromiumRenderer(executablePath string, timeout time.Duration, maxOutputBytes int) *chromiumRenderer {
	return &chromiumRenderer{
		executablePath: executablePath,
		timeout:        timeout,
		maxOutputBytes: maxOutputBytes,
		slots:          make(chan struct{}, 1),
	}
}

func (r *chromiumRenderer) Render(parent context.Context, html string) ([]byte, error) {
	if strings.TrimSpace(html) == "" {
		return nil, fmt.Errorf("HTML is empty")
	}

	ctx, cancel := context.WithTimeout(parent, r.timeout)
	defer cancel()

	select {
	case r.slots <- struct{}{}:
		defer func() { <-r.slots }()
	case <-ctx.Done():
		return nil, fmt.Errorf("wait for render slot: %w", ctx.Err())
	}

	profileDir, err := os.MkdirTemp("", "chromium-profile-*")
	if err != nil {
		return nil, fmt.Errorf("create Chromium profile: %w", err)
	}
	defer os.RemoveAll(profileDir)

	options := append([]chromedp.ExecAllocatorOption{}, chromedp.DefaultExecAllocatorOptions[:]...)
	options = append(options,
		chromedp.ExecPath(r.executablePath),
		chromedp.UserDataDir(profileDir),
		chromedp.Flag("disable-background-networking", true),
		chromedp.Flag("disable-component-update", true),
		chromedp.Flag("disable-default-apps", true),
		chromedp.Flag("disable-dev-shm-usage", true),
		chromedp.Flag("disable-extensions", true),
		chromedp.Flag("disable-gpu", true),
		chromedp.Flag("disable-javascript", true),
		chromedp.Flag("disable-sync", true),
		chromedp.Flag("host-resolver-rules", "MAP * ~NOTFOUND"),
		chromedp.Flag("metrics-recording-only", true),
		chromedp.Flag("mute-audio", true),
	)
	if r.observeCommand != nil {
		options = append(options, chromedp.ModifyCmdFunc(func(command *exec.Cmd) {
			r.observeCommand(append([]string(nil), command.Args...))
		}))
	}

	allocatorContext, cancelAllocator := chromedp.NewExecAllocator(ctx, options...)
	defer cancelAllocator()
	browserContext, cancelBrowser := chromedp.NewContext(allocatorContext)
	defer cancelBrowser()

	if err := chromedp.Do(browserContext); err != nil {
		return nil, fmt.Errorf("start Chromium: %w", err)
	}
	if _, err := chromedp.Call(browserContext, network.Enable, network.EnableParams{}); err != nil {
		return nil, fmt.Errorf("enable network controls: %w", err)
	}
	if _, err := chromedp.Call(browserContext, network.SetBlockedURLs, network.SetBlockedURLsParams{
		URLPatterns: blockedURLPatterns,
	}); err != nil {
		return nil, fmt.Errorf("block external URLs: %w", err)
	}

	dataURL := "data:text/html;base64," + base64.StdEncoding.EncodeToString([]byte(html))
	if err := chromedp.Do(browserContext,
		chromedp.Navigate("about:blank"),
		chromedp.Navigate(dataURL),
		chromedp.WaitReady(chromedp.CSS("body")),
	); err != nil {
		return nil, fmt.Errorf("load HTML: %w", err)
	}

	pdf, err := chromedp.Run(browserContext, chromedp.PrintToPDF(
		chromedp.PDFPrintBackground(),
		chromedp.PDFPreferCSSPageSize(),
		chromedp.PDFPageRanges("1-20"),
		chromedp.PDFStream(),
	))
	if err != nil {
		return nil, fmt.Errorf("print PDF: %w", err)
	}
	if len(pdf) == 0 || !bytes.HasPrefix(pdf, []byte("%PDF-")) {
		return nil, fmt.Errorf("Chromium returned invalid PDF output")
	}
	if len(pdf) > r.maxOutputBytes {
		return nil, fmt.Errorf("PDF output exceeds %d bytes", r.maxOutputBytes)
	}
	return pdf, nil
}
