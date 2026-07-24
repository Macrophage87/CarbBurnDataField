using Toybox.Test;
using Toybox.Graphics;
using Toybox.Activity;

//
// Unit tests for the rolling-metrics correctness fixes (epic #22: #7, #8, #15,
// #16). These instantiate the real CarbBurnView and drive compute() with a
// synthetic Activity.Info, so the warm-up seeding, dt-aware smoothing, coast
// behaviour and zone-colour scale are all exercised end to end.
//
// Helpers are (:debug) so they are stripped from release (-r) builds and only
// exist in debug / --unit-test builds alongside the (:test) functions.
//

// Build an Activity.Info for one sample. A duck-typed stand-in does NOT
// compile: monkeyc resolves v.compute(...) against the overridden
// DataField.compute(info as Activity.Info) and rejects a foreign class
// ("Invalid '$.FakeInfo' passed as parameter 1 of type
// '$.Toybox.Activity.Info'", rc=105 on all 13 devices), so a real Info is
// required. compute() reads only currentPower / timerTime / calories.
(:debug)
function mkInfo(power, tMs, cal) {
    var info = new Activity.Info();
    info.currentPower = power;   // Number or null (null or <= 0 => coast)
    info.timerTime    = tMs;     // ms since timer start (drives dt)
    info.calories     = cal;     // Garmin cumulative kcal or null
    return info;
}

// Relative comparison. 32-bit Floats plus differently-ordered expressions
// (carbRateAt() vs the accumulation inside compute()) can differ by an ulp,
// which at ~300 g/h exceeds any tight absolute tolerance.
(:debug)
function cbvRelEq(a, b, rel) {
    var d = a - b;
    if (d < 0.0) { d = -d; }
    var m = a;
    if (m < 0.0) { m = -m; }
    var mb = b;
    if (mb < 0.0) { mb = -mb; }
    if (mb > m) { m = mb; }
    if (m < 1.0) { m = 1.0; }
    return d <= rel * m;
}

// Fresh view primed at t=1000 (dt=0, no update), then `n` active samples at
// constant `power`, 1 Hz. Internal timer ends at (1000 + 1000*n) ms.
(:debug)
function cbvWarmView(power, n) {
    var v = new CarbBurnView();
    var t = 1000;
    v.compute(mkInfo(power, t, null));           // prime timer, dt=0
    for (var i = 0; i < n; i += 1) {
        t += 1000;
        v.compute(mkInfo(power, t, null));       // dt=1 active samples
    }
    return v;
}

// -------- harness liveness probe --------

// mkInfo() assumes Activity.Info is constructible here and its fields writable.
// Compiling only proves the symbol resolves. This runs FIRST so that, if the
// assumption is false, one test names the cause instead of eight erroring
// mysteriously downstream.
(:test)
function test_activity_info_is_writable(logger) {
    var info = new Activity.Info();
    info.currentPower = 123;
    info.timerTime    = 4567;
    info.calories     = 89;
    var ok = (info.currentPower == 123) && (info.timerTime == 4567) && (info.calories == 89);
    logger.debug("Activity.Info writable=" + ok + " power=" + info.currentPower
                 + " timerTime=" + info.timerTime + " calories=" + info.calories);
    return ok;
}

// -------- #8: warm-up seeding --------

// First active sample seeds the EMA exactly (alpha 1.0), not 0.10*inst.
(:test)
function test_warmup_seeds_first_sample(logger) {
    var v = new CarbBurnView();
    v.compute(mkInfo(200, 1000, null));          // prime (dt=0)
    v.compute(mkInfo(200, 2000, null));          // first active (dt=1)
    var expected = v.carbRateAt(200.0);
    var seeded   = cbvRelEq(v.mCarbRate, expected, 0.0001);
    var oneN     = (v.mRollN == 1);
    var fitExact = (v.clampU16(v.mCarbRate) == v.clampU16(expected));  // FIT integer exact
    logger.debug("seeded=" + seeded + " oneN=" + oneN + " fitExact=" + fitExact
                 + " carbRate=" + v.mCarbRate + " expected=" + expected);
    return seeded && oneN && fitExact;
}

// A coasting PREFIX must not consume the warm-up: the first ACTIVE sample still
// seeds exactly. Covers both coast forms - null power AND power <= 0.
(:test)
function test_warmup_not_consumed_by_coast_prefix(logger) {
    var v = new CarbBurnView();
    v.compute(mkInfo(null, 1000, null));         // prime (dt=0)
    v.compute(mkInfo(null, 2000, null));         // coast, null power
    v.compute(mkInfo(0,    3000, null));         // coast, ZERO power (<= 0 path)
    v.compute(mkInfo(null, 4000, null));         // coast, null power
    var untouched = (v.mRollN == 0);             // warm-up not consumed
    var coasted   = (v.mCoastN == 3);
    v.compute(mkInfo(200, 5000, null));          // first ACTIVE sample
    var seeded = cbvRelEq(v.mCarbRate, v.carbRateAt(200.0), 0.0001) && (v.mRollN == 1);
    var coastCleared = (v.mCoastN == 0);
    logger.debug("untouched=" + untouched + " coasted=" + coasted + " seeded=" + seeded
                 + " coastCleared=" + coastCleared + " carbRate=" + v.mCarbRate);
    return untouched && coasted && seeded && coastCleared;
}

// A second resetSession() (via onTimerReset) re-arms the warm-up; the test
// pre-warms past n>=10 first, so a missed reset would show as alpha 0.10.
(:test)
function test_reset_rearms_warmup(logger) {
    var v = cbvWarmView(200, 15);                      // mRollN = 15 (>=10)
    var warmedN = v.mRollN;
    v.onTimerReset();                                  // resetSession: counters + EMAs -> 0
    var rearmed = (v.mRollN == 0) && (v.mCoastN == 0) && cbvRelEq(v.mCarbRate, 0.0, 0.0001);
    v.compute(mkInfo(200, 100000, null));              // prime again (mLastTimerMs was 0 -> dt=0)
    v.compute(mkInfo(200, 101000, null));              // first active -> seeds exactly
    var seeded = cbvRelEq(v.mCarbRate, v.carbRateAt(200.0), 0.0001) && (v.mRollN == 1);
    logger.debug("warmedN=" + warmedN + " rearmed=" + rearmed + " seeded=" + seeded
                 + " rollN=" + v.mRollN + " carbRate=" + v.mCarbRate);
    return (warmedN >= 10) && rearmed && seeded;
}

// -------- #8/#16: steady state matches the old fixed-0.10 EMA at 1 Hz --------
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
        v.compute(mkInfo(p, t, null));
        var inst = v.carbRateAt(p.toFloat());
        ref = ref + 0.10 * (inst - ref);
        if (!cbvRelEq(v.mCarbRate, ref, 0.0001)) { ok = false; }
    }
    logger.debug("ok=" + ok + " carbRate=" + v.mCarbRate + " ref=" + ref);
    return ok;
}

// -------- #16: dt-aware alpha --------

// The formula itself: 1 - (1-0.10)^dt, with the dt==1 fast-path and [0,1] clamp.
// This is the only place Math.pow in steadyAlpha() is exercised (every other
// test steps at dt=1, which takes the fast-path).
(:test)
function test_steady_alpha_formula(logger) {
    var v = new CarbBurnView();
    var a1   = v.steadyAlpha(1.0);      // fast-path: exactly RATE_ALPHA (0.10)
    var a2   = v.steadyAlpha(2.0);      // 1 - 0.9^2  = 0.19
    var aHal = v.steadyAlpha(0.5);      // 1 - 0.9^.5 = 0.0513
    var aBig = v.steadyAlpha(1000.0);   // pow underflows to 0 -> 1.0 (never exceeds it)
    // For dt > 0, 1 - 0.9^dt is always < 1, so the UPPER clamp is defensive and
    // unreachable; the LOWER clamp needs dt < 0 (1 - 0.9^-1 = -0.111 -> 0.0).
    // Production can't produce dt <= 0 (compute() guards t > mLastTimerMs), so
    // this is the only way to execute that branch.
    var aNeg = v.steadyAlpha(-1.0);
    var ok1   = cbvRelEq(a1,   0.10,     0.000001);
    var ok2   = cbvRelEq(a2,   0.19,     0.0001);
    var okHal = cbvRelEq(aHal, 0.051317, 0.001);
    var okBig = (aBig <= 1.0) && (aBig >= 0.999);
    var okNeg = (aNeg == 0.0);          // clamped, not negative
    logger.debug("a1=" + a1 + " a2=" + a2 + " aHalf=" + aHal + " aBig=" + aBig
                 + " aNeg=" + aNeg);
    return ok1 && ok2 && okHal && okBig && okNeg;
}

// Real-time invariance: one dt=2 step == two dt=1 steps.
// NOTE: the step power MUST differ from the warm-up power. At constant power
// the EMA sits on its fixed point (inst - x == 0), so the update is a no-op for
// any alpha and the test would pass even with #16 removed. Stepping to a
// different power makes alpha observable: correct (dt-aware) gives
// x = I - 0.81*(I-x0) both ways, while a fixed-alpha 0.10 applied to the dt=2
// step gives I - 0.90*(I-x0) - a large, detected difference.
(:test)
function test_dt_invariance(logger) {
    var PWARM = 220;
    var PSTEP = 350;
    var v1 = cbvWarmView(PWARM, 15);                   // past warm-up, timer at 16000
    var v2 = cbvWarmView(PWARM, 15);
    var warmVal = v1.mCarbRate;
    v1.compute(mkInfo(PSTEP, 18000, null));            // one dt=2 step
    v2.compute(mkInfo(PSTEP, 17000, null));            // two dt=1 steps
    v2.compute(mkInfo(PSTEP, 18000, null));
    var same  = cbvRelEq(v1.mCarbRate, v2.mCarbRate, 0.0001);
    // Anti-vacuity: the EMA must actually have moved, or "same" proves nothing.
    var moved = !cbvRelEq(v1.mCarbRate, warmVal, 0.01);
    logger.debug("same=" + same + " moved=" + moved
                 + " v1=" + v1.mCarbRate + " v2=" + v2.mCarbRate + " warm=" + warmVal);
    return same && moved;
}

// -------- #7: coasting % relaxes with a sustained-coast guard --------
// Brief dropout (< N samples) holds % and colour; the N-th sample starts decay.
// Covers both coast forms (null and 0 power) inside the hold and decay windows.
(:test)
function test_coast_brief_dropout_and_boundary(logger) {
    var v = cbvWarmView(400, 20);                      // high power -> RED, high %
    var redInit = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_RED);
    var pctBefore = v.mCarbPctRoll;
    var t = 21000;
    t += 1000; v.compute(mkInfo(null, t, null));       // coast 1, null (mCoastN=1)
    t += 1000; v.compute(mkInfo(0,    t, null));       // coast 2, ZERO  (mCoastN=2 < 3)
    var heldAtN1 = cbvRelEq(v.mCarbPctRoll, pctBefore, 0.000001)
                   && (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_RED)
                   && (v.mCoastN == 2);
    t += 1000; v.compute(mkInfo(0, t, null));          // coast 3, ZERO (mCoastN=3 >= N) -> decay
    var decaysAtN = (v.mCarbPctRoll < pctBefore) && (v.mCoastN == 3);
    // Compare the NEXT sample against the value right after the N-th one, not
    // against pctBefore: a one-shot (mCoastN == COAST_HOLD_N) implementation
    // would leave this unchanged and must fail here.
    var pctAtN = v.mCarbPctRoll;
    t += 1000; v.compute(mkInfo(null, t, null));       // coast 4 -> must decay AGAIN
    var keepsDecaying = (v.mCoastN == 4) && (v.mCarbPctRoll < pctAtN);
    logger.debug("redInit=" + redInit + " heldAtN1=" + heldAtN1 + " decaysAtN=" + decaysAtN
                 + " keepsDecaying=" + keepsDecaying + " pct=" + v.mCarbPctRoll);
    return redInit && heldAtN1 && decaysAtN && keepsDecaying;
}

// Sustained coast leaves RED (no "0 g/h in RED"); resuming power resets the
// coast counter and the % climbs back.
(:test)
function test_coast_sustained_and_resume(logger) {
    var v = cbvWarmView(400, 20);
    var t = 21000;
    for (var j = 0; j < 60; j += 1) { t += 1000; v.compute(mkInfo(null, t, null)); }
    var relaxed = (v.mCarbPctRoll < 50.0)
                  && (v.mCarbRate < 1.0)
                  && (v.zoneColor(Graphics.COLOR_LT_GRAY, true) != Graphics.COLOR_RED);
    var coastReset = true;
    for (var k = 0; k < 10; k += 1) {
        t += 1000;
        v.compute(mkInfo(400, t, null));
        if (k == 0 && v.mCoastN != 0) { coastReset = false; }   // reset on the FIRST active sample
    }
    var recovered = (v.mCarbPctRoll > 50.0);
    logger.debug("relaxed=" + relaxed + " coastReset=" + coastReset + " recovered=" + recovered
                 + " pct=" + v.mCarbPctRoll + " coastN=" + v.mCoastN);
    return relaxed && coastReset && recovered;
}

// Coasting from a cold start must not crash (it would if the coast branch
// dereferenced a null currentPower) and must not fabricate any flux.
(:test)
function test_coast_cold_start_null_and_zero(logger) {
    var v = new CarbBurnView();
    v.compute(mkInfo(null, 1000, null));               // prime, null power
    v.compute(mkInfo(null, 2000, null));               // coast, null, dt=1
    var afterNull = (v.mCoastN == 1);
    v.compute(mkInfo(0, 3000, null));                  // coast, zero power, dt=1
    var afterZero = (v.mCoastN == 2);
    var noFlux = cbvRelEq(v.mCarbRate, 0.0, 0.0001)
                 && cbvRelEq(v.mFatRate, 0.0, 0.0001)
                 && cbvRelEq(v.mCarbPctRoll, 0.0, 0.0001);
    var stillUnseeded = (v.mRollN == 0);
    logger.debug("afterNull=" + afterNull + " afterZero=" + afterZero + " noFlux=" + noFlux
                 + " stillUnseeded=" + stillUnseeded);
    return afterNull && afterZero && noFlux && stillUnseeded;
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
    v.mModelKcal = 0.0;   v.mGarminKcal = 0.0;   var below1 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 130.0; var below2 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 200.0; var below3 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    var belowInvariant = (below1 == below2) && (below1 == below3)
                         && (below1 != Graphics.COLOR_BLUE) && (below1 != Graphics.COLOR_DK_BLUE);

    // At/ABOVE the boundary -> BLUE at every recon (same 3 recon values).
    v.mFatRate = 1.00 * peak;
    v.mModelKcal = 0.0;   v.mGarminKcal = 0.0;   var above1 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 130.0; var above2 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 200.0; var above3 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    var aboveInvariant = (above1 == above2) && (above1 == above3)
                         && (above1 == Graphics.COLOR_BLUE);

    logger.debug("below=" + below1 + "/" + below2 + "/" + below3
                 + " above=" + above1 + "/" + above2 + "/" + above3 + " peak=" + peak);
    return belowInvariant && aboveInvariant;
}
