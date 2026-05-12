#!/usr/bin/env bash
# ============================================================================
# GTNH Updater Launcher (Linux)
# ============================================================================
# Run this script to launch the GTNH Updater.
# If PowerShell 7 (pwsh) is not installed, it will offer to install it.
# ============================================================================

# Check if pwsh is available
if command -v pwsh &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/Update-GTNH.ps1"
fi

echo ""
echo "  PowerShell 7 (pwsh) is required but not installed."
echo ""

# Detect package manager and offer installation
install_pwsh() {
    if command -v apt-get &>/dev/null; then
        echo "  Detected apt (Debian/Ubuntu)."
        echo "  Installing PowerShell 7 via Microsoft repository..."
        echo ""
        # Install prerequisites
        sudo apt-get update
        sudo apt-get install -y wget apt-transport-https software-properties-common
        # Get OS version
        source /etc/os-release
        # Download and register Microsoft repository GPG key
        wget -q "https://packages.microsoft.com/config/debian/$VERSION_ID/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb 2>/dev/null \
            || wget -q "https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb
        sudo dpkg -i /tmp/packages-microsoft-prod.deb
        rm -f /tmp/packages-microsoft-prod.deb
        sudo apt-get update
        sudo apt-get install -y powershell
    elif command -v dnf &>/dev/null; then
        echo "  Detected dnf (Fedora/RHEL)."
        echo "  Installing PowerShell 7 via Microsoft repository..."
        echo ""
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        curl -sSL -o /tmp/microsoft.repo https://packages.microsoft.com/config/rhel/8/prod.repo
        sudo cp /tmp/microsoft.repo /etc/yum.repos.d/microsoft.repo
        rm -f /tmp/microsoft.repo
        sudo dnf install -y powershell
    elif command -v pacman &>/dev/null; then
        echo "  Detected pacman (Arch Linux)."
        echo "  Note: PowerShell is available from the AUR."
        echo "  You can install it with: yay -S powershell-bin"
        echo "  Or: paru -S powershell-bin"
        echo ""
        echo "  Alternatively, install via the .tar.gz method:"
        echo "  https://learn.microsoft.com/en-us/powershell/scripting/install/install-other-linux"
        return 1
    elif command -v zypper &>/dev/null; then
        echo "  Detected zypper (openSUSE)."
        echo "  Installing PowerShell 7 via Microsoft repository..."
        echo ""
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        sudo zypper addrepo https://packages.microsoft.com/rhel/7/prod/ microsoft
        sudo zypper install -y powershell
    elif command -v snap &>/dev/null; then
        echo "  Detected snap."
        echo "  Installing PowerShell 7 via snap..."
        echo ""
        sudo snap install powershell --classic
    else
        echo "  Could not detect a supported package manager."
        echo ""
        echo "  Install PowerShell 7 manually:"
        echo "  https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
        echo ""
        exit 1
    fi
}

echo "  [1] Install PowerShell 7 now"
echo "  [2] Open download page info"
echo "  [3] Cancel"
echo ""
read -rp "  Choose (1/2/3): " choice

case "$choice" in
    1)
        if install_pwsh; then
            if command -v pwsh &>/dev/null; then
                echo ""
                echo "  PowerShell 7 installed successfully."
                echo "  Run this script again to launch the updater."
                echo ""
            else
                echo ""
                echo "  Installation completed but pwsh is not in PATH."
                echo "  Try opening a new terminal and running this script again."
                echo ""
            fi
        else
            echo ""
            echo "  Installation may have failed."
            echo "  Try opening a new terminal and running this script again."
            echo "  If it still fails, install manually:"
            echo "  https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
            echo ""
        fi
        ;;
    2)
        echo ""
        echo "  Install PowerShell 7 from:"
        echo "  https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux"
        echo ""
        echo "  After installing, run this script again."
        echo ""
        ;;
    3)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
