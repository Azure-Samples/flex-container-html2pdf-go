<!--
---
name: Go HTML-to-PDF on Azure Functions Flex Consumption containers
description: >-
  This sample contains an Azure Functions Flex Consumption container
  application written in Go 1.27. It accepts bounded HTML and returns a PDF
  rendered with chromedp and OS-installed Chromium.
page_type: sample
languages:
- go
- bicep
- azdeveloper
- dockerfile
products:
- azure
- azure-functions
- azure-container-registry
urlFragment: flex-container-html2pdf-go
---
-->

# Go HTML-to-PDF on Azure Functions Flex Consumption containers

This sample accepts self-contained HTML in an HTTP POST request and returns a
PDF rendered with chromedp and the operating system's Chromium package.

The Azure Functions app runs from a Go 1.27 Flex Consumption container. Azure
Developer CLI (`azd`) provisions the Azure resources, builds the container
with Azure Container Registry Tasks, deploys it by immutable digest, and
verifies the live endpoints.

![Architecture diagram for Go HTML-to-PDF on Azure Functions Flex Consumption containers](./img/architecture.svg)

> [!IMPORTANT]
> Azure Functions Flex Consumption container support is currently in preview.
> Preview capabilities and deployment requirements may change before general
> availability.

## Sample workflow

1. Clone the repository.
1. Run `azd up` to build and deploy the Go 1.27 container.
1. POST your HTML to `/api/html-to-pdf`.
1. Save or display the returned `application/pdf` response.

You may use `go test` to verify the function code locally. During the preview,
deploy to Azure for end-to-end container validation.

## Prerequisites

- [Git](https://git-scm.com/downloads)
- [Go 1.27.0](https://go.dev/dl/)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- an Azure subscription enabled for the Registry-backed Flex Consumption
  container preview
- permission to create resource groups, role assignments, storage, networking,
  monitoring, Azure Container Registry, FC1 plans, and Function Apps

Local Docker isn't required for the `azd` deployment.

## Initialize the project

```shell
git clone https://github.com/Azure-Samples/flex-container-html2pdf-go.git
cd flex-container-html2pdf-go
```

## How it works

[`handler.go`](./handler.go) implements the customer endpoint:

```text
POST /api/html-to-pdf
Content-Type: text/html; charset=utf-8
```

The function:

1. validates the media type, body, and 256 KiB input limit;
1. launches OS-installed Chromium with chromedp as a non-root user;
1. disables JavaScript and blocks external subresources;
1. enforces one concurrent render, a 20-second timeout, 20 pages, and an
   8 MiB output limit;
1. validates cleanup of the browser process and temporary profile;
1. returns `application/pdf` with no-store and nosniff headers.

GET requests render a built-in invoice. [`main.go`](./main.go) also registers
the `Hello` function used by deployment verification.

Exact runtime and dependency pins live in the
[`Dockerfile`](./Dockerfile),
[`go.mod`](./go.mod), and
[`go.sum`](./go.sum). Those files are the source of truth for version updates.

## How the container image is built

The deployment uses
[Azure Container Registry Tasks](https://learn.microsoft.com/azure/container-registry/container-registry-tasks-overview)
to build the Linux AMD64 image in Azure. Customers don't need local Docker to
deploy the sample.

During `azd up`:

1. The standard-library Go
   [`deployhelper`](./infra/scripts/deployhelper/main.go) stages only files
   that affect the image and calculates a deterministic SHA-256.
1. The hash becomes the image tag: `azd-<context-hash>`.
1. An existing tag is reused; otherwise `az acr build` runs the ACR Tasks
   quick build.
1. The workflow resolves the registry manifest digest.
1. The Function App is pinned to
   `registry/repository:tag@sha256:digest`.
1. The tag is write- and delete-locked so its digest can't move.

## Deploy to Azure

Sign in:

```shell
az login
azd auth login
```

Create an `azd` environment and set the required deployment locations:

```shell
azd env new go-pdf-flex --no-prompt
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION eastus2
azd env set AZURE_FUNCTION_LOCATION eastus2euap
```

`AZURE_LOCATION` is used for storage, ACR, Log Analytics, and Application
Insights. `AZURE_FUNCTION_LOCATION` is used for the FC1 plan, Function App,
virtual network, and private endpoint. The split is required because Log
Analytics isn't available in `eastus2euap`.

Provision the resources, build the container, deploy it, and verify the Hello
and PDF endpoints:

```shell
azd up
```

For unattended execution, use `azd up --no-prompt` after all four environment
values are set.

## Test the deployed container

Get the deployed endpoint.

PowerShell:

```powershell
$apiUrl = azd env get-value API_URL
```

Bash:

```bash
API_URL=$(azd env get-value API_URL)
```

POST the included [`sample.html`](./sample.html).

PowerShell:

```powershell
$format = "HTTP %{http_code}; Content-Type %{content_type}; " +
  "Bytes %{size_download}`n"
curl.exe --fail --show-error `
  --request POST `
  --header "Content-Type: text/html; charset=utf-8" `
  --data-binary "@sample.html" `
  --output document.pdf `
  --write-out $format `
  "$apiUrl/api/html-to-pdf"
```

Bash:

```bash
FORMAT='HTTP %{http_code}; Content-Type %{content_type}; Bytes %{size_download}\n'
curl --fail --show-error \
  --request POST \
  --header 'Content-Type: text/html; charset=utf-8' \
  --data-binary @sample.html \
  --output document.pdf \
  --write-out "$FORMAT" \
  "$API_URL/api/html-to-pdf"
```

Expected output resembles:

```text
HTTP 200; Content-Type application/pdf; Bytes 20000
```

The byte count varies but must be greater than zero. Verify the PDF boundaries:

```shell
go run ./infra/scripts/deployhelper validate-pdf document.pdf
```

Expected output:

```text
Valid PDF: <non-zero byte count> bytes
```

Open the generated PDF.

Windows:

```powershell
Start-Process .\document.pdf
```

macOS:

```bash
open document.pdf
```

Linux:

```bash
xdg-open document.pdf
```

The displayed PDF should contain:

- **Azure Functions HTML-to-PDF**
- **Rendered with chromedp and system Chromium**
- **This document is self-contained and doesn't load external resources.**

## Redeploy container changes

This section isn't needed for the initial deployment. Use it later if you
change the Go source, Go dependencies, or Dockerfile and want to deploy an
updated container.

Rerun `azd up`, or use the image-only workflow after the environment is
provisioned:

PowerShell:

```powershell
.\infra\scripts\deployimage.ps1 -Verify
```

Bash:

```bash
sh ./infra/scripts/deployimage.sh --verify
```

Unchanged image inputs reuse the existing digest.

## Security

Rendering untrusted HTML invokes a complex browser parser. Before production
use, add authentication, authorization, rate limiting, tenant isolation, abuse
monitoring, and workload-specific HTML sanitization.

This sample:

- uses anonymous HTTP triggers only to simplify the sample;
- keeps ACR admin and anonymous pull disabled;
- grants the Function App a repository-scoped read-only pull credential;
- passes registry secrets only as secure deployment parameters;
- doesn't write secrets to source or `azd` environment outputs;
- uses managed identity for runtime storage and Application Insights;
- disables shared-key and public network access on runtime storage;
- reaches runtime storage through a private endpoint;
- runs the application and Chromium as UID/GID `10001`;
- keeps Chromium's sandbox enabled;
- disables JavaScript and external subresources;
- doesn't accept arbitrary URLs for server-side fetching;
- bounds input, output, concurrency, pages, and execution time.

## Preview limitations

- The direct Registry deployment uses preview Azure resource APIs.
- Region and subscription enablement are required.
- ACR Basic uses a public service endpoint; admin and anonymous access remain
  disabled.
- Runtime storage is private, but the HTTP Function endpoints are public.
- The HTTP endpoints are anonymous.
- The image is Linux AMD64 only.
- The short-lived ACR pull password must be refreshed by rerunning deployment.
- Forced or fallback HTTP-over-gRPC request handling remains affected by
  [Azure/azure-functions-golang-worker#87](https://github.com/Azure/azure-functions-golang-worker/issues/87).

## Costs

The environment can incur charges for:

- Flex Consumption executions;
- Azure Container Registry storage and ACR Tasks builds;
- the storage account and private endpoint;
- Log Analytics and Application Insights ingestion;
- Chromium CPU time and cold starts.

## Clean up resources

Review the selected environment:

```shell
azd env get-values
```

Delete the resource group and all resources created for that environment:

```shell
azd down --force
```

This command doesn't delete the local repository.

## Resources

- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/)
- [Run Azure Functions locally](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- [Azure Functions Flex Consumption](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)
- [Azure Functions Go developer guide](https://learn.microsoft.com/azure/azure-functions/functions-reference-go)
- [Azure Container Registry Tasks](https://learn.microsoft.com/azure/container-registry/container-registry-tasks-overview)
- [chromedp](https://github.com/chromedp/chromedp)

## License

This sample is licensed under the [MIT License](LICENSE).
