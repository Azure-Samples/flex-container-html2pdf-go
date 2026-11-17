package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestPrepareImageContextContainsStaticAndGoInputs(t *testing.T) {
	repository := makeRepository(t)
	destination := filepath.Join(t.TempDir(), "context")

	if _, err := prepareImageContext(repository, destination); err != nil {
		t.Fatal(err)
	}

	entries, err := os.ReadDir(destination)
	if err != nil {
		t.Fatal(err)
	}
	got := make(map[string]bool, len(entries))
	for _, entry := range entries {
		got[entry.Name()] = true
	}
	for _, name := range []string{
		".dockerignore",
		"Dockerfile",
		"go.mod",
		"go.sum",
		"handler.go",
		"host.json",
		"main.go",
	} {
		if !got[name] {
			t.Fatalf("context is missing %s", name)
		}
	}
	if got["README.md"] {
		t.Fatal("context contains unrelated README.md")
	}
}

func TestUnrelatedFileDoesNotChangeHash(t *testing.T) {
	first := makeRepository(t)
	second := makeRepository(t)
	if err := os.WriteFile(
		filepath.Join(second, "README.md"),
		[]byte("changed\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	firstHash := prepareAndHash(t, first)
	secondHash := prepareAndHash(t, second)
	if firstHash != secondHash {
		t.Fatalf("hash changed for unrelated file: %s != %s", firstHash, secondHash)
	}
}

func TestGoSourceChangeChangesHash(t *testing.T) {
	first := makeRepository(t)
	second := makeRepository(t)
	if err := os.WriteFile(
		filepath.Join(second, "handler.go"),
		[]byte("package main\nvar changed = true\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	firstHash := prepareAndHash(t, first)
	secondHash := prepareAndHash(t, second)
	if firstHash == secondHash {
		t.Fatalf("hash did not change after Go source change: %s", firstHash)
	}
}

func TestMissingRequiredInputFails(t *testing.T) {
	repository := makeRepository(t)
	if err := os.Remove(filepath.Join(repository, "go.sum")); err != nil {
		t.Fatal(err)
	}
	if _, err := prepareImageContext(
		repository,
		filepath.Join(t.TempDir(), "context"),
	); err == nil {
		t.Fatal("expected missing go.sum to fail")
	}
}

func TestValidatePDF(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.pdf")
	content := append([]byte("%PDF-1.7\n"), make([]byte, 128)...)
	content = append(content, []byte("\n%%EOF\n")...)
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	size, err := validatePDF(path)
	if err != nil {
		t.Fatal(err)
	}
	if size != len(content) {
		t.Fatalf("size = %d, want %d", size, len(content))
	}
}

func TestWriteParameters(t *testing.T) {
	values := map[string]string{
		"AZURE_ENV_NAME":                               "sample",
		"AZURE_FUNCTION_NAME":                          "func-sample",
		"AZURE_FUNCTION_LOCATION":                      "eastus2euap",
		"AZURE_APP_SERVICE_PLAN_ID":                    "/plans/sample",
		"AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING": "connection-string",
		"AZURE_STORAGE_ACCOUNT_NAME":                   "stsample",
		"AZURE_USER_ASSIGNED_IDENTITY_ID":              "/identities/sample",
		"AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID":       "client-id",
		"AZURE_FUNCTION_SUBNET_ID":                     "/subnets/sample",
		"REGISTRY_IMAGE":                               "registry/repository@sha256:digest",
		"AZURE_ACR_TOKEN_NAME":                         "pull-token",
		"REGISTRY_PASSWORD":                            "password",
	}
	for name, value := range values {
		t.Setenv(name, value)
	}

	path := filepath.Join(t.TempDir(), "parameters.json")
	if err := writeParameters(path); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var parameters parameterFile
	if err := json.Unmarshal(content, &parameters); err != nil {
		t.Fatal(err)
	}
	if got := parameters.Parameters["registryImage"].Value; got != values["REGISTRY_IMAGE"] {
		t.Fatalf("registryImage = %q", got)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("parameter mode = %o, want 600", info.Mode().Perm())
		}
	}
}

func TestValidateSite(t *testing.T) {
	t.Setenv("AZURE_REGISTRY_IMAGE", "registry/repository@sha256:digest")
	t.Setenv("AZURE_FUNCTION_SUBNET_ID", "/subnets/sample")
	t.Setenv(
		"SITE_JSON",
		`{"state":"Running","type":"Registry",`+
			`"value":"registry/repository@sha256:digest",`+
			`"subnet":"/subnets/sample","identity":"UserAssigned"}`,
	)
	if err := validateSite(); err != nil {
		t.Fatal(err)
	}
}

func TestBuildVerificationJSON(t *testing.T) {
	values := map[string]string{
		"AZURE_FUNCTION_NAME":  "func-sample",
		"AZURE_REGISTRY_IMAGE": "registry/repository@sha256:digest",
		"LEAF_NAMES":           "Hello\nHtmlToPdf",
		"HELLO_GET_STATUS":     "200",
		"HELLO_POST_STATUS":    "200",
		"PDF_GET_BYTES":        "1000",
		"PDF_POST_BYTES":       "2000",
		"INVALID_STATUS":       "415",
		"VERIFIED_UTC":         "2026-11-13T00:00:00Z",
	}
	for name, value := range values {
		t.Setenv(name, value)
	}
	content, err := buildVerificationJSON()
	if err != nil {
		t.Fatal(err)
	}
	var result verificationResult
	if err := json.Unmarshal(content, &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Functions) != 2 ||
		result.Functions[0] != "Hello" ||
		result.Functions[1] != "HtmlToPdf" {
		t.Fatalf("functions = %#v", result.Functions)
	}
}

func makeRepository(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	files := map[string]string{
		".dockerignore": "*\n!*.go\n",
		"Dockerfile":    "FROM scratch\n",
		"go.mod":        "module example.test/sample\n\ngo 1.27.0\n",
		"go.sum":        "",
		"host.json":     `{"version":"2.0"}` + "\n",
		"main.go":       "package main\nfunc main() {}\n",
		"handler.go":    "package main\n",
		"README.md":     "not part of the image\n",
	}
	for name, content := range files {
		if err := os.WriteFile(
			filepath.Join(root, name),
			[]byte(content),
			0o644,
		); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func prepareAndHash(t *testing.T, repository string) string {
	t.Helper()
	destination := filepath.Join(t.TempDir(), "context")
	contextHash, err := prepareImageContext(repository, destination)
	if err != nil {
		t.Fatal(err)
	}
	return contextHash
}
