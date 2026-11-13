#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPOSITORY_ROOT"

if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1; then
    PYTHON=python
else
    echo "Python 3 is required." >&2
    exit 1
fi

VERIFY=false
if [ "${1:-}" = "--verify" ]; then
    VERIFY=true
    shift
fi
if [ "$#" -ne 0 ]; then
    echo "Usage: sh infra/scripts/deployimage.sh [--verify]" >&2
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

retry() {
    attempts=$1
    delay=$2
    shift 2
    count=1
    while ! "$@"; do
        if [ "$count" -ge "$attempts" ]; then
            return 1
        fi
        count=$((count + 1))
        sleep "$delay"
    done
}

PARAMETER_PATH=
BUILD_CONTEXT=
REGISTRY_PASSWORD=
cleanup() {
    if [ -n "$PARAMETER_PATH" ] && [ -f "$PARAMETER_PATH" ]; then
        rm -f -- "$PARAMETER_PATH"
    fi
    if [ -n "$BUILD_CONTEXT" ] && [ -d "$BUILD_CONTEXT" ]; then
        BUILD_CONTEXT_TO_REMOVE=$BUILD_CONTEXT "$PYTHON" - <<'PY'
import os
from pathlib import Path
import shutil
import tempfile

target = Path(os.environ["BUILD_CONTEXT_TO_REMOVE"]).resolve()
temporary_root = Path(tempfile.gettempdir()).resolve()
if (
    target.parent != temporary_root
    or not target.name.startswith("function-image.")
):
    raise RuntimeError(f"Refusing to remove unexpected path: {target}")
shutil.rmtree(target)
PY
    fi
    REGISTRY_PASSWORD=
    unset REGISTRY_PASSWORD
}
trap cleanup EXIT INT TERM

AZURE_SUBSCRIPTION_ID=$(get_azd_value AZURE_SUBSCRIPTION_ID)
AZURE_ENV_NAME=$(get_azd_value AZURE_ENV_NAME)
AZURE_RESOURCE_GROUP=$(get_azd_value AZURE_RESOURCE_GROUP)
AZURE_CONTAINER_REGISTRY_NAME=$(get_azd_value AZURE_CONTAINER_REGISTRY_NAME)
AZURE_CONTAINER_REGISTRY_ENDPOINT=$(
    get_azd_value AZURE_CONTAINER_REGISTRY_ENDPOINT
)
AZURE_IMAGE_REPOSITORY=$(get_azd_value AZURE_IMAGE_REPOSITORY)
AZURE_ACR_TOKEN_NAME=$(get_azd_value AZURE_ACR_TOKEN_NAME)
AZURE_FUNCTION_NAME=$(get_azd_value AZURE_FUNCTION_NAME)
AZURE_FUNCTION_LOCATION=$(get_azd_value AZURE_FUNCTION_LOCATION)
AZURE_APP_SERVICE_PLAN_ID=$(get_azd_value AZURE_APP_SERVICE_PLAN_ID)
AZURE_STORAGE_ACCOUNT_NAME=$(get_azd_value AZURE_STORAGE_ACCOUNT_NAME)
AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING=$(
    get_azd_value AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING
)
AZURE_USER_ASSIGNED_IDENTITY_ID=$(
    get_azd_value AZURE_USER_ASSIGNED_IDENTITY_ID
)
AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID=$(
    get_azd_value AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID
)
AZURE_FUNCTION_SUBNET_ID=$(get_azd_value AZURE_FUNCTION_SUBNET_ID)

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

BUILD_CONTEXT=$(mktemp -d "${TMPDIR:-/tmp}/function-image.XXXXXX")
CONTEXT_HASH=$("$PYTHON" "$SCRIPT_DIR/imagecontext.py" "$BUILD_CONTEXT")
if ! printf '%s' "$CONTEXT_HASH" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "Image-context hash is invalid: '$CONTEXT_HASH'." >&2
    exit 1
fi

IMAGE_TAG="azd-$CONTEXT_HASH"
TAGGED_IMAGE="$AZURE_IMAGE_REPOSITORY:$IMAGE_TAG"

REPOSITORIES=$(az acr repository list \
    --name "$AZURE_CONTAINER_REGISTRY_NAME" \
    --output tsv \
    --only-show-errors)
TAG_EXISTS=false
if printf '%s\n' "$REPOSITORIES" | grep -Fxq "$AZURE_IMAGE_REPOSITORY"; then
    TAGS=$(az acr repository show-tags \
        --name "$AZURE_CONTAINER_REGISTRY_NAME" \
        --repository "$AZURE_IMAGE_REPOSITORY" \
        --output tsv \
        --only-show-errors)
    if printf '%s\n' "$TAGS" | grep -Fxq "$IMAGE_TAG"; then
        TAG_EXISTS=true
    fi
fi

if [ "$TAG_EXISTS" = true ]; then
    BUILD_ACTION=reused
    echo "Image context is unchanged; reusing $AZURE_CONTAINER_REGISTRY_ENDPOINT/$TAGGED_IMAGE"
else
    BUILD_ACTION=built
    echo "Building Linux AMD64 image with ACR Tasks: $AZURE_CONTAINER_REGISTRY_ENDPOINT/$TAGGED_IMAGE"
    PYTHONUTF8=1 PYTHONIOENCODING=utf-8 az acr build \
        --registry "$AZURE_CONTAINER_REGISTRY_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --platform linux/amd64 \
        --file Dockerfile \
        --image "$TAGGED_IMAGE" \
        --timeout 1800 \
        --only-show-errors \
        "$BUILD_CONTEXT"
fi

get_digest() {
    DIGEST=$(az acr manifest show-metadata \
        --registry "$AZURE_CONTAINER_REGISTRY_NAME" \
        --name "$TAGGED_IMAGE" \
        --query digest \
        --output tsv \
        --only-show-errors)
    printf '%s' "$DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$'
}
retry 6 10 get_digest
REGISTRY_IMAGE="$AZURE_CONTAINER_REGISTRY_ENDPOINT/$TAGGED_IMAGE@$DIGEST"

az acr repository update \
    --name "$AZURE_CONTAINER_REGISTRY_NAME" \
    --image "$TAGGED_IMAGE" \
    --write-enabled false \
    --delete-enabled false \
    --only-show-errors \
    >/dev/null

get_password() {
    REGISTRY_PASSWORD=$(az acr token credential generate \
        --registry "$AZURE_CONTAINER_REGISTRY_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --name "$AZURE_ACR_TOKEN_NAME" \
        --password1 \
        --expiration-in-days 30 \
        --query "passwords[?name=='password1'].value | [0]" \
        --output tsv \
        --only-show-errors)
    [ -n "$REGISTRY_PASSWORD" ]
}
retry 6 10 get_password

PARAMETER_PATH=$(mktemp "${TMPDIR:-/tmp}/function-app.XXXXXX.parameters.json")
export PARAMETER_PATH REGISTRY_PASSWORD REGISTRY_IMAGE
export AZURE_ENV_NAME AZURE_FUNCTION_NAME AZURE_FUNCTION_LOCATION
export AZURE_APP_SERVICE_PLAN_ID AZURE_STORAGE_ACCOUNT_NAME
export AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING
export AZURE_USER_ASSIGNED_IDENTITY_ID
export AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID
export AZURE_FUNCTION_SUBNET_ID AZURE_ACR_TOKEN_NAME

"$PYTHON" - <<'PY'
import json
import os
from pathlib import Path

parameters = {
    "$schema": (
        "https://schema.management.azure.com/schemas/"
        "2019-04-01/deploymentParameters.json#"
    ),
    "contentVersion": "1.0.0.0",
    "parameters": {
        "environmentName": {"value": os.environ["AZURE_ENV_NAME"]},
        "functionAppName": {"value": os.environ["AZURE_FUNCTION_NAME"]},
        "functionLocation": {
            "value": os.environ["AZURE_FUNCTION_LOCATION"]
        },
        "appServicePlanId": {
            "value": os.environ["AZURE_APP_SERVICE_PLAN_ID"]
        },
        "applicationInsightsConnectionString": {
            "value": os.environ[
                "AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING"
            ]
        },
        "storageAccountName": {
            "value": os.environ["AZURE_STORAGE_ACCOUNT_NAME"]
        },
        "userAssignedIdentityId": {
            "value": os.environ["AZURE_USER_ASSIGNED_IDENTITY_ID"]
        },
        "userAssignedIdentityClientId": {
            "value": os.environ["AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID"]
        },
        "virtualNetworkSubnetId": {
            "value": os.environ["AZURE_FUNCTION_SUBNET_ID"]
        },
        "registryImage": {"value": os.environ["REGISTRY_IMAGE"]},
        "registryUsername": {
            "value": os.environ["AZURE_ACR_TOKEN_NAME"]
        },
        "registryPassword": {
            "value": os.environ["REGISTRY_PASSWORD"]
        },
    },
}

path = Path(os.environ["PARAMETER_PATH"])
path.write_text(json.dumps(parameters, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)
PY

TIMESTAMP=$(date -u +%Y%m%d%H%M%S)
DEPLOYMENT_NAME="registry-app-$TIMESTAMP"
STATE=$(az deployment group create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$DEPLOYMENT_NAME" \
    --template-file ./infra/app/api.bicep \
    --parameters "@$PARAMETER_PATH" \
    --query properties.provisioningState \
    --output tsv \
    --only-show-errors)
if [ "$STATE" != "Succeeded" ]; then
    echo "Registry Function App deployment ended in state '$STATE'." >&2
    exit 1
fi

azd env set AZURE_IMAGE_CONTEXT_HASH "$CONTEXT_HASH" --no-prompt >/dev/null
azd env set AZURE_IMAGE_BUILD_ACTION "$BUILD_ACTION" --no-prompt >/dev/null
azd env set AZURE_IMAGE_TAG "$IMAGE_TAG" --no-prompt >/dev/null
azd env set AZURE_IMAGE_DIGEST "$DIGEST" --no-prompt >/dev/null
azd env set AZURE_REGISTRY_IMAGE "$REGISTRY_IMAGE" --no-prompt >/dev/null
azd env set API_URL "https://$AZURE_FUNCTION_NAME.azurewebsites.net" \
    --no-prompt \
    >/dev/null

az functionapp start \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_FUNCTION_NAME" \
    --only-show-errors

echo "Updated Registry-backed Function App '$AZURE_FUNCTION_NAME'."
echo "Image action: $BUILD_ACTION"
echo "Pinned image: $REGISTRY_IMAGE"

if [ "$VERIFY" = true ]; then
    sh "$SCRIPT_DIR/postdeploy.sh"
fi
