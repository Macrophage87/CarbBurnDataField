using Toybox.Test;
using Toybox.Graphics;
using Toybox.Activity;

//
// Unit tests for the rolling-metrics correctness fixes (epic #22: #7, #8, #15,
// #16) and the power-signal continuity / derived-percentage rework (#33). These
// drive the real CarbBurnView logic with a synthetic Activity.Info, so warm-up
// seeding, dt-aware smoothing, the ACTIVE/DROPOUT/COASTING classifier, the
// derived carb % and the flux floor are exercised end to end.
//
// Everything here is (:debug)/(:test), so none of it ships in a release (-r)
// build.
//
// SETTINGS INDEPENDENCE: the suite never relies on a particular FTP / LT1 /
// gross-efficiency. It compares against the view's own model (carbRateAt(),
// mFatMaxRate) or sets rolling state directly, because a simulator carries
// persisted device settings that differ from the repo defaults (#28), and
// settings.xml permits FTP 50-600, LT1 0-500 and GE 15-28. Assertions that
// depended on the model's 85%-at-FTP anchor sat on a knife-edge at FTP=400 and
// are gone.
//
// THOSE RANGES ARE LOAD-BEARING, not decoration. Several assertions below are
// non-vacuous only because a tolerance was chosen against the smallest value
// the model can produce anywhere in that box, so a comment quoting an
// OUT-OF-RANGE witness hides the very defect it is meant to warn about. Two
// were shipped: this paragraph said "GE 15-30" (settings.xml says 15-28) and
// cbvClose's said "lt1=599" (settings.xml caps lt1 at 500). Re-read
// resources/settings/settings.xml before trusting any witness quoted here.
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
// NOTE on the classifier (#33): currentSpeed / currentCadence are left NULL
// here, and null means "no such sensor / no data", which is deliberately NOT
// treated as evidence of a stop. Tests that need the stop-suppression path use
// mkInfoFull() below and pass an explicit 0.
(:debug)
function mkInfo(power, tMs, cal) {
    return mkInfoFull(power, tMs, cal, null, null);
}

(:debug)
function mkInfoFull(power, tMs, cal, speed, cadence) {
    var info = new Activity.Info();
    info.currentPower   = power;   // Number or null: null = NO reading (dropout),
                                   // 0 = a measured zero (real coast)
    info.timerTime      = tMs;     // ms since timer start (drives dt)
    info.calories       = cal;     // Garmin cumulative kcal or null
    info.currentSpeed   = speed;   // null = unknown, 0 = reported stop
    info.currentCadence = cadence; // null = unknown, 0 = reported stop
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

// Comparison with an EXPLICIT absolute window as well as a relative one, for
// quantities that can legitimately be far below 1.0. cbvRelEq's m < 1.0 floor
// turns any relative tolerance into an absolute one down there, which makes an
// assertion vacuous.
//
// The witness has to be REACHABLE. An earlier revision of this comment cited
// ftp=600 / lt1=599; settings.xml caps lt1 at 500, so that pair can never
// occur and the warning pointed at nothing. The real one is ftp=500 / lt1=499,
// both legal: the logistic argument clamps at -30, so choFraction(400) =
// 9.3576e-14, the derived carb % is 9.3576e-12 and the rolling carb rate is
// 3.8340e-11 g/h. At those magnitudes cbvRelEq(x, target, 1e-6) admits 0.0 -
// and so does cbvClose(x, target, 1e-7, 1e-4), which is why picking a
// comfortable-looking small absTol is not a fix either.
//
// So: callers comparing two quantities that can never BOTH be legitimately
// zero pass absTol = 0.0 and state the anti-vacuity guard themselves
// (`target > 0.0`). The window is then purely proportional, it scales all the
// way down, and there is no constant to re-derive when the model changes.
//
// The reconFactor() pins from #59 use the other end of the same helper: their
// quantities are O(1) fixed targets (1.0, 1.3, 2.0, 0.5) that are never
// legitimately near zero, so they pass an explicit absTol with relTol = 0.0
// and the window in the call site IS the tolerance. One helper, one rationale;
// do not add a second near-equality helper for either pattern.
(:debug)
function cbvClose(a, b, absTol, relTol) {
    var d = a - b;
    if (d < 0.0) { d = -d; }
    if (d <= absTol) { return true; }
    var m = a;
    if (m < 0.0) { m = -m; }
    var mb = b;
    if (mb < 0.0) { mb = -mb; }
    if (mb > m) { m = mb; }
    return d <= relTol * m;
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
    // #33's classifier reads currentSpeed / currentCadence, and mkInfoFull()
    // assigns both - including null, which is the "unknown, do not suppress"
    // case. Same contract guard as above.
    info.currentSpeed   = 8.5;
    info.currentCadence = 90;
    var motionWritable = (info.currentSpeed == 8.5) && (info.currentCadence == 90);
    info.currentSpeed   = null;
    info.currentCadence = null;
    var motionNullable = (info.currentSpeed == null) && (info.currentCadence == null);
    logger.debug("writable=" + writable + " nullable=" + nullable
                 + " motionWritable=" + motionWritable + " motionNullable=" + motionNullable);
    return writable && nullable && motionWritable && motionNullable;
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
// seeds exactly. Covers both coast forms - null power AND power <= 0 - and pins
// #33's rule 1: mNullSec counts only samples with NO reading, so the 0-W sample
// in the middle must NOT advance it, and it is cleared only on ACTIVE.
(:test)
function test_warmup_not_consumed_by_coast_prefix(logger) {
    var v = cbvNewView();
    v.compute(mkInfo(null, 1000, null));         // prime (dt=0)
    v.compute(mkInfo(null, 2000, null));         // no reading, dt=1
    v.compute(mkInfo(0,    3000, null));         // MEASURED zero (real coast)
    v.compute(mkInfo(null, 4000, null));         // no reading, dt=1
    var untouched = (v.mRollN == 0);             // warm-up not consumed
    var nullOnly  = cbvRelEq(v.mNullSec, 2.0, 0.0001);   // 3.0 would count the 0 W
    // Nothing was ever carried: no ACTIVE sample has been seen, so there is no
    // last power and the carry is unarmed.
    var noCarry   = (v.mLastPower < 0.0) && (v.mCarryArmed == false);
    v.compute(mkInfo(200, 5000, null));          // first ACTIVE sample
    var seeded = cbvRelEq(v.mCarbRate, v.carbRateAt(200.0), 0.0001) && (v.mRollN == 1);
    var nullCleared = (v.mNullSec == 0.0);
    logger.debug("untouched=" + untouched + " nullOnly=" + nullOnly + " noCarry=" + noCarry
                 + " seeded=" + seeded + " nullCleared=" + nullCleared
                 + " nullSec=" + v.mNullSec);
    return untouched && nullOnly && noCarry && seeded && nullCleared;
}

// A second resetSession() (via onTimerReset) re-arms the warm-up; the test
// pre-warms past n>=10 first, so a missed reset would show as alpha 0.10.
(:test)
function test_reset_rearms_warmup(logger) {
    var v = cbvWarmView(200, 15);                      // mRollN = 15 (>=10)
    var warmedN = v.mRollN;
    v.onTimerReset();                                  // resetSession
    // A reset is a signal gap of unknown length, so the whole #33 state machine
    // must come back to "nothing known": no last power, nothing armed, and the
    // flux latch low so the percentage reads "--" rather than a stale number.
    var rearmed = (v.mRollN == 0) && (v.mNullSec == 0.0)
                  && (v.mLastPower < 0.0) && (v.mCarryArmed == false)
                  && (v.mFluxLow == true) && (v.mActiveRun == 0)
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

// -------- #33: ACTIVE / DROPOUT / COASTING classification --------

// A brief gap with NO power reading is a measurement gap, so it is modelled at
// the last known power and the rates barely move. Past SIGNAL_GRACE_S it becomes
// a coast and they decay. The middle sample here STRADDLES the boundary, which
// is the case a test-then-carry implementation gets wrong: it must be split
// (0.5 s carried, 0.5 s coasted), not carried whole and not dropped whole.
(:test)
function test_dropout_carry_and_grace_boundary(logger) {
    var v = cbvWarmView(400, 20);                      // EMA parked on 400 W
    var held = v.mCarbRate;
    var t = 21000;
    t += 1000; v.compute(mkInfo(null, t, null));       // mNullSec 0.0 -> 1.0, fully carried
    t += 1000; v.compute(mkInfo(null, t, null));       // 1.0 -> 2.0, fully carried
    // Carried samples re-run the ACTIVE path at the same power, and the EMA is
    // already at that fixed point, so the rate must not move at all.
    //
    // NOT cbvRelEq: its m < 1.0 floor turned that 1e-6 into an ABSOLUTE 1e-6,
    // and at the legal (ftp 500, lt1 499) `held` is 3.83e-11 - so this arm
    // reported true with the whole DROPOUT carry deleted. A proportional window
    // (absTol 0.0) plus an explicit `held > 0.0` cannot degenerate: one coasted
    // second moves the rate by 10 %, which is 1000x this window at every legal
    // setting.
    var carriedFlat = (held > 0.0)
                      && cbvClose(v.mCarbRate, held, 0.0, 0.0001)
                      && cbvRelEq(v.mNullSec, 2.0, 0.0001);
    t += 1000; v.compute(mkInfo(null, t, null));       // 2.0 -> 3.0: 0.5 carried, 0.5 coast
    var straddled = (v.mCarbRate < held) && cbvRelEq(v.mNullSec, 3.0, 0.0001);
    var afterStraddle = v.mCarbRate;
    t += 1000; v.compute(mkInfo(null, t, null));       // past grace: full coast decay
    var decayed = (v.mCarbRate < afterStraddle);
    // The straddling sample coasts for only half as long as the one after it, so
    // it must have decayed strictly less. This is what separates "split" from
    // "dropped whole".
    var splitNotDropped = (held - afterStraddle) < (afterStraddle - v.mCarbRate);
    logger.debug("carriedFlat=" + carriedFlat + " straddled=" + straddled
                 + " decayed=" + decayed + " splitNotDropped=" + splitNotDropped
                 + " held=" + held + " straddle=" + afterStraddle + " now=" + v.mCarbRate);
    return carriedFlat && straddled && decayed && splitNotDropped;
}

// The carry is clamped to the room LEFT in the window - `room = SIGNAL_GRACE_S -
// mNullSec` reads the pre-increment mNullSec, and the increment plus the disarm
// follow - so one enormous sample cannot accrue phantom pedalling for its whole
// duration. Asserted in energy, against the view's own measured per-second
// accrual, so it holds at any legal settings.
//
// The pre-increment reading is deliberate. #33's rules "increment then test" and
// "clamp so a straddling dt is split" are in literal tension: post-increment,
// a dt=300 sample gives room = -297.5 and the split is vacuous - the whole sample
// coasts, which is indistinguishable from having no clamp at all. Pre-increment
// is the only reading under which BOTH rules mean something, so that is what the
// code does, and the straddle test above is what proves the split is real.
(:test)
function test_dropout_carry_bounded_on_one_long_sample(logger) {
    var v = cbvWarmView(400, 60);
    var t = 61000;
    // Measure this view's kcal for exactly 1 s of active 400 W.
    //
    // The Garmin calorie total fed on this sample is what gives the mRateDisp
    // assertion below any content. mRateDisp = mCarbRate * reconFactor(), and
    // with no calorie feed reconFactor() returns exactly 1.0, so the two sides
    // are bit-identical BY CONSTRUCTION and the assertion cannot fail whatever
    // the code does - it was a tautology, and #33's "assert on mRateDisp" went
    // unsatisfied. It touches nothing else asserted here: recon feeds only the
    // display values, not mCarbRate / mFatRate / mCarbPctRoll / mFluxLow.
    //
    // The witness had to be REBUILT for #59's bound, and this is the whole
    // reason the warm-up is 60 samples rather than 20. It used to warm 20
    // samples and feed a flat 500 kcal, which put recon "in the tens" - but
    // that factor came from a denominator of 7-14 modelled kcal, i.e. it WAS
    // the #59 defect, and at the repo default gross efficiency (21 %) the
    // denominator was 9.560 kcal, below RECON_MIN_KCAL. reconFactor() now
    // correctly returns 1.0 there and the arm went vacuous-and-false. So:
    //   - 60 warm samples put the denominator at 20.8-38.9 kcal across the
    //     legal gross-efficiency range (15-28 %), at least 2x the floor, so the
    //     floor cannot engage at any legal setting; and
    //   - the calorie total is DERIVED from this view's own modelled kcal
    //     rather than fixed, so recon lands at ~1.5 - inside the 0.5-3.0 band
    //     at every legal setting, and this arm therefore exercises the
    //     multiplication rather than the clamp. A fixed number cannot do that:
    //     the denominator moves by 1.9x across the legal range.
    var calFeed = (v.mModelKcal * 1.6).toNumber();
    var k0 = v.mModelKcal;
    t += 1000; v.compute(mkInfo(400, t, calFeed));
    var kcalPerSec = v.mModelKcal - k0;
    var pctHeld = v.mCarbPctRoll;
    var before  = v.mModelKcal;

    // #33 requires the fix to be asserted on the DISPLAYED rate. Asserted HERE,
    // before the coast, because afterwards both mRateDisp and mCarbRate are ~0
    // and comparing them is vacuous for a second, independent reason.
    // dispDiffers is the anti-tautology arm: the two sides must be different
    // numbers before an equality between them proves anything.
    var reconNow    = v.reconFactor();
    var dispDiffers = (cbvClose(v.mRateDisp, v.mCarbRate, 0.0, 0.0001) == false);
    var dispTracks  = (reconNow != 1.0) && (v.mCarbRate > 0.0) && dispDiffers
                      && cbvClose(v.mRateDisp, v.mCarbRate * reconNow, 0.0, 0.0001);

    // ONE 300 s gap with no reading. Carry must be <= SIGNAL_GRACE_S (2.5 s).
    t += 300000; v.compute(mkInfo(null, t, null));
    var carried = (v.mModelKcal - before) / kcalPerSec;      // in seconds-equivalent
    var bounded = (kcalPerSec > 0.0) && (carried > 2.0) && (carried < 3.0);

    // The remaining 297.5 s coast collapses both rates, which engages the flux
    // floor - and THAT is what removes RED, not a decaying percentage.
    //
    // NOTE on this particular duration: steadyAlpha(297.5) rounds to exactly 1.0
    // in 32-bit float (0.9^297.5 ~ 2.4e-14 is far below the Float epsilon), so
    // both rates land on exactly 0.0 and the derived percentage takes its 0/0
    // fallback. That is the production path for the guard, so it is pinned here;
    // the "percentage holds through a coast" property is pinned instead at a
    // duration where the rates stay representable (see the resume test).
    var ratesCollapsed = (v.mCarbRate < 0.02 * v.carbRateAt(400.0));
    // NOT "== 0.0": whether both rates land on exactly zero depends on whether
    // Math.pow and the EMA are evaluated in Float or Double (in Float,
    // steadyAlpha(297.5) rounds to exactly 1.0; in Double the rates survive at
    // ~2e-14 of instantaneous). The real intent is "defined and negligible", so
    // assert that - with the self-equality that only NaN fails.
    var pctAbs         = (v.mCarbPctRoll < 0.0) ? -v.mCarbPctRoll : v.mCarbPctRoll;
    var pctGuarded     = (v.mCarbPctRoll == v.mCarbPctRoll)
                         && ((pctAbs < 0.000001) || cbvRelEq(v.mCarbPctRoll, pctHeld, 0.0001));
    var floorEngaged   = (v.mFluxLow == true) && v.carbPctStr().equals("--");
    var greyNow        = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_LT_GRAY);
    logger.debug("carried=" + carried + "s bounded=" + bounded + " pctBefore=" + pctHeld
                 + " ratesCollapsed=" + ratesCollapsed + " pctGuarded=" + pctGuarded
                 + " floorEngaged=" + floorEngaged + " grey=" + greyNow
                 + " dispTracks=" + dispTracks + " recon=" + reconNow
                 + " pct=" + v.mCarbPctRoll + " carbRate=" + v.mCarbRate);
    return bounded && ratesCollapsed && pctGuarded && floorEngaged && greyNow && dispTracks;
}

// The carry re-arms only after CARRY_REARM_N consecutive ACTIVE samples, so a
// link alternating [gap, one reading, gap, one reading...] cannot carry on every
// isolated sample. Without this, a flaky meter accrues phantom energy forever.
(:test)
function test_carry_rearm_requires_consecutive_active(logger) {
    var v = cbvNewView();
    var t = 1000;
    v.compute(mkInfo(400, t, null));                   // prime (dt=0)
    t += 1000; v.compute(mkInfo(400, t, null));        // ACTIVE #1 -> not yet armed
    var notArmedYet = (v.mCarryArmed == false);
    t += 1000; v.compute(mkInfo(400, t, null));        // ACTIVE #2 -> armed
    var armed = (v.mCarryArmed == true);

    // A gap past SIGNAL_GRACE_S means the signal is genuinely lost: disarm.
    t += 4000; v.compute(mkInfo(null, t, null));       // dt=4 > 2.5 -> COASTING
    var disarmed = (v.mCarryArmed == false);

    // ONE reading is not enough to trust the link again, so the NEXT gap must
    // accrue nothing at all - asserted in energy, which is the quantity phantom
    // work is measured in.
    t += 1000; v.compute(mkInfo(400, t, null));        // isolated reading
    var notRearmed = (v.mCarryArmed == false) && (v.mActiveRun == 1);
    var k0 = v.mModelKcal;
    t += 1000; v.compute(mkInfo(null, t, null));       // gap again
    var noPhantom = (v.mModelKcal == k0);

    // Two consecutive readings DO re-arm it, and then a gap carries again.
    t += 1000; v.compute(mkInfo(400, t, null));
    t += 1000; v.compute(mkInfo(400, t, null));
    var rearmed = (v.mCarryArmed == true);
    var k1 = v.mModelKcal;
    t += 1000; v.compute(mkInfo(null, t, null));
    var carriesAgain = (v.mModelKcal > k1);

    logger.debug("notArmedYet=" + notArmedYet + " armed=" + armed
                 + " disarmed=" + disarmed + " notRearmed=" + notRearmed
                 + " noPhantom=" + noPhantom + " rearmed=" + rearmed
                 + " carriesAgain=" + carriesAgain);
    return notArmedYet && armed && disarmed && notRearmed && noPhantom
           && rearmed && carriesAgain;
}

// A MEASURED zero invalidates the carry, so a stale power cannot come back after
// a coast. Without this, an hour of freewheeling at a reported 0 W leaves the
// carry armed and mLastPower stale, and the next single missing reading revives
// an hour-old power: the rates jump off zero, the flux crosses FLUX_RELEASE, and
// the cell flips from "--" to a coloured number. Every other classifier test
// here uses null gaps only, which is exactly why none of them caught it.
(:test)
function test_measured_zero_invalidates_carry(logger) {
    var v = cbvWarmView(400, 20);                      // armed, mLastPower = 400
    var armedBefore = (v.mCarryArmed == true);
    var t = 21000;
    // A long freewheel at a REPORTED zero, with speed still live (descending).
    // 60 s, not 40: the flux has to fall below FLUX_ENGAGE for the floor arms
    // below, and at the lowest legal gross efficiency the flux at 400 W is ~574
    // g/h, which needs ~45 s of decay at alpha 0.10. 40 would red-light there.
    for (var j = 0; j < 60; j += 1) { t += 1000; v.compute(mkInfoFull(0, t, null, 12.0, null)); }
    var disarmed  = (v.mCarryArmed == false);
    var floorLow  = (v.mFluxLow == true) && v.carbPctStr().equals("--");
    var kcalBefore = v.mModelKcal;
    var rateBefore = v.mCarbRate;
    // ...then ONE missing reading, the common dropout shape.
    t += 1000; v.compute(mkInfoFull(null, t, null, 12.0, null));
    var noRevival = (v.mModelKcal == kcalBefore) && (v.mCarbRate <= rateBefore)
                    && (v.mFluxLow == true) && v.carbPctStr().equals("--");
    // And it takes CARRY_REARM_N real readings to trust the link again.
    t += 1000; v.compute(mkInfo(400, t, null));
    var oneNotEnough = (v.mCarryArmed == false);
    t += 1000; v.compute(mkInfo(400, t, null));
    var rearmed = (v.mCarryArmed == true);
    logger.debug("armedBefore=" + armedBefore + " disarmed=" + disarmed
                 + " floorLow=" + floorLow + " noRevival=" + noRevival
                 + " oneNotEnough=" + oneNotEnough + " rearmed=" + rearmed
                 + " rate=" + v.mCarbRate);
    return armedBefore && disarmed && floorLow && noRevival && oneNotEnough && rearmed;
}

// What the carry costs in the regime it was sized for. A 1 Hz link losing one
// sample in three never exceeds SIGNAL_GRACE_S, so it never disarms and every
// gap is carried whole: accrued energy is 3/2 of the pedalled time, NOT the
// pedalled time. That is intended - the readings either side are live evidence
// the rider is pedalling - but it does mean session totals include modelled
// dropout energy, so it is pinned here rather than left to be discovered.
(:test)
function test_dropout_energy_per_gap_bound(logger) {
    var v = cbvWarmView(400, 4);
    var t = 5000;
    var k0 = v.mModelKcal;
    t += 1000; v.compute(mkInfo(400, t, null));
    var kcalPerSec = v.mModelKcal - k0;
    var before = v.mModelKcal;
    // 30 x [400, 400, null] at 1 Hz: 60 pedalled seconds, 30 gaps of 1 s.
    for (var j = 0; j < 30; j += 1) {
        t += 1000; v.compute(mkInfo(400, t, null));
        t += 1000; v.compute(mkInfo(400, t, null));
        t += 1000; v.compute(mkInfo(null, t, null));
    }
    var seconds = (v.mModelKcal - before) / kcalPerSec;
    // 90 s of wall clock, every gap carried: 90, not 60.
    var carriesEveryGap = (kcalPerSec > 0.0) && (seconds > 89.0) && (seconds < 91.0);
    // The loop ends ON a gap, so mNullSec is 1.0 here; one reading clears it, and
    // only then does the next gap get the full window. (Without this the gap below
    // carries 1.5 s, not 2.5 - which is correct behaviour and a wrong assertion.)
    t += 1000; v.compute(mkInfo(400, t, null));
    var stillArmed = (v.mCarryArmed == true) && (v.mNullSec == 0.0);
    // Per-gap bound: no single gap can contribute more than SIGNAL_GRACE_S.
    var k1 = v.mModelKcal;
    t += 10000; v.compute(mkInfo(null, t, null));      // one 10 s gap
    var oneGap = (v.mModelKcal - k1) / kcalPerSec;
    var gapBounded = (oneGap > 2.0) && (oneGap < 3.0);
    logger.debug("seconds=" + seconds + " carriesEveryGap=" + carriesEveryGap
                 + " stillArmed=" + stillArmed + " oneGap=" + oneGap
                 + " gapBounded=" + gapBounded);
    return carriesEveryGap && stillArmed && gapBounded;
}

// A reported stop (speed or cadence exactly 0) proves the rider is not still
// producing the last known power, so a missing reading there is a coast, not a
// dropout worth carrying. null on those fields means "unknown" and must NOT
// suppress the carry - every other test in this file relies on that.
(:test)
function test_carry_suppressed_when_stopped(logger) {
    var vFree = cbvWarmView(400, 20);
    var vStop = cbvWarmView(400, 20);
    var held  = vFree.mCarbRate;
    var t = 22000;
    vFree.compute(mkInfoFull(null, t, null, null, null));   // unknown speed/cadence
    vStop.compute(mkInfoFull(null, t, null, 0.0,  null));   // reported STOP
    // Proportional window plus an explicit anti-vacuity guard, for the reason
    // given at cbvClose: with cbvRelEq's absolute 1e-6 floor this arm - and
    // therefore this whole test, whose other two arms only require a DECAY -
    // passed at (ftp 500, lt1 499) with the DROPOUT carry deleted.
    var carriedWhenUnknown = (held > 0.0)
                             && cbvClose(vFree.mCarbRate, held, 0.0, 0.0001);
    var coastedWhenStopped = (vStop.mCarbRate < held);
    // Cadence alone must do it too (a rider freewheeling downhill at speed).
    var vCad = cbvWarmView(400, 20);
    vCad.compute(mkInfoFull(null, t, null, 12.0, 0));
    var coastedOnCadence = (vCad.mCarbRate < held);
    logger.debug("carriedWhenUnknown=" + carriedWhenUnknown
                 + " coastedWhenStopped=" + coastedWhenStopped
                 + " coastedOnCadence=" + coastedOnCadence
                 + " free=" + vFree.mCarbRate + " stop=" + vStop.mCarbRate);
    return carriedWhenUnknown && coastedWhenStopped && coastedOnCadence;
}

// Coasting from a cold start must not throw (it would if the coast branch
// dereferenced a null currentPower), must leave the warm-up unseeded, and must
// not store NaN in the derived percentage - 0/(0+0) is reachable on the very
// first sample of every session started stationary, and NaN would render "nan".
(:test)
function test_coast_cold_start_null_and_zero(logger) {
    var v = cbvNewView();
    v.compute(mkInfo(null, 1000, null));               // prime, no reading
    v.compute(mkInfo(null, 2000, null));               // no reading, dt=1
    var afterNull = cbvRelEq(v.mNullSec, 1.0, 0.0001);
    v.compute(mkInfo(0, 3000, null));                  // MEASURED zero, dt=1
    var afterZero = cbvRelEq(v.mNullSec, 1.0, 0.0001); // a 0-W sample is not a gap
    var stillUnseeded = (v.mRollN == 0);
    // 0/0 guard: exactly zero, and equal to itself (NaN != NaN).
    var pctDefined = (v.mCarbPctRoll == 0.0) && (v.mCarbPctRoll == v.mCarbPctRoll);
    var showsDashes = v.carbPctStr().equals("--");
    logger.debug("afterNull=" + afterNull + " afterZero=" + afterZero
                 + " stillUnseeded=" + stillUnseeded + " pctDefined=" + pctDefined
                 + " showsDashes=" + showsDashes + " nullSec=" + v.mNullSec);
    return afterNull && afterZero && stillUnseeded && pctDefined && showsDashes;
}

// -------- #33: the derived percentage --------

// The percentage is derived from the two rolling rates, so it reports the
// substrate mix of the power being ridden regardless of how much of the signal
// was lost: a coast decays both rates by the same alpha, which preserves the
// ratio exactly. This is the property that makes "high % beside a ~0 rate"
// impossible by construction rather than guarded by a timer.
(:test)
function test_derived_pct_duty_cycle_invariant(logger) {
    var vFull = cbvWarmView(300, 30);                  // clean 1 Hz signal
    var pctClean = vFull.mCarbPctRoll;

    // Same power, but every other sample is a MEASURED zero, so half the samples
    // coast. Well past the re-arm/grace logic: 0 W is never carried.
    var vDuty = cbvNewView();
    var t = 1000;
    vDuty.compute(mkInfo(300, t, null));               // prime
    for (var i = 0; i < 30; i += 1) {
        t += 1000; vDuty.compute(mkInfo(300, t, null));
        t += 1000; vDuty.compute(mkInfo(0,   t, null));
    }
    var pctDuty = vDuty.mCarbPctRoll;
    // The RATES are roughly halved by the lost samples...
    var ratesLower = (vDuty.mCarbRate < 0.8 * vFull.mCarbRate);
    // ...but the RATIO is not: proportional decay preserves it exactly, so this
    // is a purely relative comparison rather than the 0.5 pp window an earlier
    // revision used. The absolute floor is 0.0 on purpose: at (ftp 500,
    // lt1 499) the percentage itself is 9.36e-12, so a 0.5 pp window - and the
    // 1e-7 that replaced it - both admit 0.0. `pctClean > 0.0` is the
    // anti-vacuity guard that an absolute floor was standing in for.
    var pctSame = (pctClean > 0.0) && cbvClose(pctClean, pctDuty, 0.0, 0.0001);
    logger.debug("pctClean=" + pctClean + " pctDuty=" + pctDuty
                 + " ratesLower=" + ratesLower + " pctSame=" + pctSame
                 + " rateFull=" + vFull.mCarbRate + " rateDuty=" + vDuty.mCarbRate);
    return ratesLower && pctSame;
}

// -------- #33: the flux floor --------

// Both thresholds, both directions. The latch must not release below
// FLUX_RELEASE nor re-engage above FLUX_ENGAGE, or a sustained hover at the
// boundary flickers the colour at 1 Hz.
//
// The rates are set directly (not driven through compute()) so the test pins the
// thresholds themselves at any legal settings; compute() is then called with a
// dt=0 sample, which updates the derived pct and the latch without accruing.
(:debug)
function cbvSetFlux(v, carbEquivGh) {
    // Pure carb, so total flux == mCarbRate: (4*C + 9*0)/4 == C.
    v.mCarbRate = carbEquivGh;
    v.mFatRate  = 0.0;
}

(:test)
function test_flux_floor_hysteresis(logger) {
    var v = cbvNewView();
    v.compute(mkInfo(null, 1000, null));               // prime the timer
    var t = 2000;

    // Cold start: latched low.
    var startsLow = (v.mFluxLow == true);

    // 6.0 is above ENGAGE (5) but below RELEASE (8): must NOT release.
    cbvSetFlux(v, 6.0); t += 1000; v.compute(mkInfo(null, t, null));
    // (the null sample decays the rates a little; assert the latch, not the rate)
    var holdsBelowRelease = (v.mFluxLow == true);

    // Clearly above RELEASE: releases.
    cbvSetFlux(v, 40.0); t += 1000; v.compute(mkInfo(null, t, null));
    var released = (v.mFluxLow == false);

    // 6.0 again: above ENGAGE, so it must NOT re-engage on the way down.
    cbvSetFlux(v, 6.0); t += 1000; v.compute(mkInfo(null, t, null));
    var holdsAboveEngage = (v.mFluxLow == false);

    // Below ENGAGE: engages.
    cbvSetFlux(v, 1.0); t += 1000; v.compute(mkInfo(null, t, null));
    var reEngaged = (v.mFluxLow == true);

    logger.debug("startsLow=" + startsLow + " holdsBelowRelease=" + holdsBelowRelease
                 + " released=" + released + " holdsAboveEngage=" + holdsAboveEngage
                 + " reEngaged=" + reEngaged);
    return startsLow && holdsBelowRelease && released && holdsAboveEngage && reEngaged;
}

// The thresholds AT their boundary values, which the test above cannot reach: it
// steps the clock, so a null sample decays the rates before the latch reads them
// and it only BRACKETS the constants. How far it decays is not uniform across
// that test's arms, and the arms are not equally strong as a result: arm 3
// (holdsAboveEngage) steps dt = 1, so 6.0 -> 5.4, which is genuinely above
// FLUX_ENGAGE = 5 and discriminating; arm 1 (holdsBelowRelease) follows the
// prime at t=1000 with t=2000 then += 1000, so dt = 2, steadyAlpha(2) = 0.19 and
// 6.0 -> 4.86 - BELOW engage, so that arm holds for the wrong reason. The
// boundary test below is what actually covers the intent.
//
// Re-using the SAME timerTime gives dt = 0, which skips the whole accrual block
// while still running the derivation - so the latch sees exactly the value set.
//
// Both comparisons are strict, so the boundary values themselves do NOT switch:
// release needs flux > FLUX_RELEASE, engage needs flux < FLUX_ENGAGE.
(:test)
function test_flux_floor_exact_boundaries(logger) {
    var v = cbvNewView();
    var t = 1000;
    v.compute(mkInfo(null, t, null));                  // prime; latch starts low

    cbvSetFlux(v, 8.0);  v.compute(mkInfo(null, t, null));   // dt = 0
    var exactReleaseHolds = (v.mFluxLow == true);      // 8.0 is not > 8.0
    cbvSetFlux(v, 8.001); v.compute(mkInfo(null, t, null));
    var justAboveReleases = (v.mFluxLow == false);

    cbvSetFlux(v, 5.0);  v.compute(mkInfo(null, t, null));
    var exactEngageHolds = (v.mFluxLow == false);      // 5.0 is not < 5.0
    cbvSetFlux(v, 4.999); v.compute(mkInfo(null, t, null));
    var justBelowEngages = (v.mFluxLow == true);

    logger.debug("exactReleaseHolds=" + exactReleaseHolds
                 + " justAboveReleases=" + justAboveReleases
                 + " exactEngageHolds=" + exactEngageHolds
                 + " justBelowEngages=" + justBelowEngages);
    return exactReleaseHolds && justAboveReleases && exactEngageHolds && justBelowEngages;
}

// The floor must never grey a state in which the BLUE fat-max band would be
// shown. This is guaranteed structurally - zoneColor() gates the floor on the
// BLUE condition itself - so it holds at ANY legal settings even if the swept
// 15.55 g/h bound is ever wrong again. Both halves are asserted: BLUE survives
// with the latch low, and the floor still fires just below the band.
(:test)
function test_flux_floor_cannot_grey_blue_band(logger) {
    var v = cbvNewView();
    v.mCarbPctRoll = 10.0;                             // below ORANGE/RED
    var peak = v.mFatMaxRate;

    // In the band, latch low (as it would be at small fat-max powers).
    v.mFluxLow  = true;
    v.mFatRate  = peak;
    v.mCarbRate = 0.0;
    var blueSurvives = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_BLUE);
    var pctShown     = v.carbPctStr().equals("--") == false;

    // Just below the band, same negligible flux -> the floor fires.
    v.mFatRate = 0.90 * peak * 0.001;                  // far below the band
    var floorFires = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_LT_GRAY)
                     && v.carbPctStr().equals("--");
    logger.debug("blueSurvives=" + blueSurvives + " pctShown=" + pctShown
                 + " floorFires=" + floorFires + " peak=" + peak);
    return blueSurvives && pctShown && floorFires;
}

// The floor is tested BEFORE the 85/50 branches. Under the derived percentage a
// coast preserves the ratio exactly, so a rider who was above threshold stays
// >= 85 % all the way to zero flux: placed after those branches the floor would
// be dead code for RED, which is the state #7 reported.
(:test)
function test_flux_floor_precedes_red(logger) {
    var v = cbvNewView();
    v.mCarbPctRoll = 90.0;                             // >= 85 => RED if reached
    v.mFatRate     = 0.0;                              // not in the BLUE band
    v.mCarbRate    = 0.0;
    v.mFluxLow     = false;
    var redWhenMeaningful = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_RED);
    v.mFluxLow = true;
    var greyWhenNegligible = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_LT_GRAY);
    var dashes = v.carbPctStr().equals("--");
    logger.debug("redWhenMeaningful=" + redWhenMeaningful
                 + " greyWhenNegligible=" + greyWhenNegligible + " dashes=" + dashes);
    return redWhenMeaningful && greyWhenNegligible && dashes;
}

// Resuming after a long gap: ONE active sample is enough to make the flux
// meaningful again and put the colour back, because the derived percentage snaps
// to the new mix rather than climbing an EMA. This documents a deliberate
// behaviour change - the deleted timer relaxed the % at 3 s and then took ~25 s
// to climb back; the floor relaxes the COLOUR tens of seconds in, but recovery
// is immediate.
(:test)
function test_resume_after_long_gap_recolours_at_once(logger) {
    var v = cbvWarmView(400, 20);
    var pctBefore = v.mCarbPctRoll;
    var preRate   = v.mCarbRate;
    var t = 21000;
    for (var j = 0; j < 60; j += 1) { t += 1000; v.compute(mkInfo(null, t, null)); }
    var greyAtRest  = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_LT_GRAY);
    var dashAtRest  = v.carbPctStr().equals("--");
    // ANTI-VACUITY, and the whole point of the design: 57.5 s of coasting at
    // alpha 0.10 leaves the rates at ~0.2 % of instantaneous but the RATIO
    // exactly where it was. The colour is grey because of the FLOOR, not because
    // the percentage decayed - which is what the deleted timer did, and did
    // wrongly. Asserted as "unchanged", not "still >= 85", so it holds at any
    // legal settings (400 W may sit below LT1).
    var ratesGone   = (preRate > 0.0) && (v.mCarbRate < 0.02 * preRate);
    // Purely proportional window with an explicit anti-vacuity guard: cbvRelEq
    // would degenerate to a 1e-4 ABSOLUTE window at settings where the
    // percentage is tiny and admit 0.0 - and so does a 1e-7 absolute floor,
    // because at (ftp 500, lt1 499) the percentage is 9.36e-12.
    var pctUnchanged = (pctBefore > 0.0)
                       && cbvClose(v.mCarbPctRoll, pctBefore, 0.0, 0.0001);
    t += 1000; v.compute(mkInfo(400, t, null));        // one ACTIVE sample
    var releasedAtOnce = (v.mFluxLow == false) && (v.carbPctStr().equals("--") == false);
    // Proportional decay plus a proportional pull means the percentage never
    // left the mix at 400 W, so it reports it exactly on resume.
    var pctTarget = v.choFraction(400.0) * 100.0;
    var near = (pctTarget > 0.0)
               && cbvClose(v.mCarbPctRoll, pctTarget, 0.0, 0.0001);
    logger.debug("greyAtRest=" + greyAtRest + " dashAtRest=" + dashAtRest
                 + " ratesGone=" + ratesGone + " pctUnchanged=" + pctUnchanged
                 + " releasedAtOnce=" + releasedAtOnce + " near=" + near
                 + " pct=" + v.mCarbPctRoll + " target=" + pctTarget);
    return greyAtRest && dashAtRest && ratesGone && pctUnchanged && releasedAtOnce && near;
}

// RED reached through compute() rather than by setting mCarbPctRoll: every other
// colour assertion in this file writes the field directly, so nothing proves the
// derived percentage can actually reach the RED branch on real samples.
//
// 3000 W is physiologically absurd and deliberately so - it is the only power
// that is settings-INDEPENDENT here. choFraction saturates at any legal
// (ftp, lt1): the logit is clamped at +30, so the carb share is ~100 % whether
// FTP is 50 or 600, and the sample is synthetic anyway.
(:test)
function test_compute_drives_red(logger) {
    var v = cbvNewView();
    var t = 1000;
    v.compute(mkInfo(3000, t, null));                  // prime (dt=0)
    t += 1000; v.compute(mkInfo(3000, t, null));       // one ACTIVE sample seeds
    var pctHigh  = (v.mCarbPctRoll >= 85.0);
    var released = (v.mFluxLow == false);
    var isRed    = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_RED);
    var numeric  = (v.carbPctStr().equals("--") == false);
    logger.debug("pct=" + v.mCarbPctRoll + " pctHigh=" + pctHigh + " released=" + released
                 + " isRed=" + isRed + " numeric=" + numeric + " str=" + v.carbPctStr());
    return pctHigh && released && isRed && numeric;
}

// ORANGE, GREEN, and the ORDER of the branches. A pure REORDER of the RED and
// ORANGE tests makes RED unreachable (every RED value is also >= 50) while
// changing no literal and no expression, so a source-literal diff cannot see it.
//
// An earlier revision of this comment went further and said no existing test
// could see it either. That was wrong, and measured to be wrong: applying the
// reorder to zoneColor() and running the suite reds THREE tests -
// test_flux_floor_precedes_red and test_compute_drives_red, both of which
// predate this comment, and this one. The commit message said so; the comment a
// future reader meets did not. What this test adds is the two bands that had no
// coverage at all (ORANGE and GREEN) and a deliberate rather than incidental
// guard on the order: reorder the branches and the 90 arm returns ORANGE.
//
// The GREEN arm is asserted RELATIVE to mPctFatMax rather than at a fixed
// percentage, because that threshold is a model output and ranges from 0.004 %
// (ftp=421 / lt1=420) to 69.7 % (ftp=61 / lt1=1) across legal settings - so any
// fixed number either misses the band or lands outside it depending on the
// runner's settings, which is exactly the #34 defect. Where mPctFatMax >= 50 the
// GREEN band is genuinely EMPTY (ORANGE pre-empts it), and the test asserts that
// instead of pretending otherwise.
//
// Both arms are reached in practice. Measured by running tools/sim_compute.py
// over its 13 settings tuples: 5 have an empty GREEN band (mPctFatMax =
// 55.3770, 66.2199, 66.0282, 65.9171, 68.1455) and 8 do not. The commit message
// that introduced this test said "6 ... and 7"; that figure was never measured
// and is wrong. Commit messages are immutable, so the correction lives here.
(:test)
function test_zone_branch_order_and_bands(logger) {
    var v = cbvNewView();
    v.mFluxLow = false;            // floor released; it has its own tests
    v.mFatRate = 0.0;              // below the BLUE band

    v.mCarbPctRoll = 90.0;
    var red = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_RED);
    v.mCarbPctRoll = 60.0;
    var orange = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_ORANGE);
    v.mCarbPctRoll = 85.0;         // the boundary itself is RED (>=, not >)
    var redAtBoundary = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_RED);
    v.mCarbPctRoll = 50.0;
    var orangeAtBoundary = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_ORANGE);

    var thr = v.mPctFatMax;
    var greenOk;
    var bandEmpty = (thr >= 49.0);
    if (bandEmpty) {
        // No room between mPctFatMax and 50: ORANGE owns the range.
        v.mCarbPctRoll = 49.0;
        greenOk = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) != Graphics.COLOR_GREEN);
    } else {
        v.mCarbPctRoll = thr + 0.5;
        var above = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_GREEN);
        var aboveLight = (v.zoneColor(Graphics.COLOR_DK_GRAY, false) == Graphics.COLOR_DK_GREEN);
        // Just below the threshold there is nothing left to match: grey.
        v.mCarbPctRoll = thr - 0.5;
        var below = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_LT_GRAY);
        greenOk = above && aboveLight && below;
    }
    logger.debug("red=" + red + " orange=" + orange + " redAtBoundary=" + redAtBoundary
                 + " orangeAtBoundary=" + orangeAtBoundary + " greenOk=" + greenOk
                 + " pctFatMax=" + thr + " bandEmpty=" + bandEmpty);
    return red && orange && redAtBoundary && orangeAtBoundary && greenOk;
}

// -------- structural pin: the fat-max scan --------
//
// Every VALUE the model produces is checked against the model itself elsewhere
// in this suite, which cannot catch a change to the SHAPE of an expression. This
// pin can: mFatMaxW must be the argmax of the fat-oxidation score over the scan
// grid, so mutating the score to pw*choFraction(pw) (or dropping the 1.0 -) moves
// it to the top of the range, where the true score is near zero, and this fails.
//
// TWO things matter about how it is written, both learned the hard way:
//
// 1. Compare the scan's OWN score expression, re-stated here, not fatRateAt().
//    fatRateAt() is the same quantity in a different operation order, so in
//    binary32 it can rank two watts differently: at ftp=540 / lt1=18 / ge=28 the
//    scan picks 324 W while fatRateAt(324) = 35.239254 < fatRateAt(326) =
//    35.239258. A pin built on fatRateAt therefore RED-LIGHTS CORRECT CODE at
//    some legal settings. Re-stating the score makes ties exact equalities.
// 2. Scan the WHOLE grid, not the +-2 neighbours. The mutated score's argmax
//    lands where choFraction is saturated and fat rate is locally flat or
//    rising, so a local check passes: the mutant survives a neighbour-only pin at
//    roughly a quarter of sampled settings - every narrow-span case (50/49,
//    60/59 ... 600/599). Full-grid, it dies everywhere.
//
// The grid bounds [30, mScanMaxW] are themselves load-bearing: the scan is
// anchored at 30 W and at small FTP the continuous peak sits below that, so
// mFatMaxW == 30 legitimately has a higher-fat-rate neighbour at 28 W
// (ftp=50 / lt1=6: fatRateAt(28) = 4.6413 > fatRateAt(30) = 4.6397).
(:debug)
function cbvFatScore(v, pw) {
    return pw * (1.0 - v.choFraction(pw));
}

(:test)
function test_fatmax_is_scan_argmax(logger) {
    var v = cbvNewView();
    var w      = v.mFatMaxW;
    var best   = cbvFatScore(v, w);
    var inGrid = (w >= 30) && (w <= v.mScanMaxW);
    var isMax  = true;
    var n      = 0;
    for (var pw = 30; pw <= v.mScanMaxW; pw += 2) {
        n += 1;
        if (cbvFatScore(v, pw) > best) { isMax = false; }
    }
    // mFatMaxRate must BE the fat rate at that power, not a separately-derived
    // value - this is the arm that catches a change to mFatMaxRate's own formula.
    var consistent = cbvRelEq(v.mFatMaxRate, v.fatRateAt(w), 0.000001);
    logger.debug("w=" + w + " scanMax=" + v.mScanMaxW + " best=" + best
                 + " inGrid=" + inGrid + " isMax=" + isMax + " scanned=" + n
                 + " consistent=" + consistent);
    return inGrid && isMax && consistent && (n >= 16);
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
    var numerator = cbvClose(v.mGarminKcal, 1.0, 0.000001, 0.0);
    var denomIsOneSample = cbvClose(v.mModelKcal, oneSample, 0.0001 * oneSample, 0.0);
    var denomIsTiny = (v.mModelKcal < 1.0) && (v.mModelKcal > 0.0);
    var seeded = cbvClose(v.mCarbRate, v.carbRateAt(200.0),
                         0.0001 * v.carbRateAt(200.0), 0.0) && (v.mRollN == 1);
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
    var live = cbvClose(r13, 1.3, 0.000001, 0.0) && cbvClose(r20, 2.0, 0.000001, 0.0)
               && cbvClose(r25, 2.5, 0.000001, 0.0);
    var degenerate = cbvClose(bothZero, 1.0, 0.0, 0.0) && cbvClose(noGarmin, 1.0, 0.0, 0.0)
                     && cbvClose(noModel, 1.0, 0.0, 0.0);
    logger.debug("live=" + live + " (" + r13 + "/" + r20 + "/" + r25 + ")"
                 + " degenerate=" + degenerate
                 + " (" + bothZero + "/" + noGarmin + "/" + noModel + ")");
    return live && degenerate;
}

// -------- #59: the bound on reconFactor() (differentials) --------

// DIFFERENTIAL for the FLOOR. The #59 trigger at 200 W with the smallest
// non-zero integer info.calories can report. One sample of model kcal is
// 0.227625 (measured, pinned by test_recon_cold_start_mechanism), two orders of
// magnitude below any usable minimum denominator - so the factor must fall back
// to 1.0 and carb_rate must carry the pure model rate, which #8's warm-up
// seeding has already made exactly right.
//
// The fallback is 1.0 rather than some invented number because the pure power
// model is the only other self-consistent scale the field already owns.
//
// RED before the fix: recon 4.393200 and mRateDisp 487 g/h against a true
// 110.877800. Also red on a CLAMP-ONLY implementation: 3.000000 and 333 g/h.
// This is the test that discriminates the floor.
(:test)
function test_recon_floor_suppresses_cold_start(logger) {
    var v = cbvColdStart(200, 1);
    var truth = v.carbRateAt(200.0);
    var recon = v.reconFactor();
    var suppressed = cbvClose(recon, 1.0, 0.000001, 0.0);
    // Window stated RELATIVE to the view's own model, so it is both
    // settings-independent and non-degenerate at settings where carbRateAt(200)
    // is small - which a fixed absolute window, or cbvRelEq's m<1.0 floor,
    // would not be.
    var rateIsModel = cbvClose(v.mRateDisp, truth, 0.0001 * truth, 0.0);
    logger.debug("recon=" + recon + " suppressed=" + suppressed
                 + " rateIsModel=" + rateIsModel + " mRateDisp=" + v.mRateDisp
                 + " true=" + truth + " FIT=" + v.clampU16(v.mRateDisp)
                 + " FITtrue=" + v.clampU16(truth)
                 + " modelKcal=" + v.mModelKcal + " garminKcal=" + v.mGarminKcal);
    return suppressed && rateIsModel;
}

// DIFFERENTIAL for the CLAMP, and the reason the clamp is the load-bearing half
// rather than the floor. 15 minutes of measured 0 W while Garmin counts to
// 60 kcal, then 600 s at 200 W.
//
// The numerator is FROZEN at 60 through the powered phase. That makes no
// assumption about how fast a device counts calories while pedalling (#67 is
// open precisely because nobody has measured that), and it is the conservative
// choice: any further accrual only raises the factor.
//
// 3.0 is a literal here, not a read of the production constant. A test that
// reads RECON_MAX cannot fail when RECON_MAX is mutated, which is the
// assertion-that-cannot-fail trap; the expected value has to be restated
// independently or it pins nothing.
//
// `binding` pins the floor and the ceiling as a PAIR: at a 10 kcal floor the
// raw factor at release is 60/10.0155 = 5.990727, above the ceiling, so the
// ceiling engages and the maximum is exactly 3.0. A materially higher floor
// would release below the ceiling and red this - deliberate, that pair is the
// design. Without `binding` the whole test passes on `return 1.0;`.
//
// This test is also the ONLY upper constraint the suite puts on
// RECON_MIN_KCAL, and it is a loose one. Measured on this tree: the suite is
// green and unchanged at a floor of 0.23, 1.0 and 19.5, and reds only at 0.22
// (the cold-start denominator is 0.227625, so a floor below it stops
// suppressing the cold start) and at 20.0 (here). The upper break is
// 60/3.0 = 20.0 kcal reached in 0.455247 kcal steps, i.e. 19.5756. So any
// value in ~[0.23, 19.57] passes unchanged and 10.0 is a design choice these
// tests do NOT defend.
//
// RED before the fix: peak factor 263.591980, peak carb_rate 29226 against a
// ceiling of 333. Also red on a FLOOR-ONLY implementation: 5.990727 and 664
// with the numerator frozen as this test freezes it. If a device instead keeps
// counting through the powered phase the release factor is higher still -
// re-measured on this tree at 6.889336 and 764, with the count modelled as
// (60 + model kcal) truncated to an integer. An earlier revision of this
// comment said "6.989182 and 775"; that pair was taken under a counting model
// that does not reproduce here and is withdrawn. Which model a real device
// follows is unmeasured (#67); freezing the numerator is the conservative
// choice either way, since any further accrual only raises the factor.
(:test)
function test_recon_never_exceeds_band_after_rollout(logger) {
    var CEIL = 3.0;
    var v = cbvNewView();
    var t = 1000;
    v.compute(mkInfo(0, t, null));                      // prime, dt = 0
    for (var i = 1; i <= 900; i += 1) {                 // 15 min of measured 0 W
        t += 1000;
        v.compute(mkInfo(0, t, (60 * i) / 900));        // truncated integer kcal
    }
    // Precondition, not decoration: if the roll-out did not actually put
    // 60 kcal in the numerator and nothing in the denominator, the rest of this
    // test is measuring something else.
    var rolledOut = cbvClose(v.mGarminKcal, 60.0, 0.000001, 0.0) && (v.mModelKcal == 0.0);
    var maxRecon = 0.0;
    var peak = 0;
    for (var s = 1; s <= 600; s += 1) {                 // 10 min at 200 W
        t += 1000;
        v.compute(mkInfo(200, t, 60));
        var r = v.reconFactor();
        if (r > maxRecon) { maxRecon = r; }
        var f = v.clampU16(v.mRateDisp);
        if (f > peak) { peak = f; }
    }
    var truth     = v.carbRateAt(200.0);
    var bounded   = (maxRecon <= CEIL + 0.000001);
    var rateBound = (peak <= v.clampU16(CEIL * truth) + 1);
    var binding   = (maxRecon >= CEIL - 0.000001);
    logger.debug("rolledOut=" + rolledOut + " bounded=" + bounded
                 + " rateBound=" + rateBound + " binding=" + binding
                 + " maxRecon=" + maxRecon + " peakFIT=" + peak
                 + " ceilFIT=" + v.clampU16(CEIL * truth) + " true=" + truth);
    return rolledOut && bounded && rateBound && binding;
}

// DIFFERENTIAL for the LOWER half of the band. The clamp is symmetric because
// info.calories is an integer: the same small-denominator window can also
// produce a factor BELOW 1.0 when it truncates, which is why #59's direction of
// error is NOT unambiguously upward (unlike #32's whole-ride bias).
//
// Driven by direct assignment, deliberately: no calorie series constructed
// in-simulator has reached this bound - the minimum factor observed across the
// design comment's ride sweeps was 0.959536 - so it is a defensive bound and is
// stated as one. A binding lower clamp INFLATES the reported grams, so it is
// set well below anything measured rather than close to 1.0.
//
// RED before the fix: 0.100000.
(:test)
function test_recon_lower_bound_clamps(logger) {
    var v = cbvNewView();
    v.mModelKcal  = 100.0;
    v.mGarminKcal = 10.0;
    var r = v.reconFactor();
    var clamped = cbvClose(r, 0.5, 0.000001, 0.0);
    logger.debug("recon=" + r + " clamped=" + clamped);
    return clamped;
}

// -------- #15: fat-max BLUE band is reconFactor()-invariant --------
// The band boundary must not move with reconFactor(), asserted across 3 recon
// values below and above the 0.95*peak threshold - plus a check that recon
// really does differ, or the invariance would be vacuous.
(:test)
function test_zonecolor_recon_invariant(logger) {
    var v = cbvNewView();
    v.mCarbPctRoll = 10.0;                              // below ORANGE/RED so we reach the BLUE test
    // #33: this test never calls compute(), so the flux latch would still be at
    // its post-reset value and the floor - which is tested FIRST - would grey
    // every arm before the BLUE check was reached. Release it explicitly; the
    // floor has its own tests.
    v.mFluxLow = false;
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
