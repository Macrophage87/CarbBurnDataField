# Continuous Integration

Carb Burn uses a **runner-free** GitHub Actions pipeline
([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)). Everything runs on
stock GitHub-hosted `ubuntu-latest`:

- **No self-hosted runner.**
- **No Garmin SDK download.** The Connect IQ SDK comes from running a pre-built
  Connect IQ Docker image as the job `container`
  (`ghcr.io/matco/connectiq-tester`, pinned by digest — `v2.8.0` = SDK 9.2.0).
- **No committed keys.** `monkeyc` needs a developer key even to compile, so each
  container job generates a *throwaway* RSA key in the workspace. It is never
  committed and is not a repo secret. A store-submittable `.iq` needs the
  account-bound key — that is a release step CI deliberately does **not** do.

## Jobs

| Job | Container? | Required? | What it does |
|---|---|---|---|
| `manifest-lint` | no | ✅ | Fails if a manifest app id is missing/placeholder/malformed, **if two manifests share an id**, or **if `manifest.xml`'s id is not the pinned registered literal**. A bad id still compiles and still passes tests, so only this check catches that store-rejection class. Invoked with **no arguments**, so it discovers `manifest.xml` + every `manifest.<variant>.xml` — an enumerated arg list is one somebody can quietly shorten. |
| `compile-unit-test` | yes | ✅ | Compiles a `--unit-test` build for **every** manifest device in one job (image pulls once). Fails only on a non-zero `monkeyc` exit; `-w` raises warnings but does not fail (the codebase is intentionally untyped, so no `-l 3`). |
| `release-build` | yes | ✅ | Release-compiles every device, **asserts every shipped `.prg` embeds the registered application id and not the beta one**, then exports the store `.iq`. For a `datafield`, `monkeyc` exits non-zero when the static image exceeds the target's data-field memory limit — so a non-zero exit **is** the memory-budget assertion. Uploads the per-device `.prg` + `.iq` as artifacts. |
| `beta-build` | yes | ✅ | The parallel-install **beta** variant (`beta.jungle` → `manifest.beta.xml`, separate application id): release-compiles every device, exports its `.iq`, then hexdumps each beta `.prg` to assert it embeds the **beta** application id and not the production one. Uploads `beta-artifacts`. |
| `run-tests` | — | not wired (measured) | Headless `(:test)` **execution** is not a CI job: with the constructor abort already fixed, `monkeydo` still timed out in this container (run `30129233091`, `rc=124`) — see below. The suite's **compilation** is gated regardless by `compile-unit-test` (13 devices). |
| `ci-required` | no | ✅ | Aggregator. Runs on every PR (`if: always()`) and **fails** unless every job in `needs` concluded `success` (iterates `toJSON(needs)`, so a skipped/cancelled/failed dep posts a real `failure`, not a skip). **This is the single status name to require in branch protection.** |
| `advisory-lint` | no | ⚠️ advisory | `continue-on-error`, out of `ci-required.needs`. Flags `System.println` / `TODO` / `FIXME` as annotations. Never blocks a merge. |

The **device matrix equals the manifest `<iq:products>` list** (13 devices:
`edge530 edge830 edge540 edge840 edge1030 edge1030plus edge1040 edge1050
edgeexplore2 fenix6pro fenix7 fenix8pro47mm fr955`). If you add or remove a
device in `manifest.xml`, update `env.DEVICES` in the workflow to match — **and
`manifest.beta.xml`**, which must declare the same products.

One direction of that is enforced rather than documented: `monkeyc` exits `102`
(`Target device id 'X' is not enabled in the application manifest file`) when
`-d` names a product the manifest omits — measured locally against SDK 9.2.0 —
so a product dropped from either manifest reds its per-device loop. The other
direction (a device dropped from `env.DEVICES`, silently narrowing the matrix)
is still unchecked; that is [#46](https://github.com/Macrophage87/CarbBurnDataField/issues/46).

## The beta variant

`manifest.beta.xml` / `beta.jungle` build the same source under a second
application id, so that the beta is *intended* to install **alongside**
production rather than replace it. (That, and the FIT-attribution consequence,
are design premises nobody has measured — #63 and #64.) CI treats it as a
first-class build regardless: `beta-build` is in `ci-required.needs`.

Why required rather than advisory: it satisfies the `needs` contract (no
job-level `if:`, so it runs on every PR and a skip is always a real fault), and
it is the **only** job that consumes `manifest.beta.xml` or `beta.jungle`. Left
advisory, those two files could break and still merge green, and a beta that
does not build cannot serve its purpose.

Cost, both halves: a third pull of the same pinned image and roughly one extra
container job of wall-clock per PR — **and** the fact that a broken beta, which
is unregistered and non-shippable, now blocks a production hotfix. That is the
price of the guarantee, and it is accepted deliberately rather than overlooked.

### The application-id guards

An XML diff proves a manifest file changed; it does not prove `monkeyc` consumed
it. `monkeyc` embeds the application id in the `.prg` as 16 raw bytes, so both
build jobs hexdump their artifacts and assert which id came out:

| Job | Asserts |
|---|---|
| `beta-build` | for each of `$DEVICES`, `bin/CarbBurn-Beta-<dev>.prg` exists and embeds the **beta** id, and **not** the production id |
| `release-build` | for each of `$DEVICES`, `bin/CarbBurn-<dev>.prg` exists and embeds the **registered** id, and **not** the beta id — checked **before** the store `.iq` is exported |

Both iterate `env.DEVICES` rather than globbing, so a missing artifact fails too
(a glob would silently assert over whatever happened to be there), and
`bin/CarbBurn-*.prg` cannot accidentally sweep in the beta artifacts.

**"Registered" is two checks composed — do not weaken either half.** The
`release-build` guard reads its expected value *out of `manifest.xml`*, so on
its own it asserts only that the artifact agrees with the manifest it was built
from. Measured: substitute a fabricated id into `manifest.xml` and `monkeyc`
still exits 0 and the guard still passes, printing the fabricated value under
`registered id:`. What makes the word *registered* true is the other half —
`manifest-lint` pins `manifest.xml`'s id to the literal
`EXPECTED_PRODUCTION_ID` in `scripts/check_manifest_appid.py`, so the id cannot
drift in the first place. Both jobs are in `ci-required.needs`.

That pin is not hypothetical insurance: `CHANGELOG.md` records "Restored the
registered application id" under 1.3, and `git log -S` places it at `9b3e238`
(changed) → `3e4ae5c` (restored). The class has occurred once here, under CI
that could not see it. The cost is that a genuine re-registration must edit two
files, which is the intent — `manifest.xml`'s own header says the id must never
change.

The `release-build` half is the one that matters most, and it exists because the
beta variant created the hole. With two manifests in the tree, a one-line
repoint of `monkey.jungle` at `manifest.beta.xml` compiles clean on all 13
devices, passes `manifest-lint`, leaves `beta-build` green, and exports a store
`.iq` under the **unregistered** beta id — against `manifest.xml`'s own "It must
never change, or store updates are rejected". Nothing else in this workflow
notices. The guard is placed before the export so a wrong id prevents the store
package from being produced at all.

Both steps are `sh` + coreutils on purpose — they do not assume the SDK
container ships `python3`.

**Known asymmetry:** on the beta side the `.iq` is exported *before* its guard
runs, the reverse of the release side, and the artifact upload is
`if: always()` — so a **red** `beta-build` can still publish a `beta-artifacts`
bundle whose `.iq` carries the wrong application id. Lower stakes than the
release side (that `.iq` is throwaway-key-signed, never submittable, and the
`.prg` is the sideload channel), but check the job status before installing
anything from a run. Tracked for reordering.

See the README for how to build and sideload the beta.

## Branch protection — must be set by a repo admin

The workflow only *posts* a status; it cannot *enforce* anything. A repository
admin must configure branch protection on `main`:

1. **Require the `ci-required` status check** (Settings → Branches → branch
   protection rule for `main` → *Require status checks to pass before merging*).
2. Enable **strict / "Require branches to be up to date before merging."**
3. **Disallow admin bypass** (do *not* tick "Allow administrators to bypass" /
   leave *Do not allow bypassing the above settings* enabled).
4. **Require `ci-required` only** — not the individual job names. Job names can
   change; `ci-required` is the stable contract.
5. **Retire any stale required check.** A required check name that no longer
   posts a status blocks *all* merges forever. If a previous CI check name was
   required, remove it from the required list once `ci-required` is in place.

> Why `ci-required` and not the individual jobs? GitHub treats a **skipped**
> required check as **passing**, so the aggregator does *not* rely on being
> skipped. It runs on every PR (`if: always()`) and **fails** unless every job
> in `needs` concluded `success` — a failed, skipped, or cancelled dependency
> makes `ci-required` post a real `failure`, which is what blocks the merge.
> Because the check iterates `needs`, the underlying jobs can evolve without
> touching branch protection, provided the contract below holds.
>
> **Contract:** every job added to `ci-required.needs` MUST run unconditionally
> on every PR (no job-level `if:`). The gate treats a skipped dependency as a
> failure, so a legitimately-skipped required job would wedge merges. If a
> genuinely conditional job is ever needed, switch the gate to an
> `alls-green`-style action with an explicit allowed-skips list (SHA-pinned).

## Bumping the SDK image

The SDK version is the Docker image digest. To move to a newer SDK (e.g. because
a new device product id isn't in SDK 9.2.0):

1. Find a newer `ghcr.io/matco/connectiq-tester` tag that ships the device.
2. Resolve its digest: `docker pull ghcr.io/matco/connectiq-tester:<tag>` then
   `docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/matco/connectiq-tester:<tag>`.
3. Replace **every** `container.image` value in `ci.yml` (currently three:
   `compile-unit-test`, `release-build` and `beta-build`) with the new `@sha256:...`, and update
   the `# vX.Y.Z = SDK ...` comment. The digest is the pin; the tag lives only in
   the comment. There is deliberately no `env` copy of the digest —
   `container.image` cannot read the `env` context, so an `env` entry would be a
   dead pin free to drift out of sync. If you re-add the `run-tests` stanza
   below, its image needs the same bump.

## Unit tests

The repo ships `(:test)` functions (`source/CarbBurnTest.mc`, the epic #22
rolling-metrics suite). Their **compilation is CI-gated**: `compile-unit-test`
builds `--unit-test` for all 13 devices on every PR (in `ci-required.needs`), so
a test that doesn't compile fails a required check.

**Headless execution is not wired — and we now know why, by measurement.**

The first two attempts at a `run-tests` job timed out: `monkeydo` launched the
simulator and never returned results. #28 found a more parsimonious explanation
than "the container is broken" — both of those runs executed a `.prg` in which
*every* test aborted in the view constructor, because each `new CarbBurnView()`
re-registered FIT developer-field ids 0–3, and `createField()` aborts
(uncatchably) on a duplicate id. Under `Xvfb`, with nobody to dismiss a fault
dialog, that presents as a hang.

**That hypothesis has now been tested and is insufficient.** The
`(:debug) class CbvTest` seam in `source/CarbBurnTest.mc` eliminates the abort
(the same seam produced 10/10 PASS on a developer machine, #28). The job was
re-wired here *with* the seam in place, and `monkeydo` **still** timed out with
no test output — run
[`30129233091`](https://github.com/Macrophage87/CarbBurnDataField/actions/runs/30129233091),
job `89599813195`, `rc=124`, head `acd3328`, `sim-run.log` uploaded and empty of
results.

**Conclusion: there are two independent problems.** The constructor abort (fixed)
and the container headless path (open, owned by #28). The job has been removed
again rather than left permanently red on every PR — it produced the finding it
was wired to produce. Re-wiring is a copy-paste from the stanza below the moment
#28 lands.

The tooling:

- [`scripts/run_ciq_tests.sh`](../scripts/run_ciq_tests.sh) — launches the
  simulator once under `Xvfb`, probes port `1234` for readiness, runs
  `monkeydo <prg> <device> -t` under a hard `timeout` (`SIGTERM` first, plus
  `stdbuf -oL` line-buffering, so a timeout **preserves** whatever was printed
  instead of discarding it in a 4 KB pipe buffer), tees to `sim-run.log`.
- [`scripts/check_ciq_tests.py`](../scripts/check_ciq_tests.py) — a **fail-closed**
  parser: passes only when `ran == passed`, `failed == 0`, `errors == 0`,
  `ran > 0`.

**Local run** (with the SDK installed): compile one device with `--unit-test`,
then `scripts/run_ciq_tests.sh bin/CarbBurn-test-<device>.prg <device>` and
`python3 scripts/check_ciq_tests.py sim-run.log`.

**To re-wire once #28 fixes the container path:** paste the stanza below into
`ci.yml`, keeping it a **separate** job from `compile-unit-test` so a simulator
flake can't mask a compile regression. Start as `continue-on-error` (out of
`ci-required.needs`); once it is shown to run reliably green, drop that and add
`run-tests` to `ci-required.needs` — the gate iterates `needs`, so that single
addition enforces it, provided the job runs unconditionally (no job-level `if:`).

```yaml
  run-tests:
    runs-on: ubuntu-latest
    continue-on-error: true
    timeout-minutes: 20
    container:
      image: ghcr.io/matco/connectiq-tester@sha256:7a6f586cb0e0393ff288da09cf27b6dad40a0058a346c529b99fd0fc19858f0f # v2.8.0 = SDK 9.2.0
    env:
      TEST_DEVICE: edge840   # one representative device; the (:test) suite is device-independent
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - name: Install headless-sim deps (guarded)
        run: |
          set -eu   # container image has no bash; steps run under dash - no pipefail
          need=""
          for p in bash xvfb x11-utils iproute2 procps openssl; do
            dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"
          done
          if [ -n "$need" ]; then apt-get update && apt-get install -y $need; fi
      - name: Generate throwaway developer key
        run: |
          set -eu
          openssl genrsa -out developer_key.pem 4096
          openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
      - name: Compile one device --unit-test
        run: |
          set -eu
          MONKEYC="$(command -v monkeyc || echo /connectiq/bin/monkeyc)"
          mkdir -p bin
          "$MONKEYC" -f monkey.jungle -o "bin/CarbBurn-test-$TEST_DEVICE.prg" \
            -y developer_key.der -d "$TEST_DEVICE" --unit-test -w
      - name: Run tests headlessly
        run: scripts/run_ciq_tests.sh "bin/CarbBurn-test-$TEST_DEVICE.prg" "$TEST_DEVICE"
      - name: Assert results (fail-closed)
        run: python3 scripts/check_ciq_tests.py sim-run.log
      - name: Upload simulator log
        if: always()
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: sim-run-log
          path: sim-run.log
          if-no-files-found: warn
```
