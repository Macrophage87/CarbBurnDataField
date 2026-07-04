using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Activity;
using Toybox.Application;
using Toybox.Math;
using Toybox.Lang;

//
// Carb Burn data field
// ---------------------
// Estimates carbohydrate (CHO) oxidation from cycling power and the athlete's
// LT1 (aerobic threshold) and FTP.
//
// Model
// 1) Power -> metabolic energy:  metabolic_watts = power / grossEfficiency.
// 2) %CHO from power: a logistic "crossover" curve anchored to the thresholds,
//    ~35% CHO at LT1 and ~85% CHO at FTP.
// 3) Grams CHO = cumulative CHO kcal / 4.0 kcal per gram.
//
// Body weight
// -----------
// The power-based carb model does NOT need body weight. Weight is used for two
// secondary things:
//   a) Garmin calorie cross-check. Garmin's own cumulative calorie figure
//      (Activity.Info.calories) is computed using the rider's weight. When it is
//      available we rescale our carb magnitude to agree with it (the substrate
//      SPLIT stays from the power model; only the total energy is reconciled).
//   b) Glycogen-store depletion %. Total body glycogen scales with body mass
//      (~8 g/kg), so weight lets us express carbs burned as a share of stores.
//
// Displayed readouts (small/short fields lay them out side by side; taller fields
// stack them and reveal extra rows). The unit is shown in each label:
//   CARBS g    total carbohydrate burned
//   FAT g      total fat burned                     (very large / full-screen only)
//   CARB g/h   current carb burn rate (smoothed)
//   CARB %     session-average share of energy from carbohydrate
//   GLYCG %    estimated glycogen stores used (needs body weight)
//   FATMAX W   power that maximises fat oxidation   (very large / full-screen only)
//
class CarbBurnView extends WatchUi.DataField {

    // ---- User settings ----
    private var mFtp;       // watts
    private var mGe;        // gross efficiency fraction (e.g. 0.21)
    private var mWeight;    // kg (0 => glycogen readout disabled)

    // ---- Derived logistic constants ----
    private var mK;         // steepness
    private var mP50;       // power at 50% CHO (crossover)
    private var mFatMaxW;   // power (W) that maximises fat oxidation rate

    // ---- Session accumulators (power model) ----
    private var mModelKcal;      // total metabolic kcal (power / GE)
    private var mModelCarbKcal;  // carb kcal
    private var mModelFatKcal;   // fat kcal
    private var mGarminKcal;     // Garmin cumulative calories, for cross-check
    private var mCarbRate;       // smoothed instantaneous carb rate, g/hr (model)
    private var mLastTimerMs;

    // ---- Display values ----
    private var mGramsCho;   // total carb grams (reconciled)
    private var mGramsFat;   // total fat grams (reconciled)
    private var mRateDisp;   // g/hr (reconciled)
    private var mPctCho;     // % from carb
    private var mGlycPct;    // % of glycogen stores used

    // ---- Constants ----
    private const E                = 2.718281828459045;
    private const J_PER_KCAL       = 4184.0;
    private const KCAL_PER_G       = 4.0;    // carbohydrate energy yield
    private const KCAL_PER_G_FAT   = 9.0;    // fat energy yield
    private const GLYCOGEN_G_PER_KG = 8.0;   // approx total body glycogen store
    private const RATE_ALPHA       = 0.10;   // EMA smoothing for g/hr

    function initialize() {
        DataField.initialize();
        mModelKcal     = 0.0;
        mModelCarbKcal = 0.0;
        mModelFatKcal  = 0.0;
        mGarminKcal    = 0.0;
        mCarbRate      = 0.0;
        mLastTimerMs   = 0;
        mGramsCho      = 0.0;
        mGramsFat      = 0.0;
        mRateDisp      = 0.0;
        mPctCho        = 0.0;
        mGlycPct       = 0.0;
        mFatMaxW       = 0;
        loadSettings();
    }

    function getProp(key, dflt) {
        var v = null;
        try {
            v = Application.Properties.getValue(key);
        } catch (ex) {
            var app = Application.getApp();
            if (app != null) {
                v = app.getProperty(key);
            }
        }
        return (v == null) ? dflt : v;
    }

    function loadSettings() {
        var ftp = getProp("ftp", 250);
        var lt1 = getProp("lt1", 0);
        var ge  = getProp("grossEfficiency", 21);
        var wt  = getProp("weight", 75);

        mFtp    = (ftp != null && ftp > 0) ? ftp.toFloat() : 250.0;
        mGe     = (ge  != null && ge >= 5) ? ge.toFloat() / 100.0 : 0.21;
        mWeight = (wt  != null && wt > 0)  ? wt.toFloat() : 0.0;

        var lt1f;
        if (lt1 != null && lt1 > 0 && lt1 < mFtp) {
            lt1f = lt1.toFloat();
        } else {
            lt1f = 0.70 * mFtp;   // FTP-only fallback
        }

        // %CHO(LT1)=0.35 (logit -0.6190), %CHO(FTP)=0.85 (logit 1.7346), span 2.3536
        var span = mFtp - lt1f;
        if (span < 1.0) { span = 1.0; }
        mK   = 2.3536 / span;
        mP50 = lt1f + 0.2631 * span;

        // Fat-max power: the wattage that maximises fat oxidation rate. Fat g/hr is
        // proportional to power * fatFraction = power * (1 - choFraction); there is no
        // closed form, so scan for the peak (cheap, only runs on settings load).
        var pMax = (mFtp * 1.3).toNumber();
        if (pMax < 60) { pMax = 60; }
        var bestP = 0;
        var bestScore = -1.0;
        for (var pw = 30; pw <= pMax; pw += 2) {
            var score = pw * (1.0 - choFraction(pw));
            if (score > bestScore) { bestScore = score; bestP = pw; }
        }
        mFatMaxW = bestP;
    }

    function onSettingsChanged() {
        loadSettings();
    }

    function choFraction(power) {
        var x = mK * (power - mP50);
        if (x >  30.0) { x =  30.0; }
        if (x < -30.0) { x = -30.0; }
        return 1.0 / (1.0 + Math.pow(E, -x));
    }

    function compute(info) {
        // dt from timerTime so pauses do not accumulate.
        var dt = 0.0;
        if (info != null && info.timerTime != null) {
            var t = info.timerTime;
            if (mLastTimerMs != 0 && t > mLastTimerMs) {
                dt = (t - mLastTimerMs) / 1000.0;
            }
            mLastTimerMs = t;
        }

        if (dt > 0.0) {
            if (info != null && info.currentPower != null && info.currentPower > 0) {
                var p          = info.currentPower.toFloat();
                var metabolicW = p / mGe;
                var kcal       = (metabolicW * dt) / J_PER_KCAL;
                var frac       = choFraction(p);

                mModelKcal     += kcal;
                mModelCarbKcal += kcal * frac;
                mModelFatKcal  += kcal * (1.0 - frac);

                // instantaneous carb rate in g/hr, then EMA-smoothed
                var instRate = frac * metabolicW / J_PER_KCAL * 3600.0 / KCAL_PER_G;
                mCarbRate = mCarbRate + RATE_ALPHA * (instRate - mCarbRate);
            } else {
                // coasting: decay the displayed rate toward zero
                mCarbRate = mCarbRate + RATE_ALPHA * (0.0 - mCarbRate);
            }
        }

        // Garmin cumulative calories (weight-aware) for the cross-check.
        if (info != null && info.calories != null && info.calories > 0) {
            mGarminKcal = info.calories.toFloat();
        }

        // Reconcile magnitude to Garmin's calorie total when available.
        var recon = 1.0;
        if (mGarminKcal > 0.0 && mModelKcal > 0.0) {
            recon = mGarminKcal / mModelKcal;
        }

        mGramsCho = mModelCarbKcal * recon / KCAL_PER_G;
        mGramsFat = mModelFatKcal * recon / KCAL_PER_G_FAT;
        mRateDisp = mCarbRate * recon;
        mPctCho   = (mModelKcal > 0.0) ? (mModelCarbKcal / mModelKcal * 100.0) : 0.0;
        mGlycPct  = (mWeight > 0.0)
                    ? (mGramsCho / (mWeight * GLYCOGEN_G_PER_KG) * 100.0)
                    : 0.0;
    }

    function onUpdate(dc) {
        var bg = getBackgroundColor();
        var fg = (bg == Graphics.COLOR_BLACK) ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;

        dc.setColor(bg, bg);
        dc.clear();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        var w = dc.getWidth();
        var h = dc.getHeight();

        // Numeric values only; the unit travels in the label, because the bold
        // FONT_NUMBER_* faces used for the figures contain no letter glyphs.
        var carbV = mGramsCho.format("%.0f");
        var fatV  = mGramsFat.format("%.0f");
        var rateV = mRateDisp.format("%.0f");
        var pctV  = mPctCho.format("%.0f");
        var glycV = mGlycPct.format("%.0f");
        var fmaxV = mFatMaxW.format("%d");

        // Build the readout set to match the field size. Very large (full-screen)
        // layouts add total fat grams and the fat-max power; taller layouts add the
        // glycogen readout (needs body weight).
        var labels;
        var values;
        if (h >= 200) {
            if (mWeight > 0.0) {
                labels = ["CARBS g", "FAT g", "CARB g/h", "CARB %", "GLYCG %", "FATMAX W"];
                values = [carbV, fatV, rateV, pctV, glycV, fmaxV];
            } else {
                labels = ["CARBS g", "FAT g", "CARB g/h", "CARB %", "FATMAX W"];
                values = [carbV, fatV, rateV, pctV, fmaxV];
            }
        } else if (h >= 130 && mWeight > 0.0) {
            labels = ["CARBS g", "CARB g/h", "CARB %", "GLYCG %"];
            values = [carbV, rateV, pctV, glycV];
        } else {
            labels = ["CARBS g", "CARB g/h", "CARB %"];
            values = [carbV, rateV, pctV];
        }

        var n = labels.size();

        // Small (short) fields lay the readouts out side by side; taller fields stack them.
        if (h < 130) {
            drawHorizontal(dc, fg, w, h, labels, values, n);
        } else {
            drawVertical(dc, w, h, labels, values, n);
        }
    }

    // Side-by-side columns, one readout per column (for small/short fields).
    function drawHorizontal(dc, fg, w, h, labels, values, n) {
        var colW = w / n;
        var numFont = (h >= 70) ? Graphics.FONT_NUMBER_MILD : Graphics.FONT_SMALL;

        // Faint dividers between columns.
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        for (var d = 1; d < n; d += 1) {
            dc.drawLine(d * colW, h * 0.18, d * colW, h * 0.82);
        }
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        for (var i = 0; i < n; i += 1) {
            var colCx = (i * colW) + (colW / 2);
            dc.drawText(colCx, h * 0.10, Graphics.FONT_XTINY,
                        labels[i], Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(colCx, h * 0.40, numFont,
                        values[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Stacked rows, one readout per row (for taller fields).
    function drawVertical(dc, w, h, labels, values, n) {
        var cx = w / 2;
        var rowH = h / n;
        var numFont = Graphics.FONT_NUMBER_MILD;
        if (rowH >= 72) { numFont = Graphics.FONT_NUMBER_MEDIUM; }
        if (rowH <  38) { numFont = Graphics.FONT_SMALL; }

        for (var i = 0; i < n; i += 1) {
            var yTop = i * rowH;
            dc.drawText(cx, yTop + rowH * 0.08, Graphics.FONT_XTINY,
                        labels[i], Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, yTop + rowH * 0.40, numFont,
                        values[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}
