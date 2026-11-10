#!/usr/bin/env bash

# Removes traces of activity on Linux, regardless of their age. Run it
# deliberately, not on a schedule. For freeing disk space see cleanlinux.sh.

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
Remove traces of activity on Linux, regardless of their age.
Run it as your normal user; it asks for root itself where needed.

Without options only traces that daily work does not depend on are removed:
everything in the user cache folder (thumbnails included; tools that keep
downloads there fetch them again), your own temp files, the system journal,
rotated logs, crash dumps, print job copies (pending print jobs are
cancelled), DNS cache, clipboard and clipboard history, and app web caches.
Files changed in the last 10 minutes are left alone so that running apps
keep working; close your apps first for a complete result.

Options:
    -h, --help          Show this help message
    -d, --dry-run       Show what would be deleted without deleting
    -v, --verbose       List every deleted file instead of a count
    -y, --yes           Do not ask for confirmation
    -H, --history       Also remove history you would notice losing: shell,
                        editor and REPL history, recent file lists, desktop
                        usage statistics, file index and file manager
                        metadata, saved sessions, notification history and
                        the system login records.
    -b, --browsers      Also remove browser history, cookies, site storage,
                        sessions, form autofill and caches (Firefox,
                        LibreWolf, Zen, Chrome, Chromium, Brave, Edge,
                        Vivaldi; native, Flatpak and snap installs). This
                        signs you out of websites, closes open tabs and
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

require_os Linux

selected="caches, temp files, logs, clipboard"
if [ "$HISTORY" = true ]; then selected="$selected, history"; fi
if [ "$BROWSERS" = true ]; then selected="$selected, browser data"; fi
if [ "$TRASH" = true ]; then selected="$selected, Trash"; fi
confirm "This permanently deletes: $selected. Continue?"

start_run

# Files a running app has just written are left alone.
RECENT=(-mmin +10)
uid=$(id -u)

# ---------------------------------------------------------------------------
# Always: traces that daily work does not depend on
# ---------------------------------------------------------------------------
echo "Starting privacy cleanup..."

# Regular files only, so sockets of running apps survive.
echo "Clearing user cache (thumbnails included)..."
clean_tree "$CACHE_DIR" "${RECENT[@]}"
remove_path "$HOME/.thumbnails"
for app_cache in "$HOME"/.var/app/*/cache "$HOME"/snap/*/common/.cache; do
    clean_tree "$app_cache" "${RECENT[@]}"
done

echo "Clearing your own temp files..."
# The X server lock files must stay while the session runs.
clean_tree /tmp -xdev -user "$uid" "${RECENT[@]}" ! -name ".X*-lock"
clean_tree /var/tmp -xdev -user "$uid" "${RECENT[@]}"

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
    remove_path "${HISTFILE:-}" "$(zsh_histfile)" \
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

    echo "Clearing recent file lists and desktop usage statistics..."
    remove_path "$DATA_DIR/recently-used.xbel" \
                "$HOME/.recently-used" \
                "$DATA_DIR"/RecentDocuments/* \
                "$DATA_DIR"/kactivitymanagerd/resources/database* \
                "$DATA_DIR/zeitgeist" \
                "$DATA_DIR/gvfs-metadata"

    # The KDE file index; it is rebuilt from the files that still exist.
    if have balooctl6; then
        run_cmd balooctl6 purge
    elif have balooctl; then
        run_cmd balooctl purge
    else
        remove_path "$DATA_DIR/baloo"
    fi

    echo "Clearing saved sessions..."
    remove_path "$CONFIG_DIR"/session/*

    echo "Clearing notification history..."
    if have dunstctl; then
        run_cmd dunstctl history-clear
    fi
    if have swaync-client; then
        run_cmd swaync-client --close-all
    fi

    echo "Clearing login records..."
    for login_record in /var/log/wtmp /var/log/btmp /var/log/lastlog; do
        if [ -e "$login_record" ]; then
            run_root truncate -s 0 "$login_record"
        fi
    done
fi

# ---------------------------------------------------------------------------
# --browsers: history, cookies, site storage, sessions and caches
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
    clean_firefox "Zen" "zen|zen-bin" \
        "$HOME/.zen" "$CACHE_DIR/zen"
    clean_firefox "Zen (Flatpak)" "zen|zen-bin" \
        "$HOME/.var/app/app.zen_browser.zen/.zen" "$HOME/.var/app/app.zen_browser.zen/cache/zen"

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

# ---------------------------------------------------------------------------
# --trash: empty the Trash completely
# ---------------------------------------------------------------------------
if [ "$TRASH" = true ]; then
    echo -e "\nEmptying Trash..."
    for trash in "$DATA_DIR/Trash" /run/media/"$USER"/*/.Trash-"$uid" /media/"$USER"/*/.Trash-"$uid" /mnt/*/.Trash-"$uid"; do
        empty_dir "$trash/files"
        empty_dir "$trash/info"
        empty_dir "$trash/expunged"
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

root_fs=$(findmnt -no FSTYPE / 2>/dev/null || true)
if have snapper || have timeshift || [ "$root_fs" = "btrfs" ] || [ "$root_fs" = "zfs" ]; then
    echo "Note: filesystem snapshots (snapper, Timeshift, btrfs, zfs) still contain the"
    echo "      deleted files until the snapshots themselves are removed."
fi

if ! lsblk -no TYPE 2>/dev/null | grep -q crypt; then
    echo "Note: no LUKS-encrypted volume was found (fscrypt and ZFS encryption are not"
    echo "      detected). Without disk encryption, deleted files cannot be made"
    echo "      unreadable on an SSD, and swap or hibernation space can hold copies."
fi
