using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Activity;
using Toybox.Application;
using Toybox.Math;
using Toybox.Lang;
using Toybox.System;
using Toybox.FitContributor;

//
// Carb Burn data field
// ---------------------
// Estimates carbohydrate (CHO) and fat oxidation from cycling power and the
// athlete's LT1 (aerobic threshold) and FTP.
//
// Model
// 1) Power -> metabolic energy:  metabolic_watts = power / grossEfficiency.
// 2) %CHO from power: a logistic "crossover" curve anchored to the thresholds,
//    ~35% CHO at LT1 and ~85% CHO at FTP.
// 3) Grams CHO = cumulative CHO kcal / 4.0 kcal/g; grams fat / 9.0 kcal/g.
//
// Layout (chosen by field shape, resolution independent):
//   - Field WIDER than tall  -> 3 core readouts side by side (carbs g, carb g/h,
//     carb %). The carb g/h and carb % are BOTH rolling (same EMA interval).
//   - Full-screen field      -> a grid: for carb g/h, fat g/h and carb % it shows
//     rolling / lap-average / overall-average; plus carbs spent, glycogen left
//     (g and %), and the fat-max and 50% crossover wattages.
//   - In-between fields       -> a short vertical stack.
//
// FIT recording
//   The rolling carbohydrate and fat oxidation rates (g/h) are written to the
//   .FIT file as per-record fields (a graphable time series), and the
//   cumulative grams as session totals. Requires the FitContributor permission
//   (declared in the manifest).
//
class CarbBurnView extends WatchUi.DataField {

    // ---- User settings ----
    private var mFtp;       // watts
    private var mGe;        // gross efficiency fraction (e.g. 0.21)
    private var mWeight;    // kg (0 => glycogen readouts disabled)

    // ---- Derived logistic constants ----
    private var mK;         // steepness
    private var mP50;       // power at 50% CHO (crossover watts)
    private var mFatMaxW;   // power (W) that maximises fat oxidation rate
    private var mCarbIntake;// assumed carb intake during the ride, g/hr
    private var mEquilW;    // power (W) where carb oxidation == intake (fueling equilibrium)
    var mFatMaxRate;// peak fat oxidation rate (g/h) at fat-max power (not private: read by tests)
    private var mPctFatMax; // carb % of energy at fat-max power

    // ---- Session (overall) accumulators ---- (mModelKcal/mGarminKcal not private: tests drive reconFactor())
    var mModelKcal;      // total metabolic kcal (power / GE)
    private var mModelCarbKcal;  // carb kcal
    private var mModelFatKcal;   // fat kcal
    var mGarminKcal;     // Garmin cumulative calories, for cross-check
    private var mTotalSec;       // total timer seconds (moving)

    // ---- Lap accumulators (reset on lap) ----
    private var mLapKcal;
    private var mLapCarbKcal;
    private var mLapFatKcal;
    private var mLapSec;

    // ---- Rolling (EMA) values ---- (not private: read by the unit tests)
    var mCarbRate;   // carb g/hr, smoothed
    var mFatRate;    // fat g/hr, smoothed
    var mCarbPctRoll;// carb % of energy, smoothed
    var mRollN;      // active-sample count for EMA warm-up seeding (0 = unseeded)
    var mCoastSec;   // accumulated consecutive coast SECONDS (sustained-coast guard)

    private var mLastTimerMs;

    // ---- FIT file contributor fields ----
    private var mFitCarbRec;   // per-record rolling carb rate (g/h)
    private var mFitFatRec;    // per-record rolling fat rate (g/h)
    private var mFitCarbSes;   // session total carbs (g)
    private var mFitFatSes;    // session total fat (g)

    // ---- Display values (reconciled where relevant) ----
    private var mGramsCho;   // total carb grams
    private var mGramsFat;   // total fat grams
    // mRateDisp is not private: it is the exact value setFitData() clamps into
    // the carb_rate RECORD field, so the #59 tests pin it directly rather than
    // recomputing mCarbRate * reconFactor() beside the production expression
    // and pinning their own arithmetic.
    var mRateDisp;           // carb g/hr rolling (reconciled)
    private var mPctCho;     // overall carb %
    private var mGlycPct;    // % of glycogen stores used

    // ---- Constants ----
    private const E                = 2.718281828459045;
    private const J_PER_KCAL       = 4184.0;
    private const KCAL_PER_G       = 4.0;    // carbohydrate energy yield
    private const KCAL_PER_G_FAT   = 9.0;    // fat energy yield
    private const GLYCOGEN_G_PER_KG = 8.0;   // approx total body glycogen store
    private const RATE_ALPHA       = 0.10;   // EMA smoothing at dt=1 s (shared by rate + %)
    private const COAST_HOLD_S     = 3.0;    // coast SECONDS before the rolling % relaxes (dt-aware, like the rates)
    // Target the rolling carb % decays toward while coasting. Held at a literal
    // 0 rather than choFraction(0)*100: the latter is ~0.2% at typical settings
    // but reaches ~30% at extreme legal ones (ftp=600 / lt1=50), which would
    // stop a coast from ever relaxing out of the GREEN band.
    private const INST_PCT0        = 0.0;

    // ---- reconFactor() bounds (#59) ----
    // WIRED INERT IN THIS COMMIT. The shape below is the guard; these three
    // values are chosen so that it is a no-op over the whole reachable input
    // domain, so this commit is behaviour-preserving and the differentials that
    // follow are red against it. The values that close #59 land in a later
    // commit and touch nothing but this block.
    //
    // RECON_MIN_KCAL = 0.0 with the `> 0.0` division guard kept alongside it is
    //   exactly the pre-existing condition.
    // RECON_MAX = 1.0e30 is unreachable: mModelKcal is at least one sample's
    //   kcal = (power / GE) * dt / 4184 with power >= 1 W, GE >= 0.05
    //   (the floor loadSettings() accepts) and dt >= 0.001 s (timerTime is
    //   integer ms and compute() requires t > mLastTimerMs), i.e. >= 4.8e-6;
    //   mGarminKcal comes from a Number, so <= 2.1e9. The factor therefore
    //   cannot exceed ~4.5e14.
    // RECON_MIN = 0.0 is unreachable: inside the branch both operands are
    //   strictly positive, so the quotient is too.
    private const RECON_MIN_KCAL   = 0.0;
    private const RECON_MAX        = 1.0e30;
    private const RECON_MIN        = 0.0;

    function initialize() {
        DataField.initialize();
        resetSession();
        loadSettings();
        createFitFields();
    }

    // Register the custom FIT fields: per-record rolling oxidation rates (g/h,
    // a graphable time series) and per-session totals (g).
    //
    // !! SAFETY - registration is ONCE PER PROCESS. Never re-enter this.
    // createField() aborts with an UNCATCHABLE System Error if a developer
    // field id is registered twice in one process (observed under --unit-test:
    // the booted view already owned 0-3, so a second registration killed the
    // run - see #28). Garmin is ASSUMED to load a data field once and reuse the
    // instance across render contexts, so this is called exactly once - that is
    // unverified on hardware (#29 covers the two-screen case), and note the
    // unit-test harness demonstrably runs a second instance alongside the booted
    // one. onTimerReset() deliberately leaves the mFit* handles alone. Any future
    // lazy re-creation (`if (mFitCarbRec == null) { createFitFields(); }`) or
    // nulling of the handles on reset would therefore be a real, uncatchable
    // production crash on the first timer reset.
    //
    // !! The ids 0-3 below are FROZEN. Renumbering them splits the FIT series
    // for existing data consumers (Garmin Connect, intervals.icu).
    function createFitFields() {
        mFitCarbRec = createField("carb_rate", 0, FitContributor.DATA_TYPE_UINT16,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "g/h"});
        mFitFatRec  = createField("fat_rate", 1, FitContributor.DATA_TYPE_UINT16,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "g/h"});
        mFitCarbSes = createField("total_carbohydrates", 2, FitContributor.DATA_TYPE_UINT16,
            {:mesgType => FitContributor.MESG_TYPE_SESSION, :units => "g"});
        mFitFatSes  = createField("total_fat", 3, FitContributor.DATA_TYPE_UINT16,
            {:mesgType => FitContributor.MESG_TYPE_SESSION, :units => "g"});
        // Defensive null-guards, matching setFitData(). NOTE: the one failure
        // mode actually observed is an abort (above), which no null-check can
        // prevent; whether createField() ever *returns* null is still open
        // (#9), so these are precaution, not a proven-exercised path.
        if (mFitCarbRec != null) { mFitCarbRec.setData(0); }
        if (mFitFatRec  != null) { mFitFatRec.setData(0); }
        if (mFitCarbSes != null) { mFitCarbSes.setData(0); }
        if (mFitFatSes  != null) { mFitFatSes.setData(0); }
    }

    // Push the rolling rates (g/h) to the record fields and the cumulative
    // grams to the session fields (UINT16, clamped). All reconciled.
    function setFitData() {
        var recon = reconFactor();
        if (mFitCarbRec != null) { mFitCarbRec.setData(clampU16(mRateDisp)); }
        if (mFitFatRec  != null) { mFitFatRec.setData(clampU16(mFatRate * recon)); }
        if (mFitCarbSes != null) { mFitCarbSes.setData(clampU16(mGramsCho)); }
        if (mFitFatSes  != null) { mFitFatSes.setData(clampU16(mGramsFat)); }
    }

    function clampU16(x) {
        var v = (x + 0.5).toNumber();
        if (v < 0)     { v = 0; }
        if (v > 65535) { v = 65535; }
        return v;
    }

    // Zero every accumulator and display value (fresh start / timer reset).
    function resetSession() {
        mModelKcal     = 0.0;
        mModelCarbKcal = 0.0;
        mModelFatKcal  = 0.0;
        mGarminKcal    = 0.0;
        mTotalSec      = 0.0;
        resetLap();
        mCarbRate      = 0.0;
        mFatRate       = 0.0;
        mCarbPctRoll   = 0.0;
        mRollN         = 0;    // re-arm EMA warm-up on every session reset
        mCoastSec      = 0.0;  // and the sustained-coast guard (seconds)
        mLastTimerMs   = 0;
        mGramsCho      = 0.0;
        mGramsFat      = 0.0;
        mRateDisp      = 0.0;
        mPctCho        = 0.0;
        mGlycPct       = 0.0;
    }

    function resetLap() {
        mLapKcal     = 0.0;
        mLapCarbKcal = 0.0;
        mLapFatKcal  = 0.0;
        mLapSec      = 0.0;
    }

    // Framework hooks for lap / reset.
    function onTimerLap() {
        resetLap();
    }

    function onTimerReset() {
        resetSession();
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
        var ci  = getProp("carbIntake", 60);
        mCarbIntake = (ci != null && ci >= 0) ? ci.toFloat() : 60.0;

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

        // Fat-max power (peak of power * fatFraction); no closed form -> scan.
        var pMax = (mFtp * 1.3).toNumber();
        if (pMax < 60) { pMax = 60; }
        var bestP = 0;
        var bestScore = -1.0;
        for (var pw = 30; pw <= pMax; pw += 2) {
            var score = pw * (1.0 - choFraction(pw));
            if (score > bestScore) { bestScore = score; bestP = pw; }
        }
        mFatMaxW = bestP;

        // Fueling equilibrium: the power at which modelled carb oxidation equals the
        // assumed intake rate (carb burn rises monotonically with power, so the first
        // crossing is the answer). Below it you spare glycogen; above it you deplete.
        var eqP = 0;
        for (var pw2 = 30; pw2 <= 600; pw2 += 2) {
            if (carbRateAt(pw2) >= mCarbIntake) { eqP = pw2; break; }
        }
        if (eqP == 0) { eqP = 600; }   // intake exceeds burn even at 600 W
        mEquilW = eqP;

        // Color-zone anchors for the rolling carb readouts: the modelled peak
        // fat oxidation rate (g/h) and the carb energy share at fat-max.
        mFatMaxRate = (1.0 - choFraction(mFatMaxW))
                      * (mFatMaxW / mGe) / J_PER_KCAL * 3600.0 / KCAL_PER_G_FAT;
        mPctFatMax  = choFraction(mFatMaxW) * 100.0;
    }

    // Color for the rolling carb readouts, derived from the rolling values (so
    // the color never lags the numbers): red at >=85%
    // rolling carb energy (at/above FTP, the model's 85%-carb power), orange at
    // >=50%, blue while the rolling fat g/h is within 5% of the modelled peak
    // (the fat-max band), green between that band and the 50% crossover, grey
    // below the band. On light backgrounds the dark blue/green variants keep the
    // text readable.
    //
    // The RED/ORANGE/GREEN thresholds read mCarbPctRoll, which IS displayed.
    // The BLUE fat-max test compares un-reconciled mFatRate against the
    // un-reconciled model peak mFatMaxRate (#15 - reconciling one side only
    // widened the band); drawGrid() displays mFatRate * recon. Both sides of
    // the comparison are on one scale, so recon cancels and the boundary is
    // recon-invariant; mFatMaxRate itself is never rendered, so there is no
    // visible number/colour contradiction.
    function zoneColor(greyColor, onDark) {
        if (mCarbPctRoll >= 85.0) { return Graphics.COLOR_RED; }
        if (mCarbPctRoll >= 50.0) { return Graphics.COLOR_ORANGE; }
        // #15: compare both sides on the SAME (un-reconciled model) scale.
        // mFatMaxRate is the un-reconciled model peak; multiplying only the
        // left side by reconFactor() (typically >1) widened the band. Reconciling
        // both sides is algebraically identical (recon cancels), so drop it.
        if (mFatRate >= 0.95 * mFatMaxRate) {
            return onDark ? Graphics.COLOR_BLUE : Graphics.COLOR_DK_BLUE;
        }
        if (mCarbPctRoll >= mPctFatMax) {
            return onDark ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GREEN;
        }
        return greyColor;
    }

    // Modelled carbohydrate oxidation rate at a given power, g/hr.
    function carbRateAt(power) {
        var metabolicW = power / mGe;
        return choFraction(power) * metabolicW / J_PER_KCAL * 3600.0 / KCAL_PER_G;
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

    // #16: steady-state EMA alpha as a function of dt (seconds), so the
    // smoothing time constant is fixed in REAL time, not per-call. The weight
    // retained on the prior value is (1 - RATE_ALPHA)^dt (geometric decay). At
    // dt = 1 s this is exactly RATE_ALPHA - the dt == 1.0 fast-path avoids any
    // Math.pow round-off, so a strict-1 Hz device stays bit-identical to before;
    // a throttled cadence (dt > 1) smooths over the same wall-clock window.
    function steadyAlpha(dt) {
        if (dt == 1.0) { return RATE_ALPHA; }
        var a = 1.0 - Math.pow(1.0 - RATE_ALPHA, dt);
        if (a < 0.0) { a = 0.0; }
        if (a > 1.0) { a = 1.0; }
        return a;
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
            mTotalSec += dt;
            mLapSec   += dt;

            var aSteady = steadyAlpha(dt);   // #16: dt-aware steady EMA alpha

            if (info != null && info.currentPower != null && info.currentPower > 0) {
                var p          = info.currentPower.toFloat();
                var metabolicW = p / mGe;
                var kcal       = (metabolicW * dt) / J_PER_KCAL;
                var frac       = choFraction(p);

                mModelKcal     += kcal;
                mModelCarbKcal += kcal * frac;
                mModelFatKcal  += kcal * (1.0 - frac);

                mLapKcal     += kcal;
                mLapCarbKcal += kcal * frac;
                mLapFatKcal  += kcal * (1.0 - frac);

                // #8 warm-up: seed the EMA to the first active sample (alpha 1.0
                // at n=1), relaxing to the dt-aware steady alpha by n>=10 - so
                // the rolling rates (and the FIT records) don't ramp up from 0
                // over the first ~20-30 s of every session. Float division.
                mRollN += 1;
                mCoastSec = 0.0;
                var a = aSteady;
                var warm = 1.0 / mRollN;
                if (warm > a) { a = warm; }

                // Rolling rates (g/hr) and carb %, all on the same EMA interval.
                var kcalPerHr  = metabolicW / J_PER_KCAL * 3600.0;
                var instCarb   = frac * kcalPerHr / KCAL_PER_G;
                var instFat    = (1.0 - frac) * kcalPerHr / KCAL_PER_G_FAT;
                var instPct    = frac * 100.0;
                mCarbRate    = mCarbRate    + a * (instCarb - mCarbRate);
                mFatRate     = mFatRate     + a * (instFat  - mFatRate);
                mCarbPctRoll = mCarbPctRoll + a * (instPct  - mCarbPctRoll);
            } else {
                // Coasting: decay the rolling rates toward zero on the steady
                // (dt-aware) alpha - NOT the warm-up alpha (mRollN untouched).
                // #7: also relax the rolling carb % in lockstep so it can't stay
                // frozen high next to a ~0 rate (contradictory RED at 0 g/h) -
                // but only after COAST_HOLD_S seconds of coasting, so a brief
                // power-meter dropout doesn't move the RED/ORANGE zones (both
                // keyed off mCarbPctRoll).
                //
                // The hold accumulates SECONDS, not samples, so that it stays
                // consistent with the dt-aware rate decay above. A sample-count
                // hold would decouple from it whenever dt != 1: one long sample
                // (say dt=300) snaps the rates to ~0 via aSteady~=1 while a
                // count of 1 would still hold the %, re-creating exactly the
                // "RED at 0 g/h" state this block exists to remove. In seconds,
                // that same sample also satisfies the hold, so both halves move
                // together. At a steady 1 Hz the behaviour is unchanged (the
                // 3rd consecutive coast sample crosses 3.0 s).
                //
                // Note the hold does NOT cover the BLUE fat-max band, which
                // keys off mFatRate - that decays from the first coast sample,
                // so a single dropout can drop out of BLUE.
                mCoastSec += dt;
                mCarbRate = mCarbRate + aSteady * (0.0 - mCarbRate);
                mFatRate  = mFatRate  + aSteady * (0.0 - mFatRate);
                if (mCoastSec >= COAST_HOLD_S) {
                    mCarbPctRoll = mCarbPctRoll + aSteady * (INST_PCT0 - mCarbPctRoll);
                }
            }
        }

        // Garmin cumulative calories (weight-aware) for the cross-check.
        if (info != null && info.calories != null && info.calories > 0) {
            mGarminKcal = info.calories.toFloat();
        }

        var recon = reconFactor();
        mGramsCho = mModelCarbKcal * recon / KCAL_PER_G;
        mGramsFat = mModelFatKcal * recon / KCAL_PER_G_FAT;
        mRateDisp = mCarbRate * recon;
        mPctCho   = (mModelKcal > 0.0) ? (mModelCarbKcal / mModelKcal * 100.0) : 0.0;
        mGlycPct  = (mWeight > 0.0)
                    ? (mGramsCho / (mWeight * GLYCOGEN_G_PER_KG) * 100.0)
                    : 0.0;

        setFitData();
    }

    // Rescale magnitude to Garmin's calorie total when available (else 1.0).
    //
    // The `mModelKcal > 0.0` clause is the DIVISION guard and stays whatever
    // RECON_MIN_KCAL is set to; the `>= RECON_MIN_KCAL` clause is the
    // minimum-denominator floor and is a separate concern. With
    // RECON_MIN_KCAL = 0.0 the second clause is implied by the first, which is
    // what makes this commit behaviour-preserving.
    function reconFactor() {
        if (mGarminKcal > 0.0 && mModelKcal > 0.0 && mModelKcal >= RECON_MIN_KCAL) {
            var r = mGarminKcal / mModelKcal;
            if (r > RECON_MAX) { r = RECON_MAX; }
            if (r < RECON_MIN) { r = RECON_MIN; }
            return r;
        }
        return 1.0;
    }

    function onUpdate(dc) {
        var bg = getBackgroundColor();
        var onDark = (bg == Graphics.COLOR_BLACK);
        var fg = onDark ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        var grey = onDark ? Graphics.COLOR_LT_GRAY : Graphics.COLOR_DK_GRAY;
        var zc = zoneColor(grey, onDark);

        dc.setColor(bg, bg);
        dc.clear();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        var w = dc.getWidth();
        var h = dc.getHeight();

        // Field WIDER than tall: three core readouts side by side. Carb g/h and
        // carb % are rolling and colored by the current power zone.
        if (w > h) {
            var hl = ["CARBS g", "CARB g/h", "CARB %"];
            var hv = [ mGramsCho.format("%.0f"),
                       mRateDisp.format("%.0f"),
                       mCarbPctRoll.format("%.0f") ];
            drawHorizontal(dc, fg, w, h, hl, hv, [fg, zc, zc], 3);
            return;
        }

        var scrH = System.getDeviceSettings().screenHeight;
        var frac = (scrH != null && scrH > 0) ? (h.toFloat() / scrH.toFloat()) : 1.0;

        // Full-screen field with room for columns: the grid.
        if (frac >= 0.70 && w >= 200) {
            drawGrid(dc, fg, zc, w, h);
            return;
        }

        // Otherwise a short vertical stack (carb g/h and carb % are rolling +
        // color-coded).
        var labels;
        var values;
        var colors;
        if (frac >= 0.38 && mWeight > 0.0) {
            labels = ["CARBS g", "CARB g/h", "CARB %", "GLYCG %"];
            values = [ mGramsCho.format("%.0f"), mRateDisp.format("%.0f"),
                       mCarbPctRoll.format("%.0f"), mGlycPct.format("%.0f") ];
            colors = [fg, zc, zc, fg];
        } else {
            labels = ["CARBS g", "CARB g/h", "CARB %"];
            values = [ mGramsCho.format("%.0f"), mRateDisp.format("%.0f"),
                       mCarbPctRoll.format("%.0f") ];
            colors = [fg, zc, zc];
        }
        drawVertical(dc, fg, w, h, labels, values, colors, labels.size());
    }

    // Side-by-side columns, one readout per column (fields wider than tall).
    // colors[i] is the color for value i (labels stay in fg).
    function drawHorizontal(dc, fg, w, h, labels, values, colors, n) {
        var colW = w / n;
        var numFont = Graphics.FONT_NUMBER_MILD;
        if (h >= 150) { numFont = Graphics.FONT_NUMBER_MEDIUM; }
        if (h <  60)  { numFont = Graphics.FONT_SMALL; }

        var lblH = dc.getFontHeight(Graphics.FONT_XTINY);
        var valH = dc.getFontHeight(numFont);
        var top  = (h - (lblH + valH)) / 2;
        if (top < 0) { top = 0; }

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        for (var d = 1; d < n; d += 1) {
            dc.drawLine(d * colW, h * 0.18, d * colW, h * 0.82);
        }

        for (var i = 0; i < n; i += 1) {
            var colCx = (i * colW) + (colW / 2);
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colCx, top, Graphics.FONT_XTINY,
                        labels[i], Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(colors[i], Graphics.COLOR_TRANSPARENT);
            dc.drawText(colCx, top + lblH, numFont,
                        values[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Stacked rows, one readout per row (fields taller than wide).
    function drawVertical(dc, fg, w, h, labels, values, colors, n) {
        var cx = w / 2;
        var rowH = h / n;
        var numFont = Graphics.FONT_NUMBER_MILD;
        if (rowH >= 90) { numFont = Graphics.FONT_NUMBER_MEDIUM; }
        if (rowH <  40) { numFont = Graphics.FONT_TINY; }

        var lblH = dc.getFontHeight(Graphics.FONT_XTINY);
        var valH = dc.getFontHeight(numFont);
        var pad  = (rowH - (lblH + valH)) / 2;
        if (pad < 0) { pad = 0; }

        for (var i = 0; i < n; i += 1) {
            var yTop = (i * rowH) + pad;
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, yTop, Graphics.FONT_XTINY,
                        labels[i], Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(colors[i], Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, yTop + lblH, numFont,
                        values[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Full-screen grid: 5 rows x (label + 3 cells). The rolling carb g/h and
    // carb % values (roll column of rows 0 and 2) are colored by power zone (zc).
    function drawGrid(dc, fg, zc, w, h) {
        var recon = reconFactor();
        var ovH  = mTotalSec / 3600.0;
        var lapH = mLapSec / 3600.0;

        var cRoll = mCarbRate * recon;
        var fRoll = mFatRate * recon;
        var cLap  = (lapH > 0.0) ? ((mLapCarbKcal * recon / KCAL_PER_G) / lapH) : 0.0;
        var fLap  = (lapH > 0.0) ? ((mLapFatKcal  * recon / KCAL_PER_G_FAT) / lapH) : 0.0;
        var cAvg  = (ovH > 0.0)  ? (mGramsCho / ovH) : 0.0;
        var fAvg  = (ovH > 0.0)  ? (mGramsFat / ovH) : 0.0;
        var pLap  = (mLapKcal > 0.0) ? (mLapCarbKcal / mLapKcal * 100.0) : 0.0;

        var hasW    = (mWeight > 0.0);
        var glyTot  = mWeight * GLYCOGEN_G_PER_KG;
        var glyLeft = hasW ? (glyTot - mGramsCho) : 0.0;
        if (glyLeft < 0.0) { glyLeft = 0.0; }
        var glyLeftPct = hasW ? (glyLeft / glyTot * 100.0) : 0.0;
        var glyLeftStr = hasW ? glyLeft.format("%.0f") : "--";
        var glyPctStr  = hasW ? glyLeftPct.format("%.0f") : "--";

        var nRows = 5;
        var rowH  = h / nRows;
        var leftW = w * 24 / 100;
        var cellW = (w - leftW) / 3;

        var fSub = Graphics.FONT_XTINY;
        var fVal = (h >= 380) ? Graphics.FONT_SMALL : Graphics.FONT_TINY;
        var fRow = Graphics.FONT_TINY;
        if (h >= 550) {
            // Large screens (e.g. Edge 1050, 480x800): bigger everything.
            fSub = Graphics.FONT_TINY;
            fVal = Graphics.FONT_LARGE;
            fRow = Graphics.FONT_SMALL;
        }
        var subH = dc.getFontHeight(fSub);
        var valH = dc.getFontHeight(fVal);
        var rowLH = dc.getFontHeight(fRow);

        // grid lines
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        for (var r = 1; r < nRows; r += 1) { dc.drawLine(0, r * rowH, w, r * rowH); }
        dc.drawLine(leftW, 0, leftW, h);
        dc.drawLine(leftW + cellW, 0, leftW + cellW, h);
        dc.drawLine(leftW + 2 * cellW, 0, leftW + 2 * cellW, h);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        var eqSub = mCarbIntake.format("%.0f") + "g eq";
        var rowNames = ["CARB/h", "FAT/h", "CARB%", "STORE", "PWR"];
        var subs = [
            ["roll", "lap", "avg"],
            ["roll", "lap", "avg"],
            ["roll", "lap", "avg"],
            ["carb g", "gly g", "gly %"],
            ["fatmax", "xover", eqSub]
        ];
        var vals = [
            [cRoll.format("%.0f"), cLap.format("%.0f"), cAvg.format("%.0f")],
            [fRoll.format("%.0f"), fLap.format("%.0f"), fAvg.format("%.0f")],
            [mCarbPctRoll.format("%.0f"), pLap.format("%.0f"), mPctCho.format("%.0f")],
            [mGramsCho.format("%.0f"), glyLeftStr, glyPctStr],
            [mFatMaxW.format("%d"), mP50.format("%.0f"), mEquilW.format("%d")]
        ];

        for (var row = 0; row < nRows; row += 1) {
            var rowTop = row * rowH;
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            dc.drawText(6, rowTop + (rowH - rowLH) / 2, fRow,
                        rowNames[row], Graphics.TEXT_JUSTIFY_LEFT);
            var blockTop = rowTop + (rowH - (subH + valH)) / 2;
            for (var c = 0; c < 3; c += 1) {
                if (vals[row][c] == null) { continue; }
                var cx = leftW + c * cellW + cellW / 2;
                dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, blockTop, fSub, subs[row][c],
                            Graphics.TEXT_JUSTIFY_CENTER);
                // roll cells of CARB/h (row 0) and CARB% (row 2) get the zone color
                var vcol = ((c == 0) && ((row == 0) || (row == 2))) ? zc : fg;
                dc.setColor(vcol, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, blockTop + subH, fVal, vals[row][c],
                            Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
    }
}
