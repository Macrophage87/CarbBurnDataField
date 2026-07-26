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
    var carriedFlat = cbvRelEq(v.mCarbRate, held, 0.000001)
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

// mNullSec is advanced BEFORE the carry is tested, and the carry is clamped to
// the room left in the window - so one enormous sample cannot accrue phantom
// pedalling for its whole duration. Asserted in energy, against the view's own
// measured per-second accrual, so it holds at any legal settings.
(:test)
function test_dropout_carry_bounded_on_one_long_sample(logger) {
    var v = cbvWarmView(400, 20);
    var t = 21000;
    // Measure this view's kcal for exactly 1 s of active 400 W.
    var k0 = v.mModelKcal;
    t += 1000; v.compute(mkInfo(400, t, null));
    var kcalPerSec = v.mModelKcal - k0;
    var pctHeld = v.mCarbPctRoll;
    var before  = v.mModelKcal;

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
    var pctGuarded     = (v.mCarbPctRoll == 0.0) && (v.mCarbPctRoll == v.mCarbPctRoll);
    var floorEngaged   = (v.mFluxLow == true) && v.carbPctStr().equals("--");
    var greyNow        = (v.zoneColor(Graphics.COLOR_LT_GRAY, true) == Graphics.COLOR_LT_GRAY);
    logger.debug("carried=" + carried + "s bounded=" + bounded + " pctBefore=" + pctHeld
                 + " ratesCollapsed=" + ratesCollapsed + " pctGuarded=" + pctGuarded
                 + " floorEngaged=" + floorEngaged + " grey=" + greyNow
                 + " pct=" + v.mCarbPctRoll + " carbRate=" + v.mCarbRate);
    return bounded && ratesCollapsed && pctGuarded && floorEngaged && greyNow;
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
    var carriedWhenUnknown = cbvRelEq(vFree.mCarbRate, held, 0.000001);
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
    // ...but the RATIO is not. 0.5 pp is generous: the two differ only by where
    // in the cycle they were sampled, and both are pure ratios of the same mix.
    var pctSame = ((pctClean - pctDuty) < 0.5) && ((pctDuty - pctClean) < 0.5);
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
    var pctUnchanged = cbvRelEq(v.mCarbPctRoll, pctBefore, 0.0001);
    t += 1000; v.compute(mkInfo(400, t, null));        // one ACTIVE sample
    var releasedAtOnce = (v.mFluxLow == false) && (v.carbPctStr().equals("--") == false);
    // Proportional decay plus a proportional pull means the percentage never
    // left the mix at 400 W, so it reports it exactly on resume.
    var pctTarget = v.choFraction(400.0) * 100.0;
    var near = cbvRelEq(v.mCarbPctRoll, pctTarget, 0.0001);
    logger.debug("greyAtRest=" + greyAtRest + " dashAtRest=" + dashAtRest
                 + " ratesGone=" + ratesGone + " pctUnchanged=" + pctUnchanged
                 + " releasedAtOnce=" + releasedAtOnce + " near=" + near
                 + " pct=" + v.mCarbPctRoll + " target=" + pctTarget);
    return greyAtRest && dashAtRest && ratesGone && pctUnchanged && releasedAtOnce && near;
}

// -------- structural pin: the fat-max scan --------
//
// Every VALUE the model produces is checked against the model itself elsewhere
// in this suite, which cannot catch a change to the SHAPE of an expression. This
// pin can: mFatMaxW must be the argmax of fat rate over the scan grid, so
// swapping the score to pw*choFraction(pw) (or dropping the 1.0 -) moves it to
// the top of the range and this fails.
//
// The neighbours MUST be clamped to [30, mScanMaxW]: the scan is anchored at
// 30 W, and at small FTP the continuous peak sits below that, so mFatMaxW == 30
// legitimately has a higher-fat-rate neighbour at 28 W. Asserting without the
// clamp red-lights at legal settings (e.g. ftp=50 / lt1=6).
(:test)
function test_fatmax_is_scan_argmax(logger) {
    var v = cbvNewView();
    var w    = v.mFatMaxW;
    var peak = v.fatRateAt(w);
    var inGrid = (w >= 30) && (w <= v.mScanMaxW);
    var lowerOk = true;
    var upperOk = true;
    var checked = 0;
    if (w - 2 >= 30)          { lowerOk = (peak >= v.fatRateAt(w - 2)); checked += 1; }
    if (w + 2 <= v.mScanMaxW) { upperOk = (peak >= v.fatRateAt(w + 2)); checked += 1; }
    // mFatMaxRate must BE that value, not a separately-derived one.
    var consistent = cbvRelEq(v.mFatMaxRate, peak, 0.000001);
    logger.debug("w=" + w + " scanMax=" + v.mScanMaxW + " peak=" + peak
                 + " inGrid=" + inGrid + " lowerOk=" + lowerOk + " upperOk=" + upperOk
                 + " checked=" + checked + " consistent=" + consistent);
    return inGrid && lowerOk && upperOk && consistent && (checked >= 1);
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
