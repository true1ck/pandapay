param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('dev', 'staging', 'prod')]
  [string]$Environment,

  [ValidateSet('apk', 'appbundle')]
  [string]$Target = 'apk',

  [switch]$SplitPerAbi,
  [string]$BuildNumber,
  [string]$ApiBaseUrl,
  [string]$AuthBaseUrl,
  [string]$LegalBaseUrl
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$appRoot = Join-Path $repoRoot 'app'

if ($Environment -eq 'dev') {
  if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) { $ApiBaseUrl = 'http://10.0.2.2:4000' }
  if ([string]::IsNullOrWhiteSpace($AuthBaseUrl)) { $AuthBaseUrl = 'http://10.0.2.2:3210' }
  if ([string]::IsNullOrWhiteSpace($LegalBaseUrl)) { $LegalBaseUrl = 'http://10.0.2.2:4000/legal/' }
} else {
  if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) { $ApiBaseUrl = $env:PANDAPAY_API_BASE_URL }
  if ([string]::IsNullOrWhiteSpace($AuthBaseUrl)) { $AuthBaseUrl = $env:PANDAPAY_AUTH_BASE_URL }
  if ([string]::IsNullOrWhiteSpace($LegalBaseUrl)) { $LegalBaseUrl = $env:PANDAPAY_LEGAL_BASE_URL }
  if ([string]::IsNullOrWhiteSpace($ApiBaseUrl) -or [string]::IsNullOrWhiteSpace($AuthBaseUrl)) {
    throw "$Environment build requires -ApiBaseUrl and -AuthBaseUrl (or PANDAPAY_API_BASE_URL and PANDAPAY_AUTH_BASE_URL)."
  }
  if ([string]::IsNullOrWhiteSpace($LegalBaseUrl)) { $LegalBaseUrl = "$($ApiBaseUrl.TrimEnd('/'))/legal/" }
  if ($ApiBaseUrl -match '^(?i)http://(localhost|127\.0\.0\.1|10\.0\.2\.2)') {
    throw "$Environment build cannot point at a local API URL: $ApiBaseUrl"
  }
  if ($AuthBaseUrl -match '^(?i)http://(localhost|127\.0\.0\.1|10\.0\.2\.2)') {
    throw "$Environment build cannot point at a local auth URL: $AuthBaseUrl"
  }
}

$flutterArgs = @(
  'build', $Target,
  '--flavor', $Environment,
  "--dart-define=PANDAPAY_ENV=$Environment",
  "--dart-define=PANDAPAY_API_BASE_URL=$ApiBaseUrl",
  "--dart-define=PANDAPAY_AUTH_BASE_URL=$AuthBaseUrl",
  "--dart-define=PANDAPAY_LEGAL_BASE_URL=$LegalBaseUrl"
)
if ($SplitPerAbi) { $flutterArgs += '--split-per-abi' }
if (-not [string]::IsNullOrWhiteSpace($BuildNumber)) { $flutterArgs += "--build-number=$BuildNumber" }

Write-Host "Building $Environment $Target with hosted endpoints:" -ForegroundColor Cyan
Write-Host "  API:   $ApiBaseUrl"
Write-Host "  Auth:  $AuthBaseUrl"
Write-Host "  Legal: $LegalBaseUrl"

Push-Location $appRoot
try {
  & flutter @flutterArgs
  if ($LASTEXITCODE -ne 0) { throw "Flutter build failed with exit code $LASTEXITCODE." }
} finally {
  Pop-Location
}
