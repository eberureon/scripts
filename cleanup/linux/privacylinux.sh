#!/usr/bin/env bash

# Removes traces of activity on Linux, regardless of their age. Run it
# deliberately, not on a schedule. For freeing disk space see cleanlinux.sh.

set -e

# Default configuration
DRY_RUN=false
HISTORY=false
BROWSERS=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]
Remove traces of activity on Linux, regardless of their age.
Run it as your normal user; it asks for root itself where needed.

Without options only traces that daily work does not depend on are removed:
everything in the user cache folder (thumbnails included; tools that keep
downloads there fetch them again), your own temp files, the system journal,
rotated logs, crash dumps, print job copies (pending print jobs are
cancelled), DNS cache, clipboard and clipboard history, and app web caches.
Best run with most apps closed.

Options:
    -h, --help          Show this help message
    -d, --dry-run       Show what would be deleted without deleting
    -H, --history       Also remove history you would notice losing: shell,
                        editor and REPL history, recent file lists, desktop
                        usage statistics, saved sessions and notification
                        history.
    -b, --browsers      Also remove browser history, cookies, sessions and
                        caches (Firefox, LibreWolf, Chrome, Chromium, Brave,
                        Edge, Vivaldi; native, Flatpak and snap installs).
                        This signs you out of websites and closes open tabs.
                        Bookmarks and saved passwords are kept. Running
                        browsers are skipped.
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
# shellcheck source=cleanlinux-lib.sh
source "$(dirname "$script_path")/cleanlinux-lib.sh"

require_linux

# Usage: clean_chromium <display name> <process regex> <profile root> <cache dir>
clean_chromium() {
    local name=$1 proc=$2 root=$3 cache=$4 profile
    if [ ! -d "$root" ]; then
        return 0
    fi
    if app_running "$name" "$proc"; then
        return 0
    fi
    echo "Cleaning $name ($root)..."
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

# Usage: clean_firefox <display name> <process regex> <profile root> <cache dir>
clean_firefox() {
    local name=$1 proc=$2 root=$3 cache=$4 profile
    if [ ! -d "$root" ]; then
        return 0
    fi
    if app_running "$name" "$proc"; then
        return 0
    fi
    echo "Cleaning $name ($root)..."
    for profile in "$root"/*/; do
        profile=${profile%/}
        # places.sqlite holds bookmarks as well as history, so the history
        # rows are deleted instead of the file.
        if [ ! -f "$profile/places.sqlite" ]; then
            continue
        fi
        if have sqlite3; then
            run_cmd sqlite3 "$profile/places.sqlite" \
                'DELETE FROM moz_historyvisits; DELETE FROM moz_inputhistory; DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL); VACUUM;'
        else
            echo "sqlite3 is not installed: history in $profile is kept."
        fi
        remove_path "$profile"/cookies.sqlite* \
                    "$profile"/favicons.sqlite* \
                    "$profile/formhistory.sqlite" \
                    "$profile"/sessionstore* \
                    "$profile/cache2"
    done
    remove_path "$cache"
}

start_run

# ---------------------------------------------------------------------------
# Always: traces that daily work does not depend on
# ---------------------------------------------------------------------------
echo "Starting privacy cleanup..."

# Regular files only, so sockets of running apps survive.
echo "Clearing user cache (thumbnails included)..."
find_clean "$CACHE_DIR" -type f
remove_path "$HOME/.thumbnails"
for app_cache in "$HOME"/.var/app/*/cache "$HOME"/snap/*/common/.cache; do
    find_clean "$app_cache" -type f
done

echo "Clearing your own temp files..."
# The X server lock files must stay while the session runs.
find_clean /tmp -xdev -type f -user "$(id -u)" ! -name ".X*-lock"
find_clean /var/tmp -xdev -type f -user "$(id -u)"

echo "Clearing logs and crash dumps..."
if have journalctl; then
    run_root journalctl --rotate
    run_root journalctl --vacuum-time=1s
fi
find_clean --root /var/log -type f \
    \( -name "*.gz" -o -name "*.xz" -o -name "*.zst" -o -name "*.bz2" -o -name "*.old" -o -name "*.[0-9]" \)
find_clean --root /var/lib/systemd/coredump -type f
find_clean --root /var/crash -type f
remove_path "$HOME"/.xsession-errors* "$DATA_DIR"/xorg/*.log*

if have cancel; then
    echo "Clearing print job copies (this also cancels pending print jobs)..."
    run_root cancel -a -x
fi

echo "Flushing DNS cache..."
if have resolvectl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    run_root resolvectl flush-caches
fi
if have nscd; then
    run_root nscd -i hosts
fi

echo "Clearing clipboard and clipboard history..."
if [ -n "${WAYLAND_DISPLAY:-}" ] && have wl-copy; then
    run_cmd wl-copy --clear
    run_cmd wl-copy --primary --clear
elif [ -n "${DISPLAY:-}" ] && have xsel; then
    run_cmd xsel --clipboard --clear
    run_cmd xsel --primary --clear
elif [ -n "${DISPLAY:-}" ] && have xclip; then
    run_cmd xclip -selection clipboard -i /dev/null
    run_cmd xclip -selection primary -i /dev/null
fi
if have cliphist; then
    run_cmd cliphist wipe
fi
if have gpaste-client; then
    run_cmd gpaste-client empty
fi
remove_path "$DATA_DIR"/klipper/history*.lst

# Electron apps (Slack, Discord, VS Code, ...) keep their web caches in their
# config folder instead of in the cache folder.
echo "Clearing app web caches in config folders..."
for config_root in "$CONFIG_DIR" "$HOME"/.var/app/*/config; do
    remove_path "$config_root"/*/Cache \
                "$config_root"/*/Code\ Cache \
                "$config_root"/*/GPUCache \
                "$config_root"/*/Service\ Worker/CacheStorage
done

# ---------------------------------------------------------------------------
# --history: history the user would notice losing
# ---------------------------------------------------------------------------
if [ "$HISTORY" = true ]; then
    echo -e "\nHistory cleanup..."

    echo "Removing shell, editor and REPL history..."
    zsh_dir="${ZDOTDIR:-$HOME}"
    remove_path "${HISTFILE:-}" \
                "$zsh_dir/.zsh_history" "$zsh_dir/.zhistory" "$zsh_dir/.histfile" \
                "$DATA_DIR/zsh/history" "$STATE_DIR/zsh/history" \
                "$HOME/.bash_history" "$STATE_DIR/bash/history" \
                "$DATA_DIR/fish/fish_history" \
                "$HOME/.lesshst" "$STATE_DIR/lesshst" \
                "$HOME/.viminfo" \
                "$DATA_DIR/nvim/shada" "$STATE_DIR/nvim/shada" \
                "$DATA_DIR/nano/search_history" \
                "$HOME/.python_history" "$HOME/.node_repl_history" \
                "$HOME/.psql_history" "$HOME/.mysql_history" \
                "$HOME/.sqlite_history" "$HOME/.wget-hsts"
    echo "Note: shells that are still open write their history back when they exit."

    echo "Clearing recent file lists and desktop usage statistics..."
    remove_path "$DATA_DIR/recently-used.xbel" \
                "$HOME/.recently-used" \
                "$DATA_DIR"/RecentDocuments/* \
                "$DATA_DIR"/kactivitymanagerd/resources/database* \
                "$DATA_DIR/zeitgeist"

    echo "Clearing saved sessions..."
    remove_path "$CONFIG_DIR"/session/*

    echo "Clearing notification history..."
    if have dunstctl; then
        run_cmd dunstctl history-clear
    fi
    if have swaync-client; then
        run_cmd swaync-client --close-all
    fi
fi

# ---------------------------------------------------------------------------
# --browsers: history, cookies, sessions and caches
# ---------------------------------------------------------------------------
if [ "$BROWSERS" = true ]; then
    echo -e "\nBrowser cleanup..."

    firefox_proc='firefox|firefox-bin|firefox-esr'
    clean_firefox "Firefox" "$firefox_proc" \
        "$HOME/.mozilla/firefox" "$CACHE_DIR/mozilla/firefox"
    clean_firefox "Firefox" "$firefox_proc" \
        "$CONFIG_DIR/mozilla/firefox" "$CACHE_DIR/mozilla/firefox"
    clean_firefox "Firefox (Flatpak)" "$firefox_proc" \
        "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" "$HOME/.var/app/org.mozilla.firefox/cache/mozilla"
    clean_firefox "Firefox (snap)" "$firefox_proc" \
        "$HOME/snap/firefox/common/.mozilla/firefox" "$HOME/snap/firefox/common/.cache/mozilla"
    clean_firefox "LibreWolf" "librewolf" \
        "$HOME/.librewolf" "$CACHE_DIR/librewolf"

    chromium_proc='chromium|chromium-browse|chromium-browser'
    clean_chromium "Google Chrome" "chrome" \
        "$CONFIG_DIR/google-chrome" "$CACHE_DIR/google-chrome"
    clean_chromium "Google Chrome (Flatpak)" "chrome" \
        "$HOME/.var/app/com.google.Chrome/config/google-chrome" "$HOME/.var/app/com.google.Chrome/cache/google-chrome"
    clean_chromium "Chromium" "$chromium_proc" \
        "$CONFIG_DIR/chromium" "$CACHE_DIR/chromium"
    clean_chromium "Chromium (Flatpak)" "$chromium_proc" \
        "$HOME/.var/app/org.chromium.Chromium/config/chromium" "$HOME/.var/app/org.chromium.Chromium/cache/chromium"
    clean_chromium "Chromium (snap)" "$chromium_proc|chrome" \
        "$HOME/snap/chromium/common/chromium" "$HOME/snap/chromium/common/.cache/chromium"
    clean_chromium "Brave" "brave|brave-browser" \
        "$CONFIG_DIR/BraveSoftware/Brave-Browser" "$CACHE_DIR/BraveSoftware/Brave-Browser"
    clean_chromium "Brave (Flatpak)" "brave|brave-browser" \
        "$HOME/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser" "$HOME/.var/app/com.brave.Browser/cache/BraveSoftware"
    clean_chromium "Microsoft Edge" "msedge" \
        "$CONFIG_DIR/microsoft-edge" "$CACHE_DIR/microsoft-edge"
    clean_chromium "Vivaldi" "vivaldi-bin|vivaldi" \
        "$CONFIG_DIR/vivaldi" "$CACHE_DIR/vivaldi"
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "\nDry run complete, nothing was deleted."
else
    echo -e "\nPrivacy cleanup complete!"
fi

# Things the script cannot fix, only point out.
if have snapper || have timeshift || [ "$(findmnt -no FSTYPE / 2>/dev/null)" = "btrfs" ] || [ "$(findmnt -no FSTYPE / 2>/dev/null)" = "zfs" ]; then
    echo "Note: filesystem snapshots (snapper, Timeshift, btrfs, zfs) still contain the"
    echo "      deleted files until the snapshots themselves are removed."
fi

if ! lsblk -no TYPE 2>/dev/null | grep -q crypt; then
    echo "Warning: no encrypted (LUKS) volume found. Deleted files cannot be securely"
    echo "         erased on an SSD; only disk encryption keeps them unreadable."
fi
