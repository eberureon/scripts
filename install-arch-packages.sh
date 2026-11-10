#!/bin/bash
# install-arch-packages.sh
#
# This script automates the installation of a list of official and AUR packages on Arch Linux.
# It first installs the 'yay' AUR helper if it's not already present, then proceeds to
# install all other specified packages and links the dotfiles.
#
# Run it with sudo from your normal user account:
# sudo bash install-arch-packages.sh

set -e # Exit immediately if a command exits with a non-zero status.

# --- SCRIPT SETUP AND PERMISSION CHECK ---
# Check if the script is running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please run with 'sudo'."
  exit 1
fi

# AUR packages must be built by a normal user: makepkg refuses to run as root.
run_user="${SUDO_USER:-}"
if [ -z "$run_user" ] || [ "$run_user" = "root" ]; then
  echo "Run this script with 'sudo' from your normal user account, not from a root shell."
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Starting Arch Linux package installation script..."
echo "This script will install a mix of official and AUR packages."
echo "You may be prompted for your password multiple times during the process."
echo ""

# --- PACKAGE DEFINITIONS ---
# List of packages from the official Arch Linux repositories
pacman_packages=(
  biome
  bitwarden
  bluedevil
  chromium
  docker
  docker-compose
  eza
  fastfetch
  ghostty
  git
  go
  jdk-openjdk
  jq
  lazygit
  neovim
  nodejs
  noto-fonts-emoji
  noto-fonts-extra
  npm
  ttf-opensans
  uv
  vim
  zoxide
  zsh
  zsh-completions
)

# Packages from the multilib repository, which is disabled by default
multilib_packages=(
  steam
)

# List of packages from the Arch User Repository (AUR)
aur_packages=(
  # ausweisapp2
  intellij-idea-ultimate-edition
  mullvad-vpn-bin
  postman-bin
  spotify
  ttf-meslo-nerd-font-powerlevel10k
  ttf-nerd-fonts-symbols
  visual-studio-code-bin
  yubico-authenticator-bin
  zen-browser-bin
  zoom
  zsh-theme-powerlevel10k
)

# --- YAY INSTALLATION FUNCTION ---
install_yay() {
  if ! command -v yay &>/dev/null; then
    echo "yay is not installed. Installing yay from AUR..."
    # Install dependencies for building yay
    pacman -S --needed --noconfirm base-devel git

    # Build in a temporary directory that belongs to the normal user
    temp_dir=$(sudo -u "$run_user" mktemp -d)
    sudo -u "$run_user" git clone https://aur.archlinux.org/yay.git "$temp_dir"

    # Build and install the package as the normal user; makepkg asks for
    # the sudo password itself when it installs.
    (cd "$temp_dir" && sudo -u "$run_user" makepkg -si --noconfirm)

    # Clean up the temporary directory
    rm -rf "$temp_dir"
  else
    echo "yay is already installed. Skipping installation."
  fi
}

# --- INSTALLATION STEPS ---
# 1. Update the system
echo "--- Updating system packages ---"
pacman -Syu --noconfirm

# 2. Install official packages (--needed skips what is already up to date)
echo "--- Installing official packages with pacman ---"
pacman -S --needed --noconfirm "${pacman_packages[@]}"

if pacman -Sl multilib &>/dev/null; then
  pacman -S --needed --noconfirm "${multilib_packages[@]}"
else
  echo "Warning: the multilib repository is not enabled, skipping: ${multilib_packages[*]}"
  echo "         Enable [multilib] in /etc/pacman.conf and run this script again."
fi

# 3. Install yay (if not already installed)
echo "--- Checking for and installing yay ---"
install_yay

# 4. Install AUR packages with yay
echo "--- Installing AUR packages with yay ---"
# yay must not run as root; it prompts for sudo itself when needed.
# The `--noconfirm` flag may not always work perfectly with yay for complex builds.
# You might need to remove it if a specific package requires manual interaction.
if [ ${#aur_packages[@]} -gt 0 ]; then
  sudo -u "$run_user" yay -S --needed --noconfirm "${aur_packages[@]}"
else
  echo "No AUR packages to install."
fi

# --- POST-INSTALLATION TASKS ---
echo "--- Installation complete! ---"
echo ""

# --- Create symlinks ---
# link-dotfiles.sh backs up existing files instead of overwriting them.
echo "--- Creating symlinks for dotfiles ---"
sudo -H -u "$run_user" bash "$script_dir/link-dotfiles.sh" \
  || echo "Warning: not all dotfiles could be linked, see the messages above."
echo ""

echo "Additional steps you may want to take:"
echo "1. Configure Zsh and Powerlevel10k theme: run 'p10k configure' in your new shell."
echo "2. Enable and start the Docker daemon: 'sudo systemctl enable --now docker'."
echo "3. Log out and back in to apply new font settings."
echo "4. For Zsh, consider changing your default shell with 'chsh -s /bin/zsh'."
