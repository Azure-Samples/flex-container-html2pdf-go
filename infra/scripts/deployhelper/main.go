package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

var staticImageInputs = []string{
	".dockerignore",
	"Dockerfile",
	"go.mod",
	"go.sum",
	"host.json",
}

type parameterValue struct {
	Value string `json:"value"`
}

type parameterFile struct {
	Schema         string                    `json:"$schema"`
	ContentVersion string                    `json:"contentVersion"`
	Parameters     map[string]parameterValue `json:"parameters"`
}

type siteState struct {
	State    string `json:"state"`
	Type     string `json:"type"`
	Value    string `json:"value"`
	Subnet   string `json:"subnet"`
	Identity string `json:"identity"`
}

type verificationResult struct {
	FunctionApp              string   `json:"functionApp"`
	State                    string   `json:"state"`
	DeploymentType           string   `json:"deploymentType"`
	Image                    string   `json:"image"`
	Functions                []string `json:"functions"`
	HelloGetStatus           int      `json:"helloGetStatus"`
	HelloPostStatus          int      `json:"helloPostStatus"`
	PDFGetBytes              int      `json:"pdfGetBytes"`
	PDFPostBytes             int      `json:"pdfPostBytes"`
	InvalidContentTypeStatus int      `json:"invalidContentTypeStatus"`
	VerifiedUTC              string   `json:"verifiedUtc"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(arguments []string) error {
	if len(arguments) == 0 {
		return usageError()
	}

	switch arguments[0] {
	case "stage-context":
		if len(arguments) != 2 {
			return usageError()
		}
		repositoryRoot, err := os.Getwd()
		if err != nil {
			return fmt.Errorf("resolve repository root: %w", err)
		}
		contextHash, err := prepareImageContext(
			repositoryRoot,
			arguments[1],
		)
		if err != nil {
			return err
		}
		fmt.Print(contextHash)
		return nil
	case "write-parameters":
		if len(arguments) != 2 {
			return usageError()
		}
		return writeParameters(arguments[1])
	case "validate-pdf":
		if len(arguments) != 2 {
			return usageError()
		}
		size, err := validatePDF(arguments[1])
		if err != nil {
			return err
		}
		fmt.Print(size)
		return nil
	case "validate-site":
		if len(arguments) != 1 {
			return usageError()
		}
		return validateSite()
	case "verification-json":
		if len(arguments) != 1 {
			return usageError()
		}
		output, err := buildVerificationJSON()
		if err != nil {
			return err
		}
		fmt.Print(string(output))
		return nil
	default:
		return usageError()
	}
}

func usageError() error {
	return errors.New(
		"usage: deployhelper " +
			"<stage-context|write-parameters|validate-pdf|" +
			"validate-site|verification-json> [path]",
	)
}

func prepareImageContext(repositoryRoot, destinationRoot string) (string, error) {
	repository, err := filepath.Abs(repositoryRoot)
	if err != nil {
		return "", fmt.Errorf("resolve repository root: %w", err)
	}
	destination, err := filepath.Abs(destinationRoot)
	if err != nil {
		return "", fmt.Errorf("resolve destination root: %w", err)
	}
	if err := os.MkdirAll(destination, 0o755); err != nil {
		return "", fmt.Errorf("create image-context destination: %w", err)
	}
	entries, err := os.ReadDir(destination)
	if err != nil {
		return "", fmt.Errorf("read image-context destination: %w", err)
	}
	if len(entries) != 0 {
		return "", fmt.Errorf(
			"image-context destination must be empty: %s",
			destination,
		)
	}

	inputs, err := imageInputs(repository)
	if err != nil {
		return "", err
	}
	for _, source := range inputs {
		destinationPath := filepath.Join(destination, filepath.Base(source))
		if err := copyEntry(source, destinationPath); err != nil {
			return "", err
		}
	}
	return hashImageContext(destination)
}

func imageInputs(repositoryRoot string) ([]string, error) {
	inputs := make([]string, 0, len(staticImageInputs)+8)
	for _, name := range staticImageInputs {
		path := filepath.Join(repositoryRoot, name)
		if _, err := os.Lstat(path); err != nil {
			return nil, fmt.Errorf("required image input is missing: %s", path)
		}
		inputs = append(inputs, path)
	}

	goFiles, err := filepath.Glob(filepath.Join(repositoryRoot, "*.go"))
	if err != nil {
		return nil, fmt.Errorf("list Go source files: %w", err)
	}
	sort.Strings(goFiles)
	if len(goFiles) == 0 {
		return nil, fmt.Errorf(
			"no root-level Go source files were found in %s",
			repositoryRoot,
		)
	}
	return append(inputs, goFiles...), nil
}

func copyEntry(source, destination string) error {
	info, err := os.Lstat(source)
	if err != nil {
		return fmt.Errorf("inspect image input %s: %w", source, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("symbolic links are not allowed: %s", source)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("unsupported image-context entry: %s", source)
	}

	content, err := os.ReadFile(source)
	if err != nil {
		return fmt.Errorf("read image input %s: %w", source, err)
	}
	if err := os.WriteFile(destination, content, 0o644); err != nil {
		return fmt.Errorf("write image input %s: %w", destination, err)
	}
	return nil
}

func hashImageContext(contextRoot string) (string, error) {
	root, err := filepath.Abs(contextRoot)
	if err != nil {
		return "", fmt.Errorf("resolve image-context root: %w", err)
	}

	digest := sha256.New()
	_, _ = digest.Write([]byte("flex-container-go-image-context-v1\x00"))

	var paths []string
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path != root {
			paths = append(paths, path)
		}
		return nil
	})
	if err != nil {
		return "", fmt.Errorf("walk image context: %w", err)
	}
	sort.Strings(paths)

	for _, path := range paths {
		info, err := os.Lstat(path)
		if err != nil {
			return "", fmt.Errorf("inspect context entry %s: %w", path, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("symbolic links are not allowed: %s", path)
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return "", fmt.Errorf("resolve context entry %s: %w", path, err)
		}
		relative = filepath.ToSlash(relative)

		if info.IsDir() {
			_, _ = fmt.Fprintf(digest, "directory\x00%s\x00", relative)
			continue
		}
		if !info.Mode().IsRegular() {
			return "", fmt.Errorf("unsupported image-context entry: %s", path)
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("read context entry %s: %w", path, err)
		}
		_, _ = fmt.Fprintf(
			digest,
			"file\x00%s\x00%d\x00",
			relative,
			len(content),
		)
		_, _ = digest.Write(content)
		_, _ = digest.Write([]byte{0})
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func writeParameters(path string) error {
	values := map[string]string{
		"environmentName":                     "AZURE_ENV_NAME",
		"functionAppName":                     "AZURE_FUNCTION_NAME",
		"functionLocation":                    "AZURE_FUNCTION_LOCATION",
		"appServicePlanId":                    "AZURE_APP_SERVICE_PLAN_ID",
		"applicationInsightsConnectionString": "AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING",
		"storageAccountName":                  "AZURE_STORAGE_ACCOUNT_NAME",
		"userAssignedIdentityId":              "AZURE_USER_ASSIGNED_IDENTITY_ID",
		"userAssignedIdentityClientId":        "AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID",
		"virtualNetworkSubnetId":              "AZURE_FUNCTION_SUBNET_ID",
		"registryImage":                       "REGISTRY_IMAGE",
		"registryUsername":                    "AZURE_ACR_TOKEN_NAME",
		"registryPassword":                    "REGISTRY_PASSWORD",
	}

	parameters := make(map[string]parameterValue, len(values))
	for parameterName, environmentName := range values {
		value, err := requiredEnvironmentValue(environmentName)
		if err != nil {
			return err
		}
		parameters[parameterName] = parameterValue{Value: value}
	}

	content, err := json.MarshalIndent(parameterFile{
		Schema: "https://schema.management.azure.com/schemas/" +
			"2019-04-01/deploymentParameters.json#",
		ContentVersion: "1.0.0.0",
		Parameters:     parameters,
	}, "", "  ")
	if err != nil {
		return fmt.Errorf("encode deployment parameters: %w", err)
	}
	content = append(content, '\n')
	if err := os.WriteFile(path, content, 0o600); err != nil {
		return fmt.Errorf("write deployment parameters: %w", err)
	}
	return nil
}

func validatePDF(path string) (int, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return 0, fmt.Errorf("read PDF %s: %w", path, err)
	}
	if len(content) < 100 ||
		!bytes.HasPrefix(content, []byte("%PDF-")) ||
		!bytes.HasSuffix(bytes.TrimSpace(content), []byte("%%EOF")) {
		return 0, fmt.Errorf("invalid PDF: %s", path)
	}
	return len(content), nil
}

func validateSite() error {
	var site siteState
	if err := json.Unmarshal([]byte(os.Getenv("SITE_JSON")), &site); err != nil {
		return fmt.Errorf("decode Function App state: %w", err)
	}
	expectedImage, err := requiredEnvironmentValue("AZURE_REGISTRY_IMAGE")
	if err != nil {
		return err
	}
	expectedSubnet, err := requiredEnvironmentValue("AZURE_FUNCTION_SUBNET_ID")
	if err != nil {
		return err
	}
	if site.State != "Running" ||
		site.Type != "Registry" ||
		site.Value != expectedImage ||
		site.Subnet != expectedSubnet ||
		!strings.Contains(site.Identity, "UserAssigned") {
		return errors.New(
			"the Function App deployment, identity, or network " +
				"configuration does not match",
		)
	}
	return nil
}

func buildVerificationJSON() ([]byte, error) {
	functionApp, err := requiredEnvironmentValue("AZURE_FUNCTION_NAME")
	if err != nil {
		return nil, err
	}
	image, err := requiredEnvironmentValue("AZURE_REGISTRY_IMAGE")
	if err != nil {
		return nil, err
	}
	verifiedUTC, err := requiredEnvironmentValue("VERIFIED_UTC")
	if err != nil {
		return nil, err
	}

	helloGetStatus, err := requiredEnvironmentInt("HELLO_GET_STATUS")
	if err != nil {
		return nil, err
	}
	helloPostStatus, err := requiredEnvironmentInt("HELLO_POST_STATUS")
	if err != nil {
		return nil, err
	}
	pdfGetBytes, err := requiredEnvironmentInt("PDF_GET_BYTES")
	if err != nil {
		return nil, err
	}
	pdfPostBytes, err := requiredEnvironmentInt("PDF_POST_BYTES")
	if err != nil {
		return nil, err
	}
	invalidStatus, err := requiredEnvironmentInt("INVALID_STATUS")
	if err != nil {
		return nil, err
	}

	output, err := json.Marshal(verificationResult{
		FunctionApp:              functionApp,
		State:                    "Running",
		DeploymentType:           "Registry",
		Image:                    image,
		Functions:                strings.Fields(os.Getenv("LEAF_NAMES")),
		HelloGetStatus:           helloGetStatus,
		HelloPostStatus:          helloPostStatus,
		PDFGetBytes:              pdfGetBytes,
		PDFPostBytes:             pdfPostBytes,
		InvalidContentTypeStatus: invalidStatus,
		VerifiedUTC:              verifiedUTC,
	})
	if err != nil {
		return nil, fmt.Errorf("encode verification result: %w", err)
	}
	return output, nil
}

func requiredEnvironmentValue(name string) (string, error) {
	value := os.Getenv(name)
	if strings.TrimSpace(value) == "" {
		return "", fmt.Errorf("required environment value %q is missing", name)
	}
	return value, nil
}

func requiredEnvironmentInt(name string) (int, error) {
	value, err := requiredEnvironmentValue(name)
	if err != nil {
		return 0, err
	}
	number, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("environment value %q must be an integer: %w", name, err)
	}
	return number, nil
}
