#!/usr/bin/env bash

# Shared helpers for cleanlinux.sh and privacylinux.sh. Source this file, do
# not run it. All deletions go through these helpers so that --dry-run is
# truthful.

DRY_RUN=${DRY_RUN:-false}

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"

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

require_linux() {
    if [ "$(uname)" != "Linux" ]; then
        echo "Error: this script only runs on Linux."
        exit 1
    fi
    # Under sudo, $HOME is usually root's, so the wrong home would be cleaned.
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "Error: run this script as your normal user, without sudo."
        echo "       It asks for root itself where it needs it."
        exit 1
    fi
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
        if [ ! -e "$p" ] && [ ! -L "$p" ]; then
            continue
        fi
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] would remove: $p"
        elif [ "$need_root" = true ] && [ "$CAN_ROOT" != true ]; then
            echo "Skipped (needs root): $p"
        elif "${pre[@]}" rm -rf -- "$p" 2>/dev/null; then
            echo "Removed: $p"
        else
            echo "Could not remove: $p"
        fi
    done
}

# Delete everything a find expression matches. The first argument must be the
# directory to search. Usage: find_clean [--root] <dir> <find expression>...
find_clean() {
    local pre=() need_root=false
    if [ "$1" = "--root" ]; then
        need_root=true
        pre=("${ROOT[@]}")
        shift
    fi
    if [ ! -e "$1" ]; then
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        # No root in a dry run: unreadable folders are simply not listed.
        find "$@" -print 2>/dev/null | awk -v dir="$1" '
            NR <= 20 { print "[DRY RUN] would remove: " $0 }
            END {
                if (NR > 20) print "[DRY RUN] ... and " NR - 20 " more under " dir
                if (NR == 0) print "[DRY RUN] nothing to remove under " dir
            }' || true
    elif [ "$need_root" = true ] && [ "$CAN_ROOT" != true ]; then
        echo "Skipped (needs root): $1"
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

# Same, as root.
run_root() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] would run as root: $*"
    elif [ "$CAN_ROOT" != true ]; then
        echo "Skipped (needs root): $*"
    else
        "${ROOT[@]}" "$@" || echo "Failed or nothing to do: $*"
    fi
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# Usage: app_running <display name> <process name regex, must match fully>
app_running() {
    if pgrep -u "$(id -u)" -x "$2" >/dev/null 2>&1; then
        echo "$1 is running, skipping it. Quit $1 and run again."
        return 0
    fi
    return 1
}
