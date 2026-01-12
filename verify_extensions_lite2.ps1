<#
.SYNOPSIS
    Verifies that all PostgreSQL extensions in the Dockerfile.lite2 image are installable and functional.
.DESCRIPTION
    This script starts a temporary container from the 'postgres-lite2' image,
    waits for it to become ready, and then iteratively attempts to create and test
    each extension defined in the Dockerfile.
#>

$ImageName = "postgres-lite2"
$ContainerName = "postgres-lite2-test-$(Get-Random)"
$PostgresPassword = "password"

Write-Host "Starting validation for image: $ImageName" -ForegroundColor Cyan

# 1. Start the container
Write-Host "Starting container..."
$dockerRunArgs = @(
    "run", "-d", "--rm",
    "--name", $ContainerName,
    "-e", "POSTGRES_PASSWORD=$PostgresPassword",
    $ImageName
)
$containerId = docker @dockerRunArgs

if (-not $containerId) {
    Write-Error "Failed to start container."
    exit 1
}

try {
    # 2. Wait for PostgreSQL to be ready
    Write-Host "Waiting for PostgreSQL to be ready..." -NoNewline
    $maxRetries = 30
    $retryCount = 0
    $isReady = $false

    while ($retryCount -lt $maxRetries) {
        $status = docker exec $ContainerName pg_isready -U postgres
        if ($LASTEXITCODE -eq 0) {
            $isReady = $true
            break
        }
        Start-Sleep -Seconds 1
        $retryCount++
        Write-Host "." -NoNewline
    }
    Write-Host ""

    if (-not $isReady) {
        throw "PostgreSQL did not become ready in time."
    }

    Write-Host "PostgreSQL is ready." -ForegroundColor Green

    # 3. Define extensions and test queries
    # Removed: pg_parquet, timescaledb, pgaudit
    $extensions = @(
        @{ Name = "vector";       Query = 'SELECT ''[1,2,3]''::vector;' }
        @{ Name = "cron";         Query = "SELECT count(*) FROM cron.job;" }
        @{ Name = "jsquery";      Query = 'SELECT ''{\"a\": 1}''::jsonb @@ ''a = 1''::jsquery;' }
        @{ Name = "partman";      Query = 'SELECT schema_name FROM information_schema.schemata WHERE schema_name = ''partman'';' }
        @{ Name = "pg_hint_plan"; Query = "SELECT 1;" }
        @{ Name = "pgpcre";       Query = "SELECT 1;" }
        @{ Name = "pgq";          Query = "SELECT 1;" }
        @{ Name = "prefix";       Query = 'SELECT ''123''::prefix_range;' }
        @{ Name = "age";          Query = 'LOAD ''age''; SET search_path = ag_catalog, \"$user\", public; SELECT count(*) FROM ag_graph;' }
    )

    # 4. Run tests
    $failed = 0
    
    foreach ($ext in $extensions) {
        $name = $ext.Name
        $query = $ext.Query
        Write-Host "Testing extension: [$name] ... " -NoNewline

        $createCmd = "CREATE EXTENSION IF NOT EXISTS $name CASCADE;"
        if ($name -eq "age") {
             $createCmd = "CREATE EXTENSION IF NOT EXISTS age;"
        }

        $sql = "$createCmd $query"
        
        # Execute the SQL
        $execResult = docker exec -e PGPASSWORD=$PostgresPassword $ContainerName psql -U postgres -d postgres -t -c $sql 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Host "OK" -ForegroundColor Green
        } else {
            Write-Host "FAILED" -ForegroundColor Red
            Write-Host "Error details: $execResult" -ForegroundColor Gray
            $failed++
        }
    }

    if ($failed -eq 0) {
        Write-Host "`nAll extensions passed validation!" -ForegroundColor Green
    } else {
        Write-Host "`n$failed extensions failed validation." -ForegroundColor Red
    }

} catch {
    Write-Error "An error occurred: $_"
} finally {
    # 5. Cleanup
    Write-Host "Cleaning up container..."
    docker stop $ContainerName | Out-Null
}
