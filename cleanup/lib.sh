#!/usr/bin/env bash

# Shared helpers for the cleanup scripts in mac/ and linux/. Source this file,
# do not run it. All deletions go through these helpers so that --dry-run is
# truthful.

DRY_RUN=${DRY_RUN:-false}
VERBOSE=${VERBOSE:-false}
ASSUME_YES=${ASSUME_YES:-false}

# macOS locations
LIB="${HOME:-}/Library"
APP_SUPPORT="$LIB/Application Support"

# Linux locations
CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-}/.cache}"
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME:-}/.config}"
DATA_DIR="${XDG_DATA_HOME:-${HOME:-}/.local/share}"
STATE_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}"

# How to become root: nothing when already root, otherwise sudo or doas.
ROOT=()
CAN_ROOT=true
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        ROOT=(sudo)
    elif command -v doas >/dev/null 2>&1; then
        ROOT=(doas)
    else
        CAN_ROOT=false
    fi
fi

die() {
    echo "Error: $*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# Refuse to run on the wrong system or with a home directory that cannot be
# trusted: every path the scripts delete from is derived from these variables.
# Usage: require_os Darwin|Linux
require_os() {
    local d
    if [ "$(uname)" != "$1" ]; then
        if [ "$1" = "Darwin" ]; then
            die "this script only runs on macOS."
        fi
        die "this script only runs on $1."
    fi
    # Under sudo, $HOME may be root's, so the wrong home would be cleaned.
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        die "run this script as your normal user, without sudo. It asks for root itself where it needs it."
    fi
    case "${HOME:-}" in
        /?*) ;;
        *) die "HOME is not set to an absolute path." ;;
    esac
    if [ ! -d "$HOME" ]; then
        die "HOME ($HOME) is not a directory."
    fi
    if [ "$1" = "Linux" ]; then
        for d in "$CACHE_DIR" "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR"; do
            case "${d%/}" in
                "${HOME%/}" | */..* | */.)
                    die "refusing to work on '$d' (check the XDG_* variables)." ;;
                /?*/?*) ;;
                *)
                    die "refusing to work on '$d' (check the XDG_* variables)." ;;
            esac
        done
    fi
}

# Ask before a destructive run. A dry run and --yes skip the question.
confirm() {
    local answer
    if [ "$DRY_RUN" = true ] || [ "$ASSUME_YES" = true ]; then
        return 0
    fi
    read -r -p "$1 [y/N] " answer || answer=""
    case $answer in
        [yY]*) ;;
        *)
            echo "Aborted, nothing was deleted."
            exit 1
            ;;
    esac
}

# Ask for the password up front, except in a dry run, which never needs root.
start_run() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Nothing will be deleted. At most 20 files are listed per location."
    elif [ "$CAN_ROOT" != true ]; then
        echo "Neither sudo nor doas found: steps that need root will be skipped."
    elif [ "${ROOT[0]:-}" = "sudo" ]; then
        echo "Requesting sudo permissions..."
        sudo -v
    fi
}

# Keep the sudo timestamp alive: long steps in between can let it expire.
root_ready() {
    if [ "${ROOT[0]:-}" = "sudo" ]; then
        sudo -v
    fi
}

# Remove files or directories (recursively). Missing paths and unmatched
# globs are skipped. Usage: remove_path [--root] <path>...
remove_path() {
    local pre=() need_root=false p
    if [ "$1" = "--root" ]; then
        need_root=true
        pre=("${ROOT[@]}")
        shift
    fi
    for p in "$@"; do
        if [ -z "$p" ] || { [ ! -e "$p" ] && [ ! -L "$p" ]; }; then
            continue
        fi
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] would remove: $p"
        elif [ "$need_root" = true ] && [ "$CAN_ROOT" != true ]; then
            echo "Skipped (needs root): $p"
        else
            if [ "$need_root" = true ]; then
                root_ready
            fi
            if "${pre[@]}" rm -rf -- "$p" 2>/dev/null; then
                echo "Removed: $p"
            else
                echo "Could not remove: $p"
            fi
        fi
    done
}

# Remove everything inside a directory, hidden entries included.
# Usage: empty_dir <dir>
empty_dir() {
    if [ ! -d "$1" ]; then
        return 0
    fi
    remove_path "$1"/* "$1"/.[!.]* "$1"/..?*
}

# Delete everything a find expression matches. The first argument must be the
# directory to search. Usage: find_clean [--root] <dir> <find expression>...
find_clean() {
    local pre=() need_root=false note="" count
    if [ "$1" = "--root" ]; then
        need_root=true
        pre=("${ROOT[@]}")
        shift
        if [ "$(id -u)" -ne 0 ]; then
            note=" (listed without root, may be incomplete)"
        fi
    fi
    if [ ! -e "$1" ]; then
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        find "$@" -exec du -k {} + 2>/dev/null | awk -F'\t' -v dir="$1" -v note="$note" '
            { kb += $1 }
            NR <= 20 { print "[DRY RUN] would remove: " $2 }
            END {
                if (NR > 20) print "[DRY RUN] ... and " NR - 20 " more"
                if (NR == 0) print "[DRY RUN] nothing to remove under " dir note
                else printf "[DRY RUN] %d files, %.1f MiB under %s%s\n", NR, kb / 1024, dir, note
            }' || true
    elif [ "$need_root" = true ] && [ "$CAN_ROOT" != true ]; then
        echo "Skipped (needs root): $1"
    else
        if [ "$need_root" = true ]; then
            root_ready
        fi
        if [ "$VERBOSE" = true ]; then
            "${pre[@]}" find "$@" -print -delete 2>/dev/null \
                || echo "Some files under $1 are restricted and were skipped."
        else
            count=$("${pre[@]}" find "$@" -print -delete 2>/dev/null | wc -l) || true
            echo "Removed $((count)) files under $1"
        fi
    fi
    return 0
}

# Delete the regular files below a directory that match the given tests, then
# the directories this leaves empty, so that folder names do not stay behind
# as traces. The directory itself is kept. The directories are picked before
# the files are deleted, because deleting a file makes its folder look new.
# Usage: clean_tree <dir> [find tests...]
clean_tree() {
    local dir=$1 list
    shift
    if [ ! -d "$dir" ]; then
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        find_clean "$dir" "$@" -type f
        return 0
    fi
    list=$(mktemp)
    find "$dir" -mindepth 1 "$@" -type d -print0 >"$list" 2>/dev/null || true
    find_clean "$dir" "$@" -type f
    # Deepest first; rmdir refuses anything that is not empty.
    sort -rz "$list" | xargs -0 rmdir 2>/dev/null || true
    rm -f "$list"
}

# Run a command, or only print it in a dry run.
run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] would run: $*"
    else
        "$@" || echo "Failed or nothing to do: $*"
    fi
}

# Same, as root.
run_root() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] would run as root: $*"
    elif [ "$CAN_ROOT" != true ]; then
        echo "Skipped (needs root): $*"
    else
        root_ready
        "${ROOT[@]}" "$@" || echo "Failed or nothing to do: $*"
    fi
}

# Usage: app_running <display name> <process name regex, must match fully>
app_running() {
    if pgrep -u "$(id -u)" -x "$2" >/dev/null 2>&1; then
        echo "$1 is running, skipping it. Quit $1 and run again."
        return 0
    fi
    return 1
}

# macOS: delete a preference key if it exists.
delete_default() {
    if defaults read "$1" "$2" >/dev/null 2>&1; then
        run_cmd defaults delete "$1" "$2"
    fi
}

# macOS: without Full Disk Access the terminal cannot read protected folders,
# and deletions there fail quietly.
note_full_disk_access() {
    if [ -d "$LIB/Safari" ] && ! ls "$LIB/Safari" >/dev/null 2>&1; then
        echo "Note: this terminal has no Full Disk Access, so Safari, Mail, Trash and"
        echo "      Notification Center data were skipped. Grant it under System Settings >"
        echo "      Privacy & Security > Full Disk Access and run again."
    fi
}

# Print the history file zsh really uses, if it can be found out. It is only
# set in interactive shells, so an interactive zsh has to be asked.
zsh_histfile() {
    local file=""
    if ! have zsh; then
        return 0
    fi
    if have timeout; then
        file=$(timeout 10 zsh -ic 'print -r -- "$HISTFILE"' </dev/null 2>/dev/null | tail -n 1) || true
    else
        file=$(zsh -ic 'print -r -- "$HISTFILE"' </dev/null 2>/dev/null | tail -n 1) || true
    fi
    # Only accept a regular file below the home directory.
    case $file in
        "$HOME"/*)
            if [ -f "$file" ]; then
                echo "$file"
            fi
            ;;
    esac
}

# Browsers of the Chromium family.
# Usage: clean_chromium <display name> <process regex> <profile root> <cache dir>
clean_chromium() {
    local name=$1 proc=$2 root=$3 cache=$4 profile entry
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
                    "$profile"/Media\ History* \
                    "$profile"/DIPS* \
                    "$profile"/Web\ Data* \
                    "$profile/TransportSecurity" \
                    "$profile/Network/TransportSecurity" \
                    "$profile"/Network/Reporting\ and\ NEL* \
                    "$profile"/Network/Trust\ Tokens* \
                    "$profile/Sessions" \
                    "$profile/Local Storage" \
                    "$profile/Session Storage" \
                    "$profile/Cache" \
                    "$profile/Code Cache" \
                    "$profile/GPUCache" \
                    "$profile/Service Worker"
        # Site databases go, the ones that belong to extensions stay.
        for entry in "$profile"/IndexedDB/*; do
            case $(basename "$entry") in
                chrome-extension_*) ;;
                *) remove_path "$entry" ;;
            esac
        done
    done
    remove_path "$cache"
}

# Browsers of the Firefox family (Firefox, LibreWolf, Zen).
# Usage: clean_firefox <display name> <process regex> <profiles dir> <cache dir>
clean_firefox() {
    local name=$1 proc=$2 root=$3 cache=$4 profile entry db tables sql
    if [ ! -d "$root" ]; then
        return 0
    fi
    if app_running "$name" "$proc"; then
        return 0
    fi
    echo "Cleaning $name ($root)..."
    for profile in "$root"/*/; do
        profile=${profile%/}
        db="$profile/places.sqlite"
        if [ ! -f "$db" ]; then
            continue
        fi
        # places.sqlite holds bookmarks as well as history, so the history
        # rows are deleted instead of the file. Pages that are bookmarked stay.
        if ! have sqlite3; then
            echo "sqlite3 is not installed: history in $profile is kept."
        elif [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] would delete the history rows in: $db"
        else
            sql="DELETE FROM moz_historyvisits; DELETE FROM moz_inputhistory;
                 DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL);
                 UPDATE moz_places SET visit_count = 0, last_visit_date = NULL;"
            # Tables that only newer versions have.
            tables=$(sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type = 'table';" 2>/dev/null || true)
            case " $(echo "$tables" | tr '\n' ' ') " in
                *" moz_origins "*)
                    sql="$sql DELETE FROM moz_origins WHERE id NOT IN (SELECT origin_id FROM moz_places WHERE origin_id IS NOT NULL);" ;;
            esac
            for entry in moz_places_metadata moz_places_metadata_search_queries moz_historyvisits_extra \
                         moz_newtab_shortcuts_interaction moz_newtab_story_click moz_newtab_story_impression; do
                case " $(echo "$tables" | tr '\n' ' ') " in
                    *" $entry "*) sql="$sql DELETE FROM $entry;" ;;
                esac
            done
            for entry in moz_places_extra moz_annos; do
                case " $(echo "$tables" | tr '\n' ' ') " in
                    *" $entry "*) sql="$sql DELETE FROM $entry WHERE place_id NOT IN (SELECT id FROM moz_places);" ;;
                esac
            done
            if sqlite3 "$db" "$sql VACUUM;" 2>/dev/null; then
                echo "Deleted the history rows in: $db"
            else
                echo "Could not clear the history in: $db"
            fi
        fi
        remove_path "$profile"/cookies.sqlite* \
                    "$profile"/favicons.sqlite* \
                    "$profile"/webappsstore.sqlite* \
                    "$profile"/permissions.sqlite* \
                    "$profile"/content-prefs.sqlite* \
                    "$profile"/SiteSecurityServiceState.* \
                    "$profile/formhistory.sqlite" \
                    "$profile"/sessionstore* \
                    "$profile/storage/temporary" \
                    "$profile/cache2"
        # Site storage goes, the storage of extensions stays.
        for entry in "$profile"/storage/default/*; do
            case $(basename "$entry") in
                moz-extension+++*) ;;
                *) remove_path "$entry" ;;
            esac
        done
    done
    remove_path "$cache"
}
