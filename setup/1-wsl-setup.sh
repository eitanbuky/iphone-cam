#!/bin/bash
# ============================================================
# Step 1: WSL2 Setup — Install Swift + xtool
# Run this INSIDE WSL2 (Ubuntu 22.04 recommended)
# ============================================================

set -e

echo "============================================"
echo " iPhone Cam — WSL2 Setup"
echo "============================================"
echo ""

# ── System dependencies ──────────────────────────────────────
echo "[1/4] Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    clang \
    libicu-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libblocksruntime-dev \
    libsqlite3-dev \
    tzdata \
    git \
    curl \
    wget \
    unzip

# ── Swift ────────────────────────────────────────────────────
echo ""
echo "[2/4] Installing Swift 5.10..."

SWIFT_VERSION="5.10"
SWIFT_PLATFORM="ubuntu22.04"
SWIFT_TAG="swift-${SWIFT_VERSION}-RELEASE"
SWIFT_DIR="/opt/swift"

if command -v swift &>/dev/null; then
    echo "      Swift already installed: $(swift --version | head -1)"
else
    SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM//.}/swift-${SWIFT_VERSION}-RELEASE/${SWIFT_TAG}-${SWIFT_PLATFORM}.tar.gz"
    echo "      Downloading from $SWIFT_URL ..."
    wget -q --show-progress "$SWIFT_URL" -O /tmp/swift.tar.gz
    sudo mkdir -p "$SWIFT_DIR"
    sudo tar -xzf /tmp/swift.tar.gz -C "$SWIFT_DIR" --strip-components=1
    rm /tmp/swift.tar.gz

    # Add to PATH
    echo "export PATH=\"$SWIFT_DIR/usr/bin:\$PATH\"" >> ~/.bashrc
    export PATH="$SWIFT_DIR/usr/bin:$PATH"
    echo "      Swift installed: $(swift --version | head -1)"
fi

# ── xtool ────────────────────────────────────────────────────
echo ""
echo "[3/4] Installing xtool..."

if command -v xtool &>/dev/null; then
    echo "      xtool already installed: $(xtool --version 2>/dev/null || echo 'unknown version')"
else
    curl -fsSL https://raw.githubusercontent.com/xtool-org/xtool/main/install.sh | bash
    # Reload PATH
    source ~/.bashrc 2>/dev/null || true
fi

# ── iOS SDK ──────────────────────────────────────────────────
echo ""
echo "[4/4] iOS SDK Setup"
echo ""
echo "  You need to download Xcode.xip from Apple (free with any Apple ID):"
echo "  → https://developer.apple.com/download/all/?q=xcode"
echo "  → Sign in, search 'Xcode', download Xcode 15.x .xip file (~8GB)"
echo ""
echo "  Once downloaded, copy Xcode.xip to your WSL home:"
echo "    cp /mnt/c/Users/eitan/Downloads/Xcode_15.x.xip ~/Xcode.xip"
echo ""
echo "  Then run:"
echo "    xtool sdk install ~/Xcode.xip"
echo ""
echo "  (This extracts the iOS SDK — takes ~5 minutes)"
echo ""
echo "============================================"
echo " Setup complete! Next: download Xcode.xip"
echo " Then run: 2-build-and-deploy.sh"
echo "============================================"
