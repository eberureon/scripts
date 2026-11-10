#!/usr/bin/env bash

# Frees disk space on Linux: old caches, logs, temp files, package manager
# and developer tool caches. Nothing here is needed for daily work. For
# history, cookies and other activity traces see privacylinux.sh.

set -e

# Default configuration
DRY_RUN=false
VERBOSE=false
AUTOREMOVE=false
DOCKER=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [DAYS]
Free disk space by removing old caches, logs and temporary files.
For history, cookies and other activity traces use privacylinux.sh.
Run it as your normal user; it asks for root itself where needed.

Options:
    -h, --help          Show this help message
    -d, --dry-run       Show what would be deleted without deleting
    -v, --verbose       List every deleted file instead of a count
    --autoremove        Also uninstall packages that were pulled in as
                        dependencies and are no longer required
                        (pacman, apt, dnf/yum, xbps)
    --docker            Also prune Docker and Podman: stopped containers,
                        unused networks, dangling images and build cache.
                        Data inside stopped containers is lost.
    -a, --all           Same as --autoremove --docker

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
            ;;
        -v|--verbose)
            VERBOSE=true
            ;;
        --autoremove)
            AUTOREMOVE=true
            ;;
        --docker)
            DOCKER=true
            ;;
        -a|--all)
            AUTOREMOVE=true
            DOCKER=true
            ;;
        -*)
            echo "Error: unknown option $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            DAYS_TO_KEEP=$1
            ;;
    esac
    shift
done

# Default to 7 days if no argument provided
DAYS_TO_KEEP=${DAYS_TO_KEEP:-7}

# Check that the number of days to keep is a non-negative integer
if ! [[ $DAYS_TO_KEEP =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "Error: DAYS must be a non-negative integer." >&2
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
# shellcheck source=../lib.sh
source "$(dirname "$script_path")/../lib.sh"

require_os Linux

# Remove trashed items that were put into the given trash more than
# DAYS_TO_KEEP days ago. The age is taken from the .trashinfo file, so a
# trashed folder is removed as a whole.
clean_trash() {
    local trash=$1 info name
    if [ ! -d "$trash/info" ]; then
        return 0
    fi
    find "$trash/info" -maxdepth 1 -name '*.trashinfo' -mtime "+${DAYS_TO_KEEP}" -print0 2>/dev/null |
        while IFS= read -r -d '' info; do
            name=$(basename "$info" .trashinfo)
            remove_path "$trash/files/$name" "$info"
        done
    return 0
}

free_kb() {
    df -Pk / | awk 'NR==2 {print $4}'
}

to_gib() {
    awk -v kb="$1" 'BEGIN { printf "%.2f", kb / 1024 / 1024 }'
}

# Get initial disk space
free_storage=$(free_kb)
total_storage=$(df -Pk / | awk 'NR==2 {print $2}')

echo "Free storage: $(to_gib "$free_storage") Gi / Total storage: $(to_gib "$total_storage") Gi"

start_run

echo "Starting Linux selective cleanup (removing files older than ${DAYS_TO_KEEP} days)..."

echo "Clearing user cache files older than ${DAYS_TO_KEEP} days..."
find_clean "$CACHE_DIR" -type f -mtime "+${DAYS_TO_KEEP}"

echo "Removing logs older than ${DAYS_TO_KEEP} days..."
if have journalctl; then
    # A value of zero would switch the limit off instead of removing everything.
    if [ "$DAYS_TO_KEEP" -eq 0 ]; then
        run_root journalctl --vacuum-time=1s
    else
        run_root journalctl --vacuum-time="${DAYS_TO_KEEP}d"
    fi
fi
# Rotated log files only; the live logs stay.
find_clean --root /var/log -type f -mtime "+${DAYS_TO_KEEP}" \
    \( -name "*.gz" -o -name "*.xz" -o -name "*.zst" -o -name "*.bz2" -o -name "*.old" -o -name "*.[0-9]" \)

echo "Removing crash dumps older than ${DAYS_TO_KEEP} days..."
find_clean --root /var/lib/systemd/coredump -type f -mtime "+${DAYS_TO_KEEP}"
find_clean --root /var/crash -type f -mtime "+${DAYS_TO_KEEP}"

echo "Clearing temporary files older than ${DAYS_TO_KEEP} days..."
find_clean --root /var/tmp -xdev -type f -mtime "+${DAYS_TO_KEEP}" ! -path "/var/tmp/systemd-private-*"
find_clean /tmp -xdev -type f -user "$(id -u)" -mtime "+${DAYS_TO_KEEP}"

# Package managers. Several can be present on one system.
echo "Cleaning package manager caches..."
if have pacman; then
    if have paccache; then
        # Keep the two newest versions of installed packages, none of removed ones.
        if [ "$DRY_RUN" = true ]; then
            paccache -dk2 || true
            paccache -duk0 || true
        else
            run_root paccache -rk2
            run_root paccache -ruk0
        fi
    else
        run_root pacman -Sc --noconfirm
    fi
    if [ "$AUTOREMOVE" = true ]; then
        orphans=$(pacman -Qdtq 2>/dev/null || true)
        if [ -n "$orphans" ]; then
            # shellcheck disable=SC2086
            echo "Orphaned packages:" $orphans
            # shellcheck disable=SC2086
            run_root pacman -Rns --noconfirm $orphans
        fi
    fi
fi

if have apt-get; then
    run_root apt-get clean
    if [ "$AUTOREMOVE" = true ]; then
        run_root apt-get autoremove -y
    fi
fi

if have dnf; then
    run_root dnf clean all
    if [ "$AUTOREMOVE" = true ]; then
        run_root dnf autoremove -y
    fi
elif have yum; then
    run_root yum clean all
    if [ "$AUTOREMOVE" = true ]; then
        run_root yum autoremove -y
    fi
fi

if have zypper; then
    run_root zypper --non-interactive clean --all
fi

if have apk; then
    run_root apk cache clean
fi

if have xbps-remove; then
    run_root xbps-remove -O -y
    if [ "$AUTOREMOVE" = true ]; then
        run_root xbps-remove -o -y
    fi
fi

if have eclean-dist; then
    run_root eclean-dist
    run_root eclean-pkg
fi

if have nix-collect-garbage; then
    # Without -d: only store paths no generation refers to, rollbacks stay.
    run_cmd nix-collect-garbage
fi

if have flatpak; then
    echo "Removing unused Flatpak runtimes..."
    run_cmd flatpak uninstall --unused -y
fi

if have snap; then
    echo "Removing disabled snap revisions..."
    snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}' |
        while read -r snap_name snap_revision; do
            run_root snap remove "$snap_name" --revision="$snap_revision"
        done
fi

echo "Emptying Trash (items trashed more than ${DAYS_TO_KEEP} days ago)..."
clean_trash "$DATA_DIR/Trash"
for volume_trash in /run/media/"$USER"/*/.Trash-"$(id -u)" /media/"$USER"/*/.Trash-"$(id -u)" /mnt/*/.Trash-"$(id -u)"; do
    clean_trash "$volume_trash"
done

# Developer tool caches
if have npm; then
    echo "Cleaning npm cache..."
    run_cmd npm cache clean --force
fi

if have yarn; then
    echo "Cleaning yarn cache..."
    run_cmd yarn cache clean
fi

if have pnpm; then
    echo "Pruning pnpm store..."
    run_cmd pnpm store prune
fi

if have pip; then
    echo "Cleaning pip cache..."
    run_cmd pip cache purge
elif have pip3; then
    echo "Cleaning pip cache..."
    run_cmd pip3 cache purge
fi

# Docker and Podman, only on request: pruning removes stopped containers.
if [ "$DOCKER" = true ]; then
    if have docker; then
        echo "Checking Docker context..."
        if ! current_context=$(docker context show 2>/dev/null); then
            echo "Unable to determine Docker context; skipping cleanup to avoid a remote connection."
        elif endpoint=$(docker context inspect "$current_context" --format '{{.Endpoints.docker.Host}}' 2>/dev/null); then
            if [[ "$endpoint" == unix://* ]]; then
                echo "Cleaning unused Docker data..."
                run_cmd docker system prune -f
            else
                echo "Docker is using a remote context ($endpoint), skipping cleanup."
            fi
        else
            echo "Unable to inspect Docker context; skipping cleanup to avoid a remote connection."
        fi
    fi

    if have podman; then
        echo "Cleaning unused Podman data..."
        run_cmd podman system prune -f
    fi
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "\nDry run complete, nothing was deleted."
else
    echo -e "\nAfter cleanup:"

    free_storage_final=$(free_kb)
    echo "Free storage: $(to_gib "$free_storage_final") Gi / Total storage: $(to_gib "$total_storage") Gi"

    # Calculate the difference in kilobytes; never report a negative value
    free_storage_diff_kb=$((free_storage_final - free_storage))
    if [ "$free_storage_diff_kb" -lt 0 ]; then
        free_storage_diff_kb=0
    fi

    # Determine appropriate unit for the difference
    if [ "$free_storage_diff_kb" -ge $((1024 * 1024)) ]; then
        echo "Space freed: $(to_gib "$free_storage_diff_kb") Gi"
    elif [ "$free_storage_diff_kb" -ge 1024 ]; then
        echo "Space freed: $(awk -v kb="$free_storage_diff_kb" 'BEGIN { printf "%.2f", kb / 1024 }') Mi"
    else
        echo "Space freed: $free_storage_diff_kb Ki"
    fi

    echo "Selective cleanup complete!"
fi
