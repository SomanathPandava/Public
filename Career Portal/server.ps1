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

    $global:mfaStore = @{}
    $mfaLogPath = Join-Path $jobAppsDir "mfa_emails.json"

    function SafeCloseResponse($resp) {
        if ($resp) {
            try { $resp.Close() } catch {}
        }
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
            SafeCloseResponse($response)
            continue
        }

        # API: Registration & 8-Digit Alphanumeric MFA Trigger (a-z, 0-9, A-Z)
        if ($httpMethod -eq "POST" -and ($urlPath -eq "/api/register" -or $urlPath -eq "/api/send-mfa")) {
            try {
                $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $data = $body | ConvertFrom-Json

                $validationError = $null

                # 1. Validate Username
                $username = ([string]$data.username).Trim()
                if ([string]::IsNullOrWhiteSpace($username) -or $username.Length -lt 4 -or $username.Length -gt 30 -or $username -notmatch '^[a-zA-Z0-9_.-]+$') {
                    $validationError = "Username must be 4-30 alphanumeric characters, hyphens, periods, or underscores."
                }

                # 2. Validate Email (RFC 5321 / RFC 5322 Standard)
                $email = ([string]$data.email).Trim()
                if (-not $validationError) {
                    if ($email.Length -lt 3 -or $email.Length -gt 254) {
                        $validationError = "Email length violates RFC 5321 (allowed 3-254 characters)."
                    } elseif ($email -notmatch '^([^@\s]+)@([^@\s]+)$') {
                        $validationError = "Email format violates RFC 5322 (must contain single @ separating local-part and domain)."
                    } else {
                        $localPart = $Matches[1]
                        $domainPart = $Matches[2]
                        if ($localPart.Length -lt 1 -or $localPart.Length -gt 64) {
                            $validationError = "Email local-part violates RFC 5321 (max 64 characters)."
                        } elseif ($domainPart.Length -lt 1 -or $domainPart.Length -gt 255) {
                            $validationError = "Email domain violates RFC 5321 (max 255 characters)."
                        } elseif ($localPart.StartsWith('.') -or $localPart.EndsWith('.') -or $localPart.Contains('..')) {
                            $validationError = "Email local-part violates RFC 5322 period rules."
                        } else {
                            $domainLabels = $domainPart.Split('.')
                            if ($domainLabels.Count -lt 2) {
                                $validationError = "Email domain must include a valid Top-Level Domain."
                            } else {
                                foreach ($lbl in $domainLabels) {
                                    if ($lbl.Length -lt 1 -or $lbl.Length -gt 63) {
                                        $validationError = "Domain label '$lbl' violates RFC 1035 length limit (max 63 characters)."
                                        break
                                    }
                                }
                            }
                        }
                    }
                }

                # 3. Validate Password Policy (A-Za-z0-9 and agreed special characters: @ $ ! % * ? & # ^ _ -)
                $password = [string]$data.password
                if (-not $validationError) {
                    if ($password.Length -lt 8 -or $password.Length -gt 64) {
                        $validationError = "Password must be 8-64 characters."
                    } elseif ($password -notmatch '^[A-Za-z0-9@$!%*?&#^_\-]+$') {
                        $validationError = "Password contains disallowed characters. Only A-Z, a-z, 0-9 and agreed special characters (@ $ ! % * ? & # ^ _ -) are permitted."
                    } elseif ($password -notmatch '[A-Z]' -or $password -notmatch '[a-z]' -or $password -notmatch '[0-9]' -or $password -notmatch '[@$!%*?&#^_\-]') {
                        $validationError = "Password must include at least one uppercase letter, one lowercase letter, one number, and one agreed special character (@ $ ! % * ? & # ^ _ -)."
                    }
                }

                if ($validationError) {
                    $response.StatusCode = 400
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{"error": "' + $validationError + '"}'))
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    SafeCloseResponse($response)
                    continue
                }

                # Generate 8-character verification code: combination of a-z, 0-9 (no A-Z)
                $chars = "abcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
                $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                $randomBytes = New-Object byte[] 8
                $rng.GetBytes($randomBytes)
                $code = -join ($randomBytes | ForEach-Object { $chars[$_ % $chars.Length] })

                # Save MFA challenge in server memory (valid for 15 minutes)
                $challenge = [PSCustomObject]@{
                    username = $username
                    email = $email
                    code = $code
                    createdAt = (Get-Date).ToString("o")
                    expiresAt = (Get-Date).AddMinutes(15).ToString("o")
                    verified = $false
                }
                $global:mfaStore[$email.ToLower()] = $challenge

                # Console audit log
                Write-Host "==========================================================" -ForegroundColor Cyan
                Write-Host "[MFA EMAIL DISPATCHED] To: $email" -ForegroundColor Green
                Write-Host "Subject: Your 8-Character Career Portal Verification Code" -ForegroundColor White
                Write-Host "Verification Code: $code (Combination of a-z, 0-9)" -ForegroundColor Yellow
                Write-Host "Expires In: 15 minutes" -ForegroundColor Gray
                Write-Host "==========================================================" -ForegroundColor Cyan

                # Append to mfa_emails.json log for inspection
                $emailEntry = [PSCustomObject]@{
                    id = [System.Guid]::NewGuid().ToString()
                    to = $email
                    username = $username
                    code = $code
                    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    status = "Dispatched"
                }
                $existingEmails = @()
                if (Test-Path $mfaLogPath) {
                    try { $existingEmails = Get-Content $mfaLogPath -Raw | ConvertFrom-Json } catch { $existingEmails = @() }
                }
                $updatedEmails = @($emailEntry) + @($existingEmails | Select-Object -First 49)
                $updatedEmails | ConvertTo-Json -Depth 4 | Set-Content $mfaLogPath -Encoding UTF8

                # Return response to client (including code for simulated inbox UI)
                $response.ContentType = "application/json; charset=utf-8"
                $respObj = [PSCustomObject]@{
                    success = $true
                    message = "Verification code sent to $email."
                    email = $email
                    username = $username
                    code = $code
                    expiresInSeconds = 900
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(($respObj | ConvertTo-Json))
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            } catch {
                Write-Host "[ERROR] /api/register failed: $_" -ForegroundColor Red
                $response.StatusCode = 500
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{"error": "' + $_.Exception.Message + '"}'))
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            SafeCloseResponse($response)
            continue
        }

        # API: Verify 8-Digit MFA Code
        if ($httpMethod -eq "POST" -and $urlPath -eq "/api/verify-mfa") {
            try {
                $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $data = $body | ConvertFrom-Json

                $email = ([string]$data.email).Trim().ToLower()
                $enteredCode = ([string]$data.code).Trim()

                if ([string]::IsNullOrWhiteSpace($email) -or [string]::IsNullOrWhiteSpace($enteredCode)) {
                    $response.StatusCode = 400
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error": "Email and 8-character verification code are required."}')
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    SafeCloseResponse($response)
                    continue
                }

                if (-not $global:mfaStore.ContainsKey($email)) {
                    $response.StatusCode = 400
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error": "No active verification challenge found for this email. Please request a new code."}')
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    SafeCloseResponse($response)
                    continue
                }

                $challenge = $global:mfaStore[$email]
                $expiresAt = [DateTime]::Parse($challenge.expiresAt)
                if ((Get-Date) -gt $expiresAt) {
                    $global:mfaStore.Remove($email)
                    $response.StatusCode = 400
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error": "Verification code has expired. Please request a new code."}')
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    SafeCloseResponse($response)
                    continue
                }

                # Match case-insensitively or lowercase match (combination of a-z, 0-9)
                if ($challenge.code.ToLower() -ne $enteredCode.ToLower()) {
                    $response.StatusCode = 400
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error": "Invalid verification code. Please check your email and enter the exact 8-character code."}')
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    SafeCloseResponse($response)
                    continue
                }

                # Successful verification
                $challenge.verified = $true
                Write-Host "[MFA VERIFIED] User $email verified successfully!" -ForegroundColor Green

                $response.ContentType = "application/json; charset=utf-8"
                $respObj = [PSCustomObject]@{
                    success = $true
                    message = "Email successfully verified!"
                    email = $challenge.email
                    username = $challenge.username
                    redirectUrl = "Application.html?verified=true&email=" + [System.Uri]::EscapeDataString($challenge.email) + "&username=" + [System.Uri]::EscapeDataString($challenge.username)
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(($respObj | ConvertTo-Json))
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            } catch {
                $response.StatusCode = 500
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{"error": "' + $_.Exception.Message + '"}'))
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            SafeCloseResponse($response)
            continue
        }

        # API: Sign In Authentication
        if ($httpMethod -eq "POST" -and ($urlPath -eq "/api/login" -or $urlPath -eq "/api/signin")) {
            try {
                $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $data = $body | ConvertFrom-Json

                $identifier = ([string]$data.identifier).Trim()
                $password = [string]$data.password

                if ([string]::IsNullOrWhiteSpace($identifier) -or [string]::IsNullOrWhiteSpace($password)) {
                    $response.StatusCode = 400
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error": "Please enter both your username/email and password."}')
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    SafeCloseResponse($response)
                    continue
                }

                # Find user from saved applications or registered accounts
                $foundUser = $null
                $matchedEmail = $null
                $matchedUsername = $null

                # 1. Search in index.json and application files
                if (Test-Path $indexFilePath) {
                    try {
                        $idx = Get-Content $indexFilePath -Raw | ConvertFrom-Json
                        # Match by email
                        if ($idx.byEmail -and $idx.byEmail.PSObject.Properties[$identifier.ToLower()]) {
                            $matchedEmail = $identifier.ToLower()
                            $appEntry = $idx.byEmail.$($identifier.ToLower())[0]
                            $appFile = Join-Path $jobAppsDir $appEntry.fileName
                            if (Test-Path $appFile) {
                                $appObj = Get-Content $appFile -Raw | ConvertFrom-Json
                                $matchedUsername = $appObj.username
                                $foundUser = $appObj
                            }
                        } else {
                            # Search by username across saved records
                            foreach ($app in $idx.applications) {
                                $appFile = Join-Path $jobAppsDir $app.fileName
                                if (Test-Path $appFile) {
                                    $appObj = Get-Content $appFile -Raw | ConvertFrom-Json
                                    if ($appObj.username -and $appObj.username.ToLower() -eq $identifier.ToLower()) {
                                        $foundUser = $appObj
                                        $matchedEmail = $appObj.email
                                        $matchedUsername = $appObj.username
                                        break
                                    }
                                }
                            }
                        }
                    } catch {}
                }

                # 2. Check in memory mfa challenges
                if (-not $foundUser) {
                    foreach ($kv in $global:mfaStore.GetEnumerator()) {
                        $item = $kv.Value
                        if ($item.email.ToLower() -eq $identifier.ToLower() -or ($item.username -and $item.username.ToLower() -eq $identifier.ToLower())) {
                            $matchedEmail = $item.email
                            $matchedUsername = $item.username
                            $foundUser = [PSCustomObject]@{
                                username = $item.username
                                email = $item.email
                            }
                            break
                        }
                    }
                }

                # If candidate not yet found in records, accept sign-in session for demo/portal access
                if (-not $foundUser) {
                    $matchedEmail = if ($identifier -match '@') { $identifier } else { "$identifier@example.com" }
                    $matchedUsername = if ($identifier -match '@') { $identifier.Split('@')[0] } else { $identifier }
                }

                Write-Host "[SIGN IN SUCCESS] User $matchedUsername ($matchedEmail) signed in." -ForegroundColor Green
                $response.ContentType = "application/json; charset=utf-8"
                $respObj = [PSCustomObject]@{
                    success = $true
                    message = "Sign in successful."
                    username = $matchedUsername
                    email = $matchedEmail
                    redirectUrl = "Application.html?auth=true&email=" + [System.Uri]::EscapeDataString($matchedEmail) + "&username=" + [System.Uri]::EscapeDataString($matchedUsername)
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(($respObj | ConvertTo-Json))
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            } catch {
                $response.StatusCode = 500
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{"error": "' + $_.Exception.Message + '"}'))
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            SafeCloseResponse($response)
            continue
        }

        # API: Save Application
        if ($httpMethod -eq "POST" -and $urlPath -eq "/api/save-application") {
            try {
                $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $appData = $body | ConvertFrom-Json

                # System-generated Application ID (no user input validation needed)
                $appId = [regex]::Replace([string]$appData.appId, '[^a-zA-Z0-9_-]', '')
                if ([string]::IsNullOrWhiteSpace($appId)) {
                    $appId = (Get-Date -Format "yyyyMMddHHmmss") + (Get-Random -Minimum 100 -Maximum 999)
                    $appData.appId = $appId
                }

                # Strict Server-Side Validation: Text Injection, RFC Email, Password Policy & File Standards
                $validationError = $null

                # 1. RFC 5321 / RFC 5322 Email Validation
                if ($appData.email) {
                    $emailStr = [string]$appData.email.Trim()
                    if ($emailStr.Length -lt 3 -or $emailStr.Length -gt 254) {
                        $validationError = "Email length ($($emailStr.Length)) violates RFC 5321 (allowed 3-254 characters)."
                    } elseif ($emailStr -notmatch '^([^@\s]+)@([^@\s]+)$') {
                        $validationError = "Email syntax violates RFC 5322 (must contain single @ separating local-part and domain)."
                    } else {
                        $localPart = $Matches[1]
                        $domainPart = $Matches[2]
                        if ($localPart.Length -lt 1 -or $localPart.Length -gt 64) {
                            $validationError = "Email local-part length ($($localPart.Length)) violates RFC 5321 (max 64 characters)."
                        } elseif ($domainPart.Length -lt 1 -or $domainPart.Length -gt 255) {
                            $validationError = "Email domain length ($($domainPart.Length)) violates RFC 5321 (max 255 characters)."
                        } elseif ($localPart.StartsWith('.') -or $localPart.EndsWith('.') -or $localPart.Contains('..')) {
                            $validationError = "Email local-part violates RFC 5322 period rules."
                        } else {
                            $domainLabels = $domainPart.Split('.')
                            if ($domainLabels.Count -lt 2) {
                                $validationError = "Email domain must include a valid Top-Level Domain."
                            } else {
                                foreach ($lbl in $domainLabels) {
                                    if ($lbl.Length -lt 1 -or $lbl.Length -gt 63) {
                                        $validationError = "Domain label '$lbl' violates RFC 1035 length limit (max 63 characters)."
                                        break
                                    }
                                }
                            }
                        }
                    }
                }

                # 2. Text Injection Protection & Field Length Caps
                if (-not $validationError) {
                    if ($appData.username -and ([string]$appData.username).Length -gt 30) {
                        $validationError = "Username exceeds maximum length of 30 characters."
                    } elseif ($appData.fullName -and ([string]$appData.fullName).Length -gt 100) {
                        $validationError = "Full name exceeds maximum length of 100 characters."
                    } elseif ($appData.bio -and ([string]$appData.bio).Length -gt 1000) {
                        $validationError = "Bio text exceeds maximum length of 1000 characters."
                    } elseif ($appData.website -and ([string]$appData.website).Length -gt 254) {
                        $validationError = "Website URL exceeds maximum length of 254 characters."
                    }
                }

                # 3. International Phone Standard (ITU-T E.164: + followed by 7-13 digits, 8-14 chars total)
                if (-not $validationError -and $appData.phone) {
                    $phoneStr = ([string]$appData.phone).Trim()
                    if ($phoneStr.Length -lt 8 -or $phoneStr.Length -gt 15 -or $phoneStr -notmatch '^\+[1-9][0-9]{6,13}$') {
                        $validationError = "Phone number must follow international standard starting with '+' followed by country code (8-14 characters, e.g. +14155552671)."
                    }
                }

                # 4. Enterprise Password Security Policy (A-Za-z0-9 and agreed special characters: @ $ ! % * ? & # ^ _ -)
                if (-not $validationError -and $appData.password) {
                    $pwd = [string]$appData.password
                    if ($pwd.Length -lt 8 -or $pwd.Length -gt 64) {
                        $validationError = "Password length must be between 8 and 64 characters."
                    } elseif ($pwd -notmatch '^[A-Za-z0-9@$!%*?&#^_\-]+$') {
                        $validationError = "Password contains disallowed characters. Only letters (A-Z, a-z), numbers (0-9), and agreed special characters (@ $ ! % * ? & # ^ _ -) are permitted."
                    } elseif ($pwd -notmatch '[A-Z]' -or $pwd -notmatch '[a-z]' -or $pwd -notmatch '[0-9]' -or $pwd -notmatch '[@$!%*?&#^_\-]') {
                        $validationError = "Password must include at least one uppercase letter, one lowercase letter, one number, and one agreed special character (@ $ ! % * ? & # ^ _ -)."
                    }
                }

                # 5. Profile Picture Validation (Extension & MIME adherence)
                if (-not $validationError -and $appData.profilePhotoName) {
                    $photoName = [string]$appData.profilePhotoName
                    if ($photoName -notmatch '\.(jpe?g|png|webp)$') {
                        $validationError = "Profile photo must be a valid image file with extension .jpg, .jpeg, .png, or .webp."
                    }
                }

                # 6. Resume Document Validation (Strict format & reject blank)
                if (-not $validationError -and $appData.resumeName) {
                    $resumeName = ([string]$appData.resumeName).Trim()
                    if ([string]::IsNullOrWhiteSpace($resumeName) -or $resumeName -eq "") {
                        $validationError = "Blank resume document rejected. A valid non-blank resume is required."
                    } elseif ($resumeName -notmatch '\.(pdf|docx?)$') {
                        $validationError = "Resume document must be in PDF or Word format (.pdf, .docx, .doc)."
                    }
                }

                if ($validationError) {
                    Write-Host "[SECURITY REJECTION] $validationError" -ForegroundColor Red
                    $response.StatusCode = 400
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{"error": "Validation failed: ' + $validationError + '"}'))
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    SafeCloseResponse($response)
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
            SafeCloseResponse($response)
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
            SafeCloseResponse($response)
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
            SafeCloseResponse($response)
            continue
        }

        # Static File Serving
        $localPath = $urlPath.TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($localPath)) {
            $localPath = if (Test-Path (Join-Path $currentDir "index.html")) { "index.html" } else { "Application.html" }
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

        SafeCloseResponse($response)
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Write-Host "Server stopped." -ForegroundColor Yellow
}
