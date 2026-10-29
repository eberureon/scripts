#!/usr/bin/env bash
# Symlink dotfiles from the workspace repo into $HOME.
# Existing real files/dirs at the target are moved to <target>.bak-<timestamp>
# instead of being overwritten. Existing symlinks are replaced.

set -euo pipefail

DOTFILES="{path_to_dotfiles}/dotfiles"
TS="$(date +%Y%m%d-%H%M%S)"

# "source|target" pairs
LINKS=(
  "$DOTFILES/.bash_aliases|$HOME/.bash_aliases"
  "$DOTFILES/.config/lazyvim|$HOME/.config/nvim"
  "$DOTFILES/linux/.config/ghostty|$HOME/.config/ghostty"
)

link() {
  local src="$1" dest="$2"

  if [[ ! -e "$src" ]]; then
    echo "SKIP: source missing: $src" >&2
    return 1
  fi

  mkdir -p "$(dirname "$dest")"

  if [[ -L "$dest" ]]; then
    # Already a symlink: replace it (nothing to back up)
    if [[ "$(readlink -f "$dest")" == "$(readlink -f "$src")" ]]; then
      echo "OK:   $dest already points to $src"
      return 0
    fi
    rm "$dest"
  elif [[ -e "$dest" ]]; then
    echo "BACKUP: $dest -> $dest.bak-$TS"
    mv "$dest" "$dest.bak-$TS"
  fi

  ln -s "$src" "$dest"
  echo "LINK: $dest -> $src"
}

status=0
for pair in "${LINKS[@]}"; do
  link "${pair%%|*}" "${pair##*|}" || status=1
done

exit $status
