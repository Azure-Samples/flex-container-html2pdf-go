[CmdletBinding()]
param(
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repositoryRoot

function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = (& azd env get-value $Name).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required azd environment value '$Name' is missing."
    }
    return $value
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [int]$Attempts = 6,
        [int]$DelaySeconds = 10
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            return & $Operation
        } catch {
            if ($attempt -eq $Attempts) {
                throw
            }
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-GoCommand {
    $command = Get-Command go -ErrorAction SilentlyContinue
    if ($command) {
        & $command.Source version *> $null
        if ($LASTEXITCODE -eq 0) {
            return $command.Source
        }
    }
    throw 'Go 1.27 or later is required for the deployment helper.'
}

$parameterPath = $null
$buildContext = $null
$helperPath = $null
$registryPassword = $null

try {
    $go = Get-GoCommand
    $subscriptionId = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
    $environmentName = Get-AzdValue 'AZURE_ENV_NAME'
    $resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
    $registryName = Get-AzdValue 'AZURE_CONTAINER_REGISTRY_NAME'
    $registryEndpoint = Get-AzdValue 'AZURE_CONTAINER_REGISTRY_ENDPOINT'
    $imageRepository = Get-AzdValue 'AZURE_IMAGE_REPOSITORY'
    $tokenName = Get-AzdValue 'AZURE_ACR_TOKEN_NAME'
    $functionAppName = Get-AzdValue 'AZURE_FUNCTION_NAME'
    $functionLocation = Get-AzdValue 'AZURE_FUNCTION_LOCATION'
    $appServicePlanId = Get-AzdValue 'AZURE_APP_SERVICE_PLAN_ID'
    $storageAccountName = Get-AzdValue 'AZURE_STORAGE_ACCOUNT_NAME'
    $applicationInsightsConnectionString =
        Get-AzdValue 'AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING'
    $identityId = Get-AzdValue 'AZURE_USER_ASSIGNED_IDENTITY_ID'
    $identityClientId = Get-AzdValue 'AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID'
    $functionSubnetId = Get-AzdValue 'AZURE_FUNCTION_SUBNET_ID'

    & az account set --subscription $subscriptionId

    $buildContext = Join-Path ([IO.Path]::GetTempPath()) (
        "function-image-$([guid]::NewGuid().ToString('N'))"
    )
    $helperPath = Join-Path ([IO.Path]::GetTempPath()) (
        "go-deploy-helper-$([guid]::NewGuid().ToString('N')).exe"
    )
    New-Item -ItemType Directory -Path $buildContext | Out-Null
    & $go build -o $helperPath .\infra\scripts\deployhelper
    $contextHash = (& $helperPath stage-context $buildContext).Trim()
    if ($contextHash -notmatch '^[0-9a-f]{64}$') {
        throw "Image-context hash is invalid: '$contextHash'."
    }

    $imageTag = "azd-$contextHash"
    $taggedImage = "$imageRepository`:$imageTag"

    $repositories = @(
        & az acr repository list `
            --name $registryName `
            --output tsv `
            --only-show-errors
    )
    $tagExists = $false
    if ($repositories -contains $imageRepository) {
        $tags = @(
            & az acr repository show-tags `
                --name $registryName `
                --repository $imageRepository `
                --output tsv `
                --only-show-errors
        )
        $tagExists = $tags -contains $imageTag
    }

    if ($tagExists) {
        $buildAction = 'reused'
        Write-Host (
            "Image context is unchanged; reusing " +
            "$registryEndpoint/$taggedImage"
        )
    } else {
        $buildAction = 'built'
        Write-Host (
            "Building Linux AMD64 image with ACR Tasks: " +
            "$registryEndpoint/$taggedImage"
        )
        $buildRunJson = & az acr build `
            --registry $registryName `
            --resource-group $resourceGroup `
            --platform linux/amd64 `
            --file Dockerfile `
            --image $taggedImage `
            --timeout 1800 `
            --no-logs `
            --only-show-errors `
            --output json `
            $buildContext
        $buildRun = $buildRunJson | ConvertFrom-Json
        if ($buildRun.status -ne 'Succeeded') {
            throw "ACR build '$($buildRun.runId)' ended in state '$($buildRun.status)'."
        }
        Write-Host "ACR build '$($buildRun.runId)' succeeded."
    }

    $digest = Invoke-WithRetry {
        $value = (& az acr manifest show-metadata `
                --registry $registryName `
                --name $taggedImage `
                --query digest `
                --output tsv `
                --only-show-errors).Trim()
        if ($value -notmatch '^sha256:[0-9a-f]{64}$') {
            throw 'Image digest is not available yet.'
        }
        return $value
    }
    $registryImage = "$registryEndpoint/$taggedImage@$digest"

    & az acr repository update `
        --name $registryName `
        --image $taggedImage `
        --write-enabled false `
        --delete-enabled false `
        --only-show-errors |
        Out-Null

    $registryPassword = Invoke-WithRetry {
        $value = (& az acr token credential generate `
                --registry $registryName `
                --resource-group $resourceGroup `
                --name $tokenName `
                --password1 `
                --expiration-in-days 30 `
                --query "passwords[?name=='password1'].value | [0]" `
                --output tsv `
                --only-show-errors).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw 'ACR token password generation returned no value.'
        }
        return $value
    }

    $parameters = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            environmentName = @{ value = $environmentName }
            functionAppName = @{ value = $functionAppName }
            functionLocation = @{ value = $functionLocation }
            appServicePlanId = @{ value = $appServicePlanId }
            applicationInsightsConnectionString = @{
                value = $applicationInsightsConnectionString
            }
            storageAccountName = @{ value = $storageAccountName }
            userAssignedIdentityId = @{ value = $identityId }
            userAssignedIdentityClientId = @{ value = $identityClientId }
            virtualNetworkSubnetId = @{ value = $functionSubnetId }
            registryImage = @{ value = $registryImage }
            registryUsername = @{ value = $tokenName }
            registryPassword = @{ value = $registryPassword }
        }
    }

    $parameterPath = Join-Path ([IO.Path]::GetTempPath()) (
        "function-app-$([guid]::NewGuid().ToString('N')).parameters.json"
    )
    $parameters |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $parameterPath -Encoding utf8NoBOM

    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $deploymentName = "registry-app-$timestamp"
    $state = (& az deployment group create `
            --resource-group $resourceGroup `
            --name $deploymentName `
            --template-file .\infra\app\api.bicep `
            --parameters "@$parameterPath" `
            --query properties.provisioningState `
            --output tsv `
            --only-show-errors).Trim()
    if ($state -ne 'Succeeded') {
        throw "Registry Function App deployment ended in state '$state'."
    }

    & azd env set AZURE_IMAGE_CONTEXT_HASH $contextHash --no-prompt |
        Out-Null
    & azd env set AZURE_IMAGE_BUILD_ACTION $buildAction --no-prompt |
        Out-Null
    & azd env set AZURE_IMAGE_TAG $imageTag --no-prompt | Out-Null
    & azd env set AZURE_IMAGE_DIGEST $digest --no-prompt | Out-Null
    & azd env set AZURE_REGISTRY_IMAGE $registryImage --no-prompt |
        Out-Null
    & azd env set API_URL "https://$functionAppName.azurewebsites.net" `
        --no-prompt |
        Out-Null

    & az functionapp start `
        --resource-group $resourceGroup `
        --name $functionAppName `
        --only-show-errors

    Write-Host "Updated Registry-backed Function App '$functionAppName'."
    Write-Host "Image action: $buildAction"
    Write-Host "Pinned image: $registryImage"

    if ($Verify) {
        & (Join-Path $PSScriptRoot 'postdeploy.ps1')
    }
} finally {
    if ($parameterPath -and (Test-Path -LiteralPath $parameterPath)) {
        Remove-Item -LiteralPath $parameterPath -Force
    }
    if ($buildContext -and (Test-Path -LiteralPath $buildContext)) {
        Remove-Item -LiteralPath $buildContext -Recurse -Force
    }
    if ($helperPath -and (Test-Path -LiteralPath $helperPath)) {
        Remove-Item -LiteralPath $helperPath -Force
    }
    $registryPassword = $null
    Pop-Location
}
