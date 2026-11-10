# Shared helpers for cleanwindows.ps1 and privacywindows.ps1. Dot-source this
# file, do not run it. All deletions go through these helpers so that -DryRun
# is truthful. Written for Windows PowerShell 5.1 and newer.
#
# The helpers read the calling script's switches: $DryRun, $Detailed, $Yes.

$script:Elevated = $false

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# True for an existing absolute folder that is not a drive root.
function Test-SafeDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not [IO.Path]::IsPathRooted($Path)) { return $false }
    if ($Path -match '\.\.') { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch {
        return $false
    }
    if ($full -notmatch '^[A-Za-z]:\\[^\\]+') { return $false }
    return (Test-Path -LiteralPath $full -PathType Container)
}

# Refuse to run on the wrong system or with folders that cannot be trusted:
# every path the scripts delete from is derived from these variables.
function Assert-Environment {
    if ($env:OS -ne 'Windows_NT') {
        Write-Host 'Error: this script only runs on Windows.'
        exit 1
    }
    foreach ($name in 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'SystemRoot') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not (Test-SafeDir $value)) {
            Write-Host "Error: refusing to run, the environment variable $name is not a usable folder ('$value')."
            exit 1
        }
    }
    $script:Elevated = Test-Elevated
}

# Ask before a destructive run. A dry run and -Yes skip the question.
function Confirm-Run {
    param([string]$Question)
    if ($DryRun -or $Yes) { return }
    $answer = Read-Host "$Question [y/N]"
    if ($answer -notmatch '^[yY]') {
        Write-Host 'Aborted, nothing was deleted.'
        exit 1
    }
}

function Start-Run {
    if ($DryRun) {
        Write-Host '[DRY RUN] Nothing will be deleted. At most 20 files are listed per location.'
    } elseif (-not $script:Elevated) {
        Write-Host 'Not running as administrator: steps that need it will be skipped.'
        Write-Host 'Start PowerShell with "Run as administrator" for a complete run.'
    }
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# List everything below a folder without entering junctions or symbolic
# links: Windows PowerShell 5.1 follows them with -Recurse, which could lead
# the cleanup out of the folder it was pointed at.
function Get-TreeEntries {
    param([string]$Dir, [switch]$NoRecurse)
    $stack = New-Object System.Collections.Stack
    $stack.Push($Dir)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            $entries = [IO.Directory]::GetFileSystemEntries($current)
        } catch {
            continue
        }
        foreach ($entry in $entries) {
            try {
                $attributes = [IO.File]::GetAttributes($entry)
            } catch {
                continue
            }
            $isDir = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
            $isLink = ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isDir) {
                if (-not $isLink -and -not $NoRecurse) { $stack.Push($entry) }
                if (-not $isLink) { New-Object IO.DirectoryInfo($entry) }
            } else {
                New-Object IO.FileInfo($entry)
            }
        }
    }
}

# Delete a file or a whole folder. A junction or symbolic link is removed
# itself, never the thing it points to. Returns $true on success.
function Remove-TreeSafe {
    param([string]$Path)
    try {
        $attributes = [IO.File]::GetAttributes($Path)
        $isDir = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
        $isLink = ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if (-not $isDir) {
            if (($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
                [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
            }
            [IO.File]::Delete($Path)
            return $true
        }
        if (-not $isLink) {
            foreach ($child in [IO.Directory]::GetFileSystemEntries($Path)) {
                [void](Remove-TreeSafe $child)
            }
        }
        # Not recursive: fails if something inside could not be deleted.
        [IO.Directory]::Delete($Path, $false)
        return $true
    } catch {
        return $false
    }
}

# Remove files or folders. Wildcards are allowed unless -Literal is given.
# Missing paths are skipped.
function Remove-Paths {
    param([string[]]$Path, [switch]$Literal, [switch]$Admin)
    foreach ($pattern in $Path) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Literal) {
            $items = @(Get-Item -LiteralPath $pattern -Force -ErrorAction SilentlyContinue)
        } else {
            $items = @(Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue)
        }
        foreach ($item in $items) {
            $full = $item.FullName
            if ($DryRun) {
                Write-Host "[DRY RUN] would remove: $full"
            } elseif ($Admin -and -not $script:Elevated) {
                Write-Host "Skipped (needs administrator): $full"
            } elseif (Remove-TreeSafe $full) {
                Write-Host "Removed: $full"
            } else {
                Write-Host "Could not remove (in use or protected): $full"
            }
        }
    }
}

# Delete the files below a folder.
#   -OlderThanDays   only files not changed for that many days
#   -MinAgeMinutes   leave files alone that were changed in the last minutes
#   -Include         only file names matching one of these wildcards
#   -NoRecurse       only the folder itself, not its subfolders
#   -PruneDirs       also remove the folders this leaves empty
#   -Admin           the folder needs administrator rights
function Clear-Files {
    param(
        [string]$Dir,
        [int]$OlderThanDays = -1,
        [int]$MinAgeMinutes = 0,
        [string[]]$Include = @(),
        [switch]$NoRecurse,
        [switch]$PruneDirs,
        [switch]$Admin
    )
    if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir -PathType Container)) {
        return
    }
    $note = ''
    if ($Admin -and -not $script:Elevated) { $note = ' (listed without administrator rights, may be incomplete)' }

    $cutoff = (Get-Date).AddMinutes(-$MinAgeMinutes)
    if ($OlderThanDays -ge 0) {
        $byDays = (Get-Date).AddDays(-$OlderThanDays)
        if ($byDays -lt $cutoff) { $cutoff = $byDays }
    }

    $files = New-Object System.Collections.ArrayList
    $dirs = New-Object System.Collections.ArrayList
    foreach ($entry in (Get-TreeEntries -Dir $Dir -NoRecurse:$NoRecurse)) {
        if ($entry.LastWriteTime -ge $cutoff) { continue }
        if ($entry -is [IO.DirectoryInfo]) {
            [void]$dirs.Add($entry.FullName)
            continue
        }
        if ($Include.Count -gt 0) {
            $matched = $false
            foreach ($pattern in $Include) {
                if ($entry.Name -like $pattern) { $matched = $true }
            }
            if (-not $matched) { continue }
        }
        [void]$files.Add($entry)
    }

    if ($DryRun) {
        $bytes = 0
        $shown = 0
        foreach ($file in $files) {
            $bytes += $file.Length
            if ($shown -lt 20) {
                Write-Host "[DRY RUN] would remove: $($file.FullName)"
                $shown++
            }
        }
        if ($files.Count -gt 20) { Write-Host "[DRY RUN] ... and $($files.Count - 20) more" }
        if ($files.Count -eq 0) {
            Write-Host "[DRY RUN] nothing to remove under $Dir$note"
        } else {
            Write-Host ("[DRY RUN] {0} files, {1:N1} MiB under {2}{3}" -f $files.Count, ($bytes / 1MB), $Dir, $note)
        }
        return
    }

    if ($Admin -and -not $script:Elevated) {
        Write-Host "Skipped (needs administrator): $Dir"
        return
    }

    $removed = 0
    $failed = 0
    foreach ($file in $files) {
        if (Remove-TreeSafe $file.FullName) {
            $removed++
            if ($Detailed) { Write-Host "Removed: $($file.FullName)" }
        } else {
            $failed++
        }
    }
    if ($PruneDirs) {
        # Deepest first; a folder that is not empty is simply left.
        foreach ($folder in ($dirs | Sort-Object -Property Length -Descending)) {
            try { [IO.Directory]::Delete($folder, $false) } catch { }
        }
    }
    if ($failed -gt 0) {
        Write-Host "Removed $removed files under $Dir ($failed in use or protected, skipped)"
    } else {
        Write-Host "Removed $removed files under $Dir"
    }
}

# Run a program, or only print it in a dry run.
function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments = @(), [switch]$Admin)
    $line = ($Exe + ' ' + ($Arguments -join ' ')).Trim()
    if ($DryRun) {
        Write-Host "[DRY RUN] would run: $line"
        return
    }
    if ($Admin -and -not $script:Elevated) {
        Write-Host "Skipped (needs administrator): $line"
        return
    }
    try {
        $global:LASTEXITCODE = 0
        & $Exe @Arguments
        if ($LASTEXITCODE -ne 0) { Write-Host "Failed or nothing to do: $line" }
    } catch {
        Write-Host "Failed: $line ($($_.Exception.Message))"
    }
}

# Run a block of PowerShell, or only print what it would do in a dry run.
# Use -ErrorAction Stop inside the block so that failures are reported.
function Invoke-Action {
    param([string]$Description, [scriptblock]$Action, [switch]$Admin)
    if ($DryRun) {
        Write-Host "[DRY RUN] would: $Description"
        return
    }
    if ($Admin -and -not $script:Elevated) {
        Write-Host "Skipped (needs administrator): $Description"
        return
    }
    try {
        & $Action | Out-Null
        Write-Host "Done: $Description"
    } catch {
        Write-Host "Failed: $Description ($($_.Exception.Message))"
    }
}

# Remove a registry key with everything below it. Explorer recreates the
# history keys this is used for.
function Remove-RegistryKey {
    param([string]$Key)
    if (-not (Test-Path -LiteralPath $Key)) { return }
    if ($DryRun) {
        Write-Host "[DRY RUN] would remove registry key: $Key"
        return
    }
    try {
        Remove-Item -LiteralPath $Key -Recurse -Force -ErrorAction Stop
        Write-Host "Removed registry key: $Key"
    } catch {
        Write-Host "Could not remove registry key: $Key"
    }
}

function Test-AppRunning {
    param([string]$Name, [string[]]$Process)
    if (Get-Process -Name $Process -ErrorAction SilentlyContinue) {
        Write-Host "$Name is running, skipping it. Quit $Name (also in the notification area) and run again."
        return $true
    }
    return $false
}

# Browsers of the Chromium family. On Windows the caches live inside the
# profile folder.
function Clear-Chromium {
    param([string]$Name, [string[]]$Process, [string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    if (Test-AppRunning -Name $Name -Process $Process) { return }
    Write-Host "Cleaning $Name ($Root)..."
    $profiles = @(Get-Item -Path (Join-Path $Root 'Default'), (Join-Path $Root 'Profile *') -Force -ErrorAction SilentlyContinue)
    foreach ($prof in $profiles) {
        $p = $prof.FullName
        Remove-Paths -Path @(
            "$p\History*",
            "$p\Cookies*",
            "$p\Network\Cookies*",
            "$p\Top Sites*",
            "$p\Visited Links",
            "$p\Network Action Predictor*",
            "$p\Shortcuts*",
            "$p\Favicons*",
            "$p\Media History*",
            "$p\DIPS*",
            "$p\Web Data*",
            "$p\TransportSecurity",
            "$p\Network\TransportSecurity",
            "$p\Network\Reporting and NEL*",
            "$p\Network\Trust Tokens*",
            "$p\Sessions",
            "$p\Local Storage",
            "$p\Session Storage",
            "$p\Cache",
            "$p\Code Cache",
            "$p\GPUCache",
            "$p\Service Worker"
        )
        # Site databases go, the ones that belong to extensions stay.
        $indexedDb = Join-Path $p 'IndexedDB'
        if (Test-Path -LiteralPath $indexedDb -PathType Container) {
            foreach ($entry in (Get-TreeEntries -Dir $indexedDb -NoRecurse)) {
                if ($entry.Name -notlike 'chrome-extension_*') {
                    Remove-Paths -Literal -Path $entry.FullName
                }
            }
        }
    }
    Remove-Paths -Path @("$Root\ShaderCache", "$Root\GrShaderCache", "$Root\GraphiteDawnCache")
}

# Browsers of the Firefox family (Firefox, LibreWolf, Zen).
function Clear-Firefox {
    param([string]$Name, [string[]]$Process, [string]$Profiles, [string]$Cache)
    if (-not (Test-Path -LiteralPath $Profiles -PathType Container)) { return }
    if (Test-AppRunning -Name $Name -Process $Process) { return }
    Write-Host "Cleaning $Name ($Profiles)..."
    foreach ($prof in (Get-TreeEntries -Dir $Profiles -NoRecurse)) {
        if ($prof -isnot [IO.DirectoryInfo]) { continue }
        $p = $prof.FullName
        $db = Join-Path $p 'places.sqlite'
        if (-not (Test-Path -LiteralPath $db -PathType Leaf)) { continue }

        # places.sqlite holds bookmarks as well as history, so the history
        # rows are deleted instead of the file. Pages that are bookmarked stay.
        if (-not (Test-Command 'sqlite3')) {
            Write-Host "sqlite3 is not installed: history in $p is kept (winget install SQLite.SQLite)."
        } elseif ($DryRun) {
            Write-Host "[DRY RUN] would delete the history rows in: $db"
        } else {
            $sql = 'DELETE FROM moz_historyvisits; DELETE FROM moz_inputhistory; ' +
                   'DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL); ' +
                   'UPDATE moz_places SET visit_count = 0, last_visit_date = NULL; '
            # Tables that only newer versions have.
            $tables = @(& sqlite3 $db "SELECT name FROM sqlite_master WHERE type = 'table';" 2>$null)
            if ($tables -contains 'moz_origins') {
                $sql += 'DELETE FROM moz_origins WHERE id NOT IN (SELECT origin_id FROM moz_places WHERE origin_id IS NOT NULL); '
            }
            foreach ($table in 'moz_places_metadata', 'moz_places_metadata_search_queries', 'moz_historyvisits_extra',
                               'moz_newtab_shortcuts_interaction', 'moz_newtab_story_click', 'moz_newtab_story_impression') {
                if ($tables -contains $table) { $sql += "DELETE FROM $table; " }
            }
            foreach ($table in 'moz_places_extra', 'moz_annos') {
                if ($tables -contains $table) {
                    $sql += "DELETE FROM $table WHERE place_id NOT IN (SELECT id FROM moz_places); "
                }
            }
            $global:LASTEXITCODE = 0
            & sqlite3 $db ($sql + 'VACUUM;') 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Deleted the history rows in: $db"
            } else {
                Write-Host "Could not clear the history in: $db"
            }
        }

        Remove-Paths -Path @(
            "$p\cookies.sqlite*",
            "$p\favicons.sqlite*",
            "$p\webappsstore.sqlite*",
            "$p\permissions.sqlite*",
            "$p\content-prefs.sqlite*",
            "$p\SiteSecurityServiceState.*",
            "$p\formhistory.sqlite",
            "$p\sessionstore*",
            "$p\storage\temporary",
            "$p\cache2"
        )
        # Site storage goes, the storage of extensions stays.
        $storage = Join-Path $p 'storage\default'
        if (Test-Path -LiteralPath $storage -PathType Container) {
            foreach ($entry in (Get-TreeEntries -Dir $storage -NoRecurse)) {
                if ($entry.Name -notlike 'moz-extension+++*') {
                    Remove-Paths -Literal -Path $entry.FullName
                }
            }
        }
    }
    if ($Cache) { Remove-Paths -Literal -Path $Cache }
}
