#!/usr/bin/env python3
"""manifest-lint: validate the Connect IQ manifest application id.

A bad application id still *compiles* and still *passes tests* - the SDK does
not care - but the Connect IQ Store rejects the upload (or, worse, silently
collides with another app / breaks FIT developer-data attribution). This check
catches that store-rejection class before it reaches a human reviewer.

It fails (non-zero exit) if the manifest app id is missing, malformed, or an
obvious placeholder. A registered id is a 32-character hex GUID with no dashes
(the format the SDK's "Generate a UUID" command produces).

Usage:  scripts/check_manifest_appid.py [manifest.xml]
"""

import re
import sys
import xml.etree.ElementTree as ET

CIQ_NS = "http://www.garmin.com/xml/connectiq"
APP_TYPES = {"datafield", "watchapp", "widget", "watchface", "audio-content-provider-app"}

# Ids that compile fine but must never ship: the all-zero / all-f fillers and a
# couple of well-known template placeholders.
PLACEHOLDER_IDS = {
    "00000000000000000000000000000000",
    "ffffffffffffffffffffffffffffffff",
    "12345678901234567890123456789012",
}


def fail(msg):
    print(f"::error::manifest-lint: {msg}")
    print(f"FAIL: {msg}")
    sys.exit(1)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "manifest.xml"

    try:
        tree = ET.parse(path)
    except (OSError, ET.ParseError) as exc:
        fail(f"could not parse {path}: {exc}")

    root = tree.getroot()
    app = root.find(f"{{{CIQ_NS}}}application")
    if app is None:
        # Fall back to a namespace-agnostic search in case the prefix differs.
        app = next((el for el in root.iter() if el.tag.endswith("application")), None)
    if app is None:
        fail(f"{path}: no <iq:application> element found")

    app_id = (app.get("id") or "").strip()
    app_type = (app.get("type") or "").strip()

    if not app_id:
        fail(f"{path}: <iq:application> has no id attribute")

    if not re.fullmatch(r"[0-9a-fA-F]{32}", app_id):
        fail(
            f"{path}: app id {app_id!r} is not a 32-char hex GUID "
            "(a registered Connect IQ id has 32 hex chars, no dashes)"
        )

    if app_id.lower() in PLACEHOLDER_IDS:
        fail(f"{path}: app id {app_id!r} is a placeholder - replace it with a registered GUID")

    if len(set(app_id.lower())) == 1:
        fail(f"{path}: app id {app_id!r} is a single repeated character - looks like a placeholder")

    # Advisory-ish structural sanity (still failed here because a broken type or
    # empty product list is also un-shippable).
    if app_type not in APP_TYPES:
        fail(f"{path}: application type {app_type!r} is not one of {sorted(APP_TYPES)}")

    products = [
        el.get("id")
        for el in app.iter()
        if el.tag.endswith("product") and el.get("id")
    ]
    if not products:
        fail(f"{path}: no <iq:product> devices declared")

    print(f"OK: app id {app_id} (type={app_type}, {len(products)} devices)")
    print("     devices: " + ", ".join(products))
    sys.exit(0)


if __name__ == "__main__":
    main()
