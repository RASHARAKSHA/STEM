# Horizon Academy Local Server with SQLite Database
# Serves the website and stores Academics feedback form data in database.sqlite

Add-Type -AssemblyName System.Web

$port = 3000
$projectRoot = $PSScriptRoot
$dbPath = Join-Path $projectRoot "database.sqlite"
$toolsDir = Join-Path $env:LOCALAPPDATA "HorizonAcademy\tools"
$sqliteExe = Join-Path $toolsDir "sqlite3.exe"

function Ensure-SqliteTools {
    if (Test-Path $sqliteExe) { return }

    Write-Host "Downloading SQLite tools (first run only)..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

    $zipUrl = "https://www.sqlite.org/2024/sqlite-tools-win-x64-3460100.zip"
    $zipPath = Join-Path $env:TEMP "sqlite-tools.zip"
    $extractDir = Join-Path $env:TEMP "sqlite-tools-extract"

    if (Test-Path $extractDir) {
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    }

    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($zipUrl, $zipPath)

        $zipSize = (Get-Item $zipPath).Length
        if ($zipSize -lt 1000000) {
            throw "Downloaded SQLite archive looks incomplete ($zipSize bytes)."
        }

        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

        $downloadedExe = Get-ChildItem -Path $extractDir -Recurse -Filter "sqlite3.exe" | Select-Object -First 1
        if (-not $downloadedExe) {
            throw "sqlite3.exe was not found in the downloaded archive."
        }

        Copy-Item -Path $downloadedExe.FullName -Destination $sqliteExe -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "Failed to download SQLite tools: $_" -ForegroundColor Red
        throw
    }
}

function Escape-SqlValue([string]$Value) {
    if ($null -eq $Value) { return "''" }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Initialize-Database {
    $createTableSql = @"
CREATE TABLE IF NOT EXISTS feedback (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  role TEXT NOT NULL,
  feedback_type TEXT NOT NULL,
  rating INTEGER NOT NULL,
  comments TEXT NOT NULL,
  created_at TEXT NOT NULL
);
"@

    $createTableSql | & $sqliteExe $dbPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize SQLite database at $dbPath"
    }
}

function Save-Feedback($data) {
    $createdAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $rating = [int]$data.rating

    $insertSql = @"
INSERT INTO feedback (name, email, role, feedback_type, rating, comments, created_at)
VALUES (
  $(Escape-SqlValue $data.name),
  $(Escape-SqlValue $data.email),
  $(Escape-SqlValue $data.role),
  $(Escape-SqlValue $data.feedback_type),
  $rating,
  $(Escape-SqlValue $data.comments),
  $(Escape-SqlValue $createdAt)
);
SELECT last_insert_rowid();
"@

    $newId = $insertSql | & $sqliteExe $dbPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SQLite insert failed: $newId"
    }

    return [int]($newId | Select-Object -Last 1)
}

function Get-FeedbackRows {
    $query = "SELECT id, name, email, role, feedback_type, rating, comments, created_at FROM feedback ORDER BY id DESC;"
    $output = & $sqliteExe -json $dbPath $query 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SQLite query failed: $output"
    }

    if ([string]::IsNullOrWhiteSpace($output)) {
        return @()
    }

    $parsed = $output | ConvertFrom-Json
    if ($parsed -is [array]) {
        return $parsed
    }
    return @($parsed)
}

function Send-JsonResponse($response, [int]$statusCode, $payload) {
    $json = $payload | ConvertTo-Json -Depth 5 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)

    $response.StatusCode = $statusCode
    $response.ContentType = "application/json; charset=utf-8"
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Close()
}

function Test-FeedbackPayload($data) {
    if (-not $data.name -or -not $data.email -or -not $data.role -or -not $data.feedback_type -or -not $data.rating -or -not $data.comments) {
        return $false
    }
    return $true
}

Ensure-SqliteTools
Initialize-Database

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")

try {
    $listener.Start()
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "  Horizon Academy Local Server Started!" -ForegroundColor Green
    Write-Host "  Website:  http://localhost:$port/academics.html" -ForegroundColor Cyan
    Write-Host "  API:      http://localhost:$port/api/feedback" -ForegroundColor Cyan
    Write-Host "  Database: SQLite ($dbPath)" -ForegroundColor Yellow
    Write-Host "  Press Ctrl+C to stop the server." -ForegroundColor Red
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Host "Error starting server: $_" -ForegroundColor Red
    exit 1
}

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $urlPath = $request.Url.LocalPath

        if ($urlPath -eq "/") { $urlPath = "/index.html" }

        if ($urlPath -eq "/api/feedback" -and $request.HttpMethod -eq "POST") {
            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()

            try {
                $data = $body | ConvertFrom-Json

                if (-not (Test-FeedbackPayload $data)) {
                    Send-JsonResponse $response 400 @{ success = $false; message = "All form fields are required." }
                    continue
                }

                $newId = Save-Feedback $data
                Send-JsonResponse $response 201 @{
                    success = $true
                    message = "Feedback submitted and stored in the SQLite database table successfully!"
                    id = $newId
                }
                Write-Host "[POST] Feedback from $($data.name) saved to SQLite with ID $newId." -ForegroundColor Gray
            } catch {
                Send-JsonResponse $response 500 @{ success = $false; message = "Failed to save feedback to SQLite database."; error = $_.Exception.Message }
                Write-Host "[POST] Error: $_" -ForegroundColor DarkRed
            }
            continue
        }

        if ($urlPath -eq "/api/feedback" -and $request.HttpMethod -eq "GET") {
            try {
                $rows = Get-FeedbackRows
                Send-JsonResponse $response 200 @{ success = $true; dbMode = "SQLite"; data = $rows }
                Write-Host "[GET] Returned feedback records from SQLite." -ForegroundColor Gray
            } catch {
                Send-JsonResponse $response 500 @{ success = $false; error = $_.Exception.Message }
                Write-Host "[GET] Error: $_" -ForegroundColor DarkRed
            }
            continue
        }

        $decodedPath = [System.Web.HttpUtility]::UrlDecode($urlPath)
        $relativeFilePath = $decodedPath.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
        $filePath = Join-Path $projectRoot $relativeFilePath

        if (Test-Path $filePath -PathType Leaf) {
            $ext = [IO.Path]::GetExtension($filePath).ToLower()
            $mime = switch ($ext) {
                ".html" { "text/html; charset=utf-8" }
                ".css"  { "text/css; charset=utf-8" }
                ".js"   { "application/javascript; charset=utf-8" }
                ".png"  { "image/png" }
                ".jpg"  { "image/jpeg" }
                ".jpeg" { "image/jpeg" }
                ".gif"  { "image/gif" }
                ".webp" { "image/webp" }
                ".json" { "application/json; charset=utf-8" }
                default { "application/octet-stream" }
            }

            $buffer = [IO.File]::ReadAllBytes($filePath)
            $response.ContentType = $mime
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.OutputStream.Close()
            Write-Host "[GET] Served $urlPath" -ForegroundColor Gray
        } else {
            $response.StatusCode = 404
            $errBody = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
            $response.ContentType = "text/plain; charset=utf-8"
            $response.ContentLength64 = $errBody.Length
            $response.OutputStream.Write($errBody, 0, $errBody.Length)
            $response.OutputStream.Close()
            Write-Host "[GET] 404 Not Found: $urlPath" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "Error processing request: $_" -ForegroundColor DarkRed
    }
}
