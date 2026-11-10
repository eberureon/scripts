# Removes traces of activity on Windows, regardless of their age. Run it
# deliberately, not on a schedule. For freeing disk space see cleanwindows.ps1.
#
# Run from PowerShell:
#   powershell -ExecutionPolicy Bypass -File privacywindows.ps1 -DryRun -All

param(
    [switch]$DryRun,
    [switch]$Detailed,
    [switch]$Yes,
    [switch]$History,
    [switch]$Browsers,
    [switch]$Trash,
    [switch]$All,
    [switch]$Help
)

if ($Help) {
    Write-Host @'
Usage: privacywindows.ps1 [OPTIONS]
Remove traces of activity on Windows, regardless of their age.
Run it in a PowerShell started with "Run as administrator" for a complete
run; without that, the system-wide steps are skipped.

Without options only traces that daily work does not depend on are removed:
temp files, the legacy web cache, thumbnail and icon caches, error reports
and crash dumps, Prefetch data, the Windows event logs, print job copies
(pending print jobs are cancelled), DNS cache, clipboard and clipboard
history, and app web caches.
Files changed in the last 10 minutes are left alone so that running apps
keep working; close your apps first for a complete result.

Options:
    -Help               Show this help message
    -DryRun             Show what would be deleted without deleting
    -Detailed           List every deleted file instead of a count
    -Yes                Do not ask for confirmation
    -History            Also remove history you would notice losing:
                        PowerShell and other shell history, recent files and
                        jump lists (pinned jump-list items are lost, Quick
                        Access pins are kept), the Run dialog, Explorer
                        address bar and search history, program usage
                        statistics and the Windows activity history.
    -Browsers           Also remove browser history, cookies, site storage,
                        sessions, form autofill and caches (Edge, Chrome,
                        Chromium, Brave, Vivaldi, Firefox, LibreWolf, Zen).
                        This signs you out of websites, closes open tabs and
                        resets custom search engines in Chromium browsers.
                        Bookmarks, saved passwords and extensions are kept.
                        Running browsers are skipped.
    -Trash              Also empty the Recycle Bin completely
    -All                Same as -History -Browsers -Trash
'@
    exit 0
}

if ($All) {
    $History = $true
    $Browsers = $true
    $Trash = $true
}

. (Join-Path $PSScriptRoot 'lib.ps1')

Assert-Environment

$selected = 'temp files, caches, logs, clipboard'
if ($History) { $selected += ', history' }
if ($Browsers) { $selected += ', browser data' }
if ($Trash) { $selected += ', Recycle Bin' }
Confirm-Run "This permanently deletes: $selected. Continue?"

Start-Run

# Files a running app has just written are left alone.
$recent = 10
$local = $env:LOCALAPPDATA
$roaming = $env:APPDATA
$windows = $env:SystemRoot

# ---------------------------------------------------------------------------
# Always: traces that daily work does not depend on
# ---------------------------------------------------------------------------
Write-Host 'Starting privacy cleanup...'

Write-Host 'Clearing temporary files...'
Clear-Files -Dir $env:TEMP -MinAgeMinutes $recent -PruneDirs
Clear-Files -Dir "$windows\Temp" -MinAgeMinutes $recent -PruneDirs -Admin

Write-Host 'Clearing web, thumbnail and icon caches...'
Clear-Files -Dir "$local\Microsoft\Windows\INetCache" -MinAgeMinutes $recent -PruneDirs
Clear-Files -Dir "$local\D3DSCache" -MinAgeMinutes $recent -PruneDirs
# Explorer keeps these open; what is in use is skipped until the next sign-in.
Clear-Files -Dir "$local\Microsoft\Windows\Explorer" -Include 'thumbcache_*.db', 'iconcache_*.db' -NoRecurse

Write-Host 'Clearing error reports and crash dumps...'
Clear-Files -Dir "$local\Microsoft\Windows\WER" -PruneDirs
Clear-Files -Dir "$local\CrashDumps"
Clear-Files -Dir "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" -PruneDirs -Admin
Clear-Files -Dir "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" -PruneDirs -Admin
Clear-Files -Dir "$windows\Minidump" -Admin
Clear-Files -Dir $windows -Include 'MEMORY.DMP' -NoRecurse -Admin

# Prefetch records which programs were started and when.
Write-Host 'Clearing Prefetch data...'
Clear-Files -Dir "$windows\Prefetch" -Include '*.pf' -NoRecurse -Admin

Write-Host 'Clearing Windows event logs...'
Invoke-Action -Admin -Description 'clear all Windows event logs' -Action {
    foreach ($log in (& wevtutil.exe el)) {
        & wevtutil.exe cl $log 2>$null
    }
}

Write-Host 'Clearing print job copies (this also cancels pending print jobs)...'
Invoke-Action -Admin -Description 'empty the print spooler folder' -Action {
    Stop-Service -Name Spooler -Force -ErrorAction Stop
    try {
        foreach ($entry in (Get-TreeEntries -Dir "$windows\System32\spool\PRINTERS" -NoRecurse)) {
            if ($entry -is [IO.FileInfo]) { [void](Remove-TreeSafe $entry.FullName) }
        }
    } finally {
        Start-Service -Name Spooler -ErrorAction Stop
    }
}

Write-Host 'Flushing DNS cache...'
Invoke-Tool -Exe 'ipconfig.exe' -Arguments '/flushdns'

Write-Host 'Clearing clipboard and clipboard history...'
Invoke-Action -Description 'clear the clipboard' -Action {
    & cmd.exe /c 'echo off | clip'
}
if ($PSVersionTable.PSVersion.Major -le 5) {
    Invoke-Action -Description 'clear the clipboard history (Win+V)' -Action {
        [void][Windows.ApplicationModel.DataTransfer.Clipboard, Windows.ApplicationModel.DataTransfer, ContentType = WindowsRuntime]
        [void][Windows.ApplicationModel.DataTransfer.Clipboard]::ClearHistory()
    }
} else {
    Write-Host 'Note: the clipboard history (Win+V) can only be cleared from Windows PowerShell 5.1.'
}

# Electron apps (Slack, Discord, VS Code, Teams, ...) keep their web caches
# in their settings folder.
Write-Host 'Clearing app web caches in AppData...'
Remove-Paths -Path @(
    "$roaming\*\Cache",
    "$roaming\*\Code Cache",
    "$roaming\*\GPUCache",
    "$roaming\*\Service Worker\CacheStorage"
)

# ---------------------------------------------------------------------------
# -History: history the user would notice losing
# ---------------------------------------------------------------------------
if ($History) {
    Write-Host ''
    Write-Host 'History cleanup...'

    Write-Host 'Removing shell and REPL history...'
    $userHome = $env:USERPROFILE
    Remove-Paths -Path @(
        "$roaming\Microsoft\Windows\PowerShell\PSReadLine\*_history.txt",
        "$userHome\.bash_history",
        "$userHome\.lesshst",
        "$userHome\.viminfo",
        "$userHome\_viminfo",
        "$userHome\.python_history",
        "$userHome\.node_repl_history",
        "$userHome\.psql_history",
        "$userHome\.mysql_history",
        "$userHome\.sqlite_history"
    )

    Write-Host 'Clearing recent files and jump lists...'
    $recentDir = "$roaming\Microsoft\Windows\Recent"
    Remove-Paths -Path "$recentDir\*.lnk"
    # These two jump lists hold the Quick Access pins and must stay.
    foreach ($folder in "$recentDir\AutomaticDestinations", "$recentDir\CustomDestinations") {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($entry in (Get-TreeEntries -Dir $folder -NoRecurse)) {
            if ($entry.Name -like 'f01b4d95cf55d32a.*' -or $entry.Name -like '5f7b5f1e01b83767.*') { continue }
            Remove-Paths -Literal -Path $entry.FullName
        }
    }

    Write-Host 'Clearing Run dialog, Explorer and program usage history...'
    $explorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
    Remove-RegistryKey "$explorer\RunMRU"
    Remove-RegistryKey "$explorer\TypedPaths"
    Remove-RegistryKey "$explorer\RecentDocs"
    Remove-RegistryKey "$explorer\WordWheelQuery"
    Remove-RegistryKey "$explorer\ComDlg32\OpenSavePidlMRU"
    Remove-RegistryKey "$explorer\ComDlg32\LastVisitedPidlMRU"
    Remove-RegistryKey "$explorer\UserAssist"

    # The activity history ("Timeline"). Its service keeps the files open, so
    # they may only go after the next sign-in.
    Write-Host 'Clearing Windows activity history...'
    Remove-Paths -Path "$local\ConnectedDevicesPlatform\*\ActivitiesCache.db*"
}

# ---------------------------------------------------------------------------
# -Browsers: history, cookies, site storage, sessions and caches
# ---------------------------------------------------------------------------
if ($Browsers) {
    Write-Host ''
    Write-Host 'Browser cleanup...'

    Clear-Chromium -Name 'Microsoft Edge' -Process 'msedge' -Root "$local\Microsoft\Edge\User Data"
    Clear-Chromium -Name 'Google Chrome' -Process 'chrome' -Root "$local\Google\Chrome\User Data"
    Clear-Chromium -Name 'Chromium' -Process 'chrome', 'chromium' -Root "$local\Chromium\User Data"
    Clear-Chromium -Name 'Brave' -Process 'brave' -Root "$local\BraveSoftware\Brave-Browser\User Data"
    Clear-Chromium -Name 'Vivaldi' -Process 'vivaldi' -Root "$local\Vivaldi\User Data"

    Clear-Firefox -Name 'Firefox' -Process 'firefox' `
        -Profiles "$roaming\Mozilla\Firefox\Profiles" -Cache "$local\Mozilla\Firefox\Profiles"
    Clear-Firefox -Name 'LibreWolf' -Process 'librewolf' `
        -Profiles "$roaming\librewolf\Profiles" -Cache "$local\librewolf\Profiles"
    Clear-Firefox -Name 'Zen' -Process 'zen' `
        -Profiles "$roaming\zen\Profiles" -Cache "$local\zen\Profiles"

    # Cookies of the old Internet Explorer engine, which some apps still use.
    Clear-Files -Dir "$local\Microsoft\Windows\INetCookies" -PruneDirs
}

# ---------------------------------------------------------------------------
# -Trash: empty the Recycle Bin completely
# ---------------------------------------------------------------------------
if ($Trash) {
    Write-Host ''
    Write-Host 'Emptying Recycle Bin...'
    Invoke-Action -Description 'empty the Recycle Bin on all drives' -Action {
        Clear-RecycleBin -Force -ErrorAction Stop
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run complete, nothing was deleted.'
} else {
    Write-Host 'Privacy cleanup complete!'
}

# Things the script cannot fix, only point out.
if ($History) {
    Write-Host 'Note: this PowerShell window keeps writing its history. Close it after the'
    Write-Host '      run; commands typed from now on are recorded again.'
}

if (-not $Trash) {
    Write-Host 'Note: the Recycle Bin was not emptied (use -Trash).'
}

Write-Host 'Note: System Restore points, File History and OneDrive can still hold copies'
Write-Host '      of the deleted files.'

# 1 = on, 3 = encryption in progress, 5 = on but suspended
$protection = $null
try {
    $shell = New-Object -ComObject Shell.Application
    $protection = $shell.NameSpace("$env:SystemDrive\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
} catch { }
if ($null -ne $protection -and $protection -ne 1 -and $protection -ne 3 -and $protection -ne 5) {
    Write-Host 'Note: BitLocker is not on for the system drive. Without disk encryption,'
    Write-Host '      deleted files cannot be made unreadable on an SSD, and the page file'
    Write-Host '      or hibernation file can hold copies.'
}
