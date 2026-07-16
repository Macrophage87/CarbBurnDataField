# Changelog

All notable changes to **Carb Burn** are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- **Speed-axis white-paper figure (Figure 3).** `tools/plot_speed_curves.py`
  renders `speed_curves.png`: speed vs power, speed vs carb rate, and speed vs
  carb %, over the 100–300 W range typical of long rides, for a flat road, a
  5% climb, and rough Class 4 gravel (Crr 0.020). Speed uses the validated
  Martin et al. (1998) power model (aero power ∝ v³). Each row auto-fits its own
  speed scale (shared across the row) with a secondary mph axis; the curves are
  colored by the field's power zones, with red starting at FTP. Shown in the
  README.

## [1.3] — 2026-07-08

### Changed

- **Red zone now starts at your FTP.** Red previously began at the 90%-carb power,
  which for most riders sits *above* FTP, so it rarely appeared. Red now begins at
  FTP (the model's 85%-carb power) and flags efforts above your one-hour power. For
  the generic sample rider (FTP 250 W) the orange band becomes 195–250 W and red is
  above 250 W (previously orange 195–265 W, red above 265 W).

### Fixed

- **Restored the registered application id.** A commit had changed the manifest's
  app id to a new GUID; it is back to the id this app is registered with on the
  Connect IQ store (required for store updates and correct FIT developer-data
  attribution).

## [1.2] — 2026-07-07

### Changed — color zones

- **The zone color can no longer lag the numbers.** The color of the rolling
  *carb g/h* and *carb %* readouts was previously driven by a separately smoothed
  power stream, so it could briefly disagree with the rolling carb % shown next to
  it. The color is now derived from the **same rolling values the field displays**:
  red at 90% or more rolling carb energy, orange at 50% or more.
- **The blue "fat-max band" is now defined by grams/hour, not watts.** Blue shows
  while the rolling fat oxidation rate is within **5%** of the modeled peak fat g/h
  — "you're burning fat at close to your maximum rate" — instead of a ±10% watts
  window around the fat-max power. Green covers the range between the top of the band
  and the 50%-carb crossover; grey sits below the band. For the generic sample rider
  (FTP 250 W, LT1 175 W) the steady-state boundaries are roughly: grey under 130 W,
  blue 130–173 W, green 173–195 W, orange 195–265 W, red above 265 W.
- **Better readability on light backgrounds.** The colored readouts use Garmin's
  darker blue and green palette entries (`COLOR_DK_BLUE`, `COLOR_DK_GREEN`) on white
  backgrounds; the bright variants are kept on black backgrounds where they read well.

### Changed — FIT recording

- **Per-record FIT fields now record rates, not totals.** The record-level developer
  fields are `carb_rate` and `fat_rate` in **g/h** (the reconciled rolling oxidation
  rates the field displays) instead of cumulative grams. A rate trace rises and falls
  with intensity and charts far better in Garmin Connect and intervals.icu. The
  session totals `total_carbohydrates` and `total_fat` (grams) are unchanged.

### Changed — display

- **Larger grid text on big screens.** On screens at least 550 px tall (e.g. Edge
  1050, 480×800) the full-screen grid uses `FONT_LARGE` values, `FONT_SMALL` row
  labels and `FONT_TINY` sub-labels instead of the small fonts sized for
  282×470-class devices.

### Added

- **One-command store export.** `tools/build_iq.sh` exports a signed release `.iq`
  package (into `dist/`) using the installed Connect IQ SDK, generating a developer
  key first if none exists.
- **Simulated screenshots.** `tools/simulate_fields.py` ports the physiology model
  and both main layouts to Python, replays a scripted 90-minute ride at 1 Hz, and
  renders `simulated_field_small.png` and `simulated_field_large.png`, shown in the
  README's "What it looks like" section.

## [1.0] — 2026-07-04

Initial release.

### Added

- Real-time **carbohydrate and fat oxidation** estimated from power, using FTP and
  (optional) LT1 via a logistic substrate-crossover model.
- **Adaptive layout** by field shape: three core readouts side by side on small/wide
  fields; a short vertical stack on medium fields; a full-screen grid on large fields.
- **Full-screen grid**: carb g/h, fat g/h and carb % as rolling / lap-average /
  overall-average; carbs spent; glycogen remaining (g and %); and the fat-max,
  50% crossover, and fueling-equilibrium wattages.
- **Rolling** carb g/h and carb % on a shared smoothing interval, with power-zone
  color coding.
- **Fueling-equilibrium power** (`carbIntake` setting) — the power where modeled carb
  burn equals your carb intake.
- **FIT recording** of carbohydrate and fat via FitContributor.
- Garmin **calorie cross-check** and body-weight **glycogen gauge**.
- Settings: FTP, LT1, gross efficiency, body weight, carb intake.
- Technical **white paper** (derivations + citations) and store assets.

Supported devices: Edge 530/830/540/840/1030/1030 Plus/1040/1050/Explore 2,
fēnix 6 Pro/7/8 Pro, Forerunner 955.
