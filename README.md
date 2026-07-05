# Carb Burn — Garmin Connect IQ Data Field

A cycling data field that estimates **carbohydrate (CHO) oxidation** live from power,
using your **FTP** and (optionally) **LT1 / aerobic threshold**.

The layout adapts to the field's shape:

- **Wide, short field** — the three core readouts side by side: **CARBS g** (total),
  **CARB g/h** and **CARB %**. The rate and the % are both *rolling* (smoothed on the
  same interval), so they rise and fall together.
- **In-between field** — a short vertical stack of the same values, plus **GLYCG %**
  (glycogen used) when body weight is set.
- **Full screen** — a grid showing, for **carb g/h**, **fat g/h** and **carb %**, the
  **rolling / lap-average / overall-average**; plus **carbs spent**, **glycogen left**
  (g and %), and the **fat-max** and **50% crossover** wattages.

### FIT recording

Cumulative **carbohydrate (g)** and **fat (g)** are written into the activity's
`.FIT` file — as per-record fields (a graphable time series) and as session totals
— so they're available in Garmin Connect and analysis tools after the ride. This
uses the `FitContributor` permission.

## How it works

1. **Power → metabolic energy.** `metabolic_watts = power / gross_efficiency`.
   Multiplying mechanical work by an (ideally individualized) gross efficiency is a
   validated way to estimate energy expenditure from a power meter.
2. **% CHO from power.** A logistic *crossover* curve anchored to your thresholds —
   about **35% CHO at LT1** and **85% CHO at FTP** — because fuel selection tracks
   relative intensity in a predictable way. Below LT1 you burn mostly fat; between
   LT1 and FTP the CHO share rises through the crossover; at/above FTP it is
   CHO-dominant.
3. **Grams.** Cumulative CHO kcal ÷ 4.0 kcal/g.

The %CHO fraction is applied *instantaneously* each second (so surges above FTP are
counted as more carb-heavy), then integrated over the ride.

### The model, illustrated

The charts below use a generic sample rider (FTP 250 W, LT1 175 W estimated, GE 21%).

**Energy share by power** — the carbohydrate/fat split. Carbs cross 50% of energy
at the crossover point (~195 W here), between LT1 and FTP:

![Substrate energy share vs power](carb_curve.png)

**Grams per hour by power** — the same model in absolute mass. Note that fat grams
peak in the moderate domain and then fall, while carbs climb steeply; by
mass the two fuels are equal at a *lower* power (~170 W) than the 50%-energy crossover,
because fat carries 9 kcal/g vs 4 kcal/g for carbohydrate:

![Carb and fat oxidation rate vs power](grams_curve.png)

A full derivation with citations is in **CarbBurn_WhitePaper.pdf**.

### If you have no LT1 test
Leave the **LT1** setting at `0`. The field estimates `LT1 ≈ 0.70 × FTP` and uses the
same curve, so it still works with FTP alone.

### About body weight
The power-based carb model **does not need your weight** — energy comes from
power ÷ gross efficiency. Weight is used for two secondary things:

1. **Garmin calorie cross-check.** Garmin's own cumulative calorie figure
   (`Activity.Info.calories`) is computed from your weight. When it's available the
   field rescales the *magnitude* of the carb numbers to agree with it — the
   carbohydrate/fat **split** always stays from the power model; only the total
   energy is reconciled. Set the weight here to match your Garmin user profile.
2. **Glycogen-store %.** Total body glycogen scales with body mass (~8 g/kg), so
   weight lets the field show carbs burned as a share of your stores.

Set weight to `0` to disable the glycogen readout.

## Settings (edit in Garmin Connect Mobile → the field's settings)

| Setting | Meaning | Default |
|---|---|---|
| FTP (watts) | Functional Threshold Power — required | 250 |
| LT1 / aerobic threshold (watts) | 0 = not tested (estimated from FTP) | 0 |
| Gross efficiency (%) | Trained cyclists ~19–24% | 21 |
| Body weight (kg) | Match your Garmin profile; 0 = disable glycogen readout | 75 |

## Build / install

1. Install the **Connect IQ SDK Manager**, the **VS Code Monkey C extension**, and a
   **JDK** (see the setup notes from earlier).
2. Open this folder in VS Code.
3. If the build complains about the application id, run **Monkey C: New Project** once
   to let the extension generate a fresh id, then copy these `source/` and `resources/`
   files and `manifest.xml` settings over — or just replace the `id="..."` in
   `manifest.xml` with your own 32-char hex GUID.
4. Generate a developer key if you don't have one: **Monkey C: Generate a Developer Key**.
5. **Monkey C: Build for Device** → produces a `.prg`. Copy it to
   `GARMIN/APPS/` on your device over USB, or run in the simulator
   (**Monkey C: Run App**, then Simulation → Data Fields).
6. On the device: add **Carb Burn** to a ride data screen. Give it a full-screen or
   half-screen slot so both numbers fit.

## Accuracy / caveats

This is a **population-calibrated estimate**, not a measurement. The fat↔CHO split
varies a lot between individuals with diet (esp. low-carb adaptation), training status,
sex, and body composition. For personal accuracy you'd calibrate gross efficiency and
the crossover anchors against a lab metabolic (RER) test. The two anchor percentages
live in `loadSettings()` in `source/CarbBurnView.mc` if you want to tune them.

## Files

```
manifest.xml                         app manifest (type = datafield)
monkey.jungle                        build config
source/CarbBurnApp.mc                app entry point
source/CarbBurnView.mc               the data field + physiology model
resources/settings/properties.xml    default setting values
resources/settings/settings.xml      Connect Mobile settings UI
resources/strings/strings.xml        display strings
resources/drawables/drawables.xml    launcher icon reference
resources/drawables/launcher_icon.png
CarbBurn_WhitePaper.pdf              technical white paper (derivation + citations)
carb_curve.png                       Figure 1 — energy share vs power
grams_curve.png                      Figure 2 — grams/hour vs power
```

## Author

**Stephen Cieply, PhD** — [@Macrophage87](https://github.com/Macrophage87)

Developed with assistance from Claude (Anthropic, Opus 4.8).

## License

Copyright © 2026 Stephen Cieply, PhD.

Released under the **MIT License** — you may use, copy, modify, and distribute this
software freely, including commercially, provided the copyright and permission notice
are retained. See [LICENSE](LICENSE) for the full text.
