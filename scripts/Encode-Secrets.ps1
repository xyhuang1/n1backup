#Requires -Version 5.1
<#
.SYNOPSIS
  把 Apple 证书 (.p12) 和描述文件 (.mobileprovision) 转成 GitHub Actions 用的 base64 文本。

.EXAMPLE
  .\scripts\Encode-Secrets.ps1 -P12Path D:\certs\dev.p12 -ProfilePath D:\certs\app.mobileprovision
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $P12Path,

    [Parameter(Mandatory = $true)]
    [string] $ProfilePath,

    [string] $OutDir = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $P12Path)) {
    throw "找不到 p12: $P12Path"
}
if (-not (Test-Path -LiteralPath $ProfilePath)) {
    throw "找不到描述文件: $ProfilePath"
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) "secrets-out"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Encode-File([string] $Path) {
    [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $Path)))
}

$certB64 = Encode-File $P12Path
$profB64 = Encode-File $ProfilePath

$certOut = Join-Path $OutDir "APPLE_CERTIFICATE_BASE64.txt"
$profOut = Join-Path $OutDir "APPLE_PROVISION_BASE64.txt"

Set-Content -Path $certOut -Value $certB64 -Encoding ascii -NoNewline
Set-Content -Path $profOut -Value $profB64 -Encoding ascii -NoNewline

Write-Host ""
Write-Host "已生成（整段复制到 GitHub Secrets，不要提交 git）：" -ForegroundColor Green
Write-Host "  $certOut"
Write-Host "  $profOut"
Write-Host ""
Write-Host "还需要手动填写的 Secrets：" -ForegroundColor Yellow
Write-Host "  APPLE_TEAM_ID"
Write-Host "  APPLE_CERTIFICATE_PASSWORD   ← 导出 p12 时的密码"
Write-Host "  PROVISIONING_PROFILE_NAME    ← 开发者后台 Profile 的 Name"
Write-Host "  APPLE_BUNDLE_ID              ← 与 App ID 一致"
Write-Host ""
Write-Host "详细步骤见 docs\GITHUB_ACTIONS_IPA.md"
