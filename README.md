# Nginx Default Conf Creator

PowerShell script to generate production-ready nginx `default.conf` for Xensor reverse proxy deployment.

## Features

- SSL configuration with CyCraft standard cipher suite (TLSv1.2)
- Security headers (X-XSS-Protection, X-Frame-Options, X-Content-Type-Options, CORS)
- UI location blocks with rewrite rules (`/dashboard`, `/auth`, `/login`)
- Path-based caching for agent downloads, cydroned, xdl, Bitdefender updates
- DNS pre-check to catch typos before generating config
- Optional self-signed certificate generation script
- `mpmpattern.conf` include support
- UTF-8 without BOM + LF line endings (Linux compatible)

## Prerequisites

- Windows PowerShell 5.1+ or PowerShell 7+
- Nginx server (deployment target)

## Usage

### Interactive Mode

```powershell
.\Generate-NginxConfig.ps1
```

The script will prompt for each parameter step by step.

### Parameter Mode

```powershell
.\Generate-NginxConfig.ps1 `
  -ListenPort 443 `
  -Backend "xensor-tw.cycarrier.com" `
  -BackendPort 443 `
  -GenerateCert `
  -EnableCache `
  -CachePolicy "bandwidth-saving" `
  -IncludeMpmPattern `
  -OutputPath ".\default.conf"
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ListenPort` | int | 443 | Nginx listen port |
| `Backend` | string | *(required)* | Backend server hostname or IP |
| `BackendPort` | int | 443 | Backend server port |
| `BackendProtocol` | string | auto | `http` or `https`, auto-detected from BackendPort |
| `GenerateCert` | switch | false | Generate self-signed certificate script |
| `CertPath` | string | `/etc/nginx/cert` | SSL certificate directory path |
| `EnableCache` | switch | false | Enable path-based caching rules |
| `CachePolicy` | string | `bandwidth-saving` | `bandwidth-saving` (1d) or `realtime` (1h) |
| `ClientMaxBodySize` | string | `100m` | Max upload body size |
| `ClientBodyBufferSize` | string | `100k` | Client body buffer size |
| `ProxyTimeout` | int | 60 | Proxy connect/send/read timeout (seconds) |
| `IncludeMpmPattern` | switch | false | Include `mpmpattern.conf` at end of config |
| `MpmPatternPath` | string | `/etc/nginx/mpmpattern.conf` | Path to mpmpattern config file |
| `OutputPath` | string | `.\default.conf` | Output file path |

## Deployment

### Step 1: Generate Config

```powershell
.\Generate-NginxConfig.ps1 `
  -ListenPort 443 `
  -Backend "xensor-tw.cycarrier.com" `
  -GenerateCert `
  -EnableCache `
  -IncludeMpmPattern `
  -OutputPath ".\default.conf"
```

### Step 2: Copy Files to Nginx Server

```bash
# Copy config
scp default.conf root@<nginx-server>:/etc/nginx/sites-enabled/default.conf

# Copy cert script (if generated)
scp generate-cert.sh root@<nginx-server>:/etc/nginx/cert/
```

### Step 3: Generate Self-Signed Certificate (on Nginx server)

```bash
cd /etc/nginx/cert
chmod +x generate-cert.sh
./generate-cert.sh
```

Or manually:

```bash
mkdir -p /etc/nginx/cert
openssl req -x509 -nodes -days 1095 \
  -newkey rsa:2048 \
  -keyout /etc/nginx/cert/nginx.key \
  -out /etc/nginx/cert/nginx.crt \
  -subj "/C=TW/ST=Taiwan/L=Taipei/O=Xensor/CN=$(hostname)/emailAddress=support@cycarrier.com"
```

### Step 4: Test and Reload Nginx

```bash
nginx -t
nginx -s reload
```

## Cache Policy

The script supports two caching strategies for downloadable resources:

| Policy | TTL | Use Case |
|--------|-----|----------|
| `bandwidth-saving` | 1 day | Default. Reduces bandwidth by caching agent/engine downloads for 24 hours |
| `realtime` | 1 hour | For environments that need faster update propagation |

### Path-Based Caching Rules

| Path | Purpose | Cache |
|------|---------|-------|
| `/` | UI root | No |
| `/dashboard`, `/auth`, `/login` | UI pages | No |
| `/v1/system`, `/v2/system`, `/v1/cysensor`, `/v1/tools`, `/v1/webapi` | Xensor API | No |
| `/cfg`, `/static`, `/cycarrier-ui.min.css` | UI assets | No |
| `/resource`, `/ldr` | Xensor Agent/Loader downloads | Yes |
| `/A00003`, `/A00005` | Agent downloads | Yes |
| `/(l\|linux\|m\|mac\|macos\|darwin\|cydroned\|...)/cydroned` | Cydroned downloads | Yes |
| `/xdl`, `/xdl/v1/`, `*.m` | XDL engine downloads | Yes |
| `/versions/.id`, `/versions/.dat` | Bitdefender version check | Yes |
| `/av32bit`, `/av64bit`, `/av64bit-arm` | Bitdefender engine | Yes |
| `/v1/patches`, `/v2/repository` | Bitdefender updates | Yes |

## Nginx Cache Zone Setup

The generated config uses `cache_common` as the proxy cache zone. Make sure it is defined in your `nginx.conf`:

```nginx
http {
    ...
    proxy_cache_path /var/cache/nginx levels=1:2
                     keys_zone=cache_common:10m
                     max_size=1g
                     inactive=1d
                     use_temp_path=off;
    ...
}
```

## mpmpattern.conf

If `-IncludeMpmPattern` is enabled, the generated config includes:

```nginx
include /etc/nginx/mpmpattern.conf;
```

Place the `mpmpattern.conf` file at `/etc/nginx/mpmpattern.conf` on the Nginx server before reloading.

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `unknown directive "#"` | Config file has UTF-8 BOM | Re-generate with this script (already outputs BOM-free UTF-8) |
| `host not found in upstream` | Backend hostname DNS resolution failed | Check the backend hostname spelling; the script validates DNS before generating |
| `unknown "cache_common"` | Cache zone not defined | Add `proxy_cache_path` to `nginx.conf` (see [Cache Zone Setup](#nginx-cache-zone-setup)) |
| `open() "/etc/nginx/mpmpattern.conf" failed` | Missing mpmpattern file | Place the file or re-generate without `-IncludeMpmPattern` |
