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
| `manifest-lint` | no | ✅ | Fails if the manifest app id is missing/placeholder/malformed. A bad id still compiles and still passes tests, so only this check catches that store-rejection class. |
| `compile-unit-test` | yes | ✅ | Compiles a `--unit-test` build for **every** manifest device in one job (image pulls once). Fails only on a non-zero `monkeyc` exit; `-w` raises warnings but does not fail (the codebase is intentionally untyped, so no `-l 3`). |
| `release-build` | yes | ✅ | Release-compiles every device **and** exports the store `.iq`. For a `datafield`, `monkeyc` exits non-zero when the static image exceeds the target's data-field memory limit — so a non-zero exit **is** the memory-budget assertion. Uploads the per-device `.prg` + `.iq` as artifacts. |
| `ci-required` | no | ✅ | Aggregator. Runs on every PR (`if: always()`) and **fails** unless every job in `needs` concluded `success` (iterates `toJSON(needs)`, so a skipped/cancelled/failed dep posts a real `failure`, not a skip). **This is the single status name to require in branch protection.** |
| `advisory-lint` | no | ⚠️ advisory | `continue-on-error`, out of `ci-required.needs`. Flags `System.println` / `TODO` / `FIXME` as annotations. Never blocks a merge. |

The **device matrix equals the manifest `<iq:products>` list** (13 devices:
`edge530 edge830 edge540 edge840 edge1030 edge1030plus edge1040 edge1050
edgeexplore2 fenix6pro fenix7 fenix8pro47mm fr955`). If you add or remove a
device in `manifest.xml`, update `env.DEVICES` in the workflow to match.

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
3. Replace **both** `env.CIQ_IMAGE` and the two `container.image` values in
   `ci.yml` with the new `@sha256:...`, and update the `# vX.Y.Z = SDK ...`
   comment. The digest is the pin; the tag lives only in the comment.

## Running / enabling unit tests (`run-tests`)

This repo currently ships **no `(:test)` functions**, so there is nothing to
execute headlessly and the `run-tests` job is intentionally omitted from
`ci.yml`. The headless-simulator tooling is already in place for the moment
tests are added (and for running them locally):

- [`scripts/run_ciq_tests.sh`](../scripts/run_ciq_tests.sh) — launches the
  simulator once under `Xvfb`, probes port `1234` for readiness, runs
  `monkeydo <prg> <device> -t` under a hard `timeout`, and tees everything to
  `sim-run.log`. Belt-and-suspenders `pkill` at entry.
- [`scripts/check_ciq_tests.py`](../scripts/check_ciq_tests.py) — a **fail-closed**
  parser: it ignores the runner exit code and passes only when
  `ran == passed`, `failed == 0`, `errors == 0`, and `ran > 0`.

To enable `run-tests`:

1. Add one or more `(:test)` functions (e.g. `source/CarbBurnTest.mc`). Pure
   tests are device-independent, so a single representative device is enough.
2. Add the job below to `ci.yml`, and add `run-tests` to `ci-required.needs`.
   The `ci-required` gate iterates `needs`, so that single addition enforces it —
   no second edit. Per the contract above, `run-tests` must run **unconditionally**
   on every PR (no job-level `if:`); the gate treats a skip as a failure.
3. Keep it a **separate** job from `compile-unit-test` so a simulator flake
   can't mask a compile regression.

```yaml
  run-tests:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/matco/connectiq-tester@sha256:7a6f586cb0e0393ff288da09cf27b6dad40a0058a346c529b99fd0fc19858f0f # v2.8.0 = SDK 9.2.0
    env:
      TEST_DEVICE: edge840   # one representative device; pure tests are device-independent
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
          set -eu   # container image has no bash; steps run under dash - no pipefail
          openssl genrsa -out developer_key.pem 4096
          openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
      - name: Compile one device --unit-test
        run: |
          set -eu   # container image has no bash; steps run under dash - no pipefail
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

Until `run-tests` has been shown to reliably run **green** (a real RED/GREEN
differential against an added test), keep any headless "boot smoke" step
advisory (`continue-on-error`, out of `ci-required.needs`).
