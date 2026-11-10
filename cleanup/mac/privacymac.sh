#!/usr/bin/env bash

# Removes traces of activity on macOS, regardless of their age. Run it
# deliberately, not on a schedule. For freeing disk space see cleanmac.sh.

set -e

# Default configuration
DRY_RUN=false
VERBOSE=false
ASSUME_YES=false
HISTORY=false
BROWSERS=false
TRASH=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]
Remove traces of activity on macOS, regardless of their age.

Without options only traces that daily work does not depend on are removed:
user caches and logs, per-user temp files, QuickLook thumbnails, the download
log, system logs, print job copies (pending print jobs are cancelled), DNS
cache, clipboard, app web caches and local Time Machine snapshots.
Files changed in the last 10 minutes are left alone so that running apps
keep working; close your apps first for a complete result.

Options:
    -h, --help          Show this help message
    -d, --dry-run       Show what would be deleted without deleting
    -v, --verbose       List every deleted file instead of a count
    -y, --yes           Do not ask for confirmation
    -H, --history       Also remove history you would notice losing: shell and
                        REPL history, "Open Recent" lists, Finder recent
                        folders, saved window state (apps stop reopening their
                        windows) and Notification Center history.
    -b, --browsers      Also remove browser history, cookies, site storage,
                        sessions, form autofill and caches (Safari, Chrome,
                        Brave, Edge, Arc, Vivaldi, Firefox, LibreWolf, Zen).
                        This signs you out of websites, closes open tabs and
                        resets custom search engines in Chromium browsers.
                        Bookmarks, saved passwords and extensions are kept.
                        Running browsers are skipped.
    -t, --trash         Also empty the Trash completely
    -a, --all           Same as --history --browsers --trash
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
        -v|--verbose)
            VERBOSE=true
            ;;
        -y|--yes)
            ASSUME_YES=true
            ;;
        -H|--history)
            HISTORY=true
            ;;
        -b|--browsers)
            BROWSERS=true
            ;;
        -t|--trash)
            TRASH=true
            ;;
        -a|--all)
            HISTORY=true
            BROWSERS=true
            TRASH=true
            ;;
        *)
            echo "Error: unknown argument $1" >&2
            usage >&2
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
# shellcheck source=../lib.sh
source "$(dirname "$script_path")/../lib.sh"

require_os Darwin

selected="caches, temp files, logs, clipboard, local snapshots"
if [ "$HISTORY" = true ]; then selected="$selected, history"; fi
if [ "$BROWSERS" = true ]; then selected="$selected, browser data"; fi
if [ "$TRASH" = true ]; then selected="$selected, Trash"; fi
confirm "This permanently deletes: $selected. Continue?"

start_run

# Files a running app has just written are left alone.
RECENT=(-mmin +10)

# ---------------------------------------------------------------------------
# Always: traces that daily work does not depend on
# ---------------------------------------------------------------------------
echo "Starting privacy cleanup..."

echo "Clearing user caches and logs..."
clean_tree "$LIB/Caches" "${RECENT[@]}"
clean_tree "$LIB/Logs" "${RECENT[@]}"

echo "Clearing per-user temp and cache folders..."
# Regular files only, so sockets of running apps survive.
user_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
user_cache=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)
for user_dir in "$user_tmp" "$user_cache"; do
    # Both live below /var/folders; anything else is not touched.
    case $user_dir in
        /var/folders/?*/?*)
            clean_tree "${user_dir%/}" "${RECENT[@]}"
            ;;
    esac
done

echo "Resetting QuickLook thumbnail cache..."
run_cmd qlmanage -r cache

echo "Clearing the download log (quarantine events)..."
quarantine_db="$LIB/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
if [ -f "$quarantine_db" ]; then
    run_cmd sqlite3 "$quarantine_db" 'DELETE FROM LSQuarantineEvent; VACUUM;'
fi

echo "Clearing system logs, crash reports and core dumps..."
find_clean --root /Library/Logs/DiagnosticReports -type f
find_clean --root /private/var/log -type f \( -name "*.gz" -o -name "*.bz2" -o -name "*.[0-9]" \)
remove_path "$APP_SUPPORT"/CrashReporter/*
remove_path --root /cores/*
run_root log erase --all

echo "Clearing print job copies (this also cancels pending print jobs)..."
run_root cancel -a -x

echo "Flushing DNS cache..."
run_root dscacheutil -flushcache
run_root killall -HUP mDNSResponder

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
    remove_path "${HISTFILE:-}" "$(zsh_histfile)" \
                "$zsh_dir/.zsh_history" "$zsh_dir/.zsh_sessions" \
                "$zsh_dir/.zhistory" "$zsh_dir/.histfile" \
                "$HOME/.bash_history" "$HOME/.bash_sessions" \
                "$HOME/.local/share/fish/fish_history" \
                "$HOME/.lesshst" "$HOME/.viminfo" \
                "$HOME/.local/state/nvim/shada" "$HOME/.local/share/nvim/shada" \
                "$HOME/.python_history" "$HOME/.node_repl_history" \
                "$HOME/.psql_history" "$HOME/.mysql_history" \
                "$HOME/.sqlite_history" "$HOME/.wget-hsts"

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
    notification_dir=$(getconf DARWIN_USER_DIR 2>/dev/null || true)
    case $notification_dir in
        /var/folders/?*/?*)
            remove_path "${notification_dir%/}"/com.apple.notificationcenter/db2/db*
            ;;
    esac
    remove_path "$LIB/Group Containers/group.com.apple.usernoted"/db2/db*
    run_cmd killall usernoted
fi

# ---------------------------------------------------------------------------
# --browsers: history, cookies, site storage, sessions and caches
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
                    "$LIB/Safari/LocalStorage" \
                    "$LIB/Safari/Databases" \
                    "$LIB/Caches/com.apple.Safari" \
                    "$LIB/Cookies/Cookies.binarycookies" \
                    "$LIB/WebKit/com.apple.Safari" \
                    "$LIB"/HTTPStorages/com.apple.Safari* \
                    "$safari_data"/Caches/* \
                    "$safari_data"/Cookies/* \
                    "$safari_data"/HTTPStorages/* \
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

    clean_firefox "Firefox" "firefox" \
        "$APP_SUPPORT/Firefox/Profiles" "$LIB/Caches/Firefox"
    clean_firefox "LibreWolf" "librewolf" \
        "$APP_SUPPORT/librewolf/Profiles" "$LIB/Caches/librewolf"
    clean_firefox "Zen" "zen" \
        "$APP_SUPPORT/zen/Profiles" "$LIB/Caches/zen"
fi

# ---------------------------------------------------------------------------
# --trash: empty the Trash completely
# ---------------------------------------------------------------------------
if [ "$TRASH" = true ]; then
    echo -e "\nEmptying Trash..."
    empty_dir "$HOME/.Trash"
    for volume_trash in /Volumes/*/.Trashes/"$(id -u)"; do
        empty_dir "$volume_trash"
    done
fi

# Deleted files stay recoverable from local Time Machine snapshots until the
# snapshots are gone. This runs last on purpose.
if have tmutil; then
    echo -e "\nDeleting local Time Machine snapshots..."
    for snapshot in $(tmutil listlocalsnapshotdates / 2>/dev/null | grep -E '^[0-9]{4}-' || true); do
        run_root tmutil deletelocalsnapshots "$snapshot"
    done
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "\nDry run complete, nothing was deleted."
else
    echo -e "\nPrivacy cleanup complete!"
fi

# Things the script cannot fix, only point out.
if [ "$HISTORY" = true ]; then
    echo "Note: every shell that is still open, this one included, writes its history"
    echo "      back when it closes. Close each with:  unset HISTFILE; exit"
fi

if [ "$TRASH" != true ]; then
    echo "Note: the Trash was not emptied (use --trash)."
fi

note_full_disk_access

if ! fdesetup status 2>/dev/null | grep -q "FileVault is On"; then
    echo "Note: FileVault is not on. Without disk encryption, deleted files cannot be"
    echo "      made unreadable on an SSD, and swap or sleep images can hold copies."
fi
