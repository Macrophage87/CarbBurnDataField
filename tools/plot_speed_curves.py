#!/usr/bin/env python3
"""White-paper figure: speed vs power, and speed vs the carb readouts.

A rider watches speed, not watts. This figure translates the substrate model
onto the speed axis using a standard steady-state cycling power model on a flat,
windless road, so the abstract "carbs at X watts" becomes "carbs at X km/h".

Three rows (flat road; a 5% grade; and rough "Class 4" gravel, which roughly
quadruples rolling resistance) x three panels, speed (km/h) on the vertical
axis throughout:
  1. speed vs power (W)          -- the physical speed<->power relationship
  2. speed vs carb rate (g/h)    -- carbohydrate cost of a given speed
  3. speed vs carb % of energy   -- fuel mix at a given speed

Speed comes from the validated Martin et al. (1998) road-cycling power model
(J Appl Biomech 14(3):276, R^2 = 0.97):
    P = 0.5*rho*CdA*v^3 + Crr*m*g*cos(theta)*v + m*g*sin(theta)*v
Aerodynamic power scales with v^3 (drag force ~ v^2, power = force x velocity),
which is why speed flattens out as power rises. On the climb the constant
gravity term dominates, so speed is far lower and closer to linear in power.

Sample rider matches the other figures / the README: FTP 250 W, LT1 175 W,
GE 21 %. Typical physics (see PHYS below).

Output: speed_curves.png (matches carb_curve.png / grams_curve.png styling).
Usage:  python3 tools/plot_speed_curves.py [output_dir]
Requires: matplotlib. Reuses the physiology model from simulate_fields.py.
"""

import math
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from matplotlib.lines import Line2D

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from simulate_fields import (  # single source of truth for the model + palette
    CarbBurnModel, COLOR_DK_GRAY, COLOR_DK_BLUE, COLOR_DK_GREEN,
    COLOR_ORANGE, COLOR_RED)

# ---- Figure palette: white background (matches carb_curve.png / grams_curve.png) ----
FIG_BG = "white"
PANEL_BG = "#f0f0f0"
GRID = "white"
INK = "#333333"


def _rgb(c):
    return (c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)


MPH_PER_KMH = 0.621371


def _kmh_to_mph(x):
    return x * MPH_PER_KMH


def _mph_to_kmh(x):
    return x / MPH_PER_KMH


# The field's on-light zone colors (the darker variants zoneColor() uses on a
# white background), so they stay legible on this figure's white panels.
Z_GREY = _rgb(COLOR_DK_GRAY)
Z_BLUE = _rgb(COLOR_DK_BLUE)
Z_GREEN = _rgb(COLOR_DK_GREEN)
Z_ORANGE = _rgb(COLOR_ORANGE)
Z_RED = _rgb(COLOR_RED)

ZONES = [
    (Z_GREY,   "below fat-max band"),
    (Z_BLUE,   "fat-max band (fat g/h ≥ 95% of peak)"),
    (Z_GREEN,  "band top → 50% carb"),
    (Z_ORANGE, "50% → FTP (50–85% carb)"),
    (Z_RED,    "≥ FTP (≥ 85% carb)"),
]


def zone_color(m, watts):
    """The field's zoneColor() at a steady power (rolling == instantaneous).

    Red starts at FTP, i.e. the model's 85%-carb power (matches CarbBurnView)."""
    pct = m.cho_fraction(watts) * 100.0
    if pct >= 85.0:
        return Z_RED
    if pct >= 50.0:
        return Z_ORANGE
    fat_gh = (1.0 - m.cho_fraction(watts)) * (watts / m.ge) / 4184.0 * 3600.0 / 9.0
    if fat_gh >= 0.95 * m.fat_max_rate:
        return Z_BLUE
    if pct >= m.pct_fat_max:
        return Z_GREEN
    return Z_GREY

# ---- Typical steady-state cycling physics ----
PHYS = {
    "mass_kg": 83.0,       # 75 kg rider + 8 kg bike + kit
    "crr": 0.005,          # rolling resistance (good road tyres, tarmac)
    "cda": 0.32,           # drag area (hoods), m^2
    "rho": 1.225,          # air density at ~15 C, sea level, kg/m^3
    "eta": 0.97,           # drivetrain efficiency
    "g": 9.81,
}
CRR_GRAVEL = 0.020         # rough, minimally-maintained ("Class 4") gravel


def speed_from_power(watts, grade=0.0, crr=None, p=PHYS):
    """Invert the Martin et al. (1998) model for v (m/s), windless.

    P*eta = 0.5*rho*CdA*v^3 + Crr*m*g*cos(theta)*v + m*g*sin(theta)*v
    grade is rise/run (0.05 = 5%); theta = atan(grade). crr overrides the
    default rolling-resistance coefficient (e.g. gravel)."""
    if watts <= 0:
        return 0.0
    if crr is None:
        crr = p["crr"]
    theta = math.atan(grade)
    grav = p["mass_kg"] * p["g"] * math.sin(theta)          # gravity force (N)
    roll = crr * p["mass_kg"] * p["g"] * math.cos(theta)    # rolling force (N)
    lo, hi = 0.0, 30.0  # m/s (0 .. 108 km/h brackets any sane cycling power)
    for _ in range(60):  # bisection
        v = 0.5 * (lo + hi)
        p_pedal = (0.5 * p["rho"] * p["cda"] * v ** 3
                   + (roll + grav) * v) / p["eta"]
        if p_pedal > watts:
            hi = v
        else:
            lo = v
    return 0.5 * (lo + hi)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))
    m = CarbBurnModel()  # FTP 250, LT1 175, GE 21%

    # 100-300 W: the range a rider can hold for the extended durations where
    # cumulative substrate use actually matters.
    watts = list(range(100, 301, 1))
    carb_gh = [m.carb_rate_at(w) for w in watts]
    carb_pct = [m.cho_fraction(w) * 100.0 for w in watts]
    # Zone colors depend on power only, so they are shared across grades.
    seg_colors = [zone_color(m, w) for w in watts]

    # One row per surface/gradient condition; the carb axes are condition-
    # independent (they depend only on power), so only the speed mapping changes.
    # Each entry: (grade, crr, row label).
    conditions = [
        (0.0,  PHYS["crr"], "Flat road (0%)\nCrr 0.005"),
        (0.05, PHYS["crr"], "Climb (5% grade)\nCrr 0.005"),
        (0.0,  CRR_GRAVEL,  "Class 4 gravel (0%)\nCrr 0.020"),
    ]

    # Axes: each column shares one zero-based x scale; the speed (y) axis is free
    # but shared across the three panels within each row (fit per row below).
    columns = [
        ("Power (W)", watts, (100.0, 300.0)),
        ("Carbohydrate rate (g/h)", carb_gh,
         (0.0, math.ceil(max(carb_gh) / 20.0) * 20.0)),
        ("Carbohydrate energy share (%)", carb_pct, (0.0, 100.0)),
    ]
    col_titles = ["Speed vs power", "Speed vs carb rate", "Speed vs carb %"]

    fig, axes = plt.subplots(len(conditions), 3, figsize=(12.86, 16.4), dpi=100,
                             sharex="col", sharey="row")
    fig.patch.set_facecolor(FIG_BG)

    def style(ax):
        ax.set_facecolor(PANEL_BG)
        ax.grid(True, color=GRID, linewidth=0.9)
        ax.set_axisbelow(True)
        for s in ax.spines.values():
            s.set_color("#cccccc")
        ax.tick_params(colors=INK, labelsize=10)

    def zoned_line(ax, xs, ys):
        """Draw y-vs-x as segments colored by the power zone at each point."""
        pts = [((xs[i], ys[i]), (xs[i + 1], ys[i + 1])) for i in range(len(xs) - 1)]
        ax.add_collection(LineCollection(pts, colors=seg_colors[:-1], linewidths=3.0))

    last = len(conditions) - 1
    for row, (grade, crr, row_label) in enumerate(conditions):
        kmh = [speed_from_power(w, grade, crr) * 3.6 for w in watts]
        speed_at = lambda w, g=grade, c=crr: speed_from_power(w, g, c) * 3.6
        for col, (xlabel, xdata, _) in enumerate(columns):
            ax = axes[row][col]
            style(ax)
            zoned_line(ax, xdata, kmh)
            if row == 0:
                ax.set_title(col_titles[col], fontsize=13, color=INK, pad=8)
            if row == last:
                ax.set_xlabel(xlabel, fontsize=11, color=INK)
        axes[row][0].set_ylabel("%s\n\nSpeed (km/h)" % row_label,
                                fontsize=12, color=INK)
        # Free y, shared across this row: fit the row's own speed range.
        lo, hi = min(kmh), max(kmh)
        axes[row][0].set_ylim(lo - 1.0, hi + 1.0)
        # Secondary mph axis on the right of the row (synced to the km/h scale).
        secax = axes[row][2].secondary_yaxis(
            "right", functions=(_kmh_to_mph, _mph_to_kmh))
        secax.set_ylabel("Speed (mph)", fontsize=12, color=INK)
        secax.tick_params(colors=INK, labelsize=10)
        secax.spines["right"].set_color("#cccccc")
        for w, lbl in [(175, "LT1"), (250, "FTP")]:
            axes[row][0].axvline(w, color=INK, linewidth=0.9, linestyle=":", alpha=0.5)
            axes[row][0].annotate("%s  %d W\n%.0f km/h" % (lbl, w, speed_at(w)),
                                  xy=(w, speed_at(w)),
                                  xytext=(w - 8, speed_at(w) + 0.05 * (hi - lo)),
                                  ha="right", fontsize=8.5, color=INK)

    # Apply the shared x limits once (propagates via sharex="col").
    for col, (_, _, xlim) in enumerate(columns):
        axes[0][col].set_xlim(*xlim)

    fig.suptitle(
        "Substrate model on the speed axis  (sample rider: FTP 250 W, LT1 175 W, GE 21%)",
        fontsize=14, color=INK, y=0.997)
    handles = [Line2D([0], [0], color=c, linewidth=3.0, label=lbl)
               for c, lbl in ZONES]
    fig.legend(handles=handles, loc="lower center", ncol=5, frameon=False,
               fontsize=8.5, labelcolor=INK, bbox_to_anchor=(0.5, 0.02))
    phys_note = ("Windless; %.0f kg total, CdA %.2f m$^2$, drivetrain %.0f%%; "
                 "Crr 0.005 tarmac / %.3f gravel; Martin et al. (1998), "
                 "aero power $\\propto v^3$  ·  line color = the field's power zone"
                 % (PHYS["mass_kg"], PHYS["cda"], PHYS["eta"] * 100, CRR_GRAVEL))
    fig.text(0.5, 0.006, phys_note, ha="center", fontsize=8.5, color=INK, alpha=0.85)

    fig.tight_layout(rect=[0, 0.04, 1, 0.97])
    out = os.path.join(out_dir, "speed_curves.png")
    fig.savefig(out, facecolor=FIG_BG)
    print("wrote", out)
    # Sanity points per condition.
    for grade, crr, label in conditions:
        print(label.replace("\n", " "))
        for w in (100, 150, 200, 250, 300):
            print("  %3d W -> %5.1f km/h, %3.0f g/h carbs, %2.0f%% carb"
                  % (w, speed_from_power(w, grade, crr) * 3.6,
                     m.carb_rate_at(w), m.cho_fraction(w) * 100.0))


if __name__ == "__main__":
    main()
