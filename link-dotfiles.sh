#!/usr/bin/env bash
# Symlink dotfiles from the dotfiles repo into $HOME.
# Existing real files/dirs at the target are moved to <target>.bak-<timestamp>
# instead of being overwritten. Existing symlinks are replaced.
#
# Usage: link-dotfiles.sh [DOTFILES_DIR]
# The dotfiles directory is taken from the argument, then from $DOTFILES,
# then defaults to ~/Documents/workspace/dotfiles.

set -euo pipefail

DOTFILES="${1:-${DOTFILES:-$HOME/Documents/workspace/dotfiles}}"
DOTFILES="${DOTFILES%/}"
TS="$(date +%Y%m%d-%H%M%S)"

if [[ ! -d "$DOTFILES" ]]; then
  echo "Dotfiles directory not found: $DOTFILES" >&2
  echo "Usage: $(basename "$0") [DOTFILES_DIR]" >&2
  exit 1
fi

# "source|target" pairs
LINKS=(
  "$DOTFILES/.bash_aliases|$HOME/.bash_aliases"
  "$DOTFILES/.config/lazyvim|$HOME/.config/nvim"
  "$DOTFILES/linux/.config/ghostty|$HOME/.config/ghostty"
)

# Every step returns on failure by itself: "set -e" is switched off inside a
# function that is called as "link ... || status=1".
link() {
  local src="$1" dest="$2"

  if [[ ! -e "$src" ]]; then
    echo "SKIP: source missing: $src" >&2
    return 1
  fi

  mkdir -p "$(dirname "$dest")" || return 1

  if [[ -L "$dest" ]]; then
    # Already a symlink: replace it (nothing to back up)
    if [[ "$(readlink -f "$dest")" == "$(readlink -f "$src")" ]]; then
      echo "OK:   $dest already points to $src"
      return 0
    fi
    rm "$dest" || return 1
  elif [[ -e "$dest" ]]; then
    echo "BACKUP: $dest -> $dest.bak-$TS"
    mv "$dest" "$dest.bak-$TS" || return 1
  fi

  # -n: never create the link inside an existing directory at the target.
  ln -sn "$src" "$dest" || return 1
  echo "LINK: $dest -> $src"
}

status=0
for pair in "${LINKS[@]}"; do
  link "${pair%%|*}" "${pair##*|}" || status=1
done

exit $status
