#!/usr/bin/env bash
# Export a signed .iq package for Connect IQ Store upload.
#
# Usage:  tools/build_iq.sh -y /path/to/developer_key.der [-o OUT.iq]
#         tools/build_iq.sh -y /path/to/developer_key.der [OUT.iq]
#
# VERSION - the top-level VERSION file is the single source of truth for the
# release version; CHANGELOG.md and store/changelog.txt must agree with it, and
# it must be strictly newer than every v* release tag that EXISTS - which means
# the remote's tags, read with ls-remote, not just whatever this checkout has
# fetched. Both are asserted by scripts/check_version.py --release, and a
# failure STOPS the export. There is no bypass flag: the only way through is to
# bump the version, which is exactly the release ritual (see docs/release.md).
# If a remote is configured but unreachable, this refuses to build rather than
# falling back to a possibly-stale local tag set.
#
# KEY - taken from -y/--key or $CIQ_DEVELOPER_KEY. This script will NOT generate
# one: a signing key you did not choose is a signing key you cannot reproduce,
# and store updates must be signed with the same key that signed the first
# upload. Absent or missing key => exit 2, nothing built.
#
# SDK - needs the Connect IQ SDK (monkeyc) and its device files, both installed
# by the Connect IQ SDK Manager (https://developer.garmin.com/connect-iq/sdk/).
# monkeyc is found from $MONKEYC, the PATH, or the SDK Manager's current-sdk
# config - which lives in ~/.Garmin/ConnectIQ on macOS/Linux and in
# %APPDATA%\Garmin\ConnectIQ on Windows. Both are checked.
#
# Exit codes: 1 monkeyc not found / export failed; 2 key problem or bad
# arguments; 3 version problem (see scripts/check_version.py).
set -euo pipefail
# Resolve this file BEFORE cd-ing, so usage() can still read it.
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")/.."

KEY=${CIQ_DEVELOPER_KEY:-}
OUT=""

usage() {
    # Print the header comment block (everything between the shebang and the
    # first non-comment line) as the help text, so the two cannot drift apart.
    sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$SELF"
    exit "${1:-2}"
}

need_arg() {
    # Without this, `shift 2` on a dangling option trips set -e and the script
    # exits 1 - which this file documents as "monkeyc not found". Bad arguments
    # are exit 2.
    [ "$2" -ge 2 ] || { echo "error: $1 needs an argument" >&2; usage 2; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--key)     need_arg "$1" $#; KEY=$2; shift 2 ;;
        -o|--output)  need_arg "$1" $#; OUT=$2; shift 2 ;;
        -h|--help)    usage 0 ;;
        -*)           echo "error: unknown option '$1'" >&2; usage 2 ;;
        *)
            # Back-compat with the old positional form: tools/build_iq.sh [out.iq]
            if [ -n "$OUT" ]; then
                echo "error: unexpected extra argument '$1'" >&2
                usage 2
            fi
            OUT=$1; shift ;;
    esac
done

# ---- require a developer key (fail closed; never mint one) ----
if [ -z "$KEY" ]; then
    cat >&2 <<'EOF'
error: no developer key given.

  Pass one explicitly:      tools/build_iq.sh -y /path/to/developer_key.der
  or set the environment:   CIQ_DEVELOPER_KEY=/path/to/developer_key.der

This script will NOT generate a key for you. The Connect IQ Store binds an app
to the key that signed its first upload, so a key minted here - or minted at a
mistyped $CIQ_DEVELOPER_KEY path - produces a package that cannot update the
published app. If you genuinely need a new one, and this app has never been
published from it:

  openssl genrsa -out key.pem 4096
  openssl pkcs8 -topk8 -inform PEM -outform DER -in key.pem -out developer_key.der -nocrypt
  rm key.pem      # then BACK UP developer_key.der
EOF
    exit 2
fi
if [ ! -f "$KEY" ]; then
    echo "error: developer key not found at '$KEY'" >&2
    echo "       (a path that does not exist is a typo, not a request to create one)" >&2
    exit 2
fi

# ---- version: read the source of truth, then gate the release ----
if [ ! -f VERSION ]; then
    echo "error: no VERSION file at the repo root - it is the version source of truth" >&2
    exit 3
fi
VERSION=$(tr -d ' \t\r\n' < VERSION)
if [ -z "$VERSION" ]; then
    echo "error: VERSION is empty" >&2
    exit 3
fi

# scripts/check_version.py owns every version assertion, so the shell and CI
# cannot drift apart. Resolve a real Python 3 first (the Windows Store stub
# named 'python3' answers command -v but is not an interpreter).
PY=${PYTHON:-}
if [ -z "$PY" ]; then
    for cand in python3 python; do
        if command -v "$cand" >/dev/null 2>&1 \
           && "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' \
                >/dev/null 2>&1; then
            PY=$cand
            break
        fi
    done
fi
if [ -z "$PY" ]; then
    echo "error: no Python 3 found; scripts/check_version.py gates this release" >&2
    echo "       install Python 3, or set PYTHON=/path/to/python3" >&2
    exit 3
fi

echo "== version gate =="
# `|| rc=$?` (not `if ! ...`) so the checker's own exit code survives: after
# `if ! cmd`, $? is the negated status, not the status.
gate_rc=0
"$PY" scripts/check_version.py --release . || gate_rc=$?
if [ "$gate_rc" -ne 0 ]; then
    echo "error: version gate failed (check_version.py rc=$gate_rc)" >&2
    echo "       refusing to export a package - see docs/release.md" >&2
    exit 3
fi
echo

# ---- locate monkeyc ----
MONKEYC=${MONKEYC:-}
if [ -z "$MONKEYC" ] && command -v monkeyc >/dev/null 2>&1; then
    MONKEYC=$(command -v monkeyc)
fi
if [ -z "$MONKEYC" ]; then
    # The SDK Manager writes current-sdk.cfg to ~/.Garmin/ConnectIQ on
    # macOS/Linux and to %APPDATA%\Garmin\ConnectIQ on Windows. The Windows
    # copy holds a backslash path with a trailing separator, so normalise both
    # before testing for bin/monkeyc (#65).
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

# ---- export ----
OUT=${OUT:-dist/CarbBurn-${VERSION}.iq}
mkdir -p "$(dirname "$OUT")"
echo "monkeyc:  $MONKEYC"
echo "version:  $VERSION"
echo "key:      $KEY"
echo "output:   $OUT"
echo
echo "exporting $OUT (release build)"
"$MONKEYC" -e -r -w -f monkey.jungle -y "$KEY" -o "$OUT"
echo "done: $OUT"
echo "upload at https://apps.garmin.com/developer/upload"
echo "then tag the release:  git tag -a v$VERSION -m 'v$VERSION' && git push origin v$VERSION"
