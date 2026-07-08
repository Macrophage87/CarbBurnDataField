# Changelog

All notable changes to **Carb Burn** are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/).

## [1.0] — 2026-07-08

Initial Connect IQ Store release.

### Added
- Real-time **carbohydrate and fat oxidation** estimated from power, using FTP and
  (optional) LT1 via a logistic substrate-crossover model.
- **Adaptive layout** by field shape: three core readouts side by side on small/wide
  fields; a short vertical stack on medium fields; a full-screen grid on large fields.
- **Full-screen grid**: carb g/h, fat g/h and carb % as rolling / lap-average /
  overall-average; carbs spent; glycogen remaining (g and %); and the fat-max,
  50% crossover, and fueling-equilibrium wattages.
- **Rolling** carb g/h and carb % on a shared smoothing interval.
- **Power-zone color coding** of the rolling readouts: grey below the fat-max band,
  blue in the fat-max band (fat within 5% of peak), green to the 50% crossover,
  orange to FTP, red above FTP.
- **Fueling-equilibrium power** (`carbIntake` setting) — the power where modeled carb
  burn equals your carb intake; below it you spare glycogen, above it you deplete.
- **FIT recording** of cumulative carbohydrate and fat grams (per-record time series
  and session totals) via FitContributor.
- Garmin **calorie cross-check** and body-weight **glycogen gauge**.
- Settings: FTP, LT1, gross efficiency, body weight, carb intake.
- Technical **white paper** (derivations + citations) and store assets.

Supported devices: Edge 530/830/540/840/1030/1030 Plus/1040/1050/Explore 2,
fēnix 6 Pro/7/8 Pro, Forerunner 955.

[1.0]: https://github.com/Macrophage87/CarbBurnDataField/releases/tag/v1.0
