#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPOSITORY_ROOT"

if ! command -v go >/dev/null 2>&1; then
    echo "Go 1.27 or later is required for the deployment helper." >&2
    exit 1
fi

get_azd_value() {
    name=$1
    eval "value=\${$name:-}"
    if [ -z "$value" ]; then
        value=$(azd env get-value "$name")
    fi
    if [ -z "$value" ]; then
        echo "Required azd environment value '$name' is missing." >&2
        exit 1
    fi
    printf '%s' "$value"
}

validate_pdf() {
    "$DEPLOY_HELPER" validate-pdf "$1"
}

AZURE_SUBSCRIPTION_ID=$(get_azd_value AZURE_SUBSCRIPTION_ID)
AZURE_RESOURCE_GROUP=$(get_azd_value AZURE_RESOURCE_GROUP)
AZURE_FUNCTION_NAME=$(get_azd_value AZURE_FUNCTION_NAME)
API_URL=$(get_azd_value API_URL)
AZURE_REGISTRY_IMAGE=$(get_azd_value AZURE_REGISTRY_IMAGE)
AZURE_FUNCTION_SUBNET_ID=$(get_azd_value AZURE_FUNCTION_SUBNET_ID)
API_URL=${API_URL%/}
SITE_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.Web/sites/$AZURE_FUNCTION_NAME"

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

TEMPORARY_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/go-pdf-verification.XXXXXX")
DEPLOY_HELPER=$(mktemp "${TMPDIR:-/tmp}/go-deploy-helper.XXXXXX")
cleanup() {
    case "$TEMPORARY_DIRECTORY" in
        "${TMPDIR:-/tmp}"/go-pdf-verification.*)
            rm -rf -- "$TEMPORARY_DIRECTORY"
            ;;
        *)
            echo "Refusing to remove unexpected path: $TEMPORARY_DIRECTORY" >&2
            ;;
    esac
    case "$DEPLOY_HELPER" in
        "${TMPDIR:-/tmp}"/go-deploy-helper.*)
            rm -f -- "$DEPLOY_HELPER"
            ;;
        *)
            echo "Refusing to remove unexpected helper: $DEPLOY_HELPER" >&2
            ;;
    esac
}
trap cleanup EXIT INT TERM
go build -o "$DEPLOY_HELPER" ./infra/scripts/deployhelper

HELLO_GET_PATH="$TEMPORARY_DIRECTORY/hello-get.txt"
ATTEMPT=1
MAX_ATTEMPTS=36
RESTARTED=false
HELLO_GET_STATUS=

while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    HELLO_GET_STATUS=$(curl --silent --show-error --max-time 120 \
        "$API_URL/api/hello" \
        --output "$HELLO_GET_PATH" \
        --write-out '%{http_code}' 2>/dev/null) || HELLO_GET_STATUS=
    if [ "$HELLO_GET_STATUS" = "200" ] &&
        [ "$(cat "$HELLO_GET_PATH")" = "Hello from the Go worker." ]; then
        break
    fi

    if [ "$ATTEMPT" -eq 12 ] && [ "$RESTARTED" = false ]; then
        az functionapp restart \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --name "$AZURE_FUNCTION_NAME" \
            --only-show-errors
        RESTARTED=true
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 10
done

if [ "$HELLO_GET_STATUS" != "200" ] ||
    [ "$(cat "$HELLO_GET_PATH")" != "Hello from the Go worker." ]; then
    echo "The Go worker did not become healthy within six minutes." >&2
    exit 1
fi

HELLO_POST_PATH="$TEMPORARY_DIRECTORY/hello-post.txt"
HELLO_POST_STATUS=$(curl --silent --show-error --max-time 120 \
    --request POST \
    "$API_URL/api/hello" \
    --output "$HELLO_POST_PATH" \
    --write-out '%{http_code}')
if [ "$HELLO_POST_STATUS" != "200" ] ||
    [ "$(cat "$HELLO_POST_PATH")" != "Hello from the Go worker." ]; then
    echo "Hello POST did not return the exact expected response." >&2
    exit 1
fi

PDF_GET_PATH="$TEMPORARY_DIRECTORY/get.pdf"
PDF_GET_RESULT=$(curl --silent --show-error --max-time 120 \
    "$API_URL/api/html-to-pdf" \
    --output "$PDF_GET_PATH" \
    --write-out '%{http_code}|%{content_type}')
PDF_GET_STATUS=${PDF_GET_RESULT%%|*}
PDF_GET_CONTENT_TYPE=${PDF_GET_RESULT#*|}
PDF_GET_BYTES=$(validate_pdf "$PDF_GET_PATH")
if [ "$PDF_GET_STATUS" != "200" ] ||
    [ "$PDF_GET_CONTENT_TYPE" != "application/pdf" ]; then
    echo "HTML-to-PDF GET did not return a valid PDF response." >&2
    exit 1
fi

CUSTOM_HTML_PATH="$TEMPORARY_DIRECTORY/custom.html"
cat >"$CUSTOM_HTML_PATH" <<'HTML'
<!doctype html>
<html lang="en">
<body>
  <h1>Flex Consumption Go container validation</h1>
  <p>Rendered from bounded raw HTML with chromedp.</p>
</body>
</html>
HTML

PDF_POST_PATH="$TEMPORARY_DIRECTORY/post.pdf"
PDF_POST_RESULT=$(curl --silent --show-error --max-time 120 \
    --request POST \
    --header 'Content-Type: text/html; charset=utf-8' \
    --data-binary "@$CUSTOM_HTML_PATH" \
    "$API_URL/api/html-to-pdf" \
    --output "$PDF_POST_PATH" \
    --write-out '%{http_code}|%{content_type}')
PDF_POST_STATUS=${PDF_POST_RESULT%%|*}
PDF_POST_CONTENT_TYPE=${PDF_POST_RESULT#*|}
PDF_POST_BYTES=$(validate_pdf "$PDF_POST_PATH")
if [ "$PDF_POST_STATUS" != "200" ] ||
    [ "$PDF_POST_CONTENT_TYPE" != "application/pdf" ]; then
    echo "HTML-to-PDF POST did not return a valid PDF response." >&2
    exit 1
fi

INVALID_PATH="$TEMPORARY_DIRECTORY/invalid.txt"
INVALID_STATUS=$(curl --silent --show-error --max-time 120 \
    --request POST \
    --header 'Content-Type: application/json' \
    --data-binary '{}' \
    "$API_URL/api/html-to-pdf" \
    --output "$INVALID_PATH" \
    --write-out '%{http_code}')
if [ "$INVALID_STATUS" != "415" ] ||
    ! grep -Fq 'Content-Type must be text/html' "$INVALID_PATH"; then
    echo "The endpoint did not reject application/json with HTTP 415." >&2
    exit 1
fi

FUNCTION_NAMES=
INVENTORY_ATTEMPT=1
while [ "$INVENTORY_ATTEMPT" -le 24 ]; do
    FUNCTION_NAMES=$(az rest \
        --method get \
        --url "https://management.azure.com$SITE_ID/functions?api-version=2026-08-01" \
        --query 'value[].name' \
        --output tsv)
    LEAF_NAMES=$(printf '%s\n' "$FUNCTION_NAMES" | awk -F/ 'NF { print $NF }')
    FUNCTION_COUNT=$(printf '%s\n' "$LEAF_NAMES" | awk 'NF { count++ } END { print count + 0 }')
    if [ "$FUNCTION_COUNT" -eq 2 ] &&
        printf '%s\n' "$LEAF_NAMES" | grep -Fxq 'Hello' &&
        printf '%s\n' "$LEAF_NAMES" | grep -Fxq 'HtmlToPdf'; then
        break
    fi
    INVENTORY_ATTEMPT=$((INVENTORY_ATTEMPT + 1))
    sleep 5
done

if [ "$FUNCTION_COUNT" -ne 2 ] ||
    ! printf '%s\n' "$LEAF_NAMES" | grep -Fxq 'Hello' ||
    ! printf '%s\n' "$LEAF_NAMES" | grep -Fxq 'HtmlToPdf'; then
    echo "Azure did not inventory exactly Hello and HtmlToPdf: $LEAF_NAMES" >&2
    exit 1
fi

SITE_JSON=$(az rest \
    --method get \
    --url "https://management.azure.com$SITE_ID?api-version=2026-08-01" \
    --query '{state:properties.state,type:properties.functionAppConfig.deployment.storage.type,value:properties.functionAppConfig.deployment.storage.value,subnet:properties.virtualNetworkSubnetId,identity:identity.type}' \
    --output json)
export SITE_JSON AZURE_REGISTRY_IMAGE AZURE_FUNCTION_SUBNET_ID
"$DEPLOY_HELPER" validate-site

SETTING_NAMES=$(az rest \
    --method post \
    --url "https://management.azure.com$SITE_ID/config/appsettings/list?api-version=2026-08-01" \
    --query 'keys(properties)' \
    --output tsv)
for forbidden in \
    FUNCTIONS_APPLICATION_DIRECTORY \
    FUNCTIONS_GO_DISABLE_HTTP_PROXY \
    AzureWebJobsScriptRoot \
    WEBSITE_RUN_FROM_PACKAGE
do
    if printf '%s\n' "$SETTING_NAMES" | grep -Fxq "$forbidden"; then
        echo "Forbidden application setting '$forbidden' is present." >&2
        exit 1
    fi
done

VERIFIED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
azd env set AZURE_VERIFIED_UTC "$VERIFIED_UTC" --no-prompt >/dev/null

export AZURE_FUNCTION_NAME AZURE_REGISTRY_IMAGE LEAF_NAMES
export HELLO_GET_STATUS HELLO_POST_STATUS PDF_GET_BYTES PDF_POST_BYTES
export INVALID_STATUS VERIFIED_UTC
"$DEPLOY_HELPER" verification-json
