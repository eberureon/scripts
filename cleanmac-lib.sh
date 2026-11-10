#!/usr/bin/env bash

# Shared helpers for cleanmac.sh and privacymac.sh. Source this file, do not
# run it. All deletions go through these helpers so that --dry-run is truthful.

DRY_RUN=${DRY_RUN:-false}

LIB="$HOME/Library"
APP_SUPPORT="$LIB/Application Support"

# The paths in both scripts only make sense on macOS; on another system they
# would delete unrelated files.
require_macos() {
    if [ "$(uname)" != "Darwin" ]; then
        echo "Error: this script only runs on macOS."
        exit 1
    fi
}

# Ask for sudo up front, except in a dry run, which never needs it.
start_run() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Nothing will be deleted. At most 20 files are listed per location."
    else
        echo "Requesting sudo permissions..."
        sudo -v
    fi
}

# Remove files or directories (recursively). Missing paths and unmatched
# globs are skipped. Usage: remove_path [--sudo] <path>...
remove_path() {
    local pre=() p
    if [ "$1" = "--sudo" ]; then
        pre=(sudo)
        shift
    fi
    for p in "$@"; do
        if [ ! -e "$p" ] && [ ! -L "$p" ]; then
            continue
        fi
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] would remove: $p"
        elif "${pre[@]}" rm -rf -- "$p" 2>/dev/null; then
            echo "Removed: $p"
        else
            echo "Could not remove: $p"
        fi
    done
}

# Delete everything a find expression matches. The first argument must be the
# directory to search. Usage: find_clean [--sudo] <dir> <find expression>...
find_clean() {
    local pre=()
    if [ "$1" = "--sudo" ]; then
        pre=(sudo)
        shift
    fi
    if [ ! -e "$1" ]; then
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        # No sudo in a dry run: unreadable folders are simply not listed.
        find "$@" -print 2>/dev/null | awk -v dir="$1" '
            NR <= 20 { print "[DRY RUN] would remove: " $0 }
            END {
                if (NR > 20) print "[DRY RUN] ... and " NR - 20 " more under " dir
                if (NR == 0) print "[DRY RUN] nothing to remove under " dir
            }' || true
    else
        "${pre[@]}" find "$@" -print -delete 2>/dev/null \
            || echo "Some files under $1 are restricted and were skipped."
    fi
    return 0
}

# Run a command, or only print it in a dry run.
run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] would run: $*"
    else
        "$@" || echo "Failed or nothing to do: $*"
    fi
}

# Delete a preference key if it exists.
delete_default() {
    if defaults read "$1" "$2" >/dev/null 2>&1; then
        run_cmd defaults delete "$1" "$2"
    fi
}

# Usage: app_running <display name> <process name>
app_running() {
    if pgrep -x "$2" >/dev/null 2>&1; then
        echo "$1 is running, skipping it. Quit $1 and run again."
        return 0
    fi
    return 1
}

# Without Full Disk Access the terminal cannot read protected folders, and
# deletions there fail quietly.
note_full_disk_access() {
    if [ -d "$LIB/Safari" ] && ! ls "$LIB/Safari" >/dev/null 2>&1; then
        echo "Note: this terminal has no Full Disk Access, so Safari, Mail, Trash and"
        echo "      Notification Center data were skipped. Grant it under System Settings >"
        echo "      Privacy & Security > Full Disk Access and run again."
    fi
}
