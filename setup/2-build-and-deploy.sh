#!/bin/bash
# ============================================================
# Step 2: Build iOS app and deploy to iPhone
# Run this INSIDE WSL2 after running 1-wsl-setup.sh
# iPhone must be plugged in via USB cable
# ============================================================

set -e

# iOS source path (accessible from WSL via /mnt/c/...)
IOS_DIR="/mnt/c/eitan/programs/Antigravity/Workspace/iphone-cam/ios"

export PATH="/opt/swift/usr/bin:$PATH"

echo "============================================"
echo " iPhone Cam — Build & Deploy"
echo "============================================"
echo ""

# ── Verify tools ─────────────────────────────────────────────
if ! command -v swift &>/dev/null; then
    echo "[ERROR] Swift not found. Run 1-wsl-setup.sh first."
    exit 1
fi

if ! command -v xtool &>/dev/null; then
    echo "[ERROR] xtool not found. Run 1-wsl-setup.sh first."
    exit 1
fi

# ── Check iPhone connected ───────────────────────────────────
echo "[1/3] Checking for connected iPhone..."
if ! xtool devices 2>/dev/null | grep -q "iPhone"; then
    echo ""
    echo "  No iPhone detected. Make sure:"
    echo "  1. iPhone is plugged in via USB"
    echo "  2. You tapped 'Trust' on the iPhone when prompted"
    echo "  3. USB passes through to WSL: in PowerShell run:"
    echo "     usbipd list"
    echo "     usbipd bind --busid <ID>"
    echo "     usbipd attach --wsl --busid <ID>"
    echo ""
    echo "  See: https://learn.microsoft.com/en-us/windows/wsl/connect-usb"
    exit 1
fi

echo "      iPhone connected!"

# ── Build ────────────────────────────────────────────────────
echo ""
echo "[2/3] Building iOS app..."
cd "$IOS_DIR"
xtool build

echo ""
echo "[3/3] Deploying to iPhone..."
echo "  When prompted, enter your Apple ID and password."
echo "  This registers a free developer certificate (no $99 needed)."
echo ""
xtool install

echo ""
echo "============================================"
echo " Done! 'iPhone Cam' should appear on your iPhone."
echo ""
echo " The app expires in 7 days (free Apple ID limit)."
echo " To re-sign, just run this script again."
echo "============================================"
