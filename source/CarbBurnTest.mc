using Toybox.Test;
using Toybox.Graphics;

//
// Unit tests for the rolling-metrics correctness fixes (epic #22: #7, #8, #15,
// #16). These instantiate the real CarbBurnView and drive compute() with a
// synthetic info object, so the warm-up seeding, dt-aware smoothing, coast
// behaviour and zone-colour scale are all exercised end to end.
//
// CarbBurnView.compute() reads only info.timerTime, info.currentPower and
// info.calories, and the codebase is untyped, so this lightweight stand-in is
// sufficient (and avoids depending on Toybox.Activity.Info being constructible
// in the test harness).
//
class FakeInfo {
    var currentPower;   // Number/Float or null (null/<=0 => coast)
    var timerTime;      // ms since timer start (drives dt)
    var calories;       // Garmin cumulative kcal or null

    function initialize(power, tMs, cal) {
        currentPower = power;
        timerTime = tMs;
        calories = cal;
    }
}

// |a - b| <= tol
function cbvFloatEq(a, b, tol) {
    var d = a - b;
    if (d < 0.0) { d = -d; }
    return d <= tol;
}

// Fresh view primed at t=1000 (dt=0, no update), then `n` active samples at
// constant `power`, 1 Hz. Internal timer ends at (1000 + 1000*n) ms.
function cbvWarmView(power, n) {
    var v = new CarbBurnView();
    var t = 1000;
    v.compute(new FakeInfo(power, t, null));           // prime timer, dt=0
    for (var i = 0; i < n; i += 1) {
        t += 1000;
        v.compute(new FakeInfo(power, t, null));       // dt=1 active samples
    }
    return v;
}

// -------- #8: warm-up seeding --------

// First active sample seeds the EMA exactly (alpha 1.0), not 0.10*inst.
(:test)
function test_warmup_seeds_first_sample(logger) {
    var v = new CarbBurnView();
    v.compute(new FakeInfo(200, 1000, null));          // prime (dt=0)
    v.compute(new FakeInfo(200, 2000, null));          // first active (dt=1)
    var expected = v.carbRateAt(200.0);
    var seeded  = cbvFloatEq(v.mCarbRate, expected, 0.001);
    var oneN    = (v.mRollN == 1);
    var fitExact = (v.clampU16(v.mCarbRate) == v.clampU16(expected));   // FIT integer exact
    logger.debug("carbRate=" + v.mCarbRate + " expected=" + expected + " rollN=" + v.mRollN);
    return seeded && oneN && fitExact;
}

// A second resetSession() (via onTimerReset) re-arms the warm-up; the test
// pre-warms past n>=10 first, so a missed reset would show as alpha 0.10.
(:test)
function test_reset_rearms_warmup(logger) {
    var v = cbvWarmView(200, 15);                      // mRollN = 15 (>=10)
    var warmedN = v.mRollN;
    v.onTimerReset();                                  // resetSession: counters + EMAs -> 0
    var rearmed = (v.mRollN == 0) && cbvFloatEq(v.mCarbRate, 0.0, 1e-9);
    v.compute(new FakeInfo(200, 100000, null));        // prime again (mLastTimerMs was 0 -> dt=0)
    v.compute(new FakeInfo(200, 101000, null));        // first active -> seeds exactly
    var seeded = cbvFloatEq(v.mCarbRate, v.carbRateAt(200.0), 0.001) && (v.mRollN == 1);
    logger.debug("warmedN=" + warmedN + " rollN=" + v.mRollN + " carbRate=" + v.mCarbRate);
    return (warmedN >= 10) && rearmed && seeded;
}

// -------- #8/#16: steady state bit-identical to the old fixed-0.10 EMA at 1 Hz --------
(:test)
function test_steady_state_matches_fixed_alpha(logger) {
    var v = cbvWarmView(150, 13);                      // past warm-up (n>=10)
    var ref = v.mCarbRate;                             // reference tracks fixed 0.10 from here
    var powers = [300, 120, 250, 90, 200, 175];
    var t = 14000;
    var ok = true;
    for (var j = 0; j < 6; j += 1) {
        t += 1000;
        var p = powers[j];
        v.compute(new FakeInfo(p, t, null));
        var inst = v.carbRateAt(p.toFloat());
        ref = ref + 0.10 * (inst - ref);
        if (!cbvFloatEq(v.mCarbRate, ref, 0.000001)) { ok = false; }
    }
    logger.debug("carbRate=" + v.mCarbRate + " ref=" + ref);
    return ok;
}

// -------- #16: dt-aware smoothing (real-time invariance past warm-up) --------
// One dt=2 step == two dt=1 steps for constant input.
(:test)
function test_dt_invariance(logger) {
    var P = 220;
    var v1 = cbvWarmView(P, 15);                       // both identical, timer at 16000, n=15
    var v2 = cbvWarmView(P, 15);
    v1.compute(new FakeInfo(P, 18000, null));          // one dt=2 step
    v2.compute(new FakeInfo(P, 17000, null));          // two dt=1 steps
    v2.compute(new FakeInfo(P, 18000, null));
    var same = cbvFloatEq(v1.mCarbRate, v2.mCarbRate, 0.000001);
    logger.debug("v1=" + v1.mCarbRate + " v2=" + v2.mCarbRate);
    return same;
}

// -------- #7: coasting % relaxes with a sustained-coast guard --------
// Brief dropout (< N samples) holds % and color; the N-th sample starts decay.
(:test)
function test_coast_brief_dropout_and_boundary(logger) {
    var v = cbvWarmView(400, 20);                      // high power -> RED, high %
    var redInit = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_RED);
    var pctBefore = v.mCarbPctRoll;
    var t = 21000;
    t += 1000; v.compute(new FakeInfo(null, t, null)); // coast 1 (mCoastN=1)
    t += 1000; v.compute(new FakeInfo(null, t, null)); // coast 2 (mCoastN=2 < COAST_HOLD_N=3)
    var heldAtN1 = cbvFloatEq(v.mCarbPctRoll, pctBefore, 1e-9)
                   && (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_RED)
                   && (v.mCoastN == 2);
    t += 1000; v.compute(new FakeInfo(null, t, null)); // coast 3 (mCoastN=3 >= N) -> % decays
    var decaysAtN = (v.mCarbPctRoll < pctBefore) && (v.mCoastN == 3);
    logger.debug("redInit=" + redInit + " heldAtN1=" + heldAtN1 + " pct=" + v.mCarbPctRoll + " coastN=" + v.mCoastN);
    return redInit && heldAtN1 && decaysAtN;
}

// Sustained coast leaves RED (no "0 g/h in RED"); resuming power resets the
// coast counter and the % climbs back.
(:test)
function test_coast_sustained_and_resume(logger) {
    var v = cbvWarmView(400, 20);
    var t = 21000;
    for (var j = 0; j < 60; j += 1) { t += 1000; v.compute(new FakeInfo(null, t, null)); }
    var relaxed = (v.mCarbPctRoll < 50.0)
                  && (v.mCarbRate < 1.0)
                  && (v.zoneColor(Graphics.COLOR_LT_GRAY, true) != Graphics.COLOR_RED);
    var coastReset = true;
    for (var k = 0; k < 10; k += 1) {
        t += 1000;
        v.compute(new FakeInfo(400, t, null));
        if (k == 0 && v.mCoastN != 0) { coastReset = false; }   // reset on the FIRST active sample
    }
    var recovered = (v.mCarbPctRoll > 50.0);
    logger.debug("relaxed=" + relaxed + " coastReset=" + coastReset + " pct=" + v.mCarbPctRoll + " coastN=" + v.mCoastN);
    return relaxed && coastReset && recovered;
}

// Null power in the coast branch must not crash (would throw if we dereferenced
// currentPower). Exercised throughout above; asserted explicitly here.
(:test)
function test_null_power_no_crash(logger) {
    var v = new CarbBurnView();
    v.compute(new FakeInfo(null, 1000, null));         // prime, coast, null power
    v.compute(new FakeInfo(null, 2000, null));         // coast, dt=1, null power
    logger.debug("survived null coast; coastN=" + v.mCoastN);
    return true;
}

// -------- #15: fat-max BLUE band is reconFactor()-invariant --------
// The band boundary must not move with reconFactor(); asserted across 3 recon
// values, both below and above the 0.95*peak threshold.
(:test)
function test_zonecolor_recon_invariant(logger) {
    var v = new CarbBurnView();
    v.mCarbPctRoll = 10.0;                              // below ORANGE/RED so we reach the BLUE test
    var peak = v.mFatMaxRate;

    // Just BELOW the boundary -> must be NOT blue at every recon.
    v.mFatRate = 0.90 * peak;
    v.mModelKcal = 0.0;   v.mGarminKcal = 0.0;   var belowRecon1  = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 130.0; var belowRecon13 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 200.0; var belowRecon2  = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    var belowInvariant = (belowRecon1 == belowRecon13) && (belowRecon1 == belowRecon2)
                         && (belowRecon1 != Graphics.COLOR_BLUE) && (belowRecon1 != Graphics.COLOR_DK_BLUE);

    // At/ABOVE the boundary -> BLUE at every recon.
    v.mFatRate = 1.00 * peak;
    v.mModelKcal = 0.0;   v.mGarminKcal = 0.0;   var aboveRecon1 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 200.0; var aboveRecon2 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    var aboveInvariant = (aboveRecon1 == aboveRecon2) && (aboveRecon1 == Graphics.COLOR_BLUE);

    logger.debug("below: " + belowRecon1 + "/" + belowRecon13 + "/" + belowRecon2
                 + " above: " + aboveRecon1 + "/" + aboveRecon2 + " peak=" + peak);
    return belowInvariant && aboveInvariant;
}
