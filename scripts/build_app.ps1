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
  [string]$LegalBaseUrl,
  [string]$NearbyRadiusMeters,
  [switch]$AllowDebugSigningForDeviceTest,
  [switch]$ProductionBackend
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$appRoot = Join-Path $repoRoot 'app'
$keyProperties = Join-Path $appRoot 'android\key.properties'

if ($Environment -eq 'prod' -and -not (Test-Path -LiteralPath $keyProperties) -and -not $AllowDebugSigningForDeviceTest) {
  throw "Production builds require app/android/key.properties. Refusing to use the Android debug signing key, because it cannot update an installed release signed with the original release key."
}

if ($AllowDebugSigningForDeviceTest -and $Environment -ne 'prod') {
  throw "-AllowDebugSigningForDeviceTest is only valid with the prod flavor."
}

if ($AllowDebugSigningForDeviceTest -and (Test-Path -LiteralPath $keyProperties)) {
  throw "The release keystore is available; do not override it with debug signing for a device test."
}

if ($ProductionBackend -and $Environment -ne 'dev') {
  throw "-ProductionBackend is only valid with the dev flavor so the existing Dev package can be updated in place."
}

if ($Environment -eq 'prod' -and [string]::IsNullOrWhiteSpace($BuildNumber)) {
  throw "Production builds require an explicit -BuildNumber so an older APK cannot be shared by mistake."
}

if ($Environment -eq 'prod' -and $Target -eq 'apk' -and -not $SplitPerAbi) {
  throw "Production phone APKs must use -SplitPerAbi. Build an app bundle separately for Play Console delivery."
}

if (-not [string]::IsNullOrWhiteSpace($BuildNumber) -and $BuildNumber -notmatch '^[1-9][0-9]*$') {
  throw "-BuildNumber must be a positive integer."
}

if (-not [string]::IsNullOrWhiteSpace($NearbyRadiusMeters)) {
  if ($NearbyRadiusMeters -notmatch '^[1-9][0-9]*(\.[0-9]+)?$') {
    throw "-NearbyRadiusMeters must be a positive number."
  }
  $radius = [double]$NearbyRadiusMeters
  if ($radius -gt 5000) {
    throw "-NearbyRadiusMeters cannot exceed 5000 while the free nearby discovery route has a 5 km limit."
  }
}

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

$backendEnvironment = $Environment
if ($ProductionBackend) {
  if ($ApiBaseUrl -match '^(?i)http://(localhost|127\.0\.0\.1|10\.0\.2\.2)') {
    throw "-ProductionBackend requires a hosted API URL: $ApiBaseUrl"
  }
  if ($AuthBaseUrl -match '^(?i)http://(localhost|127\.0\.0\.1|10\.0\.2\.2)') {
    throw "-ProductionBackend requires a hosted auth URL: $AuthBaseUrl"
  }
  $backendEnvironment = 'dev_hosted'
}

$flutterArgs = @(
  'build', $Target,
  '--flavor', $Environment,
  "--dart-define=PANDAPAY_ENV=$backendEnvironment",
  "--dart-define=PANDAPAY_API_BASE_URL=$ApiBaseUrl",
  "--dart-define=PANDAPAY_AUTH_BASE_URL=$AuthBaseUrl",
  "--dart-define=PANDAPAY_LEGAL_BASE_URL=$LegalBaseUrl"
)
if ($SplitPerAbi) { $flutterArgs += '--split-per-abi' }
if (-not [string]::IsNullOrWhiteSpace($BuildNumber)) { $flutterArgs += "--build-number=$BuildNumber" }
if (-not [string]::IsNullOrWhiteSpace($NearbyRadiusMeters)) {
  $flutterArgs += "--dart-define=PANDAPAY_NEARBY_RADIUS_METERS=$NearbyRadiusMeters"
}

Write-Host "Building $Environment $Target with backend environment ${backendEnvironment}:" -ForegroundColor Cyan
Write-Host "  API:   $ApiBaseUrl"
Write-Host "  Auth:  $AuthBaseUrl"
Write-Host "  Legal: $LegalBaseUrl"
if ($AllowDebugSigningForDeviceTest) {
  Write-Warning "This is a physical-device test build signed with the Android debug key. Do not distribute it as a production release."
}

Push-Location $appRoot
try {
  & flutter @flutterArgs
  if ($LASTEXITCODE -ne 0) { throw "Flutter build failed with exit code $LASTEXITCODE." }
} finally {
  Pop-Location
}
