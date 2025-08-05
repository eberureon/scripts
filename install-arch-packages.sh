#!/bin/bash
# install-arch-packages.sh
#
# This script automates the installation of a list of official and AUR packages on Arch Linux.
# It first installs the 'yay' AUR helper if it's not already present, then proceeds to
# install all other specified packages.
#
# To run this script, save it as 'install-packages.sh', make it executable, and run it
# with sudo:
# chmod +x install-packages.sh
# sudo ./install-packages.sh

set -e # Exit immediately if a command exits with a non-zero status.

# --- SCRIPT SETUP AND PERMISSION CHECK ---
# Check if the script is running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please run with 'sudo'."
  exit 1
fi

echo "Starting Arch Linux package installation script..."
echo "This script will install a mix of official and AUR packages."
echo "You may be prompted for your password multiple times during the process."
echo ""

# --- PACKAGE DEFINITIONS ---
# List of packages from the official Arch Linux repositories
pacman_packages=(
  bitwarden
  bluedevil
  chromium
  docker
  docker-compose
  eza
  fastfetch
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
  steam
  ttf-opensans
  zoxide
  zsh
  zsh-completions
)

# List of packages from the Arch User Repository (AUR)
aur_packages=(
  ausweisapp2
  biome
  ghostty
  intellij-idea-ultimate-edition
  mullvad-vpn-bin
  postman-bin
  spotify
  ttf-meslo-nerd-font-powerlevel10k
  ttf-nerd-fonts-symbols
  uv
  visual-studio-code-bin
  yubico-authenticator-bin
  zen-browser-bin
  zoom
  zsh-theme-powerlevel10k-git
)

# --- YAY INSTALLATION FUNCTION ---
install_yay() {
  if ! command -v yay &>/dev/null; then
    echo "yay is not installed. Installing yay from AUR..."
    # Install dependencies for building yay
    pacman -S --noconfirm base-devel git

    # Create a temporary directory to build yay
    temp_dir=$(mktemp -d)
    git clone https://aur.archlinux.org/yay.git "$temp_dir"

    # Change to the directory and build/install the package
    (cd "$temp_dir" && makepkg -si --noconfirm)

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

# 2. Install official packages
echo "--- Installing official packages with pacman ---"
pacman -S --noconfirm "${pacman_packages[@]}"

# 3. Install yay (if not already installed)
echo "--- Checking for and installing yay ---"
install_yay

# 4. Install AUR packages with yay
echo "--- Installing AUR packages with yay ---"
# Note: yay will prompt for sudo when needed, so we don't need 'sudo' here.
# We run yay as the user that ran the script, not as root.
# The `sudo -u "$(logname)"` part ensures yay runs as the logged-in user.
# The `--noconfirm` flag may not always work perfectly with yay for complex builds.
# You might need to remove it if a specific package requires manual interaction.
if [ ${#aur_packages[@]} -gt 0 ]; then
  sudo -u "$(logname)" yay -S --noconfirm "${aur_packages[@]}"
else
  echo "No AUR packages to install."
fi

# --- POST-INSTALLATION TASKS ---
echo "--- Installation complete! ---"
echo ""

# --- Create symlink ---
user_home=$(getent passwd "$(logname)" | cut -d: -f6)
# Define an array of source paths and a corresponding array of target links.
# The order must match.
source_paths=(
  "$user_home/workspace/files"
)
target_links=(
  "$user_home/.config/files"
)

echo "--- Creating symlinks for dotfiles ---"

# Loop through the arrays to create symlinks
for i in "${!source_paths[@]}"; do
  source_path="${source_paths[$i]}"
  target_link="${target_links[$i]}"

  echo "Creating symlink: $target_link -> $source_path"

  # Check if the source directory exists
  if [ -d "$source_path" ]; then
    # Create the parent directory for the symlink if it doesn't exist
    sudo -u "$(logname)" mkdir -p "$(dirname "$target_link")"

    # Check if the target symlink already exists and remove it if it does
    if [ -L "$target_link" ]; then
      sudo -u "$(logname)" rm "$target_link"
    fi

    # Create the symbolic link as the logged-in user
    sudo -u "$(logname)" ln -s "$source_path" "$target_link"
    echo "Symlink created successfully."
  else
    echo "Warning: Source directory '$source_path' does not exist. Skipping symlink creation."
  fi
done
echo ""

echo "Additional steps you may want to take:"
echo "1. Configure Zsh and Powerlevel10k theme: run 'p10k configure' in your new shell."
echo "2. Enable and start the Docker daemon: 'sudo systemctl enable --now docker'."
echo "3. Log out and back in to apply new font settings."
echo "4. For Zsh, consider changing your default shell with 'chsh -s /bin/zsh'."
