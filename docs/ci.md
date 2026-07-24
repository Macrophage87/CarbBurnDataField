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
| `run-tests` | — | not wired | Headless `(:test)` **execution** is not currently a CI job: `monkeydo` hangs in this container (launches the sim, never returns results). The `(:test)` suite's **compilation** is gated by `compile-unit-test` (all 13 devices). Execution helpers remain for local/future use — see below. |
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

## Unit tests

The repo ships `(:test)` functions (`source/CarbBurnTest.mc`, the epic #22
rolling-metrics suite). Their **compilation is CI-gated**: `compile-unit-test`
builds `--unit-test` for all 13 devices on every PR (in `ci-required.needs`), so
a test that doesn't compile fails a required check.

**Headless *execution* is not currently wired into CI.** A `run-tests` job was
attempted (`Xvfb` + the `connectiq` launcher + `monkeydo <prg> <device> -t`),
but `monkeydo` **hangs in the `connectiq-tester` container** — it launches the
simulator and never returns test results, hitting the hard `timeout`. Rather
than ship a check that is perpetually red (or misleadingly always-green), the
execution job is omitted until the headless-sim invocation is made reliable.

The tooling is in place for a local run (with the Connect IQ SDK) or for a
future fix:

- [`scripts/run_ciq_tests.sh`](../scripts/run_ciq_tests.sh) — launches the
  simulator once under `Xvfb`, probes port `1234` for readiness, runs
  `monkeydo <prg> <device> -t` under a hard `timeout`, tees to `sim-run.log`.
- [`scripts/check_ciq_tests.py`](../scripts/check_ciq_tests.py) — a **fail-closed**
  parser: passes only when `ran == passed`, `failed == 0`, `errors == 0`,
  `ran > 0`.

**To wire execution once the hang is resolved:** add a `run-tests` container job
that compiles one device `--unit-test`, runs `scripts/run_ciq_tests.sh`, then
`scripts/check_ciq_tests.py sim-run.log`; keep it a **separate** job from
`compile-unit-test`. Once it's shown to run reliably green, add `run-tests` to
`ci-required.needs` — the gate iterates `needs`, so that single addition
enforces it, provided the job runs unconditionally (no job-level `if:`).

The job definition lives in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
(`run-tests`). If the headless simulator proves flaky in practice, mark the job
`continue-on-error: true` (keeping it out of `ci-required.needs`) rather than
letting an unreliable check block merges.
