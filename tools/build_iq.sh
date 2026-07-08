#!/usr/bin/env bash
# Export a signed .iq package for Connect IQ Store upload.
#
# Usage:  tools/build_iq.sh [output.iq]
#
# Needs the Connect IQ SDK (monkeyc) and its device files, both installed by
# the Connect IQ SDK Manager (https://developer.garmin.com/connect-iq/sdk/).
# monkeyc is found from $MONKEYC, the PATH, or the SDK Manager's current-sdk
# config. The developer key is taken from $CIQ_DEVELOPER_KEY or the usual
# ~/.Garmin/ConnectIQ/developer_key.der; a fresh key is generated there if
# none exists (keep it - store updates must be signed with the same key).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)
OUT=${1:-dist/CarbBurn-${VERSION:-dev}.iq}

# ---- locate monkeyc ----
MONKEYC=${MONKEYC:-}
if [ -z "$MONKEYC" ] && command -v monkeyc >/dev/null 2>&1; then
    MONKEYC=$(command -v monkeyc)
fi
if [ -z "$MONKEYC" ]; then
    CFG="$HOME/.Garmin/ConnectIQ/current-sdk.cfg"
    if [ -f "$CFG" ]; then
        SDK_DIR=$(tr -d '\r\n' < "$CFG")
        [ -x "$SDK_DIR/bin/monkeyc" ] && MONKEYC="$SDK_DIR/bin/monkeyc"
    fi
fi
if [ -z "$MONKEYC" ]; then
    echo "error: monkeyc not found. Install the Connect IQ SDK via the SDK" >&2
    echo "Manager, or set MONKEYC=/path/to/sdk/bin/monkeyc" >&2
    exit 1
fi

# ---- locate (or create) the developer key ----
KEY=${CIQ_DEVELOPER_KEY:-"$HOME/.Garmin/ConnectIQ/developer_key.der"}
if [ ! -f "$KEY" ]; then
    echo "no developer key at $KEY - generating one (RSA 4096, PKCS#8 DER)"
    mkdir -p "$(dirname "$KEY")"
    TMP_PEM=$(mktemp)
    openssl genrsa -out "$TMP_PEM" 4096 >/dev/null 2>&1
    openssl pkcs8 -topk8 -inform PEM -outform DER -in "$TMP_PEM" \
        -out "$KEY" -nocrypt
    rm -f "$TMP_PEM"
    echo "created $KEY - BACK THIS UP; store updates need the same key"
fi

# ---- export ----
mkdir -p "$(dirname "$OUT")"
echo "exporting $OUT (release build) with $MONKEYC"
"$MONKEYC" -e -r -w -f monkey.jungle -y "$KEY" -o "$OUT"
echo "done: $OUT"
echo "upload at https://apps.garmin.com/developer/upload"
