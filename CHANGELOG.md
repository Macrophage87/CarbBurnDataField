# Changelog

Notable changes to the Carb Burn data field.

## [1.2] — 2026-07-07

### Changed — colour zones

- **The zone colour can no longer lag the numbers.** The colour of the rolling
  *carb g/h* and *carb %* readouts was previously driven by a separately
  smoothed power stream, so it could briefly disagree with the rolling carb %
  shown next to it. The colour is now derived from the **same rolling values
  the field displays**: red at 90% or more rolling carb energy, orange at 50%
  or more.
- **The blue "fat-max band" is now defined by grams/hour, not watts.** Blue
  shows while the rolling fat oxidation rate is within **5%** of the modelled
  peak fat g/h — i.e. "you are burning fat at close to your maximum rate" —
  instead of a ±10% watts window around the fat-max power. Green covers the
  range between the top of the band and the 50%-carb crossover; grey sits
  below the band. For the generic sample rider (FTP 250 W, LT1 175 W) the
  steady-state boundaries are now roughly: grey under 130 W, blue 130–173 W,
  green 173–195 W, orange 195–265 W, red above 265 W.
- **Better readability on light backgrounds.** The coloured readouts use
  Garmin's darker blue and green palette entries (`COLOR_DK_BLUE`,
  `COLOR_DK_GREEN`) on white backgrounds; the bright variants are kept on
  black backgrounds where they read well.

### Changed — FIT recording

- **Per-record FIT fields now record rates, not totals.** The record-level
  developer fields are `carb_rate` and `fat_rate` in **g/h** (the reconciled
  rolling oxidation rates the field displays) instead of cumulative grams.
  A rate trace rises and falls with intensity and charts far better in Garmin
  Connect and intervals.icu. The session totals `total_carbohydrates` and
  `total_fat` (grams) are unchanged. Field numbers stay 0/1 (record) and 2/3
  (session), so activities recorded with older versions keep their old
  cumulative traces without conflict.

### Changed — display

- **Larger grid text on big screens.** On screens at least 550 px tall (e.g.
  Edge 1050, 480×800) the full-screen grid uses `FONT_LARGE` values,
  `FONT_SMALL` row labels and `FONT_TINY` sub-labels instead of the small
  fonts sized for 282×470-class devices.

### Fixed

- **Real application GUID.** `manifest.xml` shipped with a placeholder id
  that Garmin recorded as an all-zeros application id in FIT developer data,
  leaving the custom fields unattributed. The manifest now carries a
  generated GUID (`dbdc6f97393446e69bd4d71b3be8605e`).

### Added

- **One-command store export.** `tools/build_iq.sh` exports a signed
  release `.iq` package (into `dist/`) using the installed Connect IQ SDK,
  generating a developer key first if none exists.
- **Simulated screenshots.** `tools/simulate_fields.py` ports the physiology
  model and both main layouts to Python, replays a scripted 90-minute ride
  (warm-up, endurance, 4×3-min VO2 intervals, tempo) at 1 Hz, and renders
  `simulated_field_small.png` (wide 3-column layout) and
  `simulated_field_large.png` (full-screen grid). Both images are shown in
  the README's new "What it looks like" section.

## Earlier

- Rolling carb g/h and carb % coloured by power zone; fueling-equilibrium
  power on the grid; red zone based on 90% carb fraction; grid layout with
  rolling / lap / average columns; FIT recording of carbohydrate and fat;
  colour-zone documentation in the README.
