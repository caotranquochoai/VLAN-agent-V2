param(
  [string]$Version = "0.1.0-dev",
  [string]$OutDir = "dist-release"
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$ReleaseRoot = Join-Path $Root $OutDir
$PackageDir = Join-Path $ReleaseRoot "client-manager-$Version-linux-amd64"
$ZipPath = Join-Path $ReleaseRoot "client-manager-$Version-linux-amd64.zip"

Write-Host "==> Cleaning release directory"
Remove-Item -Recurse -Force $PackageDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $PackageDir | Out-Null
New-Item -ItemType Directory -Force (Join-Path $PackageDir "bin") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $PackageDir "data") | Out-Null

Write-Host "==> Building web dashboard"
Push-Location (Join-Path $Root "web")
npm install
npm run build
Pop-Location

Write-Host "==> Building Linux amd64 binary"
Push-Location $Root
$env:GOOS = "linux"
$env:GOARCH = "amd64"
go build -trimpath -ldflags "-s -w" -o (Join-Path $PackageDir "proxy-client-manager") ./cmd/proxy-client-manager
Remove-Item Env:GOOS -ErrorAction SilentlyContinue
Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
Pop-Location

Write-Host "==> Copying runtime assets"
Copy-Item -Recurse -Force (Join-Path $Root "web\dist") (Join-Path $PackageDir "web")
if (Test-Path (Join-Path $Root "bin\bridge_linux")) {
  Copy-Item -Force (Join-Path $Root "bin\bridge_linux") (Join-Path $PackageDir "bin\bridge_linux")
} else {
  Write-Warning "bin/bridge_linux not found. Copy it manually before deploying."
}
Copy-Item -Force (Join-Path $Root "README.md") (Join-Path $PackageDir "README.md")

$InstallScript = @'
#!/usr/bin/env bash
set -euo pipefail
chmod +x ./proxy-client-manager || true
chmod +x ./bin/bridge_linux || true
mkdir -p ./data
cat <<INFO
Installed client-manager package.
Run:
  ./proxy-client-manager serve --host 0.0.0.0 --port 8090
INFO
'@
Set-Content -Path (Join-Path $PackageDir "install.sh") -Value $InstallScript -Encoding UTF8

Write-Host "==> Creating zip package"
Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $PackageDir "*") -DestinationPath $ZipPath

Write-Host "==> Release package ready: $ZipPath"
