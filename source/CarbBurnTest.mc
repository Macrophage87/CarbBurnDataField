using Toybox.Test;
using Toybox.Graphics;
using Toybox.Activity;

//
// Unit tests for the rolling-metrics correctness fixes (epic #22: #7, #8, #15,
// #16). These drive the real CarbBurnView logic with a synthetic Activity.Info,
// so warm-up seeding, dt-aware smoothing, coast behaviour and the zone-colour
// scale are exercised end to end.
//
// Everything here is (:debug)/(:test), so none of it ships in a release (-r)
// build.
//
// SETTINGS INDEPENDENCE: the suite never relies on a particular FTP / LT1 /
// gross-efficiency. It compares against the view's own model (carbRateAt(),
// mFatMaxRate) or sets rolling state directly, because a simulator carries
// persisted device settings that differ from the repo defaults (#28), and
// settings.xml permits FTP 50-600 and GE 15-30. Assertions that depended on
// the model's 85%-at-FTP anchor sat on a knife-edge at FTP=400 and are gone.
//

// ---- test seam ----------------------------------------------------------
//
// FIT developer-field registration is ONCE PER PROCESS: createField() aborts
// with an uncatchable System Error on a duplicate id, and under `monkeydo -t`
// the booted data field already owns ids 0-3. Constructing CarbBurnView
// directly in a test therefore re-registers them and kills the whole run
// (observed: 10 ERROR / 0 pass, #28). This subclass neutralises registration -
// the parent's initialize() dispatches to the override - leaving every other
// behaviour intact. setFitData() already null-guards each handle, so compute()
// runs unchanged with them all null.
(:debug)
class CbvTest extends CarbBurnView {
    function initialize() {
        CarbBurnView.initialize();
    }

    function createFitFields() {
        // deliberately empty - see above
    }
}

// Single construction point, so the seam is one line rather than six.
(:debug)
function cbvNewView() {
    return new CbvTest();
}

// Build an Activity.Info for one sample. A duck-typed stand-in does NOT
// compile: monkeyc resolves v.compute(...) against the inherited
// DataField.compute(info as Activity.Info) signature and rejects a foreign
// class (rc=105 on all 13 devices). compute() reads only currentPower /
// timerTime / calories.
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
// which at ~300 g/h exceeds any tight absolute tolerance. NOTE the m < 1.0
// floor: for values well below 1 this degenerates to an absolute tolerance, so
// small quantities are asserted with explicit windows instead.
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

// Absolute window. Deliberately NOT cbvRelEq(): that helper floors its
// magnitude at 1.0, so below ~1.0 it silently degenerates into an absolute
// tolerance and an assertion written as "relative" stops being one. Every
// reconFactor() quantity asserted in this file is O(1) or smaller (1.0, 1.3,
// 0.5), so the window is stated in absolute terms on purpose and the number in
// the call site is the real tolerance.
(:debug)
function cbvNear(a, b, eps) {
    var d = a - b;
    if (d < 0.0) { d = -d; }
    return d <= eps;
}

// Fresh view primed at t=1000 (dt=0, no update), then `n` active samples at
// constant `power`, 1 Hz. Internal timer ends at (1000 + 1000*n) ms.
(:debug)
function cbvWarmView(power, n) {
    var v = cbvNewView();
    var t = 1000;
    v.compute(mkInfo(power, t, null));           // prime timer, dt=0
    for (var i = 0; i < n; i += 1) {
        t += 1000;
        v.compute(mkInfo(power, t, null));       // dt=1 active samples
    }
    return v;
}

// -------- harness liveness probe --------

// mkInfo() assumes Activity.Info is constructible and its fields writable -
// including ASSIGNABLE TO NULL, which is the form the coast tests depend on
// (mkInfo(null, t, null)). #28 confirmed all of this; this is a contract guard
// against it regressing, not a live risk.
//
// NOTE: no ordering is claimed or relied upon. Monkey C gives no test-ordering
// guarantee and `monkeydo -t <name>` runs a single test in isolation, so this
// cannot be depended on to run "first" and diagnose the others. It stands or
// falls on its own.
(:test)
function test_activity_info_surface(logger) {
    var info = new Activity.Info();
    info.currentPower = 123;
    info.timerTime    = 4567;
    info.calories     = 89;
    var writable = (info.currentPower == 123) && (info.timerTime == 4567)
                   && (info.calories == 89);
    // The coast path passes nulls; prove the fields accept them.
    info.currentPower = null;
    info.calories     = null;
    var nullable = (info.currentPower == null) && (info.calories == null);
    logger.debug("writable=" + writable + " nullable=" + nullable);
    return writable && nullable;
}

// -------- #8: warm-up seeding --------

// First active sample seeds the EMA exactly (alpha 1.0), not 0.10*inst.
(:test)
function test_warmup_seeds_first_sample(logger) {
    var v = cbvNewView();
    v.compute(mkInfo(200, 1000, null));          // prime (dt=0)
    v.compute(mkInfo(200, 2000, null));          // first active (dt=1)
    var expected = v.carbRateAt(200.0);
    var seeded   = cbvRelEq(v.mCarbRate, expected, 0.0001);
    var oneN     = (v.mRollN == 1);
    // Rounding agreement of the value setFitData() would clamp into carb_rate.
    // (This compares two in-memory floats; it does not touch a FIT field.)
    var sameRounded = (v.clampU16(v.mCarbRate) == v.clampU16(expected));
    // mFatRate must seed too, asserted from a COMPUTED value - otherwise its EMA
    // line could be deleted entirely and the suite would stay green, while
    // zoneColor()'s fat-max band still reads it.
    var fatSeeded = cbvRelEq(v.mFatRate, cbvExpectedFat(v, 200.0), 0.0001);
    logger.debug("seeded=" + seeded + " oneN=" + oneN + " sameRounded=" + sameRounded
                 + " fatSeeded=" + fatSeeded + " carbRate=" + v.mCarbRate
                 + " fatRate=" + v.mFatRate);
    return seeded && oneN && sameRounded && fatSeeded;
}

// Expected instantaneous fat rate (g/h) at `power`, derived from the view's own
// public model so it stays settings-independent:
//   carb g/h = frac * kcalPerHr / 4      =>  kcalPerHr = carbRateAt * 4 / frac
//   fat  g/h = (1-frac) * kcalPerHr / 9  =>  (1-frac)/frac * carbRateAt * 4/9
(:debug)
function cbvExpectedFat(v, power) {
    var frac = v.choFraction(power);
    return (1.0 - frac) / frac * v.carbRateAt(power) * (4.0 / 9.0);
}

// #8's headline requirement is that the warm-up divisor is FLOAT: `1.0/mRollN`.
// The integer mutant `1/mRollN` yields 1 at n=1 (bit-identical seeding) and 0
// for every n >= 2, collapsing the 1, 1/2, 1/3 ... ramp straight to aSteady.
// Nothing catches that unless a test observes n in [2,9] with a CHANGING target,
// because at constant power inst - x == 0 and every update is a no-op for any
// alpha. So: vary the power on each of those samples and check the EMA against
// the expected max(0.10, 1.0/n) ramp. 1/n > 0.10 for all n <= 9.
(:test)
function test_warmup_ramp_uses_fractional_alpha(logger) {
    var v = cbvNewView();
    var t = 1000;
    v.compute(mkInfo(200, t, null));                 // prime (dt=0)
    t += 1000;
    v.compute(mkInfo(200, t, null));                 // n=1: seeds exactly
    var x  = v.carbRateAt(200.0);
    var ok = cbvRelEq(v.mCarbRate, x, 0.0001);
    var powers = [320, 140, 300, 160, 280, 180, 260, 200];   // n = 2..9
    for (var i = 0; i < 8; i += 1) {
        t += 1000;
        var p = powers[i];
        v.compute(mkInfo(p, t, null));
        var a = 1.0 / (i + 2);                       // 0.5, 0.333, ... 0.111
        if (a < 0.10) { a = 0.10; }
        x = x + a * (v.carbRateAt(p.toFloat()) - x);
        if (!cbvRelEq(v.mCarbRate, x, 0.0001)) { ok = false; }
    }
    logger.debug("ok=" + ok + " rollN=" + v.mRollN
                 + " carbRate=" + v.mCarbRate + " expected=" + x);
    return ok && (v.mRollN == 9);
}

// A coasting PREFIX must not consume the warm-up: the first ACTIVE sample still
// seeds exactly. Covers both coast forms - null power AND power <= 0.
(:test)
function test_warmup_not_consumed_by_coast_prefix(logger) {
    var v = cbvNewView();
    v.compute(mkInfo(null, 1000, null));         // prime (dt=0)
    v.compute(mkInfo(null, 2000, null));         // coast, null power
    v.compute(mkInfo(0,    3000, null));         // coast, ZERO power (<= 0 path)
    v.compute(mkInfo(null, 4000, null));         // coast, null power
    var untouched = (v.mRollN == 0);             // warm-up not consumed
    var coasted   = cbvRelEq(v.mCoastSec, 3.0, 0.0001);
    v.compute(mkInfo(200, 5000, null));          // first ACTIVE sample
    var seeded = cbvRelEq(v.mCarbRate, v.carbRateAt(200.0), 0.0001) && (v.mRollN == 1);
    var coastCleared = (v.mCoastSec == 0.0);
    logger.debug("untouched=" + untouched + " coasted=" + coasted + " seeded=" + seeded
                 + " coastCleared=" + coastCleared);
    return untouched && coasted && seeded && coastCleared;
}

// A second resetSession() (via onTimerReset) re-arms the warm-up; the test
// pre-warms past n>=10 first, so a missed reset would show as alpha 0.10.
(:test)
function test_reset_rearms_warmup(logger) {
    var v = cbvWarmView(200, 15);                      // mRollN = 15 (>=10)
    var warmedN = v.mRollN;
    v.onTimerReset();                                  // resetSession
    var rearmed = (v.mRollN == 0) && (v.mCoastSec == 0.0)
                  && cbvRelEq(v.mCarbRate, 0.0, 0.0001);
    v.compute(mkInfo(200, 100000, null));              // prime again (dt=0)
    v.compute(mkInfo(200, 101000, null));              // first active -> seeds exactly
    var seeded = cbvRelEq(v.mCarbRate, v.carbRateAt(200.0), 0.0001) && (v.mRollN == 1);
    logger.debug("warmedN=" + warmedN + " rearmed=" + rearmed + " seeded=" + seeded);
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
    var v = cbvNewView();
    var a1   = v.steadyAlpha(1.0);      // fast-path: exactly RATE_ALPHA (0.10)
    var a2   = v.steadyAlpha(2.0);      // 1 - 0.9^2  = 0.19
    var aHal = v.steadyAlpha(0.5);      // 1 - 0.9^.5 = 0.051317
    var aBig = v.steadyAlpha(1000.0);   // pow underflows to 0 -> 1.0 (never exceeds it)
    // For dt > 0, 1 - 0.9^dt is always < 1, so the UPPER clamp is defensive and
    // unreachable; the LOWER clamp needs dt < 0 (1 - 0.9^-1 = -0.111 -> 0.0).
    // Production cannot produce dt <= 0 (compute() guards t > mLastTimerMs), so
    // this is the only way to execute that branch.
    var aNeg = v.steadyAlpha(-1.0);
    var ok1   = cbvRelEq(a1, 0.10, 0.000001);
    var ok2   = cbvRelEq(a2, 0.19, 0.0001);
    // Explicit window, not cbvRelEq: its m<1.0 floor would turn a 1e-3 relative
    // tolerance into 1e-3 absolute and let a linear alpha (RATE_ALPHA*dt = 0.05)
    // slip through.
    var okHal = (aHal > 0.05126) && (aHal < 0.05138);
    var okBig = (aBig <= 1.0) && (aBig >= 0.999);
    var okNeg = (aNeg == 0.0);          // clamped, not negative
    logger.debug("a1=" + a1 + " a2=" + a2 + " aHalf=" + aHal + " aBig=" + aBig
                 + " aNeg=" + aNeg);
    return ok1 && ok2 && okHal && okBig && okNeg;
}

// Real-time invariance: one dt=2 step == two dt=1 steps.
// NOTE: the step power MUST differ from the warm-up power. At constant power
// the EMA sits on its fixed point (inst - x == 0), so the update is a no-op for
// any alpha and the test would pass even with #16 removed.
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
    // Measured as a FRACTION OF THE GAP it was closing, not an absolute delta:
    // cbvRelEq's m<1.0 floor turns a small-value comparison into an absolute
    // 0.01 g/h window, which red-lights on legal narrow-span settings where the
    // rates are tiny. Correct dt-aware code closes 19% of the gap; a no-op 0%.
    var gap   = v1.carbRateAt(PSTEP.toFloat()) - warmVal;
    if (gap < 0.0) { gap = -gap; }
    var delta = v1.mCarbRate - warmVal;
    if (delta < 0.0) { delta = -delta; }
    var moved = (gap > 0.0) && (delta >= 0.10 * gap);
    logger.debug("same=" + same + " moved=" + moved
                 + " v1=" + v1.mCarbRate + " v2=" + v2.mCarbRate + " warm=" + warmVal);
    return same && moved;
}

// -------- #7: coasting % relaxes with a sustained-coast guard --------

// Brief dropout (< COAST_HOLD_S) holds % and colour; crossing the threshold
// starts the relax and it keeps going. Covers both coast forms (null and 0).
// mCarbPctRoll is set directly so the RED precondition holds at any FTP.
(:test)
function test_coast_brief_dropout_and_boundary(logger) {
    var v = cbvWarmView(400, 20);
    v.mCarbPctRoll = 90.0;                             // >= 85 => RED, settings-independent
    var redInit = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_RED);
    var pctBefore = v.mCarbPctRoll;
    var t = 21000;
    t += 1000; v.compute(mkInfo(null, t, null));       // coast 1.0 s, null
    t += 1000; v.compute(mkInfo(0,    t, null));       // coast 2.0 s, ZERO  (< 3.0)
    var heldBelowThreshold = cbvRelEq(v.mCarbPctRoll, pctBefore, 0.000001)
                             && (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_RED)
                             && cbvRelEq(v.mCoastSec, 2.0, 0.0001);
    t += 1000; v.compute(mkInfo(0, t, null));          // coast 3.0 s >= COAST_HOLD_S -> relax
    var relaxesAtThreshold = (v.mCarbPctRoll < pctBefore)
                             && cbvRelEq(v.mCoastSec, 3.0, 0.0001);
    // Compare the NEXT sample against the value right after the threshold, not
    // against pctBefore: a one-shot implementation would leave this unchanged.
    var pctAtThreshold = v.mCarbPctRoll;
    t += 1000; v.compute(mkInfo(null, t, null));
    var keepsRelaxing = (v.mCarbPctRoll < pctAtThreshold)
                        && cbvRelEq(v.mCoastSec, 4.0, 0.0001);
    logger.debug("redInit=" + redInit + " held=" + heldBelowThreshold
                 + " relaxes=" + relaxesAtThreshold + " keeps=" + keepsRelaxing
                 + " pct=" + v.mCarbPctRoll);
    return redInit && heldBelowThreshold && relaxesAtThreshold && keepsRelaxing;
}

// B1 regression: the hold is measured in SECONDS, so ONE long coast sample -
// which drives the rates to ~0 via steadyAlpha(dt)~=1 - must also relax the %.
// A sample-counted hold would keep the % pinned high next to a ~0 rate, i.e.
// RED at 0 g/h: exactly the #7 symptom this whole change removes.
(:test)
function test_coast_long_single_sample_relaxes_together(logger) {
    var v = cbvWarmView(400, 20);
    v.mCarbPctRoll = 90.0;                             // RED precondition
    // One 30 s coast sample: aSteady = 1 - 0.9^30 = 0.958.
    v.compute(mkInfo(null, 21000 + 30000, null));
    var ratesCollapsed = (v.mCarbRate < 0.10 * v.carbRateAt(400.0));
    var pctRelaxed     = (v.mCarbPctRoll < 45.0);       // was 90; must move with the rates
    var notRed         = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) != Graphics.COLOR_RED);
    logger.debug("ratesCollapsed=" + ratesCollapsed + " pctRelaxed=" + pctRelaxed
                 + " notRed=" + notRed + " pct=" + v.mCarbPctRoll
                 + " carbRate=" + v.mCarbRate + " coastSec=" + v.mCoastSec);
    return ratesCollapsed && pctRelaxed && notRed;
}

// Sustained coast leaves RED (no "0 g/h in RED") and lands on the grey the
// caller passed; resuming power resets the coast timer and the % climbs back.
(:test)
function test_coast_sustained_and_resume(logger) {
    var v = cbvWarmView(400, 20);
    v.mCarbPctRoll = 90.0;
    var preRate = v.mCarbRate;
    var t = 21000;
    for (var j = 0; j < 60; j += 1) { t += 1000; v.compute(mkInfo(null, t, null)); }
    // Relative, so gross efficiency (settings.xml allows 15-30) cannot flip it.
    var ratesGone = (v.mCarbRate < 0.02 * preRate) && (preRate > 0.0);
    var pctGone   = (v.mCarbPctRoll < 5.0);
    // Assert the ACTUAL colour, not merely "not RED" (which pctGone entails).
    var greyNow   = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_LT_GRAY);
    var pctAtRest = v.mCarbPctRoll;
    var coastReset = true;
    for (var k = 0; k < 10; k += 1) {
        t += 1000;
        v.compute(mkInfo(400, t, null));
        if (k == 0 && v.mCoastSec != 0.0) { coastReset = false; }   // cleared on the FIRST active sample
    }
    // Recovery asserted as a FRACTION OF THE GAP toward the achievable target,
    // not a fixed +10 pp: at legal settings where 400 W sits below LT1 the
    // achievable carb % is small and an absolute margin red-lights (89 of 2856
    // legal (ftp, lt1) points). 10 samples at alpha 0.10 close ~65% of the gap.
    // NOTE this also documents a deliberate behaviour change: mRollN is NOT
    // re-armed after a coast, so recovery runs at the steady alpha (~25 s to
    // threshold) where main showed RED instantly because its % never left.
    var pctTarget = v.choFraction(400.0) * 100.0;
    var pctGap    = pctTarget - pctAtRest;
    var recovered = (pctGap > 0.0)
                    && (v.mCarbPctRoll >= pctAtRest + 0.25 * pctGap);
    logger.debug("ratesGone=" + ratesGone + " pctGone=" + pctGone + " grey=" + greyNow
                 + " coastReset=" + coastReset + " recovered=" + recovered
                 + " pct=" + v.mCarbPctRoll);
    return ratesGone && pctGone && greyNow && coastReset && recovered;
}

// Coasting from a cold start must not throw (it would if the coast branch
// dereferenced a null currentPower) and must leave the warm-up unseeded.
// NOTE: this deliberately does NOT assert "the rates stay 0" - from a zero
// start, x + a*(0-x) == 0 for any alpha, so that assertion cannot fail and
// would prove nothing. Rate decay is covered by the tests above.
(:test)
function test_coast_cold_start_null_and_zero(logger) {
    var v = cbvNewView();
    v.compute(mkInfo(null, 1000, null));               // prime, null power
    v.compute(mkInfo(null, 2000, null));               // coast, null, dt=1
    var afterNull = cbvRelEq(v.mCoastSec, 1.0, 0.0001);
    v.compute(mkInfo(0, 3000, null));                  // coast, zero power, dt=1
    var afterZero = cbvRelEq(v.mCoastSec, 2.0, 0.0001);
    var stillUnseeded = (v.mRollN == 0);
    logger.debug("afterNull=" + afterNull + " afterZero=" + afterZero
                 + " stillUnseeded=" + stillUnseeded + " coastSec=" + v.mCoastSec);
    return afterNull && afterZero && stillUnseeded;
}

// -------- #59: reconFactor() characterization (pre-existing contract) --------

// The #59 trigger, as one sequence: a prime sample, one COAST sample during
// which Garmin has already counted `cal` kcal, then the first POWERED sample at
// dt = 1 s. That leaves a numerator of `cal` over a denominator of exactly one
// sample of model kcal. Every quantity is fed in; nothing is set directly.
(:debug)
function cbvColdStart(power, cal) {
    var v = cbvNewView();
    v.compute(mkInfo(null, 1000, null));      // prime, dt = 0
    v.compute(mkInfo(null, 2000, cal));       // coast; Garmin is already counting
    v.compute(mkInfo(power, 3000, cal));      // first powered sample, dt = 1 s
    return v;
}

// Model kcal for ONE 1 s sample at `power`, from the view's own public model so
// it stays settings-independent (CarbBurnTest.mc:14-19):
//   carbRateAt(p) = frac * (p/GE)/4184 * 3600 / 4
//   =>  (p/GE)/4184 = carbRateAt(p) * 4 / (frac * 3600)
(:debug)
function cbvExpectedKcalPerSec(v, power) {
    return v.carbRateAt(power) * 4.0 / (v.choFraction(power) * 3600.0);
}

// MECHANISM pin, green before and after the #59 bound. It asserts the two
// halves of the accrual asymmetry that creates the defect, and nothing about
// the factor itself - so the bound may change the factor freely and this test
// still has to hold:
//   numerator   - a non-null info.calories reaches mGarminKcal from the COAST
//                 sample, i.e. before the model has counted anything (:408-410);
//   denominator - after the first powered sample mModelKcal is exactly ONE
//                 sample of model kcal (:350), which is < 1 kcal at any legal
//                 setting, i.e. two orders of magnitude under any floor worth
//                 having.
// It also pins the #8 warm-up seed that makes the spike visible: mCarbRate is
// the true instantaneous rate, so whatever the factor does, it multiplies a
// correct value.
//
// Incidentally this is the first test in the suite to feed a non-null
// info.calories through compute() at all - part of #48's gap, not all of it
// (#48 also wants mGarminKcal asserted to TRACK a series; that belongs there).
(:test)
function test_recon_cold_start_mechanism(logger) {
    var v = cbvColdStart(200, 1);
    var oneSample = cbvExpectedKcalPerSec(v, 200.0);
    var numerator = cbvNear(v.mGarminKcal, 1.0, 0.000001);
    var denomIsOneSample = cbvNear(v.mModelKcal, oneSample, 0.0001 * oneSample);
    var denomIsTiny = (v.mModelKcal < 1.0) && (v.mModelKcal > 0.0);
    var seeded = cbvNear(v.mCarbRate, v.carbRateAt(200.0),
                         0.0001 * v.carbRateAt(200.0)) && (v.mRollN == 1);
    logger.debug("numerator=" + numerator + " denomIsOneSample=" + denomIsOneSample
                 + " denomIsTiny=" + denomIsTiny + " seeded=" + seeded
                 + " garminKcal=" + v.mGarminKcal + " modelKcal=" + v.mModelKcal
                 + " oneSample=" + oneSample + " carbRate=" + v.mCarbRate);
    return numerator && denomIsOneSample && denomIsTiny && seeded;
}

// CHARACTERIZATION. Pins the part of reconFactor()'s contract that the #59
// bound must NOT disturb, on arms it is green for both before and after that
// change: the plain ratio for a healthy denominator, and 1.0 on each of the
// three degenerate inputs.
//
// It is also the anti-vacuity guard for the #59 tests further down: those two
// assert that recon FALLS BACK to 1.0 in a cold-start window, and `return 1.0;`
// would satisfy them both. This test is what makes that mutant red.
//
// The 2.5 arm is deliberate and is the reason it is here rather than folded
// into an existing test. It records that the intended upper bound is ABOVE 2.0:
// 2.0 is exactly the third arm of test_zonecolor_recon_invariant (:423 at the
// time of writing), so a bound of 2.0 would leave that test passing on the
// coincidence that clamping 2.0 to 2.0 is a no-op. 2.5 has no such excuse.
(:test)
function test_recon_factor_current_shape(logger) {
    var v = cbvNewView();
    v.mModelKcal = 100.0; v.mGarminKcal = 130.0; var r13 = v.reconFactor();
    v.mModelKcal = 100.0; v.mGarminKcal = 200.0; var r20 = v.reconFactor();
    v.mModelKcal = 100.0; v.mGarminKcal = 250.0; var r25 = v.reconFactor();
    v.mModelKcal = 0.0;   v.mGarminKcal = 0.0;   var bothZero = v.reconFactor();
    v.mModelKcal = 100.0; v.mGarminKcal = 0.0;   var noGarmin = v.reconFactor();
    v.mModelKcal = 0.0;   v.mGarminKcal = 130.0; var noModel  = v.reconFactor();
    var live = cbvNear(r13, 1.3, 0.000001) && cbvNear(r20, 2.0, 0.000001)
               && cbvNear(r25, 2.5, 0.000001);
    var degenerate = cbvNear(bothZero, 1.0, 0.0) && cbvNear(noGarmin, 1.0, 0.0)
                     && cbvNear(noModel, 1.0, 0.0);
    logger.debug("live=" + live + " (" + r13 + "/" + r20 + "/" + r25 + ")"
                 + " degenerate=" + degenerate
                 + " (" + bothZero + "/" + noGarmin + "/" + noModel + ")");
    return live && degenerate;
}

// -------- #15: fat-max BLUE band is reconFactor()-invariant --------
// The band boundary must not move with reconFactor(), asserted across 3 recon
// values below and above the 0.95*peak threshold - plus a check that recon
// really does differ, or the invariance would be vacuous.
(:test)
function test_zonecolor_recon_invariant(logger) {
    var v = cbvNewView();
    v.mCarbPctRoll = 10.0;                              // below ORANGE/RED so we reach the BLUE test
    var peak = v.mFatMaxRate;

    // Anti-vacuity: prove the three settings really produce different recon.
    v.mModelKcal = 0.0;   v.mGarminKcal = 0.0;   var r1 = v.reconFactor();
    v.mModelKcal = 100.0; v.mGarminKcal = 130.0; var r2 = v.reconFactor();
    v.mModelKcal = 100.0; v.mGarminKcal = 200.0; var r3 = v.reconFactor();
    var reconVaries = cbvRelEq(r1, 1.0, 0.0001) && cbvRelEq(r2, 1.3, 0.0001)
                      && cbvRelEq(r3, 2.0, 0.0001);

    // Just BELOW the boundary -> not blue at any recon.
    v.mFatRate = 0.90 * peak;
    v.mModelKcal = 0.0;   v.mGarminKcal = 0.0;   var below1 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 130.0; var below2 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 200.0; var below3 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    var belowInvariant = (below1 == below2) && (below1 == below3)
                         && (below1 != Graphics.COLOR_BLUE);

    // At/ABOVE the boundary -> BLUE at every recon (same 3 values). This arm is
    // a POSITIVE CONTROL, not a discriminator: at 1.00*peak the test passes
    // under both the fixed and the pre-#15 code. All the #15 discrimination
    // lives in the `below` arm, where recon=2.0 made the old
    // `mFatRate * recon >= 0.95 * peak` true and the fixed form false.
    v.mFatRate = 1.00 * peak;
    v.mModelKcal = 0.0;   v.mGarminKcal = 0.0;   var above1 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 130.0; var above2 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    v.mModelKcal = 100.0; v.mGarminKcal = 200.0; var above3 = v.zoneColor(Graphics.COLOR_LT_GRAY, true);
    var aboveInvariant = (above1 == above2) && (above1 == above3)
                         && (above1 == Graphics.COLOR_BLUE);

    // The light-background variant (onDark = false) is otherwise uncovered.
    var aboveLight = (v.zoneColor(Graphics.COLOR_DK_GRAY, false) == Graphics.COLOR_DK_BLUE);

    logger.debug("reconVaries=" + reconVaries + " (" + r1 + "/" + r2 + "/" + r3 + ")"
                 + " below=" + below1 + "/" + below2 + "/" + below3
                 + " above=" + above1 + "/" + above2 + "/" + above3
                 + " aboveLight=" + aboveLight + " peak=" + peak);
    return reconVaries && belowInvariant && aboveInvariant && aboveLight;
}
