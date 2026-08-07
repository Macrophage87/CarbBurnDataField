#!/usr/bin/env python3
"""manifest-lint: validate the Connect IQ manifest application ids.

A bad application id still *compiles* and still *passes tests* - the SDK does
not care - but the Connect IQ Store rejects the upload (or, worse, silently
collides with another app / breaks FIT developer-data attribution). This check
catches that store-rejection class before it reaches a human reviewer.

It fails (non-zero exit) if a manifest app id is missing, malformed, or an
obvious placeholder. A registered id is a 32-character hex GUID with no dashes
(the format the SDK's "Generate a UUID" command produces).

The repo ships more than one manifest: manifest.xml (production, registered on
the store) and manifest.beta.xml (the parallel-install beta variant). Those two
ids MUST differ, because an application id is how Connect IQ identifies an
installed app - two entries sharing one id are one app, so the beta would
replace the production build rather than sit beside it. The variant's further
premise, that the two would then be attributed separately in a .FIT file, is
UNMEASURED here and is tracked as #64; it is not restated as fact. Either way,
identical ids defeat the purpose, so this check asserts that every validated
manifest carries a DISTINCT id.

Usage:
    scripts/check_manifest_appid.py                # discover every manifest
    scripts/check_manifest_appid.py manifest.xml   # validate exactly these

With NO arguments the manifest set is DISCOVERED from the repo root:
manifest.xml plus every manifest.<variant>.xml sibling. That is how CI invokes
it, deliberately - an enumerated argument list is a list somebody can quietly
shorten, and a dropped entry would take the distinctness assertion with it.
Adding a new manifest.<variant>.xml puts it under this check automatically.
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

CIQ_NS = "http://www.garmin.com/xml/connectiq"
APP_TYPES = {"datafield", "watchapp", "widget", "watchface", "audio-content-provider-app"}

# The production manifest. Discovery fails if it is missing, so nobody can
# weaken this check by deleting the file it is mainly about.
PRIMARY_MANIFEST = "manifest.xml"
VARIANT_GLOB = "manifest.*.xml"

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


def discover(root):
    """manifest.xml plus every manifest.<variant>.xml sibling, in stable order."""
    primary = root / PRIMARY_MANIFEST
    if not primary.is_file():
        fail(f"{primary}: production manifest not found")
    variants = sorted(p for p in root.glob(VARIANT_GLOB) if p.is_file())
    return [primary] + variants


def check_one(path):
    """Validate one manifest. Returns its application id; exits non-zero on fault."""
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

    print(f"OK: {path}: app id {app_id} (type={app_type}, {len(products)} devices)")
    print("     devices: " + ", ".join(products))
    return app_id


def check_distinct(ids_by_path):
    """Every manifest must carry its own application id."""
    seen = {}
    for path, app_id in ids_by_path:
        key = app_id.lower()
        if key in seen:
            fail(
                f"{path} and {seen[key]} share application id {app_id} - "
                "manifests must carry DISTINCT ids, or the variants are the same "
                "app to Connect IQ and one replaces the other on install"
            )
        seen[key] = path
    if len(seen) > 1:
        print(f"OK: {len(seen)} manifests, {len(seen)} distinct application ids")


def main():
    if len(sys.argv) > 1:
        paths = [Path(a) for a in sys.argv[1:]]
    else:
        paths = discover(Path(__file__).resolve().parent.parent)

    ids_by_path = [(path, check_one(path)) for path in paths]
    check_distinct(ids_by_path)
    sys.exit(0)


if __name__ == "__main__":
    main()
