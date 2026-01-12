<#
.SYNOPSIS
    Builds a Docker image, flattens it, and restores configuration via a reconstruction build.
.DESCRIPTION
    1. Builds the target image (with layers).
    2. Exports it to a tarball (flattening filesystem).
    3. Imports the tarball as a temporary base image.
    4. Generates a dynamic Dockerfile to restore ENV, ENTERYPOINT, CMD, etc.
    5. Builds the final optimized image.
.PARAMETER ImageName
    The final image name (default: postgres-lite-opt)
.PARAMETER DockerFile
    The source Dockerfile (default: Dockerfile.lite3)
.PARAMETER Platform
    The target platform for cross-compilation (e.g., "linux/arm64" for Raspberry Pi).
    Requires Docker Buildx/QEMU if different from host.
#>

param(
    [string]$ImageName = "postgres-lite-opt",
    [string]$DockerFile = "Dockerfile.lite3",
    [string]$Platform = ""
)

$TempBuildImage = "temp-build-layered-$(Get-Random)"
$TempContainer = "temp-container-$(Get-Random)"
$FlatBaseImage = "temp-flat-base-$(Get-Random)"
$FinalDockerfile = "Dockerfile.generated.final"

# Build arguments configuration
$BuildArgs = @("build", "-t", $TempBuildImage, "-f", $DockerFile)
if (-not [string]::IsNullOrWhiteSpace($Platform)) {
    $BuildArgs += "--platform", $Platform
}
$BuildArgs += "."

try {
    Write-Host "1. Building source image..." -ForegroundColor Cyan
    if ($Platform) { Write-Host "   Target Platform: $Platform" -ForegroundColor Yellow }
    
    docker @BuildArgs
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }

    Write-Host "2. Inspecting configuration..." -ForegroundColor Cyan
    $configJson = docker inspect $TempBuildImage | ConvertFrom-Json
    $cfg = $configJson[0].Config

    Write-Host "3. Flattening image (Export/Import)..." -ForegroundColor Cyan
    docker create --name $TempContainer $TempBuildImage
    try {
        $tarFile = "${TempContainer}.tar"
        docker export $TempContainer -o $tarFile
        
        # Import args
        $ImportArgs = @("import")
        if (-not [string]::IsNullOrWhiteSpace($Platform)) {
            $ImportArgs += "--platform", $Platform
        }
        $ImportArgs += $tarFile
        $ImportArgs += $FlatBaseImage
        
        docker @ImportArgs
    } finally {
        docker rm $TempContainer -f 2>$null
        if (Test-Path $tarFile) { Remove-Item $tarFile }
    }

    Write-Host "4. Generating reconstruction Dockerfile..." -ForegroundColor Cyan
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("FROM $FlatBaseImage")
    
    # Restore ENV
    if ($cfg.Env) {
        foreach ($envLine in $cfg.Env) {
            $parts = $envLine -split '=', 2
            $k = $parts[0]
            $v = $parts[1]
            if ($v) {
                # Escape quotes in value
                $vEscaped = $v -replace '"', '\"'
                # Wrap value in quotes to handle spaces etc
                [void]$sb.AppendLine("ENV $k=`"$vEscaped`"")
            } else {
                [void]$sb.AppendLine("ENV $k=")
            }
        }
    }

    # Restore WORKDIR
    if ($cfg.WorkingDir) {
        [void]$sb.AppendLine("WORKDIR $($cfg.WorkingDir)")
    }

    # Restore USER
    if ($cfg.User) {
        [void]$sb.AppendLine("USER $($cfg.User)")
    }

    # Restore ENTRYPOINT
    if ($cfg.Entrypoint) {
        $epItems = @($cfg.Entrypoint)
        $epStrList = $epItems | ForEach-Object { "`"$_`"" }
        $epJoined = $epStrList -join ", "
        [void]$sb.AppendLine("ENTRYPOINT [$epJoined]")
    }

    # Restore CMD
    if ($cfg.Cmd) {
        $cmdItems = @($cfg.Cmd)
        $cmdStrList = $cmdItems | ForEach-Object { "`"$_`"" }
        $cmdJoined = $cmdStrList -join ", "
        [void]$sb.AppendLine("CMD [$cmdJoined]")
    }
    
    # Restore EXPOSE
    if ($cfg.ExposedPorts) {
        foreach ($port in $cfg.ExposedPorts.PSObject.Properties.Name) {
            [void]$sb.AppendLine("EXPOSE $port")
        }
    }

    # Restore VOLUMES
    if ($cfg.Volumes) {
        foreach ($vol in $cfg.Volumes.PSObject.Properties.Name) {
            [void]$sb.AppendLine("VOLUME [`"$vol`"]")
        }
    }

    Set-Content -Path $FinalDockerfile -Value $sb.ToString()

    Write-Host "5. Building final optimized image..." -ForegroundColor Cyan
    # Final build argument construction (reuse relevant args)
    $FinalBuildArgs = @("build", "-t", $ImageName, "-f", $FinalDockerfile)
    if (-not [string]::IsNullOrWhiteSpace($Platform)) {
        $FinalBuildArgs += "--platform", $Platform
    }
    $FinalBuildArgs += "."
    docker @FinalBuildArgs

    Write-Host "6. Size Comparison..." -ForegroundColor Cyan
    $oldSize = docker images $TempBuildImage --format "{{.Size}}"
    $newSize = docker images $ImageName --format "{{.Size}}"
    Write-Host "   Original:  $oldSize"
    Write-Host "   Optimized: $newSize" -ForegroundColor Green

} catch {
    Write-Error "Error: $_"
} finally {
    Write-Host "Cleanup..."
    docker rmi $TempBuildImage -f 2>$null
    docker rmi $FlatBaseImage -f 2>$null
    if (Test-Path $FinalDockerfile) { Remove-Item $FinalDockerfile }
}
