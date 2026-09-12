#!/usr/bin/env python3
"""version-lint: assert the repo has ONE version, and that everything agrees.

The source of truth is the top-level ``VERSION`` file - one line, e.g. ``1.3``.
Nothing else in the tree may state a version independently; the two human-facing
records must *derive* from it and are checked here:

    VERSION              the version tools/build_iq.sh stamps on the package
    CHANGELOG.md         newest numbered "## [X.Y]" heading must equal VERSION
    store/changelog.txt  first line "Version X.Y - ..." must equal VERSION

``VERSION`` names the version of the package ``tools/build_iq.sh`` would produce
*right now*. Between releases that is the version already published, so the
release gate below refuses to build until it is bumped. That refusal is the
point: the defect this file exists to prevent is exporting a package labelled
with a version the store has already seen.

Two modes:

  (default)   consistency only. Safe to run on every push/PR - it is green on a
              tree that is merely between releases.
  --release   consistency AND the release gate: VERSION must be strictly greater
              than the newest ``v*`` tag that EXISTS. Red between releases, by
              design. tools/build_iq.sh runs this and refuses to export if it
              fails.

Which tags count, and why it is not simply ``git tag --list``:

    ``git tag --list`` answers "what does this checkout happen to have", which
    is a different question from "what has been released". A ``--no-tags``
    clone, a shallow clone, or a checkout that has not fetched since the last
    release all answer the first question confidently and the second one
    wrongly - and the wrong answer is a confident PASS that exports the
    already-published version. So when the repo has a remote, ``--release``
    reads that remote's tags with ``git ls-remote --tags`` and compares against
    the UNION of remote and local tags (a local tag not yet pushed is still a
    version that exists). If the remote exists but cannot be reached, the gate
    FAILS (exit 3); it never falls back to the local view. Only a repository
    with genuinely no remote is compared against local tags alone, and it says
    so on every line it prints.

Exit codes (distinct so a caller - and a differential - can tell them apart):

    0   all checks passed
    1   a consistency check failed (the three records disagree, or one is
        missing/malformed)
    2   the release gate failed (VERSION is not greater than the newest v* tag)
    3   usage or environment error (bad arguments; git unavailable, or the
        remote's tags unreadable, in --release)

Precedence when several fail: 3 beats 1 beats 2.

Usage:  scripts/check_version.py [--release] [ROOT]

ROOT defaults to the repository root (the parent of this script's directory).

NOTE: the repo has no regression harness for scripts/ (#70). The behaviours
below are proven by a mutation matrix run by hand and recorded in the PR that
added this file - a measurement, not a committed test. Nothing re-runs it.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

# A Connect IQ store version: two or three dot-separated numbers. "v" prefixes,
# pre-release suffixes and four-part versions are rejected on purpose - the one
# format has to be unambiguous or "the same version" stops being decidable.
VERSION_RE = re.compile(r"\A\d+\.\d+(?:\.\d+)?\Z")

# "## [1.3] - 2026-07-08" / "## [1.3]" ... and NOT "## [Unreleased]".
CHANGELOG_NUMBERED_RE = re.compile(r"\A##\s+\[(\d[0-9.]*)\]")
CHANGELOG_UNRELEASED_RE = re.compile(r"\A##\s+\[Unreleased\]", re.IGNORECASE)

# store/changelog.txt line 1: "Version 1.3 - What's new"
STORE_FIRST_LINE_RE = re.compile(r"\AVersion\s+(\d[0-9.]*)\b")

# Release tags. Anything else under refs/tags is reported and ignored.
TAG_RE = re.compile(r"\Av(\d+\.\d+(?:\.\d+)?)\Z")

# ls-remote talks to the network. A hung remote must fail the gate, not hang it.
GIT_TIMEOUT_S = 60

EXIT_OK = 0
EXIT_INCONSISTENT = 1
EXIT_GATE = 2
EXIT_USAGE = 3


def err(msg):
    """Emit one failure line, in both the Actions and the plain-text forms."""
    print(f"::error::version-lint: {msg}")
    print(f"FAIL: {msg}")


def note(msg):
    print(f"note: {msg}")


def sort_key(version):
    """Comparison key for a dotted version, with trailing zeros normalised.

    ``1.3`` and ``1.3.0`` compare equal, so "1.3.0" cannot sneak past a "must be
    greater than v1.3" gate. ``1.10`` sorts above ``1.9`` (numeric, not string).
    """
    parts = [int(p) for p in version.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def suggest_bump(version):
    """The obvious next minor version, for the actionable half of an error."""
    parts = [int(p) for p in version.split(".")]
    if len(parts) == 1:
        parts.append(0)
    return f"{parts[0]}.{parts[1] + 1}"


def read_text(path):
    """Read a text file, normalising CRLF. Returns None if unreadable."""
    try:
        return path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
    except OSError:
        return None


def load_version_file(root, failures):
    """The source of truth. Strict: exactly one line, exactly one version."""
    path = root / "VERSION"
    raw = read_text(path)
    if raw is None:
        failures.append(
            f"{path}: missing or unreadable - this file is the version source of truth"
        )
        return None
    lines = [ln for ln in raw.split("\n") if ln.strip()]
    if len(lines) != 1:
        failures.append(f"{path}: expected exactly one non-empty line, found {len(lines)}")
        return None
    version = lines[0].strip()
    if not VERSION_RE.match(version):
        failures.append(
            f"{path}: {version!r} is not a bare X.Y or X.Y.Z version "
            "(no 'v' prefix, no suffix)"
        )
        return None
    return version


def load_changelog(root, failures):
    """Newest numbered heading in CHANGELOG.md, plus every numbered heading.

    Also asserts the numbered headings descend strictly, and that
    ``## [Unreleased]`` (if present) sits above all of them. The old scrape in
    tools/build_iq.sh was ``... | head -1``, which silently trusts both.
    """
    path = root / "CHANGELOG.md"
    raw = read_text(path)
    if raw is None:
        failures.append(f"{path}: missing or unreadable")
        return None, []

    numbered = []          # [(lineno, version)]
    unreleased_lines = []  # [lineno]
    for lineno, line in enumerate(raw.split("\n"), 1):
        m = CHANGELOG_NUMBERED_RE.match(line)
        if m:
            numbered.append((lineno, m.group(1)))
            continue
        if CHANGELOG_UNRELEASED_RE.match(line):
            unreleased_lines.append(lineno)

    if not numbered:
        failures.append(f"{path}: no numbered '## [X.Y]' release heading found")
        return None, []

    for lineno, version in numbered:
        if not VERSION_RE.match(version):
            failures.append(
                f"{path}:{lineno}: heading version {version!r} is not X.Y or X.Y.Z"
            )

    for (prev_line, prev), (cur_line, cur) in zip(numbered, numbered[1:]):
        if sort_key(cur) >= sort_key(prev):
            failures.append(
                f"{path}:{cur_line}: heading [{cur}] is not below [{prev}] "
                f"(line {prev_line}) - release headings must descend strictly, "
                "because the newest one is read positionally"
            )

    first_numbered_line = numbered[0][0]
    for lineno in unreleased_lines:
        if lineno > first_numbered_line:
            failures.append(
                f"{path}:{lineno}: '## [Unreleased]' appears below the newest "
                f"release heading (line {first_numbered_line})"
            )

    return numbered[0][1], [v for _, v in numbered]


def load_store_changelog(root, failures):
    """Leading version of store/changelog.txt - the text pasted into the store."""
    path = root / "store" / "changelog.txt"
    raw = read_text(path)
    if raw is None:
        failures.append(f"{path}: missing or unreadable")
        return None
    first = raw.split("\n", 1)[0].strip()
    m = STORE_FIRST_LINE_RE.match(first)
    if not m:
        failures.append(
            f"{path}:1: first line {first!r} does not start "
            "'Version <X.Y> ...' - the store copy has no readable version"
        )
        return None
    return m.group(1)


def _git(root, *args, timeout=GIT_TIMEOUT_S):
    """Run a git command in ROOT. Raises on failure; the callers decide."""
    return subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True, text=True, check=True, timeout=timeout,
    ).stdout


def local_tags(root, env_failures):
    """Tags present in THIS checkout. None on failure (fails closed)."""
    try:
        out = _git(root, "tag", "--list")
    except (OSError, subprocess.SubprocessError) as exc:
        env_failures.append(
            f"could not list git tags in {root}: {exc}. Run the release from a "
            "git checkout."
        )
        return None
    return [t.strip() for t in out.split("\n") if t.strip()]


def pick_remote(root, env_failures):
    """The remote to consult: 'origin' if it exists, else the first one.

    Returns the remote name, or "" when the repo genuinely has no remote.
    None signals a hard failure.
    """
    try:
        out = _git(root, "remote")
    except (OSError, subprocess.SubprocessError) as exc:
        env_failures.append(f"could not list git remotes in {root}: {exc}")
        return None
    remotes = [r.strip() for r in out.split("\n") if r.strip()]
    if not remotes:
        return ""
    return "origin" if "origin" in remotes else remotes[0]


def remote_tags(root, remote, env_failures):
    """Tags on REMOTE, via ls-remote. None on failure - and failure is fatal.

    This is the whole point of B1: `git tag --list` answers "what does this
    checkout happen to have", which is not the same question as "what has been
    released". A shallow clone, a `--no-tags` clone, or a checkout that simply
    has not fetched since the last release all answer the first question
    confidently and the second one wrongly. So when a remote exists we ask it,
    and if we cannot reach it we refuse to release rather than quietly falling
    back to the local view.
    """
    try:
        out = _git(root, "ls-remote", "--tags", remote)
    except (OSError, subprocess.SubprocessError) as exc:
        env_failures.append(
            f"could not read tags from remote '{remote}': {exc}\n"
            "    The release gate must compare against the tags that actually "
            "exist, not\n"
            "    whatever this checkout happens to have fetched. Refusing to fall "
            "back to\n"
            "    local tags: a stale local tag set is exactly how a duplicate "
            "version ships.\n"
            "    Restore network/credentials for that remote and re-run."
        )
        return None
    tags = []
    for line in out.split("\n"):
        _, _, ref = line.partition("refs/tags/")
        ref = ref.strip()
        if not ref:
            continue
        tags.append(ref[:-3] if ref.endswith("^{}") else ref)   # peel annotated
    return tags


def collect_tags(root, env_failures):
    """(tags, provenance) for the gate. (None, None) => fail closed.

    ``provenance`` is printed on the success line, so a passing run always
    states what it actually compared against.
    """
    local = local_tags(root, env_failures)
    if local is None:
        return None, None
    remote = pick_remote(root, env_failures)
    if remote is None:
        return None, None
    if not remote:
        return set(local), "this checkout only - NO GIT REMOTE IS CONFIGURED"
    rtags = remote_tags(root, remote, env_failures)
    if rtags is None:
        return None, None
    # Union, not the remote alone: a tag created locally and not yet pushed is
    # still a version that exists, and must still block re-using it.
    return set(local) | set(rtags), f"this checkout + remote '{remote}' (ls-remote)"


def check_release_gate(root, version, gate_failures, env_failures):
    """VERSION must be strictly greater than every v* tag that exists."""
    tags, provenance = collect_tags(root, env_failures)
    if tags is None:
        return None, None

    releases = []
    ignored = []
    for tag in sorted(tags):
        m = TAG_RE.match(tag)
        if m:
            releases.append((sort_key(m.group(1)), m.group(1), tag))
        else:
            ignored.append(tag)
    if ignored:
        note(f"ignoring {len(ignored)} non-release tag(s): {', '.join(sorted(ignored))}")

    print(f"release tags compared against: {provenance}")
    if not releases:
        note("no v* release tags found - treating this as the first release")
        return [], provenance

    newest = max(releases)
    print(f"newest release tag: {newest[2]}  ({len(releases)} v* tag(s) total)")
    if sort_key(version) <= newest[0]:
        nxt = suggest_bump(newest[1])
        gate_failures.append(
            f"release gate: VERSION {version} is not greater than the newest "
            f"release tag {newest[2]}. A package built now would carry a version "
            "the store has already seen. Bump all three in one commit:\n"
            f"    VERSION              -> e.g. {nxt}\n"
            f"    CHANGELOG.md         -> add a '## [{nxt}]' section, dated, "
            "directly under [Unreleased]\n"
            f"    store/changelog.txt  -> first line 'Version {nxt} - What's new'"
            # Deliberately no dash character in the heading example: the repo's
            # headings use an em dash, but this string is printed to a console
            # and an em dash renders as '?' on a cp1252 Windows terminal.
        )
    return [r[1] for r in releases], provenance


def advise_tag_drift(changelog_versions, release_versions, current):
    """Advisory only - never fails the run.

    CHANGELOG headings and git tags already disagree on this repo's published
    history (#60: [1.2] exists with no v1.2 tag, and there is no [1.1] at all).
    Rewriting published history is out of scope, so this is reported, not
    enforced - a gate that is red on arrival gets switched off.

    ``current`` (the VERSION being released) is excluded: the gate *requires* it
    to have no tag yet, so listing it would be noise on every real release.
    """
    if release_versions is None:
        return
    tagged = {sort_key(v) for v in release_versions}
    logged = {sort_key(v) for v in changelog_versions}
    skip = {sort_key(current)} if current else set()
    untagged = [v for v in changelog_versions
                if sort_key(v) not in tagged and sort_key(v) not in skip]
    unlogged = [v for v in release_versions if sort_key(v) not in logged]
    if untagged:
        note("advisory (non-fatal): CHANGELOG release(s) with no matching v* tag: "
             + ", ".join(untagged))
    if unlogged:
        note("advisory (non-fatal): v* tag(s) with no CHANGELOG heading: "
             + ", ".join(unlogged))


def main():
    parser = argparse.ArgumentParser(
        description="Assert VERSION, CHANGELOG.md and store/changelog.txt agree.",
    )
    parser.add_argument(
        "--release", action="store_true",
        help="also assert VERSION is strictly greater than the newest v* git tag",
    )
    parser.add_argument(
        "root", nargs="?", default=None,
        help="repository root (default: the parent of scripts/)",
    )
    args = parser.parse_args()

    root = Path(args.root) if args.root else Path(__file__).resolve().parent.parent
    if not root.is_dir():
        err(f"{root}: not a directory")
        return EXIT_USAGE

    failures = []       # -> exit 1
    gate_failures = []  # -> exit 2
    env_failures = []   # -> exit 3

    version = load_version_file(root, failures)
    changelog_newest, changelog_all = load_changelog(root, failures)
    store_version = load_store_changelog(root, failures)

    if version is not None:
        if changelog_newest is not None and changelog_newest != version:
            failures.append(
                f"CHANGELOG.md newest release heading is [{changelog_newest}] but "
                f"VERSION says {version} - add a '## [{version}]' section (or fix "
                "VERSION); the two must be the same string"
            )
        if store_version is not None and store_version != version:
            failures.append(
                f"store/changelog.txt:1 says 'Version {store_version}' but VERSION "
                f"says {version} - the store copy would advertise the wrong release"
            )

    release_versions = None
    provenance = None
    if args.release and version is not None:
        release_versions, provenance = check_release_gate(
            root, version, gate_failures, env_failures)

    if version is not None:
        print(f"VERSION: {version}")
    if changelog_newest is not None:
        print(f"CHANGELOG.md newest release heading: [{changelog_newest}] "
              f"({len(changelog_all)} numbered heading(s))")
    if store_version is not None:
        print(f"store/changelog.txt: Version {store_version}")
    advise_tag_drift(changelog_all, release_versions, version)

    for msg in env_failures + failures + gate_failures:
        err(msg)

    if env_failures:
        return EXIT_USAGE
    if failures:
        return EXIT_INCONSISTENT
    if gate_failures:
        return EXIT_GATE

    if args.release:
        # State what was compared against, every time. The failure this file
        # exists to prevent once got past an unqualified "newer than every v*
        # tag" that was, in fact, false - it had only seen a stale local set.
        print(f"OK: {version} is consistent across VERSION, CHANGELOG.md and "
              f"store/changelog.txt, and is newer than every v* tag in "
              f"{provenance}")
        if provenance and "NO GIT REMOTE" in provenance:
            note("this repository has no remote, so no tag set could be "
                 "confirmed against a published one")
    else:
        print(f"OK: {version} is consistent across VERSION, CHANGELOG.md and "
              "store/changelog.txt")
        note("consistency only - the release gate (--release) was NOT run")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
