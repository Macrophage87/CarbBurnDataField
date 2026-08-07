#!/usr/bin/env python3
"""manifest-lint: validate the Connect IQ manifest application ids.

A bad application id still *compiles* and still *passes tests* - the SDK does
not care - but the Connect IQ Store rejects the upload (or, worse, silently
collides with another app / breaks FIT developer-data attribution). This check
catches that store-rejection class before it reaches a human reviewer.

It fails (non-zero exit) if a manifest app id is missing, malformed, or an
obvious placeholder. A registered id is a 32-character hex GUID with no dashes
(the format the SDK's "Generate a UUID" command produces).

It also PINS the production id: manifest.xml must carry the literal
EXPECTED_PRODUCTION_ID below, so an edit to that id fails the lint rather than
sailing through every check in the repo. See the constant for why that is worth
two-place maintenance.

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

# ---------------------------------------------------------------------------
# THE PIN. This is the application id Carb Burn is REGISTERED with on the
# Connect IQ Store, written out as a literal on purpose.
#
# manifest.xml's own header says the id "must never change, or store updates are
# rejected and FIT developer-data attribution breaks". Until this pin existed,
# nothing enforced that. Every other check in this repo reads the expected value
# OUT OF manifest.xml - this script did, and so do both of the byte-level guards
# in .github/workflows/ci.yml - so they all assert SELF-CONSISTENCY: edit the id
# in manifest.xml and the lint, the compile and both guards stay green while the
# guard cheerfully prints the fabricated id under the label "registered id".
#
# It is not hypothetical. It has happened here once: 9b3e238 changed the app id
# to a different GUID and 3e4ae5c restored it, recorded in CHANGELOG.md under
# 1.3 as "Restored the registered application id". CI at the time could not see
# it, and without this constant it still could not.
#
# CONSEQUENCE, and it is the intent rather than an oversight: changing the
# registered id now requires editing TWO files. If you are reading this because
# the lint just failed, the overwhelmingly likely correct action is to restore
# manifest.xml, NOT to update this constant. Only change this line if the app
# has genuinely been re-registered on the store under a new id - which, per the
# manifest comment, should never happen.
#
# Deliberately NOT pinned: the beta variant's id in manifest.beta.xml. It is not
# registered anywhere by this project, so changing it costs nothing but a new
# parallel install - there is no external contract to protect. What the beta id
# must satisfy is that it DIFFERS from this one, which check_distinct() below
# enforces independently of this pin.
EXPECTED_PRODUCTION_ID = "b7e4c1a9f3d24e6cae10928f4c5d6a71"

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


def check_pinned(ids_by_path):
    """manifest.xml must still carry the REGISTERED application id.

    Applies only to the production manifest, matched by file name, so that
    passing manifest.beta.xml on its own does not drag the production pin along
    with it. Case-insensitive: a hex GUID is the same id in either case.
    """
    for path, app_id in ids_by_path:
        if Path(path).name != PRIMARY_MANIFEST:
            continue
        if app_id.lower() != EXPECTED_PRODUCTION_ID.lower():
            fail(
                f"{path}: app id {app_id} is not the REGISTERED production id "
                f"{EXPECTED_PRODUCTION_ID}. That id must never change - store "
                "updates are rejected and FIT developer-data attribution breaks "
                "(it happened once already: 9b3e238 changed it, 3e4ae5c restored "
                "it). Restore manifest.xml; only edit EXPECTED_PRODUCTION_ID in "
                "this script if the app has genuinely been re-registered."
            )
        print(f"OK: {path}: app id matches the pinned registered id")


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
    check_pinned(ids_by_path)
    check_distinct(ids_by_path)
    sys.exit(0)


if __name__ == "__main__":
    main()
