#!/usr/bin/env bash

# Credit: https://github.com/hkdobrev/cleanmac
#
# Frees disk space: old caches, logs, temp files and developer tool caches.
# Nothing here is needed for daily work. For history, cookies and other
# activity traces see privacymac.sh.

set -e

# Default configuration
DRY_RUN=false
XCODE_ARCHIVES=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [DAYS]
Free disk space by removing old caches, logs and temporary files.
For history, cookies and other activity traces use privacymac.sh.

Options:
    -h, --help          Show this help message
    -d, --dry-run       Show what would be deleted without deleting
    --xcode-archives    Also delete Xcode archives (they hold the dSYMs of
                        shipped builds, so they are kept by default)

Arguments:
    DAYS                Number of days of cache to keep (default: 7)
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
            shift
            ;;
        --xcode-archives)
            XCODE_ARCHIVES=true
            shift
            ;;
        -*)
            echo "Error: unknown option $1"
            usage
            exit 1
            ;;
        *)
            DAYS_TO_KEEP=$1
            shift
            ;;
    esac
done

# Default to 7 days if no argument provided
DAYS_TO_KEEP=${DAYS_TO_KEEP:-7}

# Check that the number of days to keep is a non-negative integer
if ! [[ $DAYS_TO_KEEP =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "Error: DAYS must be a non-negative integer."
    exit 1
fi

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

# Get initial disk space
free_storage=$(df -k / | awk 'NR==2 {print $4}')
total_storage=$(df -k / | awk 'NR==2 {print $2}')
free_storage_gb=$(echo "scale=2; $free_storage / 1024 / 1024" | bc)
total_storage_gb=$(echo "scale=2; $total_storage / 1024 / 1024" | bc)

echo "Free storage: $free_storage_gb Gi / Total storage: $total_storage_gb Gi"

start_run

echo "Starting macOS selective cleanup (removing files older than ${DAYS_TO_KEEP} days)..."

echo "Clearing system and user cache files older than ${DAYS_TO_KEEP} days..."
find_clean --sudo /Library/Caches -type f -mtime "+${DAYS_TO_KEEP}" \
    ! -path "/Library/Caches/com.apple.amsengagementd.classicdatavault/*" \
    ! -path "/Library/Caches/com.apple.aned/*" \
    ! -path "/Library/Caches/com.apple.aneuserd/*" \
    ! -path "/Library/Caches/com.apple.iconservices.store/*"
find_clean "$LIB/Caches" -type f -mtime "+${DAYS_TO_KEEP}"

echo "Removing application logs older than ${DAYS_TO_KEEP} days..."
find_clean --sudo /Library/Logs -type f -mtime "+${DAYS_TO_KEEP}"
find_clean "$LIB/Logs" -type f -mtime "+${DAYS_TO_KEEP}"

# /tmp is a symlink to /private/tmp, which find does not follow.
echo "Clearing temporary files older than ${DAYS_TO_KEEP} days..."
find_clean --sudo /private/var/tmp -type f -mtime "+${DAYS_TO_KEEP}"
find_clean /private/tmp -type f -mtime "+${DAYS_TO_KEEP}" ! -path "/private/tmp/tmp-mount-*"

if command -v brew >/dev/null 2>&1; then
    echo "Running Homebrew cleanup and cache clearing..."
    if [ "$DRY_RUN" = true ]; then
        brew cleanup --dry-run --prune="${DAYS_TO_KEEP}" || echo "Homebrew cleanup encountered an error."
        brew autoremove --dry-run || echo "Homebrew autoremove encountered an error."
    else
        brew cleanup --prune="${DAYS_TO_KEEP}" || echo "Homebrew cleanup encountered an error."
        brew autoremove || echo "Homebrew autoremove encountered an error."
    fi
    brew doctor || echo "Homebrew doctor reported problems."
fi

echo "Emptying Trash (files older than ${DAYS_TO_KEEP} days)..."
find_clean "$HOME/.Trash" -type f -mtime "+${DAYS_TO_KEEP}"
for volume_trash in /Volumes/*/.Trashes/"$(id -u)"; do
    find_clean "$volume_trash" -type f -mtime "+${DAYS_TO_KEEP}"
done
if [ "$DRY_RUN" != true ]; then
    find "$HOME/.Trash" -mindepth 1 -type d -empty -delete 2>/dev/null || echo "Error removing empty Trash directories."
fi

echo "Cleaning Safari cache..."
find_clean "$LIB/Containers/com.apple.Safari/Data/Library/Caches" -type f -mtime "+${DAYS_TO_KEEP}"

echo "Cleaning Spotify cache..."
find_clean "$APP_SUPPORT/Spotify/PersistentCache/Storage" -type f -mtime "+${DAYS_TO_KEEP}"

echo "Cleaning Xcode derived data..."
remove_path "$LIB"/Developer/Xcode/DerivedData/*
if [ "$XCODE_ARCHIVES" = true ]; then
    echo "Cleaning Xcode archives..."
    remove_path "$LIB"/Developer/Xcode/Archives/*
fi

# Node.js cache cleaning
if command -v npm >/dev/null 2>&1; then
    echo "Cleaning npm cache..."
    run_cmd npm cache clean --force
fi

if command -v yarn >/dev/null 2>&1; then
    echo "Cleaning yarn cache..."
    run_cmd yarn cache clean
fi

# Docker cleanup
if command -v docker >/dev/null 2>&1; then
    echo "Checking Docker context..."
    if ! current_context=$(docker context show 2>/dev/null); then
        echo "Unable to determine Docker context; assuming local and cleaning."
        run_cmd docker system prune -f
    else
        if endpoint=$(docker context inspect "$current_context" --format '{{.Endpoints.docker.Host}}' 2>/dev/null); then
            if [[ "$endpoint" == unix://* ]]; then
                echo "Cleaning unused Docker data..."
                run_cmd docker system prune -f
            else
                echo "Docker is using a remote context ($endpoint), skipping cleanup."
            fi
        else
            echo "Unable to inspect Docker context; skipping cleanup to avoid potential remote connection."
        fi
    fi
fi

# System memory cleanup
echo "Purging system memory cache..."
run_cmd sudo purge

if [ "$DRY_RUN" = true ]; then
    echo -e "\nDry run complete, nothing was deleted."
else
    echo -e "\nAfter cleanup:"

    # Get disk space
    free_storage_final=$(df -k / | awk 'NR==2 {print $4}')
    total_storage_final=$(df -k / | awk 'NR==2 {print $2}')
    free_storage_final_gb=$(echo "scale=2; $free_storage_final / 1024 / 1024" | bc)
    total_storage_final_gb=$(echo "scale=2; $total_storage_final / 1024 / 1024" | bc)

    echo "Free storage: $free_storage_final_gb Gi / Total storage: $total_storage_final_gb Gi"

    # Calculate the difference in kilobytes
    free_storage_diff_kb=$((free_storage_final - free_storage))

    # If the difference is negative, set it to 0
    if [ "$free_storage_diff_kb" -lt 0 ]; then
        free_storage_diff_kb=0
    fi

    # Determine appropriate unit for the difference
    if [ "$free_storage_diff_kb" -ge $((1024 * 1024)) ]; then
        # Convert difference to gigabytes if >= 1 Gi
        free_storage_diff_gb=$(echo "scale=2; $free_storage_diff_kb / 1024 / 1024" | bc)
        echo "Space freed: $free_storage_diff_gb Gi"
    elif [ "$free_storage_diff_kb" -ge 1024 ]; then
        # Convert difference to megabytes if >= 1 Mi but < 1 Gi
        free_storage_diff_mb=$(echo "scale=2; $free_storage_diff_kb / 1024" | bc)
        echo "Space freed: $free_storage_diff_mb Mi"
    else
        # Output difference in kilobytes if < 1 Mi
        echo "Space freed: $free_storage_diff_kb Ki"
    fi

    echo "Selective cleanup complete!"
fi

note_full_disk_access
