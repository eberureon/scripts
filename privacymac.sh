#!/usr/bin/env bash

# Removes traces of activity on macOS, regardless of their age. Run it
# deliberately, not on a schedule. For freeing disk space see cleanmac.sh.

set -e

# Default configuration
DRY_RUN=false
HISTORY=false
BROWSERS=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]
Remove traces of activity on macOS, regardless of their age.

Without options only traces that daily work does not depend on are removed:
user caches and logs, per-user temp files, QuickLook thumbnails, the download
log, system logs, print job copies (pending print jobs are cancelled), DNS
cache, clipboard, app web caches and local Time Machine snapshots.
Best run with most apps closed.

Options:
    -h, --help          Show this help message
    -d, --dry-run       Show what would be deleted without deleting
    -H, --history       Also remove history you would notice losing: shell and
                        REPL history, "Open Recent" lists, Finder recent
                        folders, saved window state (apps stop reopening their
                        windows) and Notification Center history.
    -b, --browsers      Also remove browser history, cookies, sessions and
                        caches (Safari, Chrome, Brave, Edge, Arc, Vivaldi,
                        Firefox). This signs you out of websites and closes
                        open tabs. Bookmarks and saved passwords are kept.
                        Running browsers are skipped.
    -a, --all           Same as --history --browsers
EOF
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -d|--dry-run)
            DRY_RUN=true
            ;;
        -H|--history)
            HISTORY=true
            ;;
        -b|--browsers)
            BROWSERS=true
            ;;
        -a|--all)
            HISTORY=true
            BROWSERS=true
            ;;
        *)
            echo "Error: unknown argument $1"
            usage
            exit 1
            ;;
    esac
    shift
done

# Load the shared helpers from the folder this script really lives in, also
# when it is called through a symlink.
script_path="${BASH_SOURCE[0]}"
while [ -L "$script_path" ]; do
    link_target=$(readlink "$script_path")
    case $link_target in
        /*) script_path=$link_target ;;
        *) script_path="$(dirname "$script_path")/$link_target" ;;
    esac
done
# shellcheck source=cleanmac-lib.sh
source "$(dirname "$script_path")/cleanmac-lib.sh"

require_macos

# Usage: clean_chromium <display name> <process name> <profile root> <cache dir>
clean_chromium() {
    local name=$1 proc=$2 root=$3 cache=$4 profile
    if [ ! -d "$root" ]; then
        return 0
    fi
    if app_running "$name" "$proc"; then
        return 0
    fi
    echo "Cleaning $name..."
    for profile in "$root"/Default "$root"/Profile\ *; do
        if [ ! -d "$profile" ]; then
            continue
        fi
        remove_path "$profile"/History* \
                    "$profile"/Cookies* \
                    "$profile"/Network/Cookies* \
                    "$profile"/Top\ Sites* \
                    "$profile"/Visited\ Links \
                    "$profile"/Network\ Action\ Predictor* \
                    "$profile"/Shortcuts* \
                    "$profile"/Favicons* \
                    "$profile"/Sessions \
                    "$profile"/Cache \
                    "$profile"/Code\ Cache \
                    "$profile"/GPUCache \
                    "$profile"/Service\ Worker
    done
    remove_path "$cache"
}

start_run

# ---------------------------------------------------------------------------
# Always: traces that daily work does not depend on
# ---------------------------------------------------------------------------
echo "Starting privacy cleanup..."

echo "Clearing user caches and logs..."
find_clean "$LIB/Caches" -type f
find_clean "$LIB/Logs" -type f

echo "Clearing per-user temp and cache folders..."
# Regular files only, so sockets of running apps survive.
user_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
user_cache=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)
if [ -n "$user_tmp" ]; then
    find_clean "${user_tmp%/}" -type f
fi
if [ -n "$user_cache" ]; then
    find_clean "${user_cache%/}" -type f
fi

echo "Resetting QuickLook thumbnail cache..."
run_cmd qlmanage -r cache

echo "Clearing the download log (quarantine events)..."
quarantine_db="$LIB/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
if [ -f "$quarantine_db" ]; then
    run_cmd sqlite3 "$quarantine_db" 'DELETE FROM LSQuarantineEvent; VACUUM;'
fi

echo "Clearing system logs, crash reports and core dumps..."
find_clean --sudo /Library/Logs/DiagnosticReports -type f
find_clean --sudo /private/var/log -type f \( -name "*.gz" -o -name "*.bz2" -o -name "*.[0-9]" \)
remove_path "$APP_SUPPORT"/CrashReporter/*
remove_path --sudo /cores/*
run_cmd sudo log erase --all

echo "Clearing print job copies (this also cancels pending print jobs)..."
run_cmd sudo cancel -a -x

echo "Flushing DNS cache..."
run_cmd sudo dscacheutil -flushcache
run_cmd sudo killall -HUP mDNSResponder

echo "Clearing clipboard..."
run_cmd pbcopy </dev/null

echo "Clearing Mail attachment scratch folder..."
remove_path "$LIB/Containers/com.apple.mail/Data/Library/Mail Downloads"/*

# Electron apps (Slack, Discord, VS Code, Teams, ...) keep their web caches
# here instead of in ~/Library/Caches.
echo "Clearing app web caches in Application Support..."
remove_path "$APP_SUPPORT"/*/Cache \
            "$APP_SUPPORT"/*/Code\ Cache \
            "$APP_SUPPORT"/*/GPUCache \
            "$APP_SUPPORT"/*/Service\ Worker/CacheStorage

ios_backups="$APP_SUPPORT/MobileSync/Backup"
if [ -d "$ios_backups" ]; then
    echo "Note: iOS device backups are kept: $(du -sh "$ios_backups" 2>/dev/null | cut -f1) in $ios_backups"
fi

# ---------------------------------------------------------------------------
# --history: history the user would notice losing
# ---------------------------------------------------------------------------
if [ "$HISTORY" = true ]; then
    echo -e "\nHistory cleanup..."

    echo "Removing shell and REPL history..."
    zsh_dir="${ZDOTDIR:-$HOME}"
    remove_path "$zsh_dir/.zsh_history" "$zsh_dir/.zsh_sessions" \
                "$HOME/.bash_history" "$HOME/.bash_sessions" \
                "$HOME/.lesshst" "$HOME/.viminfo" \
                "$HOME/.python_history" "$HOME/.node_repl_history" \
                "$HOME/.psql_history" "$HOME/.mysql_history" \
                "$HOME/.sqlite_history" "$HOME/.wget-hsts"
    echo "Note: shells that are still open write their history back when they exit."

    # Only the Recent* lists: the same folder also holds Finder sidebar
    # favourites and tags, which must stay.
    echo "Clearing recent items..."
    shared_lists="$APP_SUPPORT/com.apple.sharedfilelist"
    remove_path "$shared_lists"/com.apple.LSSharedFileList.Recent*.sfl* \
                "$shared_lists"/com.apple.LSSharedFileList.ApplicationRecentDocuments/*
    delete_default com.apple.finder FXRecentFolders
    delete_default com.apple.finder GoToField
    delete_default com.apple.finder GoToFieldHistory
    run_cmd killall sharedfilelistd
    run_cmd killall Finder

    echo "Clearing saved application state..."
    remove_path "$LIB/Saved Application State"/*

    echo "Clearing Notification Center history..."
    user_dir=$(getconf DARWIN_USER_DIR 2>/dev/null || true)
    if [ -n "$user_dir" ]; then
        remove_path "${user_dir%/}"/com.apple.notificationcenter/db2/db*
    fi
    remove_path "$LIB/Group Containers/group.com.apple.usernoted"/db2/db*
    run_cmd killall usernoted
fi

# ---------------------------------------------------------------------------
# --browsers: history, cookies, sessions and caches
# ---------------------------------------------------------------------------
if [ "$BROWSERS" = true ]; then
    echo -e "\nBrowser cleanup..."

    if ! app_running "Safari" "Safari"; then
        echo "Cleaning Safari..."
        safari_data="$LIB/Containers/com.apple.Safari/Data/Library"
        remove_path "$LIB"/Safari/History.db* \
                    "$LIB/Safari/Downloads.plist" \
                    "$LIB/Safari/LastSession.plist" \
                    "$LIB/Safari/RecentlyClosedTabs.plist" \
                    "$LIB/Safari/TopSites.plist" \
                    "$LIB/Safari/Favicon Cache" \
                    "$LIB/Safari/Touch Icons Cache" \
                    "$LIB/Caches/com.apple.Safari" \
                    "$LIB/Cookies/Cookies.binarycookies" \
                    "$LIB/WebKit/com.apple.Safari" \
                    "$LIB"/HTTPStorages/com.apple.Safari* \
                    "$safari_data"/Caches/* \
                    "$safari_data"/Cookies/* \
                    "$safari_data/WebKit/WebsiteData"
    fi

    clean_chromium "Google Chrome" "Google Chrome" \
        "$APP_SUPPORT/Google/Chrome" "$LIB/Caches/Google/Chrome"
    clean_chromium "Brave" "Brave Browser" \
        "$APP_SUPPORT/BraveSoftware/Brave-Browser" "$LIB/Caches/BraveSoftware/Brave-Browser"
    clean_chromium "Microsoft Edge" "Microsoft Edge" \
        "$APP_SUPPORT/Microsoft Edge" "$LIB/Caches/Microsoft Edge"
    clean_chromium "Arc" "Arc" \
        "$APP_SUPPORT/Arc/User Data" "$LIB/Caches/Arc"
    clean_chromium "Vivaldi" "Vivaldi" \
        "$APP_SUPPORT/Vivaldi" "$LIB/Caches/Vivaldi"

    if [ -d "$APP_SUPPORT/Firefox/Profiles" ] && ! app_running "Firefox" "firefox"; then
        echo "Cleaning Firefox..."
        for profile in "$APP_SUPPORT"/Firefox/Profiles/*; do
            if [ ! -d "$profile" ]; then
                continue
            fi
            # places.sqlite holds bookmarks as well as history, so the history
            # rows are deleted instead of the file.
            if [ -f "$profile/places.sqlite" ]; then
                run_cmd sqlite3 "$profile/places.sqlite" \
                    'DELETE FROM moz_historyvisits; DELETE FROM moz_inputhistory; DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL); VACUUM;'
            fi
            remove_path "$profile"/cookies.sqlite* \
                        "$profile"/favicons.sqlite* \
                        "$profile/formhistory.sqlite" \
                        "$profile"/sessionstore* \
                        "$profile/cache2"
        done
        remove_path "$LIB/Caches/Firefox"
    fi
fi

# Deleted files stay recoverable from local Time Machine snapshots until the
# snapshots are gone. This runs last on purpose.
if command -v tmutil >/dev/null 2>&1; then
    echo -e "\nDeleting local Time Machine snapshots..."
    for snapshot in $(tmutil listlocalsnapshotdates / 2>/dev/null | grep -E '^[0-9]{4}-' || true); do
        run_cmd sudo tmutil deletelocalsnapshots "$snapshot"
    done
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "\nDry run complete, nothing was deleted."
else
    echo -e "\nPrivacy cleanup complete!"
fi

note_full_disk_access

if ! fdesetup status 2>/dev/null | grep -q "FileVault is On"; then
    echo "Warning: FileVault is not on. Deleted files cannot be securely erased on"
    echo "         an SSD; only disk encryption keeps them unreadable."
fi
