<#
.SYNOPSIS
    Generate nginx default.conf for Xensor reverse proxy deployment.

.DESCRIPTION
    Produces a production-ready nginx configuration matching CyCraft's
    standard deployment pattern, including:
    - SSL with specific cipher suite
    - Security headers (XSS, X-Frame-Options, CORS)
    - UI location blocks with rewrite rules
    - Path-based caching (agent, cydroned, xdl)
    - include mpmpattern.conf
    - Optional self-signed certificate generation

.EXAMPLE
    .\Generate-NginxConfig.ps1
    # Interactive mode - prompts for all parameters

.EXAMPLE
    .\Generate-NginxConfig.ps1 -ListenPort 443 -Backend "xensor-tw.cycarrier.com" -GenerateCert
#>

param(
    [int]$ListenPort,
    [string]$Backend,
    [int]$BackendPort = 443,
    [string]$BackendProtocol,
    [switch]$GenerateCert,
    [string]$CertPath = "/etc/nginx/cert",
    [switch]$EnableCache,
    [ValidateSet("bandwidth-saving", "realtime")]
    [string]$CachePolicy = "bandwidth-saving",
    [string]$ClientMaxBodySize = "100m",
    [string]$ClientBodyBufferSize = "100k",
    [int]$ProxyTimeout = 60,
    [switch]$IncludeMpmPattern,
    [string]$MpmPatternPath = "/etc/nginx/mpmpattern.conf",
    [string]$OutputPath
)

# ===============================
# Interactive Input
# ===============================
function Read-Parameter {
    param(
        [string]$Prompt,
        [string]$Default,
        [string]$CurrentValue
    )
    if ($CurrentValue) { return $CurrentValue }
    $display = if ($Default) { "$Prompt [default: $Default]" } else { $Prompt }
    $val = Read-Host $display
    if ([string]::IsNullOrWhiteSpace($val) -and $Default) { return $Default }
    if ([string]::IsNullOrWhiteSpace($val)) {
        Write-Host "  This parameter is required." -ForegroundColor Red
        return Read-Parameter -Prompt $Prompt -Default $Default -CurrentValue ""
    }
    return $val
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $defaultText = if ($Default) { "Y/n" } else { "y/N" }
    $val = Read-Host "$Prompt [$defaultText]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return ($val -match "^[Yy]")
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Nginx Config Generator for Xensor" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- Core ---
if (-not $ListenPort) {
    $ListenPort = [int](Read-Parameter -Prompt "Listen Port (e.g. 80, 443)" -Default "443")
}
$Backend = Read-Parameter -Prompt "Backend IP or URL (e.g. xensor-tw.cycarrier.com)" -Default "" -CurrentValue $Backend

# DNS pre-check: validate backend hostname before proceeding
$backendHost = $Backend -replace '^\w+://', '' -replace '/.*$', '' -replace ':\d+$', ''
try {
    $dnsResult = [System.Net.Dns]::GetHostAddresses($backendHost)
    Write-Host "  [OK] DNS resolved: ${backendHost} -> $($dnsResult[0])" -ForegroundColor Green
} catch {
    Write-Host "  [WARNING] Cannot resolve '${backendHost}' via DNS!" -ForegroundColor Red
    Write-Host "  nginx will fail to start if the backend hostname is unreachable." -ForegroundColor Yellow
    $confirm = Read-Host "  Continue anyway? (y/N)"
    if ($confirm -notmatch "^[Yy]") {
        Write-Host "  Aborted." -ForegroundColor Red
        exit 1
    }
}

$BackendPort = [int](Read-Parameter -Prompt "Backend Port" -Default "443" -CurrentValue $(if ($PSBoundParameters.ContainsKey('BackendPort')) { $BackendPort } else { "" }))

if (-not $BackendProtocol) {
    $BackendProtocol = if ($BackendPort -eq 443) { "https" } else { "http" }
}

$backendUrl = if ($BackendPort -eq 443 -or $BackendPort -eq 80) {
    "${BackendProtocol}://${Backend}"
} else {
    "${BackendProtocol}://${Backend}:${BackendPort}"
}

# --- SSL ---
$isSSL = ($ListenPort -eq 443)
if ($isSSL -and -not $PSBoundParameters.ContainsKey('GenerateCert')) {
    $GenerateCert = Read-YesNo -Prompt "Generate self-signed certificate?" -Default $true
}
if ($isSSL -and -not $PSBoundParameters.ContainsKey('CertPath') -and [string]::IsNullOrWhiteSpace($CertPath)) {
    $CertPath = Read-Parameter -Prompt "Certificate directory" -Default "/etc/nginx/cert" -CurrentValue ""
}

# --- Cache ---
if (-not $PSBoundParameters.ContainsKey('EnableCache')) {
    $EnableCache = Read-YesNo -Prompt "Enable path-based caching rules?" -Default $true
}
if ($EnableCache -and -not $PSBoundParameters.ContainsKey('CachePolicy')) {
    Write-Host ""
    Write-Host "  Cache Policy:" -ForegroundColor Yellow
    Write-Host "    1) bandwidth-saving  - cache downloadable resources for 1 day" -ForegroundColor Gray
    Write-Host "    2) realtime          - cache downloadable resources for 1 hour" -ForegroundColor Gray
    $choice = Read-Parameter -Prompt "Choose cache policy (1 or 2)" -Default "1"
    $CachePolicy = if ($choice -eq "2") { "realtime" } else { "bandwidth-saving" }
}

# --- mpmpattern ---
if (-not $PSBoundParameters.ContainsKey('IncludeMpmPattern')) {
    $IncludeMpmPattern = Read-YesNo -Prompt "Include mpmpattern.conf?" -Default $true
}

# --- Advanced ---
if (-not $PSBoundParameters.ContainsKey('ClientMaxBodySize') -and $ClientMaxBodySize -eq "100m") {
    $ClientMaxBodySize = Read-Parameter -Prompt "Client max body size" -Default "100m" -CurrentValue ""
}
if (-not $PSBoundParameters.ContainsKey('ProxyTimeout') -and $ProxyTimeout -eq 60) {
    $ProxyTimeout = [int](Read-Parameter -Prompt "Proxy timeout (seconds)" -Default "60" -CurrentValue "")
}

# --- Output ---
if (-not $OutputPath) {
    $defaultOutput = Join-Path $PSScriptRoot "default.conf"
    $OutputPath = Read-Parameter -Prompt "Output file path" -Default $defaultOutput -CurrentValue ""
}

# ===============================
# Helper: build a location block
# ===============================
$cacheTTL = if ($CachePolicy -eq "realtime") { "1h" } else { "1d" }

function New-LocationBlock {
    param(
        [string]$Location,
        [string]$BackendUrl,
        [switch]$Cache,
        [string]$CacheTTL,
        [switch]$ProxySslServerName,
        [string[]]$RewriteRules
    )
    $lines = @()
    $lines += ("        location " + $Location + " {")

    if ($RewriteRules) {
        foreach ($r in $RewriteRules) {
            $lines += "              ${r}"
        }
    }

    $lines += '              add_header "Access-Control-Allow-Origin"  *;'
    $lines += '              add_header "Access-Control-Allow-Methods" "GET, POST, OPTIONS, HEAD";'
    $lines += '              add_header Cache-Control "public";'

    if ($Cache) {
        $lines += "              proxy_cache_valid  200 ${CacheTTL};"
        $lines += '              proxy_cache_key $uri$is_args$args;'
        $lines += "              proxy_cache cache_common;"
        $lines += "              expires ${CacheTTL};"
    }

    $lines += ""
    $lines += '              proxy_set_header  Host                           $host;'
    $lines += '              proxy_set_header  X-Real-IP                      $remote_addr;'
    $lines += '              proxy_set_header  X-Forwarded-For        $proxy_add_x_forwarded_for;'
    $lines += "              proxy_set_header  X-Forwarded-Proto  https;"

    if ($ProxySslServerName) {
        $lines += "              proxy_ssl_server_name on;"
    }

    $lines += ("              proxy_pass " + $BackendUrl + ";")
    $lines += "        }"

    return $lines
}

# ===============================
# Build Configuration
# ===============================
$conf = @()

$conf += "# ================================================"
$conf += "# Nginx Reverse Proxy Configuration for Xensor"
$conf += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$conf += "# Backend:  ${backendUrl}"
$conf += "# ================================================"
$conf += ""

# --- Main server block ---
$conf += "server {"

if ($isSSL) {
    $conf += "	listen ${ListenPort} ssl default_server;"
    $conf += ""
    $conf += "	ssl_certificate ${CertPath}/nginx.crt;"
    $conf += "	ssl_certificate_key ${CertPath}/nginx.key;"
    $conf += "	server_name default_server;"
} else {
    $conf += "	listen ${ListenPort} default_server;"
    $conf += "	server_name default_server;"
}

$conf += ""
$conf += "	#buffer larger messages"
$conf += "	client_max_body_size ${ClientMaxBodySize};"
$conf += "	client_body_buffer_size ${ClientBodyBufferSize};"
$conf += ""

if ($isSSL) {
    $conf += "	ssl_protocols TLSv1.2;"
    $conf += "	ssl_ciphers 'EECDH+ECDSA+AESGCM EECDH+aRSA+AESGCM EECDH+ECDSA+SHA384 EECDH+ECDSA+SHA256 EECDH+aRSA+SHA384 EECDH+aRSA+SHA256 EECDH+aRSA+RC4 EECDH EDH+aRSA !aNULL !eNULL !LOW !3DES !MD5 !EXP !PSK !SRP !DSS !RC4';"
    $conf += ""
}

$conf += '	add_header X-XSS-Protection "1; mode=block";'
$conf += "	add_header X-Frame-Options SAMEORIGIN;"
$conf += "	add_header X-Content-Type-Options nosniff;"
$conf += '	add_header "Access-Control-Allow-Origin"  *;'
$conf += '	add_header "Access-Control-Allow-Methods" "GET, POST, OPTIONS, HEAD";'
$conf += ""
$conf += ""

# ===============================
# Location Blocks
# ===============================

# --- UI / ---
$uiRewrites = @(
    "rewrite /dashboard /  break;",
    "rewrite /auth / break;",
    "rewrite /login / break;"
)
$conf += New-LocationBlock -Location "= /" -BackendUrl $backendUrl -RewriteRules $uiRewrites
$conf += ""

# --- UI /dashboard | /auth | /login ---
$conf += New-LocationBlock -Location '~* ^/(dashboard|auth|login)' -BackendUrl $backendUrl -RewriteRules $uiRewrites
$conf += ""

# --- API / System / UI assets (no cache) ---
$conf += New-LocationBlock -Location '~* ^/(v1/dash|v1/system|v2/system|v1/cysensor|v1/tools|v1/webapi|cfg|static|cycarrier-ui.min.css)' -BackendUrl $backendUrl
$conf += ""

if ($EnableCache) {
    # --- Agent downloads (cache) ---
    $conf += New-LocationBlock -Location '~* /(A00003|A00005|resource|ldr)' -BackendUrl $backendUrl -Cache -CacheTTL $cacheTTL
    $conf += ""

    # --- Cydroned downloads (cache) ---
    $conf += New-LocationBlock -Location '~* ^/(l|linux|m|mac(os)?|darwin|cydroned|A00003|A00005)/cydroned$' -BackendUrl $backendUrl -Cache -CacheTTL $cacheTTL
    $conf += ""

    # --- XDL cache ---
    $conf += New-LocationBlock -Location '~* ^(/xdl|/xdl/v1/|\.m$)' -BackendUrl $backendUrl -Cache -CacheTTL $cacheTTL -ProxySslServerName
    $conf += ""

    # --- Bitdefender updates (cache) ---
    $conf += New-LocationBlock -Location '~* ^/(versions/\.(id|dat)|av32bit|av64bit|av64bit-arm|v1/patches|v2/repository)' -BackendUrl $backendUrl -Cache -CacheTTL $cacheTTL
    $conf += ""
}

# --- mpmpattern include ---
if ($IncludeMpmPattern) {
    $conf += ""
    $conf += "include ${MpmPatternPath};"
}

$conf += "}"

# ===============================
# Write Output
# ===============================
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Write UTF-8 without BOM + LF line endings (nginx on Linux requires this)
$content = ($conf -join "`n") -replace "`r", ""
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
[System.IO.File]::WriteAllText($resolvedOutput, $content, $utf8NoBom)
Write-Host ""
Write-Host "  [OK] Configuration written to: $OutputPath" -ForegroundColor Green

# ===============================
# Generate Self-Signed Certificate Script
# ===============================
if ($GenerateCert) {
    $certScript = @()
    $certScript += "#!/bin/bash"
    $certScript += "# Self-signed certificate generator for Xensor nginx proxy"
    $certScript += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $certScript += ""
    $certScript += "CERT_DIR=`"${CertPath}`""
    $certScript += "mkdir -p `"`$CERT_DIR`""
    $certScript += ""
    $certScript += 'openssl req -x509 -nodes -days 1095 \'
    $certScript += '  -newkey rsa:2048 \'
    $certScript += "  -keyout `"`$CERT_DIR/nginx.key`" \"
    $certScript += "  -out `"`$CERT_DIR/nginx.crt`" \"
    $certScript += "  -subj `"/C=TW/ST=Taiwan/L=Taipei/O=Xensor/CN=`$( hostname)/emailAddress=support@cycarrier.com`""
    $certScript += ""
    $certScript += "echo `"Certificate generated at `$CERT_DIR`""
    $certScript += "openssl x509 -in `"`$CERT_DIR/nginx.crt`" -noout -subject -dates"

    $certScriptPath = Join-Path (Split-Path $OutputPath -Parent) "generate-cert.sh"
    $certContent = ($certScript -join "`n") -replace "`r", ""
    $resolvedCert = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($certScriptPath)
    [System.IO.File]::WriteAllText($resolvedCert, $certContent, $utf8NoBom)
    Write-Host "  [OK] Certificate script written to: $certScriptPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Run on the nginx server:" -ForegroundColor Yellow
    Write-Host "    chmod +x generate-cert.sh && ./generate-cert.sh" -ForegroundColor Gray
}

# ===============================
# Summary
# ===============================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Configuration Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Listen:     ${ListenPort} (default_server)" -ForegroundColor White
Write-Host "  Backend:    ${backendUrl}" -ForegroundColor White
Write-Host "  SSL:        $(if ($isSSL) { 'Yes (TLSv1.2)' } else { 'No' })" -ForegroundColor White
Write-Host "  Cache:      $(if ($EnableCache) { "${CachePolicy} (${cacheTTL})" } else { 'Disabled' })" -ForegroundColor White
Write-Host "  Timeout:    ${ProxyTimeout}s" -ForegroundColor White
Write-Host "  Max Body:   ${ClientMaxBodySize}" -ForegroundColor White
Write-Host "  mpmpattern: $(if ($IncludeMpmPattern) { $MpmPatternPath } else { 'No' })" -ForegroundColor White
Write-Host ""
Write-Host "  Deploy to nginx:" -ForegroundColor Yellow
Write-Host "    cp default.conf /etc/nginx/conf.d/default.conf" -ForegroundColor Gray
Write-Host "    nginx -t && nginx -s reload" -ForegroundColor Gray
Write-Host ""
