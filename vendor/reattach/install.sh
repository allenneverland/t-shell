#!/bin/sh
set -e

REPO="allenneverland/t-shell"
BINARY="tmuxd"

# Detect platform and fallback candidates
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m | tr '[:upper:]' '[:lower:]')"
case "$OS-$ARCH" in
    linux-x86_64) candidates="linux-x86_64-gnu linux-x86_64-musl linux-x86_64 linux-amd64" ;;
    linux-aarch64|linux-arm64) candidates="linux-aarch64-gnu linux-aarch64-musl linux-aarch64 linux-arm64" ;;
    darwin-arm64|darwin-aarch64) candidates="darwin-aarch64 darwin-arm64" ;;
    darwin-x86_64) candidates="darwin-x86_64 darwin-amd64" ;;
    *) echo "Unsupported platform: $OS-$ARCH"; exit 1 ;;
esac
echo "Detected platform: $OS-$ARCH"

# Get latest tmuxd release tag (prefers tmuxd-v* tags)
RELEASES_API="https://api.github.com/repos/$REPO/releases?per_page=100"
if command -v curl > /dev/null 2>&1; then
    RELEASES_JSON=$(curl -fsSL "$RELEASES_API")
elif command -v wget > /dev/null 2>&1; then
    RELEASES_JSON=$(wget -qO- "$RELEASES_API")
else
    echo "Error: curl or wget is required"
    exit 1
fi

LATEST=$(printf '%s\n' "$RELEASES_JSON" | awk -F'"' '/"tag_name":[[:space:]]*"tmuxd-v/ { print $4; exit }')
if [ -z "$LATEST" ]; then
    LATEST=$(printf '%s\n' "$RELEASES_JSON" | awk -F'"' '/"tag_name":[[:space:]]*"/ { print $4; exit }')
fi

if [ -z "$LATEST" ]; then
    echo "Error: Could not determine latest version"
    exit 1
fi

echo "Selected release tag: $LATEST"

# Create temp directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Download and extract
SELECTED_URL=""
for PLATFORM in $candidates; do
    URL="https://github.com/$REPO/releases/download/$LATEST/tmuxd-$PLATFORM.tar.gz"
    echo "Trying download: $URL"
    if command -v curl > /dev/null 2>&1; then
        if curl -fsSL "$URL" -o "$TMP_DIR/tmuxd.tgz"; then
            SELECTED_URL="$URL"
            break
        fi
    else
        if wget -qO "$TMP_DIR/tmuxd.tgz" "$URL"; then
            SELECTED_URL="$URL"
            break
        fi
    fi
done

if [ -z "$SELECTED_URL" ]; then
    echo "Error: Could not find a matching tmuxd binary asset for $OS-$ARCH"
    exit 1
fi

echo "Downloaded from: $SELECTED_URL"
tar xzf "$TMP_DIR/tmuxd.tgz" -C "$TMP_DIR"

# Install
INSTALL_DIR="/usr/local/bin"
if [ ! -w "$INSTALL_DIR" ]; then
    if command -v sudo > /dev/null 2>&1; then
        echo "Installing to $INSTALL_DIR (requires sudo)..."
        sudo mv "$TMP_DIR/$BINARY" "$INSTALL_DIR/$BINARY"
        sudo chmod +x "$INSTALL_DIR/$BINARY"
    else
        INSTALL_DIR="$HOME/.local/bin"
        mkdir -p "$INSTALL_DIR"
        mv "$TMP_DIR/$BINARY" "$INSTALL_DIR/$BINARY"
        chmod +x "$INSTALL_DIR/$BINARY"
    fi
else
    mv "$TMP_DIR/$BINARY" "$INSTALL_DIR/$BINARY"
    chmod +x "$INSTALL_DIR/$BINARY"
fi

echo ""
echo "Installed $BINARY to $INSTALL_DIR/$BINARY"
echo ""

if [ "$INSTALL_DIR" != "/usr/local/bin" ]; then
    echo "Note: For systemd service, copy to /usr/local/bin:"
    echo "  sudo cp $INSTALL_DIR/$BINARY /usr/local/bin/"
    echo ""
fi

echo "Run 'tmuxd --help' to get started"
