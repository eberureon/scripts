# Frees disk space on Windows: old temp files, caches, error reports, logs
# and developer tool caches. Nothing here is needed for daily work. For
# history, cookies and other activity traces see privacywindows.ps1.
#
# Run from PowerShell:
#   powershell -ExecutionPolicy Bypass -File cleanwindows.ps1 -DryRun

param(
    [Parameter(Position = 0)]
    [ValidateRange(0, 36500)]
    [int]$Days = 7,
    [switch]$DryRun,
    [switch]$Detailed,
    [switch]$ComponentStore,
    [switch]$Docker,
    [switch]$All,
    [switch]$Help
)

if ($Help) {
    Write-Host @'
Usage: cleanwindows.ps1 [OPTIONS] [DAYS]
Free disk space by removing old caches, logs and temporary files.
For history, cookies and other activity traces use privacywindows.ps1.
Run it in a PowerShell started with "Run as administrator" for a complete
run; without that, the system folders are skipped.

Options:
    -Help               Show this help message
    -DryRun             Show what would be deleted without deleting
    -Detailed           List every deleted file instead of a count
    -ComponentStore     Also clean up the Windows component store (WinSxS)
                        with DISM. Safe, but it can take several minutes.
    -Docker             Also prune Docker: stopped containers, unused
                        networks, dangling images and build cache. Data
                        inside stopped containers is lost.
    -All                Same as -ComponentStore -Docker

Arguments:
    DAYS                Number of days of cache to keep (default: 7)
'@
    exit 0
}

if ($All) {
    $ComponentStore = $true
    $Docker = $true
}

. (Join-Path $PSScriptRoot 'lib.ps1')

Assert-Environment

# Remove items that were put into the Recycle Bin more than $Days days ago.
# Every deleted item has a small "$I..." file that is written when it is
# deleted and a "$R..." entry with the same ending that holds the data.
function Clear-OldRecycleBin {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $cutoff = (Get-Date).AddDays(-$Days)
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        if ($drive.DriveType -ne [IO.DriveType]::Fixed -and $drive.DriveType -ne [IO.DriveType]::Removable) { continue }
        $bin = Join-Path $drive.RootDirectory.FullName ('$Recycle.Bin\' + $sid)
        if (-not (Test-Path -LiteralPath $bin -PathType Container)) { continue }
        try {
            $infoFiles = [IO.Directory]::GetFiles($bin, '$I*')
        } catch {
            continue
        }
        foreach ($info in $infoFiles) {
            if ([IO.File]::GetLastWriteTime($info) -ge $cutoff) { continue }
            $name = [IO.Path]::GetFileName($info)
            $data = Join-Path $bin ('$R' + $name.Substring(2))
            Remove-Paths -Literal -Path $data, $info
        }
    }
}

function Get-FreeBytes {
    $drive = New-Object IO.DriveInfo($env:SystemDrive)
    return $drive.AvailableFreeSpace
}

$systemDrive = New-Object IO.DriveInfo($env:SystemDrive)
$freeBefore = Get-FreeBytes
Write-Host ("Free storage: {0:N2} Gi / Total storage: {1:N2} Gi" -f ($freeBefore / 1GB), ($systemDrive.TotalSize / 1GB))

Start-Run

Write-Host "Starting Windows selective cleanup (removing files older than $Days days)..."

Write-Host "Clearing temporary files older than $Days days..."
Clear-Files -Dir $env:TEMP -OlderThanDays $Days
Clear-Files -Dir "$env:SystemRoot\Temp" -OlderThanDays $Days -Admin

Write-Host "Clearing caches older than $Days days..."
Clear-Files -Dir "$env:LOCALAPPDATA\Microsoft\Windows\INetCache" -OlderThanDays $Days
Clear-Files -Dir "$env:LOCALAPPDATA\D3DSCache" -OlderThanDays $Days
Clear-Files -Dir "$env:SystemRoot\SoftwareDistribution\Download" -OlderThanDays $Days -Admin
if (Test-Command 'Delete-DeliveryOptimizationCache') {
    Invoke-Action -Admin -Description 'clear the Delivery Optimization cache' -Action {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
    }
}

Write-Host "Removing error reports and crash dumps older than $Days days..."
Clear-Files -Dir "$env:LOCALAPPDATA\Microsoft\Windows\WER" -OlderThanDays $Days
Clear-Files -Dir "$env:LOCALAPPDATA\CrashDumps" -OlderThanDays $Days
Clear-Files -Dir "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" -OlderThanDays $Days -Admin
Clear-Files -Dir "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" -OlderThanDays $Days -Admin
Clear-Files -Dir "$env:SystemRoot\Minidump" -OlderThanDays $Days -Admin
Clear-Files -Dir $env:SystemRoot -OlderThanDays $Days -Include 'MEMORY.DMP' -NoRecurse -Admin

Write-Host "Removing Windows log files older than $Days days..."
Clear-Files -Dir "$env:SystemRoot\Logs" -OlderThanDays $Days -Include '*.log', '*.cab', '*.etl', '*.old' -Admin

Write-Host "Emptying Recycle Bin (items deleted more than $Days days ago)..."
Clear-OldRecycleBin

# Developer tool caches
if (Test-Command 'npm') {
    Write-Host 'Cleaning npm cache...'
    Invoke-Tool -Exe 'npm' -Arguments 'cache', 'clean', '--force'
}

if (Test-Command 'yarn') {
    Write-Host 'Cleaning yarn cache...'
    Invoke-Tool -Exe 'yarn' -Arguments 'cache', 'clean'
}

if (Test-Command 'pnpm') {
    Write-Host 'Pruning pnpm store...'
    Invoke-Tool -Exe 'pnpm' -Arguments 'store', 'prune'
}

if (Test-Command 'pip') {
    Write-Host 'Cleaning pip cache...'
    Invoke-Tool -Exe 'pip' -Arguments 'cache', 'purge'
}

if (Test-Command 'dotnet') {
    Write-Host 'Cleaning NuGet HTTP cache...'
    Invoke-Tool -Exe 'dotnet' -Arguments 'nuget', 'locals', 'http-cache', '--clear'
}

if (Test-Command 'scoop') {
    Write-Host 'Cleaning Scoop download cache...'
    Invoke-Tool -Exe 'scoop' -Arguments 'cache', 'rm', '*'
}

# Docker, only on request: pruning removes stopped containers.
if ($Docker -and (Test-Command 'docker')) {
    Write-Host 'Checking Docker context...'
    $context = (& docker context show 2>$null)
    if (-not $context) {
        Write-Host 'Unable to determine Docker context; skipping cleanup to avoid a remote connection.'
    } else {
        $endpoint = (& docker context inspect $context --format '{{.Endpoints.docker.Host}}' 2>$null)
        if (-not $endpoint) {
            Write-Host 'Unable to inspect Docker context; skipping cleanup to avoid a remote connection.'
        } elseif ($endpoint -like 'npipe://*' -or $endpoint -like 'unix://*') {
            Write-Host 'Cleaning unused Docker data...'
            Invoke-Tool -Exe 'docker' -Arguments 'system', 'prune', '-f'
        } else {
            Write-Host "Docker is using a remote context ($endpoint), skipping cleanup."
        }
    }
}

# Component store, only on request: it is slow.
if ($ComponentStore) {
    Write-Host 'Cleaning up the Windows component store (this can take several minutes)...'
    Invoke-Tool -Admin -Exe 'Dism.exe' -Arguments '/Online', '/Cleanup-Image', '/StartComponentCleanup'
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'Dry run complete, nothing was deleted.'
} else {
    Write-Host ''
    Write-Host 'After cleanup:'
    $freeAfter = Get-FreeBytes
    Write-Host ("Free storage: {0:N2} Gi / Total storage: {1:N2} Gi" -f ($freeAfter / 1GB), ($systemDrive.TotalSize / 1GB))

    # Never report a negative value
    $freed = $freeAfter - $freeBefore
    if ($freed -lt 0) { $freed = 0 }

    if ($freed -ge 1GB) {
        Write-Host ("Space freed: {0:N2} Gi" -f ($freed / 1GB))
    } elseif ($freed -ge 1MB) {
        Write-Host ("Space freed: {0:N2} Mi" -f ($freed / 1MB))
    } else {
        Write-Host ("Space freed: {0:N0} Ki" -f ($freed / 1KB))
    }

    Write-Host 'Selective cleanup complete!'
}
