# ============================================================================
# Group 6: Network / GitHub API - HTTP requests, downloads, rate-limit handling
# ============================================================================
# Functions:
#   Invoke-GitHubApi              - Wrapper for Invoke-RestMethod with User-Agent
#                                    header (GTNH-Updater-Script), rate-limit
#                                    detection (HTTP 403 + X-RateLimit-Reset),
#                                    and error handling
#   Get-LatestStableRelease       - Scrape official downloads page for latest
#                                    stable version and extract download URLs
#   Get-LatestStableReleaseFallback - Scrape downloads.gtnewhorizons.com file
#                                    listing as fallback for version/URL info
#   Get-WebsiteReleases           - Scrape version history page for all releases
#                                    (stable + beta/RC) with download URLs
#   Get-OfficialModList           - Fetch official mod list for a version from
#                                    the GitHub repo README
#   Invoke-FileDownload           - Download file with progress display (URL, size
#                                    in MB, elapsed time), save to cache folder
#   Test-FileIntegrity            - Verify SHA256 hash of a downloaded file
#   Get-ScriptUpdateInfo          - Check for newer script version on GitHub
#
# All network operations wrapped in try/catch distinguishing connectivity
# failures, HTTP errors, and rate limiting.
# ============================================================================

function Test-IsNetworkException {
    param([Parameter(Mandatory)]$ex)
    return ($ex -is [System.Net.WebException] -or
            $ex.InnerException -is [System.Net.WebException] -or
            $ex -is [System.Net.Http.HttpRequestException] -or
            $ex.InnerException -is [System.Net.Http.HttpRequestException])
}

# ── ETag Cache for GitHub API ─────────────────────────────────────────────────
# Stores ETags and cached responses to avoid burning rate limit on repeated calls.
# Key = URI, Value = @{ ETag; Response }
$script:GitHubETagCache = @{}

function New-ZipUrls {
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$PackType = 'java17'
    )
    $javaSuffix = $PackType -eq 'java17' ? 'Java_17-25' : 'Java_8'
    return [PSCustomObject]@{
        ServerZipName = "GT_New_Horizons_${Version}_Server_${javaSuffix}.zip"
        ServerZipUrl  = "$($script:GtnhDownloadsBase)/ServerPacks/GT_New_Horizons_${Version}_Server_${javaSuffix}.zip"
        ClientZipName = "GT_New_Horizons_${Version}_${javaSuffix}.zip"
        ClientZipUrl  = "$($script:GtnhDownloadsBase)/Multi_mc_downloads/GT_New_Horizons_${Version}_${javaSuffix}.zip"
    }
}

function Invoke-GitHubApi {
    <#
    .SYNOPSIS
        Wrapper for Invoke-RestMethod with User-Agent header and error handling.
    .DESCRIPTION
        Calls the specified URI with a GTNH-Updater-Script User-Agent header.
        Supports ETag caching to avoid burning GitHub rate limit on repeated calls.
        Handles HTTP 403 rate-limit responses, other HTTP errors, and network
        connectivity failures. Returns $null on failure, response object on success.
    .PARAMETER Uri
        The API endpoint URL to call.
    .PARAMETER Method
        HTTP method. Defaults to 'Get'.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'Get'
    )

    try {
        $headers = @{ 'User-Agent' = 'GTNH-Updater-Script' }

        # Add If-None-Match header if we have a cached ETag for this URI
        $cached = $script:GitHubETagCache[$Uri]
        if ($cached -and $cached.ETag) {
            $headers['If-None-Match'] = $cached.ETag
        }

        $response = Invoke-WebRequest -Uri $Uri -Method $Method -Headers $headers -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop

        # Handle 304 Not Modified (some PS7 versions don't throw on 304)
        if ($response.StatusCode -eq 304 -and $cached -and $cached.Response) {
            Write-Log "[API] 304 Not Modified for $Uri - using cached response"
            return $cached.Response
        }

        # Store ETag from response for future conditional requests
        $etag = $response.Headers['ETag']
        if ($etag) {
            $etagValue = if ($etag -is [System.Collections.IEnumerable] -and $etag -isnot [string]) { $etag[0] } else { $etag }
            $parsed = $response.Content | ConvertFrom-Json
            $script:GitHubETagCache[$Uri] = @{ ETag = $etagValue; Response = $parsed }
            return $parsed
        }

        return ($response.Content | ConvertFrom-Json)
    }
    catch {
        $ex = $_.Exception

        # Check for HTTP 304 Not Modified - return cached response
        if ($ex -is [Microsoft.PowerShell.Commands.HttpResponseException] -or
            ($ex.Response -and $ex.Response.StatusCode)) {

            $statusCode = if ($ex.Response) { $ex.Response.StatusCode.value__ } else { 0 }

            if ($statusCode -eq 304 -and $cached -and $cached.Response) {
                Write-Log "[API] 304 Not Modified for $Uri - using cached response"
                return $cached.Response
            }

            if ($statusCode -eq 403) {
                # Check for rate-limit reset header
                $resetHeader = $ex.Response.Headers | Where-Object { $_.Key -eq 'X-RateLimit-Reset' }
                if ($resetHeader) {
                    $resetEpoch = [long]($resetHeader.Value | Select-Object -First 1)
                    $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch).LocalDateTime
                    $waitMinutes = [math]::Ceiling(($resetTime - (Get-Date)).TotalMinutes)
                    $waitMinutes = [math]::Max($waitMinutes, 1)
                    Write-Warn "GitHub API rate limited. Resets at $($resetTime.ToString('HH:mm:ss')) (~${waitMinutes} min). Try again later."
                }
                else {
                    Write-Warn "GitHub API returned HTTP 403 (Forbidden). You may be rate-limited."
                }
                Write-Log "[WARN] GitHub API 403 for $Uri"
                # Return cached response if available (better than nothing)
                if ($cached -and $cached.Response) {
                    Write-Log "[API] Returning cached response after 403 for $Uri"
                    return $cached.Response
                }
            }
            elseif ($statusCode -eq 404) {
                Write-Log "[INFO] GitHub API 404 for $Uri - resource not found, skipping silently."
            }
            else {
                Write-Err "Server returned HTTP ${statusCode}: $($ex.Message)"
                Write-Log "[ERROR] HTTP $statusCode for $Uri - $($ex.Message)"
            }
        }
        elseif ($ex -is [System.Net.WebException] -or
                $ex.InnerException -is [System.Net.WebException] -or
                $ex -is [System.Net.Http.HttpRequestException] -or
                $ex.InnerException -is [System.Net.Http.HttpRequestException]) {
            Write-Err "Network request failed. Check your internet connection."
            Write-Log "[ERROR] Network failure for $Uri - $($ex.Message)"
            # Return cached response if available (offline resilience)
            if ($cached -and $cached.Response) {
                Write-Log "[API] Returning cached response after network failure for $Uri"
                return $cached.Response
            }
        }
        else {
            Write-Err "API request failed: $($ex.Message)"
            Write-Log "[ERROR] API failure for $Uri - $($ex.Message)"
        }

        return $null
    }
}

function Get-LatestStableRelease {
    <#
    .SYNOPSIS
        Get the latest stable GTNH release from the official downloads page.
    .DESCRIPTION
        Scrapes www.gtnewhorizons.com/downloads to find the latest stable version
        and extract the actual download URLs. This is the PRIMARY source for stable
        releases - GitHub releases only contain nightly builds.

        The page contains direct links like:
          Server: https://downloads.gtnewhorizons.com/ServerPacks/GT_New_Horizons_X.Y.Z_Server_Java_17-25.zip
          Client: https://downloads.gtnewhorizons.com/Multi_mc_downloads/GT_New_Horizons_X.Y.Z_Java_17-25.zip
    .PARAMETER PackType
        The Java version: 'java17' or 'java8'. Defaults to 'java17'.
    .OUTPUTS
        PSCustomObject with Version, ServerZipUrl, ServerZipName, ClientZipUrl,
        ClientZipName, ReleaseUrl. Returns $null if fetch fails.
    #>
    param(
        [string]$PackType = 'java17'
    )

    $downloadsPageUrl = 'https://www.gtnewhorizons.com/downloads/'

    try {
        Write-Log "[STABLE] Fetching official downloads page: $downloadsPageUrl"
        $response = Invoke-WebRequest -Uri $downloadsPageUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $content = $response.Content

        # Parse for version pattern: Latest (X.Y.Z)
        if ($content -match 'Latest\s*\((\d+\.\d+\.\d+)\)') {
            $version = $Matches[1]
        }
        else {
            Write-Warn "Could not parse version from official downloads page."
            return $null
        }

        Write-Log "[STABLE] Found version $version on downloads page."

        # Extract actual download URLs from the page links
        $serverZipUrl = $null
        $serverZipName = $null
        $clientZipUrl = $null
        $clientZipName = $null

        $javaLabel = $PackType -eq 'java17' ? 'Java_17' : 'Java_8'

        # Find server zip URL from page links
        $serverLinks = $response.Links | Where-Object {
            $_.href -match 'ServerPacks' -and $_.href -match $javaLabel -and $_.href -match '\.zip$'
        }
        if ($serverLinks) {
            $serverLink = $serverLinks | Select-Object -First 1
            $serverZipUrl = $serverLink.href
            $serverZipName = Split-Path -Leaf $serverZipUrl
        }

        # Find client/Prism zip URL from page links (Multi_mc_downloads)
        $clientLinks = $response.Links | Where-Object {
            $_.href -match 'Multi_mc_downloads' -and $_.href -match $javaLabel -and $_.href -match '\.zip$'
        }
        if ($clientLinks) {
            $clientLink = $clientLinks | Select-Object -First 1
            $clientZipUrl = $clientLink.href
            $clientZipName = Split-Path -Leaf $clientZipUrl
        }

        # Fallback: construct URLs from known patterns if link parsing failed
        if (-not $serverZipUrl) {
            $javaSuffix = $PackType -eq 'java17' ? 'Java_17-25' : 'Java_8'
            $serverZipName = "GT_New_Horizons_${version}_Server_${javaSuffix}.zip"
            $serverZipUrl = "$($script:GtnhDownloadsBase)/ServerPacks/$serverZipName"
            Write-Log "[STABLE] Server URL constructed from pattern: $serverZipUrl"
        }

        if (-not $clientZipUrl) {
            $javaSuffix = $PackType -eq 'java17' ? 'Java_17-25' : 'Java_8'
            $clientZipName = "GT_New_Horizons_${version}_${javaSuffix}.zip"
            $clientZipUrl = "$($script:GtnhDownloadsBase)/Multi_mc_downloads/$clientZipName"
            Write-Log "[STABLE] Client URL constructed from pattern: $clientZipUrl"
        }

        return [PSCustomObject]@{
            Version       = $version
            ServerZipUrl  = $serverZipUrl
            ServerZipName = $serverZipName
            ClientZipUrl  = $clientZipUrl
            ClientZipName = $clientZipName
            ReleaseUrl    = $downloadsPageUrl
        }
    }
    catch {
        $ex = $_.Exception
        if (Test-IsNetworkException $ex) {
            Write-Err "Network request failed. Check your internet connection."
            Write-Log "[ERROR] Network failure for downloads page - $($ex.Message)"
        }
        else {
            Write-Err "Failed to fetch downloads page: $($ex.Message)"
            Write-Log "[ERROR] Downloads page fetch failed - $($ex.Message)"
        }
        return $null
    }
}

function Get-LatestStableReleaseFallback {
    <#
    .SYNOPSIS
        Fallback: construct stable release URLs from known download patterns.
    .DESCRIPTION
        If the primary downloads page fetch fails, this function tries to scrape
        the downloads.gtnewhorizons.com file listing directly, or constructs URLs
        from the known naming convention as a last resort.
    .PARAMETER PackType
        The Java version: 'java17' or 'java8'. Defaults to 'java17'.
    .OUTPUTS
        PSCustomObject with Version, ServerZipUrl, ServerZipName, ClientZipUrl,
        ClientZipName, ReleaseUrl. Returns $null on failure.
    #>
    param(
        [string]$PackType = 'java17'
    )

    $javaLabel = $PackType -eq 'java17' ? 'Java_17' : 'Java_8'

    # Try the direct file listing on downloads.gtnewhorizons.com
    $serverPacksUrl = "$($script:GtnhDownloadsBase)/ServerPacks"

    try {
        Write-Log "[STABLE-FALLBACK] Trying direct file listing: $serverPacksUrl"
        $response = Invoke-WebRequest -Uri $serverPacksUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $content = $response.Content

        # Look for server zips matching the requested Java version
        $allVersions = @()
        $serverMatches = [regex]::Matches($content, "GT_New_Horizons_(\d+\.\d+\.\d+)_Server_${javaLabel}[^""]*\.zip")
        foreach ($m in $serverMatches) {
            $allVersions += $m.Groups[1].Value
        }

        if ($allVersions.Count -eq 0) {
            Write-Warn "No server packs found in file listing for $javaLabel."
            return $null
        }

        # Sort versions and pick the latest
        $version = $allVersions | Sort-Object { [version]$_ } -Descending | Select-Object -First 1

        # Find the exact filename for this version
        $serverFileMatch = [regex]::Match($content, "(GT_New_Horizons_${version}_Server_${javaLabel}[^""]*\.zip)")
        $urls = New-ZipUrls -Version $version -PackType $PackType
        $serverZipName = $serverFileMatch.Success ? $serverFileMatch.Groups[1].Value : $urls.ServerZipName
        $serverZipUrl  = "$($script:GtnhDownloadsBase)/ServerPacks/$serverZipName"

        return [PSCustomObject]@{
            Version       = $version
            ServerZipUrl  = $serverZipUrl
            ServerZipName = $serverZipName
            ClientZipUrl  = $urls.ClientZipUrl
            ClientZipName = $urls.ClientZipName
            ReleaseUrl    = 'https://www.gtnewhorizons.com/downloads/'
        }
    }
    catch {
        $ex = $_.Exception
        if (Test-IsNetworkException $ex) {
            Write-Err "Network request failed. Check your internet connection."
            Write-Log "[ERROR] Network failure for fallback file listing - $($ex.Message)"
        }
        else {
            Write-Err "Failed to fetch file listing: $($ex.Message)"
            Write-Log "[ERROR] Fallback file listing failed - $($ex.Message)"
        }
        return $null
    }
}

function Invoke-FileDownload {
    <#
    .SYNOPSIS
        Download a file with progress display and cache support.
    .DESCRIPTION
        Checks the download cache first. If not cached, downloads the file using
        HttpClient with streaming progress display, measures elapsed time,
        displays file size and duration, and saves to the cache folder.
    .PARAMETER Url
        The URL to download from.
    .PARAMETER OutPath
        The destination file path.
    .PARAMETER Description
        A human-readable description of what is being downloaded.
    .OUTPUTS
        $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutPath,
        [string]$Description = 'file'
    )

    # Check cache first
    $fileName = Split-Path -Leaf $OutPath
    $cached = Get-CachedFile -FileName $fileName
    if ($cached) {
        Write-Info "Using cached file: $fileName"
        try {
            Copy-Item -LiteralPath $cached -Destination $OutPath -Force
            Write-Success "Loaded $Description from cache."
            return $true
        }
        catch {
            Write-Warn "Cache copy failed, downloading fresh: $($_.Exception.Message)"
        }
    }

    Write-Info "Downloading: $Description"

    $httpClient = $null
    $response = $null
    $stream = $null
    $fileStream = $null

    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        # Use HttpClient for streaming download with progress
        $httpClient = [System.Net.Http.HttpClient]::new()
        $httpClient.DefaultRequestHeaders.Add('User-Agent', 'GTNH-Updater-Script')
        $httpClient.Timeout = [TimeSpan]::FromMinutes(10)

        $response = $httpClient.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        $response.EnsureSuccessStatusCode()

        $totalBytes = $response.Content.Headers.ContentLength
        $stream = $response.Content.ReadAsStreamAsync().Result
        $fileStream = [System.IO.File]::Create($OutPath)

        $buffer = [byte[]]::new(81920)
        $totalRead = 0
        $lastPercent = -1
        $speedTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $speedBytes = 0
        $speedLabel = ''

        while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $totalRead += $bytesRead
            $speedBytes += $bytesRead

            if ($totalBytes -and $totalBytes -gt 0) {
                $percent = [math]::Floor(($totalRead / $totalBytes) * 100)
                if ($percent -ne $lastPercent) {
                    $downloadedMB = [math]::Round($totalRead / 1MB, 1)
                    $totalMB = [math]::Round($totalBytes / 1MB, 1)
                    $bar = ('█' * [math]::Floor($percent / 2)).PadRight(50, '░')

                    # Calculate speed (update every 500ms to avoid flicker)
                    if ($speedTimer.ElapsedMilliseconds -gt 500) {
                        $speedBytesPerSec = ($speedBytes / ($speedTimer.ElapsedMilliseconds / 1000))
                        $speedMBs = [math]::Round($speedBytesPerSec / 1MB, 1)
                        if ($speedMBs -gt 0) {
                            $remainingBytes = $totalBytes - $totalRead
                            $etaSeconds = [math]::Ceiling($remainingBytes / $speedBytesPerSec)
                            if ($etaSeconds -lt 60) {
                                $speedLabel = "  ${speedMBs} MB/s  ~${etaSeconds}s"
                            } elseif ($etaSeconds -lt 3600) {
                                $etaMin = [math]::Floor($etaSeconds / 60)
                                $etaSec = $etaSeconds % 60
                                $speedLabel = "  ${speedMBs} MB/s  ~${etaMin}m${etaSec}s"
                            } else {
                                $speedLabel = "  ${speedMBs} MB/s"
                            }
                        } else {
                            $speedLabel = ''
                        }
                        $speedBytes = 0
                        $speedTimer.Restart()
                    }

                    $progressLine = "  [$bar] ${percent}%  ${downloadedMB}/${totalMB} MB${speedLabel}"
                    # Pad to fixed width to fully overwrite previous line content
                    $progressLine = $progressLine.PadRight((Get-TerminalWidth))
                    Write-Host "`r${progressLine}" -NoNewline -ForegroundColor Gray
                    $lastPercent = $percent
                }
            }
            elseif ($speedTimer.ElapsedMilliseconds -gt 500) {
                # No Content-Length: show downloaded size + speed without percentage
                $downloadedMB = [math]::Round($totalRead / 1MB, 1)
                $speedMBs = [math]::Round(($speedBytes / 1MB) / ($speedTimer.ElapsedMilliseconds / 1000), 1)
                $progressLine = "  Downloading... ${downloadedMB} MB  ${speedMBs} MB/s"
                Write-Host "`r$($progressLine.PadRight((Get-TerminalWidth)))" -NoNewline -ForegroundColor Gray
                $speedBytes = 0
                $speedTimer.Restart()
            }
        }

        Write-Host "`r$(' ' * (Get-TerminalWidth))" # Clear the progress bar line
        Write-Host ""
        $stopwatch.Stop()

        $fileInfo = Get-Item -LiteralPath $OutPath
        $sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
        $elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)

        Write-Success "Downloaded $Description - ${sizeMB} MB in ${elapsed}s"

        # Close the file stream before copying to cache
        if ($fileStream) { try { $fileStream.Dispose(); $fileStream = $null } catch {} }

        # Save to cache folder
        $cacheDir = $script:CacheDir
        if (-not $cacheDir) { $cacheDir = Join-Path $script:ScriptDir 'cache' }
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
        }
        $cacheDest = Join-Path $cacheDir (Split-Path -Leaf $OutPath)
        if ($cacheDest -ne $OutPath) {
            try {
                Copy-Item -LiteralPath $OutPath -Destination $cacheDest -Force
            }
            catch {
                Write-Log "[WARN] Could not save to cache: $($_.Exception.Message)"
            }
        }

        return $true
    }
    catch {
        # Clear progress bar line on error so it doesn't linger
        Write-Host "`r$(' ' * (Get-TerminalWidth))"

        $ex = $_.Exception
        if (Test-IsNetworkException $ex) {
            Write-Err "Download failed. Check your internet connection."
            Write-Log "[ERROR] Download network failure for $Url - $($ex.Message)"
        }
        else {
            Write-Err "Download failed: $($ex.Message)"
            Write-Log "[ERROR] Download failure for $Url - $($ex.Message)"
        }

        # Clean up partial download to avoid corrupted files
        if ($fileStream) { try { $fileStream.Dispose(); $fileStream = $null } catch {} }
        if (Test-Path -LiteralPath $OutPath) {
            try { Remove-Item -LiteralPath $OutPath -Force } catch {}
        }

        return $false
    }
    finally {
        # Dispose all IDisposable objects in reverse order, guarding each
        if ($fileStream)  { try { $fileStream.Dispose()  } catch {} }
        if ($stream)      { try { $stream.Dispose()      } catch {} }
        if ($response)    { try { $response.Dispose()    } catch {} }
        if ($httpClient)  { try { $httpClient.Dispose()   } catch {} }
    }
}

function Test-FileIntegrity {
    <#
    .SYNOPSIS
        Verify the SHA256 hash of a downloaded file.
    .DESCRIPTION
        Computes the SHA256 hash of the file at FilePath and compares it to the
        expected hash. Returns $true if they match, $false if they don't, and
        $null if the expected hash is not available (skip verification).
    .PARAMETER FilePath
        Full path to the file to verify.
    .PARAMETER ExpectedHash
        The expected SHA256 hash string (hex, case-insensitive).
    .OUTPUTS
        $true if hash matches, $false if mismatch, $null if no hash to check.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$ExpectedHash
    )

    if ([string]::IsNullOrEmpty($ExpectedHash)) {
        return $null  # No hash available, skip verification
    }

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Err "File not found for integrity check: $FilePath"
        return $false
    }

    try {
        Write-Info "Verifying file integrity (SHA256)..."
        $actualHash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash

        if ($actualHash -eq $ExpectedHash.ToUpper()) {
            Write-Success "Integrity check passed (SHA256 match)."
            Write-Log "[INTEGRITY] SHA256 OK: $(Split-Path -Leaf $FilePath)"
            return $true
        } else {
            Write-Err "Integrity check FAILED - file may be corrupted."
            Write-Err "Expected: $($ExpectedHash.ToUpper())"
            Write-Err "Actual:   $actualHash"
            Write-Log "[INTEGRITY] SHA256 MISMATCH: $(Split-Path -Leaf $FilePath) expected=$ExpectedHash actual=$actualHash"
            return $false
        }
    }
    catch {
        Write-Warn "Could not verify file integrity: $($_.Exception.Message)"
        Write-Log "[WARN] Integrity check error: $($_.Exception.Message)"
        return $null
    }
}

function Get-OfficialModList {
    <#
    .SYNOPSIS
        Fetch the official GTNH mod list for a specific version from GitHub.
    .DESCRIPTION
        Downloads the README.md from the GT-New-Horizons-Modpack repo at the
        specified version tag and parses the modlist table. Returns an array
        of mod names (the Name column from the markdown table).
    .PARAMETER Version
        The GTNH version tag (e.g., '2.8.4', '2.8.0-beta-4').
    .OUTPUTS
        Array of mod name strings, or $null on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Version
    )

    $readmeUrl = "https://raw.githubusercontent.com/GTNewHorizons/GT-New-Horizons-Modpack/$Version/README.md"

    try {
        Write-Log "[MODLIST] Fetching official mod list for $Version from GitHub..."
        $response = Invoke-WebRequest -Uri $readmeUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $content = $response.Content

        # Parse the markdown table: | [Name](url) | Version |
        # Extract the mod name from each row (strip markdown link syntax)
        $modNames = @()
        $inTable = $false
        foreach ($line in ($content -split "`n")) {
            $trimmed = $line.Trim()

            # Detect the start of the modlist table
            if ($trimmed -match '^\|\s*Name\s*\|\s*Version\s*\|') {
                $inTable = $true
                continue
            }
            # Skip the separator row
            if ($inTable -and $trimmed -match '^\|\s*---') {
                continue
            }
            # Parse mod rows
            if ($inTable -and $trimmed -match '^\|') {
                # Extract the name cell: | [Name](url) | or | Name |
                if ($trimmed -match '^\|\s*\[([^\]]+)\]') {
                    $modNames += $Matches[1]
                }
                elseif ($trimmed -match '^\|\s*([^|]+?)\s*\|') {
                    $modNames += $Matches[1].Trim()
                }
            }
            elseif ($inTable -and $trimmed -notmatch '^\|') {
                # End of table
                break
            }
        }

        Write-Log "[MODLIST] Found $($modNames.Count) official mods for $Version."
        if ($modNames.Count -eq 0) {
            return $null
        }
        return $modNames
    }
    catch {
        $ex = $_.Exception
        if (Test-IsNetworkException $ex) {
            Write-Log "[WARN] Could not fetch mod list for $Version (network error)"
        }
        else {
            Write-Log "[WARN] Could not fetch mod list for $Version - $($ex.Message)"
        }
        return $null
    }
}

function Get-WebsiteReleases {
    <#
    .SYNOPSIS
        Get all GTNH releases from the version history page.
    .DESCRIPTION
        Scrapes www.gtnewhorizons.com/version-history to find all listed releases,
        both stable and beta/RC. Returns them in page order (newest first).

        Each entry includes the version string, release type (Stable or Beta),
        and constructed download URLs following the standard naming convention:
          Server: https://downloads.gtnewhorizons.com/ServerPacks/GT_New_Horizons_{VERSION}_Server_Java_17-25.zip
          Client: https://downloads.gtnewhorizons.com/Multi_mc_downloads/GT_New_Horizons_{VERSION}_Java_17-25.zip
    .PARAMETER PackType
        The Java version: 'java17' or 'java8'. Defaults to 'java17'.
    .OUTPUTS
        Array of PSCustomObject with Version, Type (Stable/Beta), Date (YYYY/MM/DD),
        ServerZipUrl, ServerZipName, ClientZipUrl, ClientZipName, ReleaseUrl.
        Returns $null if fetch fails.
    #>
    param(
        [string]$PackType = 'java17'
    )

    $versionHistoryUrl = 'https://www.gtnewhorizons.com/version-history'

    try {
        Write-Log "[RELEASES] Fetching version history page: $versionHistoryUrl"
        $response = Invoke-WebRequest -Uri $versionHistoryUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $content = $response.Content

        # Match version entries in the HTML. The version and type label are in
        # separate <span> tags: ...>2.8.4</span> <span ...>Stable release</span>
        # Also capture the date which follows in another span.
        $entryPattern = '(\d+\.\d+\.\d+(?:[-_](?:beta|rc)[-_]?\d*)?)</span>\s*<span[^>]*>\s*(Stable|Beta)\s+release'
        $regexMatches = [regex]::Matches($content, $entryPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        if ($regexMatches.Count -eq 0) {
            Write-Warn "No releases found on version history page."
            return $null
        }

        $javaSuffix = $PackType -eq 'java17' ? 'Java_17-25' : 'Java_8'
        $releases = @()

        foreach ($m in $regexMatches) {
            $version = $m.Groups[1].Value
            $rawType = $m.Groups[2].Value
            $type = $rawType.Substring(0,1).ToUpper() + $rawType.Substring(1).ToLower()

            # Try to find the date near this match in the HTML
            $date = ''
            $afterMatch = $content.Substring($m.Index, [math]::Min(800, $content.Length - $m.Index))
            if ($afterMatch -match '(\d{4}/\d{2}/\d{2})') {
                $date = $Matches[1]
            }

            $urls = New-ZipUrls -Version $version -PackType $PackType

            $releases += [PSCustomObject]@{
                Version       = $version
                Type          = $type
                Date          = $date
                ServerZipUrl  = $urls.ServerZipUrl
                ServerZipName = $urls.ServerZipName
                ClientZipUrl  = $urls.ClientZipUrl
                ClientZipName = $urls.ClientZipName
                ReleaseUrl    = $versionHistoryUrl
            }
        }

        Write-Log "[RELEASES] Found $($releases.Count) releases on version history page."
        if ($releases.Count -eq 0) {
            return $null
        }
        return $releases
    }
    catch {
        $ex = $_.Exception
        if (Test-IsNetworkException $ex) {
            Write-Err "Network request failed. Check your internet connection."
            Write-Log "[ERROR] Network failure for version history page - $($ex.Message)"
        }
        else {
            Write-Err "Failed to fetch version history page: $($ex.Message)"
            Write-Log "[ERROR] Version history page fetch failed - $($ex.Message)"
        }
        return $null
    }
}

function Get-ScriptUpdateInfo {
    <#
    .SYNOPSIS
        Check if a newer version of the GTNH Updater script is available.
    .DESCRIPTION
        Queries the configured GitHub repository for the latest release.
        If the release tag is different from $script:UpdaterVersion, an
        update is available. Simple tag comparison - any new release with
        a different tag triggers the update prompt.
    .OUTPUTS
        PSCustomObject with Version, DownloadUrl, ReleaseUrl, Body.
        Returns $null if up to date or on failure.
    #>

    $apiUrl = $script:ScriptUpdateApi
    if ([string]::IsNullOrEmpty($apiUrl)) {
        return $null  # No update URL configured
    }

    $response = Invoke-GitHubApi -Uri $apiUrl
    if (-not $response) {
        return $null
    }

    # /releases returns an array (newest first); /releases/latest returns a single object
    $release = if ($response -is [System.Array]) { $response | Select-Object -First 1 } else { $response }
    if (-not $release) { return $null }

    $latestTag = $release.tag_name -replace '^v', ''
    $currentVer = $script:UpdaterVersion
    # Semantic version comparison - only prompt if remote is actually newer
    # Parse versions like "0.1.2.3-beta" into comparable parts
    $parseVer = {
        param($v)
        $v = $v -replace '^v', ''
        $base = if ($v -match '^(\d+\.\d+[\.\d]*)') { $Matches[1] } else { '0.0.0' }
        $parts = $base -split '\.' | ForEach-Object { [int]$_ }
        while ($parts.Count -lt 4) { $parts += 0 }
        # Pre-release suffix lowers the version: alpha(1) < beta(2) < rc(3) < stable(4)
        $pre = 4  # stable (no suffix)
        if ($v -match '-alpha') { $pre = 1 }
        elseif ($v -match '-beta') { $pre = 2 }
        elseif ($v -match '-rc') { $pre = 3 }
        return $parts + $pre
    }
    $localParts  = & $parseVer $currentVer
    $remoteParts = & $parseVer $latestTag
    $isNewer = $false
    for ($pi = 0; $pi -lt $localParts.Count; $pi++) {
        if ($remoteParts[$pi] -gt $localParts[$pi]) { $isNewer = $true; break }
        if ($remoteParts[$pi] -lt $localParts[$pi]) { break }
    }
    if (-not $isNewer) { return $null }  # Local is same or newer

    # Find the zip asset for download, fall back to GitHub's auto-generated source zip
    $zipAsset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    $downloadUrl = $zipAsset ? $zipAsset.browser_download_url : $release.zipball_url

    return [PSCustomObject]@{
        Version     = $latestTag
        DownloadUrl = $downloadUrl
        ReleaseUrl  = $release.html_url
        Body        = $release.body
    }
}
