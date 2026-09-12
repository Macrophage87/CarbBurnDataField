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
//     carb %). The carb g/h is a rolling EMA; the carb % is DERIVED from the two
//     rolling rates (#33), so it can never contradict them, and reads "--" while
//     the total flux is too small for a substrate ratio to mean anything.
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
    var mFatMaxW;   // power (W) that maximises fat oxidation rate (not private: read by tests)
    var mScanMaxW;  // top of the fat-max scan grid (not private: read by tests)
    private var mCarbIntake;// assumed carb intake during the ride, g/hr
    private var mEquilW;    // power (W) where carb oxidation == intake (fueling equilibrium)
    var mFatMaxRate;// peak fat oxidation rate (g/h) at fat-max power (not private: read by tests)
    var mPctFatMax; // carb % at fat-max power = the GREEN threshold (not private: read by tests)

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
    var mCarbPctRoll;// carb % of energy - DERIVED from the two rates above (#33)
    var mRollN;      // active-sample count for EMA warm-up seeding (0 = unseeded)

    // ---- Power-signal state machine (#33) ---- (not private: read by the unit tests)
    var mLastPower;  // last ACTIVE power (W), POWER_UNSET before the first one
    var mNullSec;    // consecutive seconds with NO power reading (null), not 0 W
    var mActiveRun;  // consecutive ACTIVE samples (re-arms the dropout carry)
    var mCarryArmed; // may a null gap carry mLastPower? (see CARRY_REARM_N)
    var mFluxLow;    // flux-floor hysteresis latch: is the rolling flux negligible?

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
    private const RATE_ALPHA       = 0.10;   // EMA smoothing at dt=1 s

    // #33: power-signal continuity. A MISSING reading (currentPower == null) is a
    // measurement gap, not a physiological event - power does not teleport to 0 W
    // for one second and back - so up to SIGNAL_GRACE_S of it is modelled at the
    // last known power. A measured 0 W is always a real coast.
    //
    // 2.5 s is chosen from the link budgets, not from taste: ANT+ broadcasts at
    // 4.005 Hz so interference gaps run sub-second to ~2 s, and BLE CPS notifies
    // at 1 Hz with a 2-6 s supervision timeout, so a gap past ~3 s is usually a
    // real disconnect. Anything >= 5 s buys little and multiplies phantom work.
    private const SIGNAL_GRACE_S   = 2.5;
    // Consecutive ACTIVE samples needed to (re-)arm the carry once it has been
    // LOST - which happens on a gap past the window, or on a measured 0 W.
    //
    // Note what it therefore does NOT do: a link alternating [1 s gap, one
    // reading, ...] never exceeds the window, so it never disarms and it carries
    // on every gap. That is intended - the alternate readings are live evidence
    // the rider is still pedalling, which is the whole basis for carrying - but
    // it means this guard is about regaining trust after a real loss of signal,
    // not about rate-limiting short gaps. The aggregate bound in that regime is
    // SIGNAL_GRACE_S per gap, and nothing more.
    private const CARRY_REARM_N    = 2;
    // mLastPower before the first ACTIVE sample. Must be < 0, NOT 0.0: a session
    // opening on null then has no power to carry and falls through to COASTING,
    // which is also what keeps a coasting prefix from consuming the #8 warm-up.
    private const POWER_UNSET      = -1.0;

    // #33 flux floor. Below FLUX_ENGAGE carb-equivalent g/h the substrate ratio
    // is not a meaningful quantity and the percentage reads "--"; it becomes
    // meaningful again above FLUX_RELEASE (hysteresis, so a sustained hover at
    // the boundary cannot flicker the colour).
    //
    // The binding constraint is that the floor must never grey a power at which
    // the BLUE fat-max band would be shown. Swept over the full legal grid
    // (ftp 50-600 x lt1 0-500, ge at its legal max 0.28), the minimum total
    // carb-equivalent flux anywhere on the BLUE band - at its LOWER EDGE, not at
    // the fat-max point - is 15.5491 g/h, at ftp=50 / lt1=19 / 20.24 W.
    // FLUX_RELEASE is the binding threshold (the higher of the two), leaving
    // 1.94x margin.
    //
    // Precisely: 15.5491 is the CONTINUUM infimum over the band edge. Because
    // mFatRate is an EMA it interpolates between integer watts, so the reachable
    // set is wider than the integer-watt one (whose own hull bottoms out at
    // 15.5606) - hence the continuum figure is the safe one to pin.
    //
    // That number is sensitive to how the edge search is discretised, so the
    // convention is part of the constraint: continuous edge, threshold taken as
    // 0.95 x the fat-max SCAN's own peak (not a continuous peak). The same sweep
    // over coarser grids gives 16.13 g/h at 1 W steps, 16.90 at anchor 2 step 2,
    // and 23.05 inheriting the scan's own "30 ... += 2" - all of which greyed
    // part of the band for some legal settings. zoneColor() also gates the floor
    // on the BLUE test itself, so the band is protected structurally even if this
    // bound is ever wrong again.
    private const FLUX_ENGAGE      = 5.0;
    private const FLUX_RELEASE     = 8.0;
    // The one sentinel this field renders in place of a number. Single-sourced so
    // carbPctStr(), drawGrid()'s glycogen cells and valueFont() cannot disagree.
    private const NO_VALUE         = "--";

    // ---- reconFactor() bounds (#59) ----
    // reconFactor() guarded a ZERO denominator but not a SMALL one. At the
    // first powered sample of a session the denominator is a single sample of
    // model kcal (0.227625 at 200 W, measured), so the factor was Garmin's
    // whole cumulative kcal divided by that - unbounded, and it multiplies the
    // g/h written to the carb_rate and fat_rate FIT RECORD fields. Measured at
    // 0698921 with this guard reverted: 4.393200x at 200 W with the smallest
    // reportable calorie count, 351.455963x after a neutral roll-out, writing
    // 487 and 10650 g/h against true rates of 110.9 and 30.3. (Re-measured
    // after #37 restructured the accrual that produces mModelKcal; every
    // figure here is unchanged by that restructure.)
    //
    // RECON_MIN_KCAL - minimum denominator. Below it the field reports the pure
    //   power model (factor 1.0), which is the only other self-consistent scale
    //   it already owns; it does not invent a number. 10.0 kcal is ~44 s at
    //   200 W and ~88 s at 100 W, over which the un-reconciled carbohydrate
    //   TOTAL reaches ~1.35 g at 200 W (~0.12 g at 100 W - the window is
    //   fixed in kcal, so the grams scale with choFraction). That total is a
    //   level, not a difference: mGramsCho = mModelCarbKcal * recon /
    //   KCAL_PER_G rescales the whole accumulator, so suppressing the factor
    //   costs total * (recon - 1), not total. The step at release is below.
    // RECON_MAX - upper bound, and the load-bearing half. A floor alone only
    //   converts an unbounded error into a large one: measured, a 10 kcal floor
    //   with no clamp still writes 664 g/h at the release sample after a
    //   15-minute roll-out, against a true 110.9 - raw factor 60/10.015479 =
    //   5.990727, with the numerator frozen at 60 through the powered phase.
    //   If the device instead keeps counting through that phase the release
    //   factor is higher still, and the two constructible counting models
    //   differ by one sample. If info.calories for a sample already includes
    //   that sample's energy, the count at release is (60 + 10.015479)
    //   truncated = 70 kcal: factor 6.989182 -> 775 g/h. If it lags the model
    //   by one sample it is (60 + 9.787854) truncated = 69 kcal: factor
    //   6.889336 -> 764 g/h. Which one a real device follows is unmeasured -
    //   #67 is what would measure it. An earlier revision of this comment
    //   gave "664-775" without naming the model; 664 stays the lower bound
    //   under all three, because any further accrual only raises the factor.
    //   A later revision withdrew 775 as "not reproducing"; that withdrawal
    //   was wrong - 775 is the NO-LAG model, measured, and it is restored.
    //   3.0 rather than 2.0 deliberately: 2.0 is exactly the third arm pinned
    //   by test_zonecolor_recon_invariant, so a bound of 2.0 would leave that
    //   test passing on the coincidence that clamping 2.0 to 2.0 is a no-op.
    //   3.0 also sits above every factor produced by any whole-ride sweep run
    //   on this model (maximum observed 1.435102).
    // RECON_MIN - lower bound. The clamp is symmetric because info.calories is
    //   an integer: the same small-denominator window can also produce a factor
    //   BELOW 1.0 when it truncates, so #59's direction of error is not
    //   unambiguously upward. Defensive: no sweep has reached it (minimum
    //   observed 0.959536), and a binding lower clamp INFLATES reported grams,
    //   so it sits well below anything measured rather than close to 1.0.
    //
    // The bound is a per-sample step in the reported rate when it engages or
    // disengages (measured 111 -> 333 g/h at the release sample). In cumulative
    // grams that step is ~1.4 g -> ~4 g, i.e. negligible against the product,
    // but it is a discontinuity and it is deliberate.
    //
    // These bound the ARITHMETIC only. Nothing here gates a setData() call:
    // record-scope FIT fields latch, so a skipped write would re-emit the
    // previous value rather than produce a gap, and setFitData() stays
    // unconditional for that reason.
    private const RECON_MIN_KCAL   = 10.0;
    private const RECON_MAX        = 3.0;
    private const RECON_MIN        = 0.5;

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
        // #33 signal state machine: a reset is a gap of unknown length, so the
        // correct restore is "no power known, nothing armed, flux negligible".
        mLastPower     = POWER_UNSET;
        mNullSec       = 0.0;
        mActiveRun     = 0;
        mCarryArmed    = false;
        mFluxLow       = true; // "--" until the flux is provably meaningful
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
        //
        // The scan grid (anchor 30, step 2, bound 1.3*FTP) is load-bearing, not
        // incidental: mFatMaxW is the argmax over THIS grid, so the continuous
        // peak can legitimately sit below 30 W at small FTP - which is why a test
        // asserting "fat rate at mFatMaxW is maximal" must restrict itself to
        // neighbours inside [30, mScanMaxW].
        //
        // The comparison is a strict `>`, so on the rare tie the LOWER power
        // wins. Ties are reachable: in 32-bit float the scores at two adjacent
        // even watts can be bit-identical (e.g. ftp=189/lt1=16 gives exactly
        // 37.491180419921875 at both 110 W and 112 W), so a re-implementation
        // that uses `>=` will disagree with this one by one scan step.
        var pMax = (mFtp * 1.3).toNumber();
        if (pMax < 60) { pMax = 60; }
        mScanMaxW = pMax;
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
        mFatMaxRate = fatRateAt(mFatMaxW);
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
        // #33 flux floor, tested FIRST and for a reason: the rolling % is now
        // derived from the two rates, and a coast decays both by the same alpha,
        // so the ratio is preserved exactly all the way to zero flux. A rider who
        // was above threshold therefore stays >= 85 % forever - place this test
        // after the 85/50 branches and it is dead code for exactly the users who
        // need it (the "RED at 0 g/h" of #7).
        if (fluxUndefined()) { return greyColor; }
        if (mCarbPctRoll >= 85.0) { return Graphics.COLOR_RED; }
        if (mCarbPctRoll >= 50.0) { return Graphics.COLOR_ORANGE; }
        // #15: compare both sides on the SAME (un-reconciled model) scale.
        // mFatMaxRate is the un-reconciled model peak; multiplying only the
        // left side by reconFactor() (typically >1) widened the band. Reconciling
        // both sides is algebraically identical (recon cancels), so drop it.
        // NOTE this branch is knowingly NOT duty-cycle-invariant, unlike the
        // others: it asks a magnitude question, so a rider at exactly fat-max
        // seen through a 50 %-duty meter has mFatRate ~= 53 % of instantaneous
        // and never turns BLUE, while the derived percentage equals mPctFatMax
        // exactly and the field falls through to GREEN. That is defensible - the
        // fat-max band is about how much fat, not what share - but it is a
        // deliberate asymmetry, not an oversight.
        if (mFatRate >= 0.95 * mFatMaxRate) {
            return onDark ? Graphics.COLOR_BLUE : Graphics.COLOR_DK_BLUE;
        }
        if (mCarbPctRoll >= mPctFatMax) {
            return onDark ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GREEN;
        }
        return greyColor;
    }

    // Total rolling oxidation as carb-equivalent g/h: (4*carb + 9*fat) / 4.
    // UN-RECONCILED, like the BLUE band it is compared against (#15) - recon is a
    // session-cumulative ratio, so gating "is this quantity meaningful" on it
    // would make the floor's engagement depend on ride history.
    function totalFlux() {
        return (KCAL_PER_G * mCarbRate + KCAL_PER_G_FAT * mFatRate) / KCAL_PER_G;
    }

    // Is the rolling substrate ratio meaningless right now? Latched with
    // hysteresis (see FLUX_ENGAGE / FLUX_RELEASE), and gated on the BLUE test so
    // the floor can never grey a power at which the fat-max band would be shown -
    // for ANY legal settings, independently of the swept 15.55 g/h bound.
    function fluxUndefined() {
        return mFluxLow && (mFatRate < 0.95 * mFatMaxRate);
    }

    // The carb-% cell as a STRING. Below the floor it reads "--", not "0": 0 is a
    // legal percentage, so a numeric sentinel is unrepresentable, and printing a
    // number there would assert a value the floor has just called undefined
    // (#7's contradiction rebuilt - at the release threshold the g/h cell beside
    // it can still read 23 at recon 3.0). drawGrid() already uses "--" for the
    // glycogen cells when weight is unset, so the idiom is not new here.
    function carbPctStr() {
        if (fluxUndefined()) { return NO_VALUE; }
        return mCarbPctRoll.format("%.0f");
    }

    // Font for a value cell. The FONT_NUMBER_* faces are digit-only designs -
    // their documented safe set is "#%+-./0123456789:" plus the degree sign, and
    // Garmin has removed the per-device glyph tables, while an unsupported glyph
    // renders as a filled BOX on Edge hardware. Rather than bet the sentinel on
    // that, draw any non-numeric value string in a text font (which is what
    // drawGrid() has always done for its own NO_VALUE cells).
    //
    // The substitute must FIT the slot the number font was measured for, so walk
    // down the text faces and take the first that is no taller. Picking a fixed
    // face does not work: drawVertical() uses FONT_TINY when a row is under 40 px,
    // and FONT_SMALL is taller than that, so the value would be drawn above its
    // slot and collide with the label - in the tightest layout, where there is
    // least room to absorb it. FONT_XTINY is the floor (it is what the labels
    // use, so it always fits).
    function valueFont(dc, s, numFont) {
        if (s.equals(NO_VALUE) == false) { return numFont; }
        var budget = dc.getFontHeight(numFont);
        var ladder = [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY];
        for (var i = 0; i < ladder.size(); i += 1) {
            if (dc.getFontHeight(ladder[i]) <= budget) { return ladder[i]; }
        }
        return Graphics.FONT_XTINY;
    }

    // Modelled carbohydrate oxidation rate at a given power, g/hr.
    function carbRateAt(power) {
        var metabolicW = power / mGe;
        return choFraction(power) * metabolicW / J_PER_KCAL * 3600.0 / KCAL_PER_G;
    }

    // Modelled fat oxidation rate at a given power, g/hr (the complement of
    // carbRateAt at 9 kcal/g). mFatMaxRate is this evaluated at mFatMaxW.
    function fatRateAt(power) {
        var metabolicW = power / mGe;
        return (1.0 - choFraction(power)) * metabolicW / J_PER_KCAL * 3600.0 / KCAL_PER_G_FAT;
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

            // ---- #33: classify the sample before acting on it ----------------
            //
            // main had ONE boolean (currentPower > 0) driving energy accrual, the
            // rate EMA and the coast hold, while conflating three physical states.
            // They are now separated:
            //
            //   ACTIVE   a power reading > 0            -> accrue at that power
            //   DROPOUT  NO reading (null), within the  -> accrue at mLastPower
            //            grace window, carry armed
            //   COASTING a measured 0 W, or a gap past  -> decay toward zero
            //            grace, or no power ever seen,
            //            or speed/cadence prove a stop
            //
            // A measured 0 W is never a dropout: the meter is reporting, and it is
            // reporting no work.
            var p = null;
            if (info != null && info.currentPower != null) {
                p = info.currentPower.toFloat();
            }

            if (p != null && p > 0.0) {
                mNullSec   = 0.0;    // cleared ONLY here, never on a 0-W sample
                mLastPower = p;
                mActiveRun += 1;
                if (mActiveRun >= CARRY_REARM_N) { mCarryArmed = true; }
                accrueActive(p, dt);
            } else {
                mActiveRun = 0;
                // A MEASURED zero is a reading, and it says the rider stopped
                // pedalling - so it invalidates the carry. Without this, an hour
                // of freewheeling at a reported 0 W leaves mCarryArmed set and
                // mLastPower stale, and the first null sample afterwards revives
                // an hour-old power: the rates jump off zero, the flux crosses
                // FLUX_RELEASE and the cell flips from "--" to a coloured number.
                // Re-arming costs CARRY_REARM_N readings, which is the right
                // price after a coast. (mNullSec is untouched here: it counts
                // MISSING readings only, which is what rule 1 requires.)
                if (p != null) { mCarryArmed = false; }
                // How much of this sample may be modelled at the last known
                // power: the part of dt that still lies inside the grace window.
                // Clamping rather than testing is what keeps one long sample from
                // being carried whole - a dt=300 s gap contributes 2.5 s of carry
                // and 297.5 s of coasting, not 300 s of phantom pedalling.
                var carry = 0.0;
                if (p == null && mCarryArmed && mLastPower > 0.0 && !signalStopped(info)) {
                    var room = SIGNAL_GRACE_S - mNullSec;
                    if (room > 0.0) { carry = (dt < room) ? dt : room; }
                }
                if (p == null) {
                    mNullSec += dt;
                    // Past the window the signal is treated as genuinely lost, so
                    // the carry DISARMS: it takes CARRY_REARM_N consecutive
                    // readings to trust the link again. Without this a meter
                    // alternating [long gap, one reading, long gap, ...] carries
                    // on every isolated reading for the whole ride.
                    if (mNullSec >= SIGNAL_GRACE_S) { mCarryArmed = false; }
                }
                if (carry > 0.0)        { accrueActive(mLastPower, carry); }
                if (dt - carry > 0.0)   { accrueCoast(dt - carry); }
            }
        }

        // Garmin cumulative calories (weight-aware) for the cross-check.
        if (info != null && info.calories != null && info.calories > 0) {
            mGarminKcal = info.calories.toFloat();
        }

        // #33/#7: the rolling carb % is DERIVED from the two rolling rates, not
        // smoothed independently. mCoastSec / COAST_HOLD_S / INST_PCT0 are gone
        // with it. This makes "high % beside a near-zero rate" impossible by
        // construction instead of guarding it with a timer that measurably failed
        // to (a 50 %-duty meter never reached the hold at all).
        //
        // Two properties follow. Good: the percentage is duty-cycle-invariant -
        // a coast decays both rates by the same alpha, so the ratio always
        // reports the substrate mix of the power being ridden. Costly: a
        // sustained coast therefore HOLDS its pre-coast percentage, which is why
        // the flux floor below is load-bearing rather than belt-and-braces.
        var carbKcalHr = KCAL_PER_G * mCarbRate;
        var fatKcalHr  = KCAL_PER_G_FAT * mFatRate;
        var totKcalHr  = carbKcalHr + fatKcalHr;
        // Guarded HERE, at the assignment site, not in zoneColor(): both rates
        // are exactly 0.0 after resetSession(), so an unguarded 0/(0+0) would
        // store NaN and every layout would render "nan".
        mCarbPctRoll = (totKcalHr > 0.0) ? (carbKcalHr / totKcalHr * 100.0) : 0.0;

        // Flux-floor latch. A pure function of the derived flux, so unlike the
        // deleted mCoastSec timer it cannot desynchronise from the rates it is
        // meant to describe. Routed through totalFlux() so there is exactly ONE
        // definition of the quantity the floor tests.
        var flux = totalFlux();
        if (mFluxLow) {
            if (flux > FLUX_RELEASE) { mFluxLow = false; }
        } else if (flux < FLUX_ENGAGE) {
            mFluxLow = true;
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

    // Does the rest of Activity.Info prove the rider has stopped? A stopped rider
    // is not producing the last known power, so a missing reading there is not a
    // dropout worth carrying. null means "no such sensor / no data", which is NOT
    // evidence of a stop - only a reported zero is.
    function signalStopped(info) {
        if (info == null) { return true; }
        if (info.currentSpeed != null && info.currentSpeed <= 0) { return true; }
        if (info.currentCadence != null && info.currentCadence <= 0) { return true; }
        return false;
    }

    // Accrue `dt` seconds of pedalling at `power`, and advance the rate EMAs.
    // Called for ACTIVE samples and for the carried part of a DROPOUT - a carried
    // sample is a MODELLED active sample, so it consumes warm-up (#8) and uses
    // the warm-up alpha, consistent with it accruing energy.
    function accrueActive(power, dt) {
        var metabolicW = power / mGe;
        var kcal       = (metabolicW * dt) / J_PER_KCAL;
        var frac       = choFraction(power);

        mModelKcal     += kcal;
        mModelCarbKcal += kcal * frac;
        mModelFatKcal  += kcal * (1.0 - frac);

        mLapKcal     += kcal;
        mLapCarbKcal += kcal * frac;
        mLapFatKcal  += kcal * (1.0 - frac);

        // #8 warm-up: seed the EMA to the first active sample (alpha 1.0 at n=1),
        // relaxing to the dt-aware steady alpha by n>=10 - so the rolling rates
        // (and the FIT records) don't ramp up from 0 over the first ~20-30 s of
        // every session. Float division.
        mRollN += 1;
        var a = steadyAlpha(dt);         // #16: dt-aware steady EMA alpha
        var warm = 1.0 / mRollN;
        if (warm > a) { a = warm; }

        var kcalPerHr = metabolicW / J_PER_KCAL * 3600.0;
        var instCarb  = frac * kcalPerHr / KCAL_PER_G;
        var instFat   = (1.0 - frac) * kcalPerHr / KCAL_PER_G_FAT;
        mCarbRate = mCarbRate + a * (instCarb - mCarbRate);
        mFatRate  = mFatRate  + a * (instFat  - mFatRate);
    }

    // Decay both rolling rates toward zero over `dt` seconds, on the steady
    // (dt-aware) alpha - NOT the warm-up alpha, and mRollN is untouched, so a
    // coasting prefix cannot consume the warm-up. Decaying both by the same alpha
    // is what makes the derived percentage duty-cycle-invariant.
    function accrueCoast(dt) {
        var a = steadyAlpha(dt);
        mCarbRate = mCarbRate + a * (0.0 - mCarbRate);
        mFatRate  = mFatRate  + a * (0.0 - mFatRate);
    }

    // Rescale magnitude to Garmin's calorie total when available (else 1.0).
    //
    // Bounded per #59: see the RECON_* block above for why each bound exists
    // and why the clamp, not the floor, is the load-bearing one.
    //
    // The `mModelKcal > 0.0` clause is the DIVISION guard and is kept
    // independently of RECON_MIN_KCAL: the floor is policy and may be retuned,
    // the division must stay guarded either way.
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
                       carbPctStr() ];
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
                       carbPctStr(), mGlycPct.format("%.0f") ];
            colors = [fg, zc, zc, fg];
        } else {
            labels = ["CARBS g", "CARB g/h", "CARB %"];
            values = [ mGramsCho.format("%.0f"), mRateDisp.format("%.0f"),
                       carbPctStr() ];
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
            var vf = valueFont(dc, values[i], numFont);
            var vy = top + lblH + ((valH - dc.getFontHeight(vf)) / 2);
            dc.drawText(colCx, vy, vf, values[i], Graphics.TEXT_JUSTIFY_CENTER);
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
            var vf = valueFont(dc, values[i], numFont);
            var vy = yTop + lblH + ((valH - dc.getFontHeight(vf)) / 2);
            dc.drawText(cx, vy, vf, values[i], Graphics.TEXT_JUSTIFY_CENTER);
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
        var glyLeftStr = hasW ? glyLeft.format("%.0f") : NO_VALUE;
        var glyPctStr  = hasW ? glyLeftPct.format("%.0f") : NO_VALUE;

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
            [carbPctStr(), pLap.format("%.0f"), mPctCho.format("%.0f")],
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
