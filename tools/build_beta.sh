#!/usr/bin/env bash
# Build the "Carb Burn (Beta)" variant - the parallel-install build.
#
# Usage:  tools/build_beta.sh [-y /path/to/developer_key.der] [-o OUTDIR]
#
# Produces BOTH artifacts:
#   OUTDIR/CarbBurn-Beta-<version>.iq        - the packaged multi-device build
#   OUTDIR/prg/CarbBurn-Beta-<device>.prg    - one release .prg per manifest product,
#                                              for copying to GARMIN/APPS/ over USB
#
# The beta uses manifest.beta.xml (application id 3aa0137493fa4511ba559720835b1ab5)
# via beta.jungle. The INTENT is that it installs alongside the store build
# rather than replacing it, and that a ride recorded with both fields active
# yields two separately attributed sets of developer data. Both of those are
# design premises, not measurements - nothing here has been run on a device or
# through a FIT decoder. See #63 and #64. The FIT developer field ids stay 0-3,
# identical to production, so that an A/B diff is readable if it works out.
#
# That id was not registered on the Connect IQ Store by this project. Do not
# upload either artifact there; this variant is for sideloading.
#
# Needs the Connect IQ SDK (monkeyc) and its device files, both installed by the
# Connect IQ SDK Manager (https://developer.garmin.com/connect-iq/sdk/). monkeyc
# is found from $MONKEYC, the PATH, or the SDK Manager's current-sdk config.
#
# KEY HANDLING - deliberately stricter than tools/build_iq.sh.
# build_iq.sh generates a signing key when none is found and signs with it
# without asking (open as #58). This script does NOT do that: it requires an
# explicit key path and fails closed when one is absent. Silently minting a key
# is how you end up with a package signed by a key you cannot reproduce.
set -euo pipefail
cd "$(dirname "$0")/.."

JUNGLE=beta.jungle
MANIFEST=manifest.beta.xml
VERSION=$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)
OUTDIR=dist/beta
KEY=${CIQ_DEVELOPER_KEY:-}

usage() {
    # Print the header comment block (everything between the shebang and the
    # first non-comment line) as the help text, so the two cannot drift apart.
    sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
    exit "${1:-2}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--key)    KEY=${2:-}; shift 2 ;;
        -o|--outdir) OUTDIR=${2:-}; shift 2 ;;
        -h|--help)   usage 0 ;;
        *) echo "error: unknown argument '$1'" >&2; usage 2 ;;
    esac
done

# ---- require a developer key (fail closed; never mint one) ----
if [ -z "$KEY" ]; then
    cat >&2 <<'EOF'
error: no developer key given.

  Pass one explicitly:      tools/build_beta.sh -y /path/to/developer_key.der
  or set the environment:   CIQ_DEVELOPER_KEY=/path/to/developer_key.der

This script will NOT generate a key for you. A signing key you did not choose
is a signing key you cannot reproduce; if you genuinely need a new one:

  openssl genrsa -out key.pem 4096
  openssl pkcs8 -topk8 -inform PEM -outform DER -in key.pem -out developer_key.der -nocrypt
  rm key.pem      # then BACK UP developer_key.der
EOF
    exit 2
fi
if [ ! -f "$KEY" ]; then
    echo "error: developer key not found at '$KEY'" >&2
    exit 2
fi

# ---- locate monkeyc (same order as tools/build_iq.sh) ----
MONKEYC=${MONKEYC:-}
if [ -z "$MONKEYC" ] && command -v monkeyc >/dev/null 2>&1; then
    MONKEYC=$(command -v monkeyc)
fi
if [ -z "$MONKEYC" ]; then
    # The SDK Manager writes current-sdk.cfg to ~/.Garmin/ConnectIQ on
    # macOS/Linux and to %APPDATA%\Garmin\ConnectIQ on Windows. build_iq.sh
    # only checks the first; both are checked here so the script works from
    # Git Bash on Windows without presetting $MONKEYC.
    for CFG in "$HOME/.Garmin/ConnectIQ/current-sdk.cfg" \
               "${APPDATA:-$HOME/AppData/Roaming}/Garmin/ConnectIQ/current-sdk.cfg"; do
        [ -f "$CFG" ] || continue
        SDK_DIR=$(tr -d '\r\n' < "$CFG" | tr '\\' '/')
        SDK_DIR=${SDK_DIR%/}
        if [ -x "$SDK_DIR/bin/monkeyc" ]; then MONKEYC="$SDK_DIR/bin/monkeyc"; break; fi
    done
fi
if [ -z "$MONKEYC" ]; then
    echo "error: monkeyc not found. Install the Connect IQ SDK via the SDK" >&2
    echo "Manager, or set MONKEYC=/path/to/sdk/bin/monkeyc" >&2
    exit 1
fi

# ---- device list comes FROM the beta manifest ----
# Read, never hardcoded: the promise is "every product this manifest declares",
# so a product added to manifest.beta.xml is built here without editing this file.
#
# Parsed with a real XML parser, NOT a regex. This used to be a line-oriented
# `sed`, and that was measurably wrong: of nine reformattings of the SAME 13
# products that ElementTree accepts and that `monkeyc` compiles (rc=0 for a
# device the sed had dropped, with `-d fr965` giving rc=102 as a control that
# monkeyc really does read this list), the sed returned the right 13 for only
# four. Two of the five failures returned a non-empty SUBSET - 7 and 1 device -
# which is the dangerous shape: the emptiness guard below cannot see it, NDEV is
# derived from the same narrowed list, and the script would cheerfully print
# "7/7 OK" while silently building half the matrix. Attribute order, quoting
# style, spaces around '=', line breaks inside a tag and several elements per
# line are all legal XML; a regex over lines is not a parser.
#
# Element matching mirrors scripts/check_manifest_appid.py (tag.endswith
# "product"), so the two agree about what the manifest declares.
PYTHON=${PYTHON:-}
if [ -z "$PYTHON" ]; then
    for cand in python3 python; do
        if command -v "$cand" >/dev/null 2>&1; then PYTHON=$cand; break; fi
    done
fi
if [ -z "$PYTHON" ]; then
    echo "error: python3 not found, and it is required to read the device list" >&2
    echo "  from $MANIFEST. Set PYTHON=/path/to/python3." >&2
    echo "  This script will NOT fall back to a regex: a line-oriented parse of" >&2
    echo "  legal XML silently returns a SUBSET of the products, and building a" >&2
    echo "  subset of the device matrix while reporting success is worse than" >&2
    echo "  not building at all. python3 is already required elsewhere in this" >&2
    echo "  repo (scripts/check_manifest_appid.py, and CI runs it)." >&2
    exit 1
fi
# The `tr -d '\r'` is load-bearing, not cargo: on Windows, Python's text-mode
# stdout translates every '\n' to '\r\n', so without it each id arrives as
# "edge530\r" - '\r' is not in IFS, so it survives word splitting and monkeyc
# rejects it with "Invalid device id specified: 'edge530'". Measured: 12 of 13
# devices failed that way on the first run of this parser.
DEVICES=$("$PYTHON" -c 'import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
sys.stdout.write("\n".join(e.get("id") for e in root.iter()
                           if e.tag.endswith("product") and e.get("id")))' \
    "$MANIFEST" | tr -d '\r') || {
    echo "error: could not parse $MANIFEST" >&2
    exit 1
}
if [ -z "$DEVICES" ]; then
    echo "error: no <iq:product> entries found in $MANIFEST" >&2
    exit 1
fi
NDEV=$(printf '%s\n' "$DEVICES" | wc -w | tr -d ' ')

echo "monkeyc:  $MONKEYC"
echo "jungle:   $JUNGLE  (manifest: $MANIFEST)"
echo "key:      $KEY"
echo "outdir:   $OUTDIR"
echo "devices:  $NDEV -> $(printf '%s ' $DEVICES)"
echo

# ---- 1) per-device release .prg (sideload over USB) ----
mkdir -p "$OUTDIR/prg"
ok=0
fail=0
for dev in $DEVICES; do
    out="$OUTDIR/prg/CarbBurn-Beta-$dev.prg"
    if "$MONKEYC" -f "$JUNGLE" -o "$out" -y "$KEY" -d "$dev" -r -w; then
        echo "OK   $dev -> $out"
        ok=$((ok + 1))
    else
        rc=$?
        echo "FAIL $dev (monkeyc rc=$rc)" >&2
        fail=$((fail + 1))
    fi
done
echo
echo "per-device release build: $ok/$NDEV OK, $fail failed"
if [ "$fail" -ne 0 ]; then
    echo "error: $fail device(s) failed to build - not exporting the package" >&2
    exit 1
fi

# ---- 2) packaged .iq ----
IQ="$OUTDIR/CarbBurn-Beta-${VERSION:-dev}.iq"
echo
echo "exporting $IQ (release build)"
"$MONKEYC" -e -r -w -f "$JUNGLE" -y "$KEY" -o "$IQ"

echo
echo "done."
echo "  package : $IQ"
echo "  sideload: copy $OUTDIR/prg/CarbBurn-Beta-<device>.prg to GARMIN/APPS/ on the device"
echo
echo "NOTE: the beta application id was not registered on the Connect IQ Store by"
echo "      this project. Do not upload this package there; it is for sideloading."
