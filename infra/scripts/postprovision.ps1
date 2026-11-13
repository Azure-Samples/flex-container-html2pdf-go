$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

& (Join-Path $PSScriptRoot 'deployimage.ps1')
