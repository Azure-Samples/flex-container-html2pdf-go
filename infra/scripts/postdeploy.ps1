$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

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

function Invoke-CurlRequest {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Directory
    )

    $headersPath = Join-Path $Directory "$Name.headers"
    $bodyPath = Join-Path $Directory "$Name.body"
    $curlArguments = @(
        '--silent',
        '--show-error',
        '--max-time', '120',
        '--dump-header', $headersPath,
        '--output', $bodyPath,
        '--write-out', '%{http_code}'
    ) + $Arguments
    $statusText = & curl.exe @curlArguments
    $exitCode = $LASTEXITCODE
    $status = if ($statusText -match '^\d{3}$') {
        [int]$statusText
    } else {
        0
    }
    return [pscustomobject]@{
        Name = $Name
        ExitCode = $exitCode
        Status = $status
        HeadersPath = $headersPath
        BodyPath = $bodyPath
    }
}

function Get-ResponseContentType {
    param([Parameter(Mandatory)][string]$HeadersPath)

    $line = Select-String `
        -Path $HeadersPath `
        -Pattern '^Content-Type:' `
        -CaseSensitive:$false |
        Select-Object -Last 1
    if (-not $line) {
        return ''
    }
    return ($line.Line -split ':', 2)[1].Trim()
}

function Test-PdfFile {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 100) {
        throw "PDF '$Path' is unexpectedly small."
    }
    $prefix = [Text.Encoding]::ASCII.GetString($bytes, 0, 5)
    $tailLength = [Math]::Min(2048, $bytes.Length)
    $tail = [Text.Encoding]::ASCII.GetString(
        $bytes,
        $bytes.Length - $tailLength,
        $tailLength
    )
    if ($prefix -ne '%PDF-' -or $tail -notmatch '%%EOF\s*$') {
        throw "PDF '$Path' does not contain valid PDF boundary markers."
    }
    return $bytes.Length
}

$subscriptionId = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
$resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
$functionAppName = Get-AzdValue 'AZURE_FUNCTION_NAME'
$apiUrl = (Get-AzdValue 'API_URL').TrimEnd('/')
$registryImage = Get-AzdValue 'AZURE_REGISTRY_IMAGE'
$functionSubnetId = Get-AzdValue 'AZURE_FUNCTION_SUBNET_ID'
$siteId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$functionAppName"

& az account set --subscription $subscriptionId

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) (
    "go-pdf-verification-$([guid]::NewGuid().ToString('N'))"
)
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

try {
    $deadline = [DateTime]::UtcNow.AddMinutes(6)
    $restartAt = [DateTime]::UtcNow.AddMinutes(2)
    $restarted = $false
    $helloGet = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        $helloGet = Invoke-CurlRequest `
            -Name 'hello-get' `
            -Arguments @("$apiUrl/api/hello") `
            -Directory $temporaryDirectory
        $helloBody = if (Test-Path $helloGet.BodyPath) {
            Get-Content -LiteralPath $helloGet.BodyPath -Raw
        } else {
            ''
        }
        if ($helloGet.ExitCode -eq 0 -and
            $helloGet.Status -eq 200 -and
            $helloBody -eq 'Hello from the Go worker.') {
            break
        }

        if (-not $restarted -and [DateTime]::UtcNow -ge $restartAt) {
            & az functionapp restart `
                --resource-group $resourceGroup `
                --name $functionAppName `
                --only-show-errors
            $restarted = $true
        }
        Start-Sleep -Seconds 10
    }

    if ($helloGet.Status -ne 200 -or
        $helloBody -ne 'Hello from the Go worker.') {
        throw 'The Go worker did not become healthy within six minutes.'
    }

    $helloPost = Invoke-CurlRequest `
        -Name 'hello-post' `
        -Arguments @('--request', 'POST', "$apiUrl/api/hello") `
        -Directory $temporaryDirectory
    $helloPostBody = Get-Content -LiteralPath $helloPost.BodyPath -Raw
    if ($helloPost.ExitCode -ne 0 -or
        $helloPost.Status -ne 200 -or
        $helloPostBody -ne 'Hello from the Go worker.') {
        throw 'Hello POST did not return the exact expected response.'
    }

    $pdfGet = Invoke-CurlRequest `
        -Name 'pdf-get' `
        -Arguments @("$apiUrl/api/html-to-pdf") `
        -Directory $temporaryDirectory
    $pdfGetContentType = Get-ResponseContentType $pdfGet.HeadersPath
    $pdfGetBytes = Test-PdfFile $pdfGet.BodyPath
    if ($pdfGet.ExitCode -ne 0 -or
        $pdfGet.Status -ne 200 -or
        $pdfGetContentType -notmatch '^application/pdf') {
        throw 'HTML-to-PDF GET did not return a valid PDF response.'
    }

    $customHtmlPath = Join-Path $temporaryDirectory 'custom.html'
    @'
<!doctype html>
<html lang="en">
<body>
  <h1>Flex Consumption Go container validation</h1>
  <p>Rendered from bounded raw HTML with chromedp.</p>
</body>
</html>
'@ | Set-Content -LiteralPath $customHtmlPath -Encoding utf8NoBOM

    $pdfPost = Invoke-CurlRequest `
        -Name 'pdf-post' `
        -Arguments @(
            '--request', 'POST',
            '--header', 'Content-Type: text/html; charset=utf-8',
            '--data-binary', "@$customHtmlPath",
            "$apiUrl/api/html-to-pdf"
        ) `
        -Directory $temporaryDirectory
    $pdfPostContentType = Get-ResponseContentType $pdfPost.HeadersPath
    $pdfPostBytes = Test-PdfFile $pdfPost.BodyPath
    if ($pdfPost.ExitCode -ne 0 -or
        $pdfPost.Status -ne 200 -or
        $pdfPostContentType -notmatch '^application/pdf') {
        throw 'HTML-to-PDF POST did not return a valid PDF response.'
    }

    $invalidPost = Invoke-CurlRequest `
        -Name 'pdf-invalid-json' `
        -Arguments @(
            '--request', 'POST',
            '--header', 'Content-Type: application/json',
            '--data-binary', '{}',
            "$apiUrl/api/html-to-pdf"
        ) `
        -Directory $temporaryDirectory
    $invalidBody = Get-Content -LiteralPath $invalidPost.BodyPath -Raw
    if ($invalidPost.ExitCode -ne 0 -or
        $invalidPost.Status -ne 415 -or
        $invalidBody -notmatch 'Content-Type must be text/html') {
        throw 'The endpoint did not reject application/json with HTTP 415.'
    }

    $inventoryDeadline = [DateTime]::UtcNow.AddMinutes(2)
    $functionNames = @()
    do {
        $functionNames = @(
            & az rest `
                --method get `
                --url "https://management.azure.com$siteId/functions?api-version=2026-08-01" `
                --query 'value[].name' `
                --output tsv
        )
        $leafNames = @(
            $functionNames |
                ForEach-Object { ($_ -split '/')[-1] } |
                Where-Object { $_ }
        )
        if ($leafNames.Count -eq 2 -and
            $leafNames -contains 'Hello' -and
            $leafNames -contains 'HtmlToPdf') {
            break
        }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $inventoryDeadline)

    if ($leafNames.Count -ne 2 -or
        -not ($leafNames -contains 'Hello') -or
        -not ($leafNames -contains 'HtmlToPdf')) {
        throw "Azure did not inventory exactly Hello and HtmlToPdf: $leafNames"
    }

    $site = & az rest `
        --method get `
        --url "https://management.azure.com$siteId`?api-version=2026-08-01" `
        --output json |
        ConvertFrom-Json
    if ($site.properties.state -ne 'Running' -or
        $site.properties.functionAppConfig.deployment.storage.type -ne 'Registry' -or
        $site.properties.functionAppConfig.deployment.storage.value -ne $registryImage -or
        $site.properties.virtualNetworkSubnetId -ne $functionSubnetId -or
        $site.identity.type -notmatch 'UserAssigned') {
        throw 'The Function App deployment, identity, or network configuration does not match.'
    }

    $appSettings = (& az rest `
            --method post `
            --url "https://management.azure.com$siteId/config/appsettings/list?api-version=2026-08-01" `
            --output json |
            ConvertFrom-Json).properties
    $settingNames = @($appSettings.PSObject.Properties.Name)
    $appSettings = $null
    foreach ($forbiddenName in @(
            'FUNCTIONS_APPLICATION_DIRECTORY',
            'FUNCTIONS_GO_DISABLE_HTTP_PROXY',
            'AzureWebJobsScriptRoot',
            'WEBSITE_RUN_FROM_PACKAGE'
        )) {
        if ($settingNames -contains $forbiddenName) {
            throw "Forbidden application setting '$forbiddenName' is present."
        }
    }

    $verifiedUtc = [DateTime]::UtcNow.ToString('o')
    & azd env set AZURE_VERIFIED_UTC $verifiedUtc --no-prompt | Out-Null

    [ordered]@{
        functionApp = $functionAppName
        state = $site.properties.state
        deploymentType = $site.properties.functionAppConfig.deployment.storage.type
        image = $site.properties.functionAppConfig.deployment.storage.value
        functions = $leafNames
        helloGetStatus = $helloGet.Status
        helloPostStatus = $helloPost.Status
        pdfGetBytes = $pdfGetBytes
        pdfPostBytes = $pdfPostBytes
        invalidContentTypeStatus = $invalidPost.Status
        verifiedUtc = $verifiedUtc
    } | ConvertTo-Json -Depth 4
} finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
