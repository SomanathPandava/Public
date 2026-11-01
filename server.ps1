# Lightweight PowerShell HTTP Server for Job Applications Portal
param (
    [int]$Port = 8080
)

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$currentDir = $PSScriptRoot

try {
    $listener.Start()
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "Job Applications Server running at http://localhost:$Port/" -ForegroundColor Cyan
    Write-Host "Serving static files and backend API for JobApplications" -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop the server" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Green

    $indexFilePath = Join-Path $currentDir "JobApplications\index.json"
    $jobAppsDir = Join-Path $currentDir "JobApplications"

    if (-not (Test-Path $jobAppsDir)) {
        New-Item -ItemType Directory -Path $jobAppsDir -Force | Out-Null
    }

    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $urlPath = $request.Url.LocalPath
        $httpMethod = $request.HttpMethod

        # CORS Headers
        $response.AddHeader("Access-Control-Allow-Origin", "*")
        $response.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $response.AddHeader("Access-Control-Allow-Headers", "Content-Type")

        if ($httpMethod -eq "OPTIONS") {
            $response.StatusCode = 200
            $response.Close()
            continue
        }

        # API: Save Application
        if ($httpMethod -eq "POST" -and $urlPath -eq "/api/save-application") {
            try {
                $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $appData = $body | ConvertFrom-Json

                $appId = [regex]::Replace([string]$appData.appId, '[^a-zA-Z0-9_-]', '')
                if ([string]::IsNullOrWhiteSpace($appId)) {
                    $response.StatusCode = 400
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error": "Missing or invalid appId"}')
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.Close()
                    continue
                }

                # Extract client IP and network context
                $clientIp = $request.RemoteEndPoint.Address.ToString()
                if ($request.Headers["X-Forwarded-For"]) {
                    $clientIp = $request.Headers["X-Forwarded-For"].Split(',')[0].Trim()
                }
                if ($clientIp -eq "::1") { $clientIp = "127.0.0.1" }

                $clientPort = $request.RemoteEndPoint.Port
                $userAgent = if ($request.UserAgent) { $request.UserAgent } else { "" }
                $protocol = $request.ProtocolVersion.ToString()
                $serverTimeUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                $serverTimeLocal = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

                # Ensure applicantMetadata exists on $appData
                if (-not $appData.applicantMetadata) {
                    $appData | Add-Member -MemberType NoteProperty -Name "applicantMetadata" -Value ([PSCustomObject]@{}) -Force
                }

                # Attach clientIp directly on metadata if not set
                $appData.applicantMetadata | Add-Member -MemberType NoteProperty -Name "clientIp" -Value $clientIp -Force

                # Attach server inspection details
                $serverInspection = [PSCustomObject]@{
                    clientIp = $clientIp
                    clientPort = $clientPort
                    httpProtocol = $protocol
                    userAgent = $userAgent
                    serverHostname = [System.Environment]::MachineName
                    serverReceivedAtUtc = $serverTimeUtc
                    serverReceivedAtLocal = $serverTimeLocal
                }
                $appData.applicantMetadata | Add-Member -MemberType NoteProperty -Name "serverInspection" -Value $serverInspection -Force

                # Save enriched application JSON
                $targetFile = Join-Path $jobAppsDir "$appId.json"
                $enrichedJson = $appData | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($targetFile, $enrichedJson, [System.Text.Encoding]::UTF8)

                # Update index.json
                $indexObj = $null
                if (Test-Path $indexFilePath) {
                    try {
                        $indexContent = [System.IO.File]::ReadAllText($indexFilePath, [System.Text.Encoding]::UTF8)
                        $indexObj = $indexContent | ConvertFrom-Json
                    } catch {
                        $indexObj = $null
                    }
                }

                if ($null -eq $indexObj) {
                    $indexObj = [PSCustomObject]@{
                        lastUpdated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                        totalApplications = 0
                        applications = @()
                        byEmail = [PSCustomObject]@{}
                        byAppId = [PSCustomObject]@{}
                    }
                }

                $email = $appData.email
                $status = if ($appData.status) { $appData.status } else { "draft" }
                $nowIso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

                # Remove existing entry if present in applications array
                $appsList = [System.Collections.ArrayList]@($indexObj.applications)
                $idxToRemove = -1
                for ($i = 0; $i -lt $appsList.Count; $i++) {
                    if ($appsList[$i].appId -eq $appId) {
                        $idxToRemove = $i
                        break
                    }
                }
                if ($idxToRemove -ge 0) {
                    $appsList.RemoveAt($idxToRemove)
                }

                $stage = if ($appData.stage) { $appData.stage } elseif ($status -eq "submitted") { "applied" } else { "draft" }
                $fullName = if ($appData.fullName) { $appData.fullName } else { "" }
                $primaryRole = if ($appData.primaryRole) { $appData.primaryRole } else { "" }

                $clientIpFromMeta = if ($appData.applicantMetadata -and $appData.applicantMetadata.clientIp) { $appData.applicantMetadata.clientIp } else { $clientIp }

                $newIndexEntry = [PSCustomObject]@{
                    appId = $appId
                    email = $email
                    fullName = $fullName
                    primaryRole = $primaryRole
                    stage = $stage
                    status = $status
                    clientIp = $clientIpFromMeta
                    submittedAt = $appData.submittedAt
                    lastUpdated = $nowIso
                    fileName = "$appId.json"
                }
                $appsList.Insert(0, $newIndexEntry) | Out-Null
                $indexObj.applications = $appsList
                $indexObj.totalApplications = $appsList.Count
                $indexObj.lastUpdated = $nowIso

                # Save index.json back to disk
                $updatedIndexJson = $indexObj | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($indexFilePath, $updatedIndexJson, [System.Text.Encoding]::UTF8)

                Write-Host "[API] Saved application $appId (Email: $email, Status: $status, Client IP: $clientIp) to JobApplications folder and updated index.json" -ForegroundColor Green

                $response.ContentType = "application/json; charset=utf-8"
                $response.StatusCode = 200
                $resBytes = [System.Text.Encoding]::UTF8.GetBytes('{"success": true, "appId": "' + $appId + '", "clientIp": "' + $clientIp + '"}')
                $response.OutputStream.Write($resBytes, 0, $resBytes.Length)
            } catch {
                Write-Host "[ERROR] Failed to save application: $_" -ForegroundColor Red
                $response.StatusCode = 500
                $resBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error": "' + $_.Exception.Message + '"}')
                $response.OutputStream.Write($resBytes, 0, $resBytes.Length)
            }
            $response.Close()
            continue
        }

        # API: Get Client IP & Network Context
        if ($httpMethod -eq "GET" -and $urlPath -eq "/api/client-ip") {
            $clientIp = $request.RemoteEndPoint.Address.ToString()
            if ($request.Headers["X-Forwarded-For"]) {
                $clientIp = $request.Headers["X-Forwarded-For"].Split(',')[0].Trim()
            }
            if ($clientIp -eq "::1") { $clientIp = "127.0.0.1" }
            $ipObj = [PSCustomObject]@{
                ip = $clientIp
                port = $request.RemoteEndPoint.Port
                userAgent = if ($request.UserAgent) { $request.UserAgent } else { "" }
                serverTimestampUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            }
            $response.ContentType = "application/json; charset=utf-8"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($ipObj | ConvertTo-Json))
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            $response.Close()
            continue
        }

        # API: Get Index
        if ($httpMethod -eq "GET" -and $urlPath -eq "/api/index") {
            if (Test-Path $indexFilePath) {
                $response.ContentType = "application/json; charset=utf-8"
                $bytes = [System.IO.File]::ReadAllBytes($indexFilePath)
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $response.StatusCode = 404
            }
            $response.Close()
            continue
        }

        # Static File Serving
        $localPath = $urlPath.TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($localPath)) {
            $localPath = if (Test-Path (Join-Path $currentDir "index.html")) { "index.html" } else { "Learning_html.html" }
        }

        $filePath = Join-Path $currentDir $localPath
        if (Test-Path $filePath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $contentType = switch ($ext) {
                ".html" { "text/html; charset=utf-8" }
                ".htm"  { "text/html; charset=utf-8" }
                ".svg"  { "image/svg+xml" }
                ".json" { "application/json; charset=utf-8" }
                ".css"  { "text/css; charset=utf-8" }
                ".js"   { "application/javascript; charset=utf-8" }
                Default { "application/octet-stream" }
            }
            $response.ContentType = $contentType
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $response.StatusCode = 404
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $urlPath")
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }

        $response.Close()
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Write-Host "Server stopped." -ForegroundColor Yellow
}
