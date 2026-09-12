# Releasing Carb Burn

## The version source of truth is `VERSION`

One file, at the repo root, one line:

```
1.3
```

`VERSION` names the version that `tools/build_iq.sh` would stamp on a package
**right now**. Between releases that is the version already published, so the
release gate refuses to build until it is bumped. Everything else *derives* from
or is *checked against* it:

| Record | Relationship to `VERSION` | Checked by |
|---|---|---|
| `VERSION` | the source of truth | — |
| `CHANGELOG.md` | newest numbered `## [X.Y]` heading must be the same string | `scripts/check_version.py` |
| `store/changelog.txt` | first line `Version X.Y - ...` must be the same string | `scripts/check_version.py` |
| `dist/CarbBurn-<version>.iq` | filename is read from `VERSION` | `tools/build_iq.sh` |
| `v<version>` git tag | must be strictly *older* than `VERSION` at build time | `scripts/check_version.py --release` |

`manifest.xml` carries no app version. Structurally: the only `version`
attribute in the file is on `<iq:manifest>` (`manifest.xml:5`, `version="3"` —
the manifest format, shared by every Connect IQ app type), and
`<iq:application>` (`manifest.xml:6-11`) has `entry`, `id`, `launcherIcon`,
`minApiLevel`, `name` and `type` and nothing version-like. So the store version
is a field the developer supplies at upload — which is exactly why it needs a
checked-in source of truth to be derived from.

### Why a `VERSION` file and not "keep scraping `CHANGELOG.md`"

Both options were on the table in #60. The scrape lost on four counts:

1. **It makes prose load-bearing.** The release version was derived by
   `sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1` — a field
   the store uses to decide whether an upload is an update, read out of a
   markdown heading that every feature PR edits. `head -1` silently trusts file
   order, and the capture silently trusts the heading punctuation.
2. **The two existing records already disagree**, so trusting either alone is
   not an option: `CHANGELOG.md` has `[1.2]` with no `v1.2` tag, and no `[1.1]`
   section ever existed while tags jump `v1.0` → `v1.3`. Adding a third
   derivation off the same prose does not create a source of truth.
3. **Nothing in the tree stated the version as data.** Any consumer — this
   script, CI, a human — had to re-implement the same fragile scrape.
4. **The scrape-only variant's *release* assertion cannot run in CI.** #60
   proposes two checks for that variant: "the newest numbered heading is
   strictly greater than the newest `v*` git tag", and "the leading version in
   `store/changelog.txt` matches". Only the first is CI-hostile — it is *false
   on `main` between releases*, and a gate that is red on arrival gets switched
   off. **The second is perfectly CI-runnable and green on `main` today**, so
   this count is narrower than counts 1–3 and does not on its own decide the
   question.

Counts 1–3 are what actually decide it. Count 4 is a secondary observation, and
an earlier revision of this document overstated it as "its only assertion is
'newest heading > newest tag'" — that was false about #60's text and is
corrected here.

The cost is one extra file to bump. `scripts/check_version.py` prints all three
paths and the exact strings to change, so the bump is transcription.

A constant in `source/*.mc` was rejected too: it would be unreadable from shell
without a Monkey C parser, and would need a compile to inspect.

> **Current CI status, stated once so nothing in this file implies otherwise:
> no CI job runs `scripts/check_version.py`.** The consistency half *can* run on
> every PR — it is green on `main` and needs no container — but the wiring is
> deferred, for the reason and with the exact stanza in "Wiring the check into
> CI" below. Today the only thing that runs either half is
> `tools/build_iq.sh`, at release time.

## Cutting a release

1. Land the content. Make sure `CHANGELOG.md`'s `[Unreleased]` section actually
   describes what shipped (#55 tracks the current gap).
2. Bump, **in one commit**:
   - `VERSION` → `1.4`
   - `CHANGELOG.md` → rename `[Unreleased]` to `## [1.4] — YYYY-MM-DD` and open a
     fresh empty `## [Unreleased]` above it
   - `store/changelog.txt` → first line `Version 1.4 - What's new`, then the
     user-facing bullets
3. Verify: `python3 scripts/check_version.py --release .` → exit 0.
4. Export: `tools/build_iq.sh -y /path/to/developer_key.der`
   → `dist/CarbBurn-1.4.iq`. The script re-runs step 3 and refuses to build if it
   fails. There is no bypass flag.
5. Upload at <https://apps.garmin.com/developer/upload>, pasting
   `store/changelog.txt`.
6. Tag it: `git tag -a v1.4 -m 'v1.4' && git push origin v1.4`. The tag is what
   makes the *next* release's gate meaningful, so do not skip it — `v1.1` and
   `v1.2` were skipped and that is half of why #60 existed.

### The gate, precisely

`scripts/check_version.py` exit codes:

| Code | Meaning |
|---|---|
| 0 | all checks passed |
| 1 | consistency failure — `VERSION`, `CHANGELOG.md` and `store/changelog.txt` disagree, or one is missing/malformed |
| 2 | release gate failure — `VERSION` is not strictly greater than the newest `v*` tag |
| 3 | usage/environment failure — bad arguments, `git` unavailable, or the remote's tags unreadable, under `--release` |

`1.3` and `1.3.0` compare **equal**, so `1.3.0` cannot slip past a "greater than
`v1.3`" gate. `1.10` sorts above `1.9`. Tags that are not `v<X.Y[.Z]>` are listed
and ignored. With no `v*` tags at all the gate passes and says so — first
release.

`tools/build_iq.sh` flattens any non-zero from the checker to its own exit 3 and
prints the checker's code.

#### Which tags the gate compares against

`git tag --list` answers *"what does this checkout happen to have"*, which is a
different question from *"what has been released"*. A `--no-tags` clone, a
shallow clone, or a checkout that simply has not fetched since the last release
all answer the first question confidently and the second one **wrongly** — and
the wrong answer is a confident PASS that exports the already-published version.
An earlier revision of this mechanism did exactly that: with local tags reduced
to `v1.0` while `v1.3` existed on the remote, it printed `OK: 1.3 ... is newer
than every v* tag` and wrote `dist/CarbBurn-1.3.iq`, exit 0. That claim was not
vacuous, it was false.

So the gate establishes that its tag view is **current**, not merely present:

| Situation | What the gate does |
|---|---|
| a remote is configured (`origin`, else the first) | reads it with `git ls-remote --tags` and compares against the **union** of remote and local tags — a local tag not yet pushed is still a version that exists |
| the remote exists but cannot be reached (network, credentials, 60 s timeout) | **fails closed, exit 3.** It does *not* fall back to the local view |
| the repository genuinely has no remote | compares against local tags, and says `NO GIT REMOTE IS CONFIGURED` on the line that reports what it compared |
| no `.git` at all | fails closed, exit 3 |

Every `--release` run prints a `release tags compared against: …` line before the
verdict, and the `OK:` line names the same provenance. A success that cannot say
what it checked against is the failure mode this section exists to prevent.

**Consequence of "no bypass flag", worth knowing before step 6:** once you tag
`v1.4`, you can no longer re-export `1.4` — the gate will refuse until `VERSION`
moves again. Export and upload before tagging, or bump to `1.4.1`.

## Wiring the check into CI

**Not applied to `.github/workflows/ci.yml` in the PR that added this file** —
`ci.yml` is being rewritten by #66 and a conflict there costs more than the job
is worth. Paste this in once #66 lands. It is runner-free (no container, stdlib
Python only) and takes seconds.

Add the job:

```yaml
  # 1b) version-lint - runner-free. VERSION is the release version source of
  #     truth; this asserts CHANGELOG.md and store/changelog.txt agree with it.
  #     Deliberately NOT --release: that mode asserts VERSION is newer than the
  #     newest v* tag, which is false on main between releases by design.
  #     tools/build_iq.sh runs the --release mode at export time.
  version-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - name: Validate the version source of truth
        run: python3 scripts/check_version.py .
```

and add it to the aggregator's `needs` (the gate iterates `toJSON(needs)`, so
this is the whole wiring):

```yaml
  ci-required:
    runs-on: ubuntu-latest
    needs: [manifest-lint, version-lint, compile-unit-test, release-build]
```

`version-lint` runs unconditionally with no job-level `if:`, which is the
contract `ci-required` requires (`docs/ci.md`, "Contract").

> `actions/checkout` does **not** fetch tags by default. That is fine here
> because the CI job runs the default (non-`--release`) mode, which never looks
> at tags. A future `--release` job would want `with: { fetch-depth: 0 }` — but
> note it is no longer *load-bearing*: under a runner checkout `origin` is
> configured, so `--release` reads the remote's tags with `ls-remote` regardless
> of what was fetched, and fails closed if it cannot.

## Known drift, named rather than folded in

- **`README.md`, "Build / install" step 7** (at `42c4dbf` that was lines
  165–168; the line numbers move with every `README.md` edit, so the step is
  named rather than numbered here) still says `tools/build_iq.sh` runs with no
  arguments and generates a key if you have none. Both halves are now false: the
  key is required (#58) and the version comes from `VERSION` (#60). `README.md`
  is being edited by #37 and #66 concurrently, so the correction is filed as #77
  rather than made here. Replacement text for step 7:

  > 7. **Store release:** bump `VERSION`, `CHANGELOG.md` and
  >    `store/changelog.txt` together, then run
  >    `tools/build_iq.sh -y /path/to/developer_key.der` to export a signed
  >    `dist/CarbBurn-<version>.iq` and upload it at
  >    [apps.garmin.com/developer/upload](https://apps.garmin.com/developer/upload).
  >    The script refuses to build unless the three version records agree and the
  >    version is newer than the newest `v*` tag — see [docs/release.md](docs/release.md).
  >    The VS Code equivalent is **Monkey C: Export Project**.

- **`tools/build_iq.sh` and `tools/build_beta.sh` (#66) will want reconciling**
  once #66 lands. They now share fail-closed key handling and the two-location
  SDK discovery, arrived at independently rather than by copying an unmerged
  file. `build_beta.sh` still derives its version by scraping `CHANGELOG.md`; it
  should read `VERSION` instead. #71 tracks that `build_beta.sh` has no CI
  coverage at all.

- **No regression harness for `scripts/` (#70), and none for the build scripts
  (#71).** `scripts/check_version.py` and `tools/build_iq.sh` are proven by
  mutation matrices run by hand and recorded in their PR — measurements, not
  committed tests. Nothing re-runs them. A future edit that deletes an assertion
  leaves CI green, because the real tree has nothing for it to catch. Note both
  issues were filed about *other* files (`check_manifest_appid.py`,
  `build_beta.sh`); closing either as written would still leave these two
  uncovered.

- **The two matrices are exit-code differentials, and an exit code cannot
  distinguish a clean refusal from a crash.** Measured, not assumed: reverting
  the `VERSION`-format check makes `version_malformed[release]` exit 1 by
  `ValueError` out of `sort_key()` rather than by a check. The harness now flags
  any run that ends in a traceback; on `HEAD` there are none.

---
_Generated by [Claude Code](https://claude.ai/code)_
