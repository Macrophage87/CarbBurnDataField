#!/usr/bin/env python3
"""Render simulated screenshots of the Carb Burn data field.

Ports the physiology model and the two main layouts from
source/CarbBurnView.mc, replays a scripted 90-minute ride through the model
at 1 Hz (the same cadence as compute()), and draws:

  * simulated_field_small.png  -- the wide, short field (3 readouts side by
    side), as it appears in a multi-field ride screen slot.
  * simulated_field_large.png  -- the full-screen grid layout.

The sample rider matches the README: FTP 250 W, LT1 175 W, GE 21 %,
weight 75 kg, carb intake 60 g/h.

Usage:  python3 tools/simulate_fields.py [output_dir]
Requires: Pillow (pip install pillow).
"""

import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# ---------------------------------------------------------------------------
# Model constants (mirrors CarbBurnView.mc)
# ---------------------------------------------------------------------------
J_PER_KCAL = 4184.0
KCAL_PER_G = 4.0
KCAL_PER_G_FAT = 9.0
GLYCOGEN_G_PER_KG = 8.0
RATE_ALPHA = 0.10

# Garmin Graphics colour palette (Connect IQ constants)
COLOR_WHITE = (255, 255, 255)
COLOR_BLACK = (0, 0, 0)
COLOR_LT_GRAY = (170, 170, 170)
COLOR_DK_GRAY = (85, 85, 85)
COLOR_BLUE = (0, 170, 255)
COLOR_DK_BLUE = (0, 0, 255)
COLOR_GREEN = (0, 255, 0)
COLOR_DK_GREEN = (0, 170, 0)
COLOR_ORANGE = (255, 85, 0)
COLOR_RED = (255, 0, 0)

FONT_DIR = "/usr/share/fonts/truetype/dejavu"
SCALE = 3  # supersampling factor over device pixels


class CarbBurnModel:
    """The physiology model + accumulators from CarbBurnView.mc."""

    def __init__(self, ftp=250.0, lt1=175.0, ge=0.21, weight=75.0, carb_intake=60.0):
        self.ftp = ftp
        self.ge = ge
        self.weight = weight
        self.carb_intake = carb_intake

        lt1f = lt1 if 0 < lt1 < ftp else 0.70 * ftp
        span = max(ftp - lt1f, 1.0)
        # %CHO(LT1)=0.35, %CHO(FTP)=0.85 (same logit anchors as the device code)
        self.k = 2.3536 / span
        self.p50 = lt1f + 0.2631 * span

        # Fat-max power: peak of power * fatFraction (scan, like the device).
        p_max = max(int(ftp * 1.3), 60)
        best_p, best_score = 0, -1.0
        for pw in range(30, p_max + 1, 2):
            score = pw * (1.0 - self.cho_fraction(pw))
            if score > best_score:
                best_score, best_p = score, pw
        self.fat_max_w = best_p

        # Fueling equilibrium: first power where carb burn >= intake.
        eq_p = 0
        for pw in range(30, 601, 2):
            if self.carb_rate_at(pw) >= self.carb_intake:
                eq_p = pw
                break
        self.equil_w = eq_p if eq_p else 600

        # Colour-zone anchors: peak fat g/h and carb % at fat-max.
        self.fat_max_rate = ((1.0 - self.cho_fraction(self.fat_max_w))
                             * (self.fat_max_w / ge) / J_PER_KCAL * 3600.0 / KCAL_PER_G_FAT)
        self.pct_fat_max = self.cho_fraction(self.fat_max_w) * 100.0

        self.reset_session()

    def reset_session(self):
        self.model_kcal = 0.0
        self.model_carb_kcal = 0.0
        self.model_fat_kcal = 0.0
        self.total_sec = 0.0
        self.reset_lap()
        self.carb_rate = 0.0
        self.fat_rate = 0.0
        self.carb_pct_roll = 0.0
        self.power_roll = 0.0

    def reset_lap(self):
        self.lap_kcal = 0.0
        self.lap_carb_kcal = 0.0
        self.lap_fat_kcal = 0.0
        self.lap_sec = 0.0

    def cho_fraction(self, power):
        x = max(min(self.k * (power - self.p50), 30.0), -30.0)
        return 1.0 / (1.0 + math.exp(-x))

    def carb_rate_at(self, power):
        metabolic_w = power / self.ge
        return self.cho_fraction(power) * metabolic_w / J_PER_KCAL * 3600.0 / KCAL_PER_G

    def zone_color(self, grey, on_dark):
        """Zone colour from the displayed rolling values (no lag)."""
        if self.carb_pct_roll >= 90.0:
            return COLOR_RED
        if self.carb_pct_roll >= 50.0:
            return COLOR_ORANGE
        if self.fat_rate >= 0.90 * self.fat_max_rate:
            return COLOR_BLUE if on_dark else COLOR_DK_BLUE
        if self.carb_pct_roll >= self.pct_fat_max:
            return COLOR_GREEN if on_dark else COLOR_DK_GREEN
        return grey

    def compute(self, power, dt=1.0):
        """One compute() tick with the given current power (W)."""
        self.total_sec += dt
        self.lap_sec += dt
        if power and power > 0:
            metabolic_w = power / self.ge
            kcal = metabolic_w * dt / J_PER_KCAL
            frac = self.cho_fraction(power)

            self.model_kcal += kcal
            self.model_carb_kcal += kcal * frac
            self.model_fat_kcal += kcal * (1.0 - frac)
            self.lap_kcal += kcal
            self.lap_carb_kcal += kcal * frac
            self.lap_fat_kcal += kcal * (1.0 - frac)

            kcal_per_hr = metabolic_w / J_PER_KCAL * 3600.0
            inst_carb = frac * kcal_per_hr / KCAL_PER_G
            inst_fat = (1.0 - frac) * kcal_per_hr / KCAL_PER_G_FAT
            inst_pct = frac * 100.0
            self.carb_rate += RATE_ALPHA * (inst_carb - self.carb_rate)
            self.fat_rate += RATE_ALPHA * (inst_fat - self.fat_rate)
            self.carb_pct_roll += RATE_ALPHA * (inst_pct - self.carb_pct_roll)
            self.power_roll += RATE_ALPHA * (power - self.power_roll)
        else:
            self.carb_rate += RATE_ALPHA * (0.0 - self.carb_rate)
            self.fat_rate += RATE_ALPHA * (0.0 - self.fat_rate)
            self.power_roll += RATE_ALPHA * (0.0 - self.power_roll)

    # -- Display values (recon factor = 1.0: no Garmin calorie feed in sim) --
    @property
    def grams_cho(self):
        return self.model_carb_kcal / KCAL_PER_G

    @property
    def grams_fat(self):
        return self.model_fat_kcal / KCAL_PER_G_FAT

    @property
    def pct_cho(self):
        return self.model_carb_kcal / self.model_kcal * 100.0 if self.model_kcal > 0 else 0.0

    @property
    def glyc_pct(self):
        if self.weight <= 0:
            return 0.0
        return self.grams_cho / (self.weight * GLYCOGEN_G_PER_KG) * 100.0


def simulate_ride(model, seed=7):
    """A scripted 90-minute ride: warm-up, endurance, 4x3' VO2 intervals,
    tempo, and a final endurance stretch. Deterministic pseudo-noise so the
    output images are reproducible."""

    def noise(t):  # cheap deterministic +-12 W jitter
        return 12.0 * math.sin(0.9 * t + seed) * math.sin(0.13 * t + 2 * seed)

    segments = [
        (10 * 60, lambda t, f: 120 + 55 * f),          # warm-up 120 -> 175 W
        (20 * 60, lambda t, f: 185),                   # endurance
        # 4 x (3 min @ 265 W + 2 min @ 140 W)
        (20 * 60, lambda t, f: 265 if (t % 300) < 180 else 140),
        (25 * 60, lambda t, f: 215),                   # tempo
        (15 * 60, lambda t, f: 205),                   # steady to the line
    ]
    lap_marks = {10 * 60, 30 * 60, 50 * 60, 75 * 60}   # lap button presses

    elapsed = 0
    for dur, powfn in segments:
        for s in range(dur):
            if elapsed in lap_marks:
                model.reset_lap()
            f = s / max(dur - 1, 1)
            p = max(powfn(s, f) + noise(elapsed), 0.0)
            model.compute(p, 1.0)
            elapsed += 1
    return model


# ---------------------------------------------------------------------------
# Rendering (mirrors onUpdate / drawHorizontal / drawGrid)
# ---------------------------------------------------------------------------

def font(px, bold=False):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    return ImageFont.truetype(os.path.join(FONT_DIR, name), int(px * SCALE))


def text_h(fnt):
    a, d = fnt.getmetrics()
    return (a + d) / SCALE


def draw_text(dr, x, y, fnt, s, color, center=False):
    """drawText with Garmin semantics: y is the top of the glyph box."""
    xx, yy = x * SCALE, y * SCALE
    anchor = "ma" if center else "la"
    dr.text((xx, yy), s, font=fnt, fill=color, anchor=anchor)


# Approximate Garmin Edge font heights (device px)
F_XTINY = lambda: font(15)
F_TINY = lambda: font(17)
F_SMALL = lambda: font(23)
F_NUM_MILD = lambda: font(34, bold=True)
F_NUM_MEDIUM = lambda: font(46, bold=True)


def new_canvas(w, h, bg):
    img = Image.new("RGB", (w * SCALE, h * SCALE), bg)
    return img, ImageDraw.Draw(img)


def line(dr, x1, y1, x2, y2, color):
    dr.line([x1 * SCALE, y1 * SCALE, x2 * SCALE, y2 * SCALE],
            fill=color, width=max(SCALE // 2, 1))


def render_small(model, w=282, h=110, dark=True):
    """Field wider than tall: three readouts side by side (drawHorizontal)."""
    bg = COLOR_BLACK if dark else COLOR_WHITE
    fg = COLOR_WHITE if dark else COLOR_BLACK
    grey = COLOR_LT_GRAY if dark else COLOR_DK_GRAY
    zc = model.zone_color(grey, dark)

    img, dr = new_canvas(w, h, bg)

    labels = ["CARBS g", "CARB g/h", "CARB %"]
    values = ["%.0f" % model.grams_cho,
              "%.0f" % model.carb_rate,
              "%.0f" % model.carb_pct_roll]
    colors = [fg, zc, zc]

    n = 3
    col_w = w / n
    num_font = F_NUM_MEDIUM() if h >= 150 else (F_SMALL() if h < 60 else F_NUM_MILD())
    lbl_font = F_XTINY()
    lbl_h = text_h(lbl_font)
    val_h = text_h(num_font)
    top = max((h - (lbl_h + val_h)) / 2, 0)

    for d in range(1, n):
        line(dr, d * col_w, h * 0.18, d * col_w, h * 0.82, COLOR_LT_GRAY)

    for i in range(n):
        cx = i * col_w + col_w / 2
        draw_text(dr, cx, top, lbl_font, labels[i], fg, center=True)
        draw_text(dr, cx, top + lbl_h, num_font, values[i], colors[i], center=True)
    return img


def render_grid(model, w=282, h=470, dark=True):
    """Full-screen grid: 5 rows x (label + roll/lap/avg cells) (drawGrid)."""
    bg = COLOR_BLACK if dark else COLOR_WHITE
    fg = COLOR_WHITE if dark else COLOR_BLACK
    grey = COLOR_LT_GRAY if dark else COLOR_DK_GRAY
    zc = model.zone_color(grey, dark)

    img, dr = new_canvas(w, h, bg)

    ov_h = model.total_sec / 3600.0
    lap_h = model.lap_sec / 3600.0
    c_roll, f_roll = model.carb_rate, model.fat_rate
    c_lap = (model.lap_carb_kcal / KCAL_PER_G) / lap_h if lap_h > 0 else 0.0
    f_lap = (model.lap_fat_kcal / KCAL_PER_G_FAT) / lap_h if lap_h > 0 else 0.0
    c_avg = model.grams_cho / ov_h if ov_h > 0 else 0.0
    f_avg = model.grams_fat / ov_h if ov_h > 0 else 0.0
    p_lap = model.lap_carb_kcal / model.lap_kcal * 100.0 if model.lap_kcal > 0 else 0.0

    gly_tot = model.weight * GLYCOGEN_G_PER_KG
    gly_left = max(gly_tot - model.grams_cho, 0.0)
    gly_left_pct = gly_left / gly_tot * 100.0

    n_rows = 5
    row_h = h / n_rows
    left_w = w * 24 / 100
    cell_w = (w - left_w) / 3

    f_sub = F_XTINY()
    f_val = F_SMALL() if h >= 380 else F_TINY()
    f_row = F_TINY()
    sub_h = text_h(f_sub)
    val_h = text_h(f_val)
    row_lh = text_h(f_row)

    for r in range(1, n_rows):
        line(dr, 0, r * row_h, w, r * row_h, COLOR_LT_GRAY)
    for c in range(3):
        line(dr, left_w + c * cell_w, 0, left_w + c * cell_w, h, COLOR_LT_GRAY)

    eq_sub = "%.0fg eq" % model.carb_intake
    row_names = ["CARB/h", "FAT/h", "CARB%", "STORE", "PWR"]
    subs = [["roll", "lap", "avg"],
            ["roll", "lap", "avg"],
            ["roll", "lap", "avg"],
            ["carb g", "gly g", "gly %"],
            ["fatmax", "xover", eq_sub]]
    vals = [["%.0f" % c_roll, "%.0f" % c_lap, "%.0f" % c_avg],
            ["%.0f" % f_roll, "%.0f" % f_lap, "%.0f" % f_avg],
            ["%.0f" % model.carb_pct_roll, "%.0f" % p_lap, "%.0f" % model.pct_cho],
            ["%.0f" % model.grams_cho, "%.0f" % gly_left, "%.0f" % gly_left_pct],
            ["%d" % model.fat_max_w, "%.0f" % model.p50, "%d" % model.equil_w]]

    for row in range(n_rows):
        row_top = row * row_h
        draw_text(dr, 6, row_top + (row_h - row_lh) / 2, f_row, row_names[row], fg)
        block_top = row_top + (row_h - (sub_h + val_h)) / 2
        for c in range(3):
            cx = left_w + c * cell_w + cell_w / 2
            draw_text(dr, cx, block_top, f_sub, subs[row][c], fg, center=True)
            vcol = zc if (c == 0 and row in (0, 2)) else fg
            draw_text(dr, cx, block_top + sub_h, f_val, vals[row][c], vcol, center=True)
    return img


def frame(img, border=COLOR_DK_GRAY, pad=2):
    """A thin bezel line so the field edge is visible on any background."""
    w, h = img.size
    out = Image.new("RGB", (w + 2 * pad * SCALE, h + 2 * pad * SCALE), border)
    out.paste(img, (pad * SCALE, pad * SCALE))
    return out


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    model = CarbBurnModel()
    simulate_ride(model)

    print("--- simulated state after 90 min ---")
    print("rolling power  %.0f W" % model.power_roll)
    print("zone colour from rolling carb %% (%.0f) and fat g/h (%.0f vs peak %.0f)"
          % (model.carb_pct_roll, model.fat_rate, model.fat_max_rate))
    print("carbs total    %.0f g   fat total %.0f g" % (model.grams_cho, model.grams_fat))
    print("carb roll      %.0f g/h  fat roll  %.0f g/h" % (model.carb_rate, model.fat_rate))
    print("carb %% roll    %.0f     overall   %.0f" % (model.carb_pct_roll, model.pct_cho))
    print("fatmax %d W  xover %.0f W  equil %d W" % (model.fat_max_w, model.p50, model.equil_w))

    small = frame(render_small(model))
    large = frame(render_grid(model))
    small_path = os.path.join(out_dir, "simulated_field_small.png")
    large_path = os.path.join(out_dir, "simulated_field_large.png")
    small.save(small_path)
    large.save(large_path)
    print("wrote", small_path)
    print("wrote", large_path)


if __name__ == "__main__":
    main()
