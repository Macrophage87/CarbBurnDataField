#!/usr/bin/env python3
"""Python port of CarbBurnView's compute path, used to run the (:test) suite's
assertions over many settings before the SDK sees them.

WHY THIS EXISTS
    CI compiles the (:test) suite on 13 devices but does not EXECUTE it (see
    docs/ci.md - the container simulator times out, tracked in #28). So an
    assertion that is wrong at some legal settings ships green. This script is
    the stopgap: it re-implements loadSettings(), choFraction(), carbRateAt(),
    fatRateAt(), the fat-max scan, steadyAlpha(), the ACTIVE/DROPOUT/COASTING
    classifier, the derived carb %, the flux-floor latch, zoneColor() and
    carbPctStr(), then evaluates each test body over a list of settings tuples.

WHAT IT IS NOT
    Not a substitute for a device/simulator run, and not bit-exact. It is a
    binary32-CONSISTENT model: every arithmetic result and literal is round-
    tripped through struct.pack('f'), and Math.pow(E, -x) is reproduced with a
    Float E rather than math.exp - but whether the VM evaluates Math.pow in
    single or double is unverified, and expression order is matched by hand.
    Where a result depends on that (see test_dropout_carry_bounded_on_one_long_
    sample) the Monkey C assertion is written to hold under either.

    It is also NOT run by CI: tools/ is in the push paths-ignore list, and no
    workflow job executes Python against the model. It is an author-side check.

HOW TO USE
    python3 tools/sim_compute.py
    Exits 0 with every check PASS, or lists the failures. Add settings tuples to
    SET at the bottom - narrow spans (ftp, ftp-1), the ge extremes 15 and 28, and
    any witness a review names are the ones that find real bugs.

    Keep it in step with source/CarbBurnView.mc by hand. It has no automatic
    drift check; #36 tracks giving the repo's Python ports one.
"""
import math, struct
def f32(x): return struct.unpack('f', struct.pack('f', x))[0]
E32 = f32(2.718281828459045)
J = f32(4184.0); KC = f32(4.0); KF = f32(9.0)
ALPHA = f32(0.10); GRACE = f32(2.5); REARM = 2; UNSET = f32(-1.0)
ENGAGE = f32(5.0); RELEASE = f32(8.0)
RED, ORANGE, BLUE, GREEN, GREY = "RED", "ORANGE", "BLUE", "GREEN", "GREY"

class View:
    def __init__(self, ftp=250.0, lt1=0, ge=21, wt=75, ci=60):
        self.reset()
        self.load(ftp, lt1, ge)
    def reset(self):
        self.modelKcal=0.0; self.carbKcal=0.0; self.fatKcal=0.0; self.garmin=0.0
        self.lapKcal=0.0; self.lapCarb=0.0; self.lapFat=0.0; self.lapSec=0.0
        self.totalSec=0.0
        self.carbRate=0.0; self.fatRate=0.0; self.pct=0.0; self.rollN=0
        self.lastPower=UNSET; self.nullSec=0.0; self.activeRun=0
        self.carryArmed=False; self.fluxLow=True; self.lastMs=0
    def load(self, ftp, lt1, ge):
        self.ftp=f32(ftp); self.ge=f32(ge/100.0)
        lt1f = f32(lt1) if (lt1>0 and lt1<self.ftp) else f32(f32(0.70)*self.ftp)
        span = f32(self.ftp-lt1f)
        if span < 1.0: span = f32(1.0)
        self.k=f32(f32(2.3536)/span); self.p50=f32(lt1f+f32(f32(0.2631)*span))
        pMax=int(f32(self.ftp*f32(1.3)))
        if pMax<60: pMax=60
        self.scanMax=pMax
        bP=0; bS=f32(-1.0)
        for pw in range(30,pMax+1,2):
            s=f32(f32(pw)*f32(f32(1.0)-self.cho(pw)))
            if s>bS: bS=s; bP=pw
        self.fatMaxW=bP
        self.fatMaxRate=self.fatRateAt(bP)
        self.pctFatMax=f32(self.cho(bP)*f32(100.0))
    def cho(self, p):
        x=f32(self.k*f32(f32(p)-self.p50))
        if x>30.0: x=f32(30.0)
        if x<-30.0: x=f32(-30.0)
        return f32(f32(1.0)/f32(f32(1.0)+f32(math.pow(E32,f32(-x)))))
    def carbRateAt(self,p):
        m=f32(f32(p)/self.ge)
        return f32(f32(f32(self.cho(p)*m)/J)*f32(3600.0)/KC)
    def fatRateAt(self,p):
        m=f32(f32(p)/self.ge)
        return f32(f32(f32(f32(1.0)-self.cho(p))*m/J)*f32(3600.0)/KF)
    def steadyAlpha(self,dt):
        if dt==1.0: return ALPHA
        a=f32(f32(1.0)-f32(math.pow(f32(f32(1.0)-ALPHA),f32(dt))))
        if a<0.0: a=0.0
        if a>1.0: a=f32(1.0)
        return a
    def accrueActive(self,power,dt):
        m=f32(f32(power)/self.ge); kcal=f32(f32(m*f32(dt))/J); frac=self.cho(power)
        self.modelKcal=f32(self.modelKcal+kcal)
        self.carbKcal=f32(self.carbKcal+f32(kcal*frac))
        self.fatKcal=f32(self.fatKcal+f32(kcal*f32(1.0-frac)))
        self.lapKcal=f32(self.lapKcal+kcal)
        self.lapCarb=f32(self.lapCarb+f32(kcal*frac))
        self.lapFat=f32(self.lapFat+f32(kcal*f32(1.0-frac)))
        self.rollN+=1
        a=self.steadyAlpha(dt); warm=f32(1.0/self.rollN)
        if warm>a: a=warm
        kph=f32(f32(m/J)*f32(3600.0))
        iC=f32(f32(frac*kph)/KC); iF=f32(f32(f32(1.0-frac)*kph)/KF)
        self.carbRate=f32(self.carbRate+f32(a*f32(iC-self.carbRate)))
        self.fatRate =f32(self.fatRate +f32(a*f32(iF-self.fatRate)))
    def accrueCoast(self,dt):
        a=self.steadyAlpha(dt)
        self.carbRate=f32(self.carbRate+f32(a*f32(0.0-self.carbRate)))
        self.fatRate =f32(self.fatRate +f32(a*f32(0.0-self.fatRate)))
    def stopped(self,info):
        if info is None: return True
        if info.get('speed') is not None and info['speed']<=0: return True
        if info.get('cad') is not None and info['cad']<=0: return True
        return False
    def compute(self,info):
        dt=0.0
        if info is not None and info.get('t') is not None:
            t=info['t']
            if self.lastMs!=0 and t>self.lastMs: dt=f32((t-self.lastMs)/1000.0)
            self.lastMs=t
        if dt>0.0:
            self.totalSec=f32(self.totalSec+dt); self.lapSec=f32(self.lapSec+dt)
            p=info.get('p')
            p=None if p is None else f32(p)
            if p is not None and p>0.0:
                self.nullSec=0.0; self.lastPower=p; self.activeRun+=1
                if self.activeRun>=REARM: self.carryArmed=True
                self.accrueActive(p,dt)
            else:
                self.activeRun=0
                if p is not None: self.carryArmed=False   # measured zero invalidates the carry
                carry=0.0
                if p is None and self.carryArmed and self.lastPower>0.0 and not self.stopped(info):
                    room=f32(GRACE-self.nullSec)
                    if room>0.0: carry=dt if dt<room else room
                if p is None:
                    self.nullSec=f32(self.nullSec+dt)
                    if self.nullSec>=GRACE: self.carryArmed=False
                if carry>0.0: self.accrueActive(self.lastPower,carry)
                if f32(dt-carry)>0.0: self.accrueCoast(f32(dt-carry))
        if info is not None and info.get('cal') is not None and info['cal']>0:
            self.garmin=f32(info['cal'])
        cK=f32(KC*self.carbRate); fK=f32(KF*self.fatRate); tot=f32(cK+fK)
        self.pct = f32(f32(cK/tot)*f32(100.0)) if tot>0.0 else 0.0
        flux=f32(tot/KC)
        if self.fluxLow:
            if flux>RELEASE: self.fluxLow=False
        elif flux<ENGAGE:
            self.fluxLow=True
        self.recon = f32(self.garmin/self.modelKcal) if (self.garmin>0.0 and self.modelKcal>0.0) else 1.0
        self.rateDisp=f32(self.carbRate*self.recon)
    def totalFlux(self):
        return f32(f32(f32(KC*self.carbRate)+f32(KF*self.fatRate))/KC)
    def fluxUndefined(self):
        return self.fluxLow and (self.fatRate < f32(f32(0.95)*self.fatMaxRate))
    def carbPctStr(self):
        return "--" if self.fluxUndefined() else "%.0f" % self.pct
    def zoneColor(self):
        if self.fluxUndefined(): return GREY
        if self.pct>=85.0: return RED
        if self.pct>=50.0: return ORANGE
        if self.fatRate>=f32(f32(0.95)*self.fatMaxRate): return BLUE
        if self.pct>=self.pctFatMax: return GREEN
        return GREY

def mk(p,t,cal=None,speed=None,cad=None): return {'p':p,'t':t,'cal':cal,'speed':speed,'cad':cad}
def relEq(a,b,rel):
    d=abs(a-b); m=max(abs(a),abs(b),1.0); return d<=rel*m
def warm(power,n,**kw):
    v=View(**kw); t=1000; v.compute(mk(power,t))
    for _ in range(n):
        t+=1000; v.compute(mk(power,t))
    return v

FAIL=[]
def check(name, cond, detail=""):
    print(("  PASS " if cond else "  FAIL ")+name+("  "+detail if detail else ""))
    if not cond: FAIL.append(name)

def run(settings):
    ftp,lt1,ge = settings
    print(f"\n===== settings ftp={ftp} lt1={lt1} ge={ge} =====")
    kw={'ftp':ftp,'lt1':lt1,'ge':ge}

    # test_warmup_seeds_first_sample
    v=View(**kw); v.compute(mk(200,1000)); v.compute(mk(200,2000))
    check("warmup_seeds", relEq(v.carbRate,v.carbRateAt(200.0),1e-4) and v.rollN==1)

    # test_warmup_ramp_uses_fractional_alpha
    v=View(**kw); t=1000; v.compute(mk(200,t)); t+=1000; v.compute(mk(200,t))
    x=v.carbRateAt(200.0); ok=relEq(v.carbRate,x,1e-4)
    for i,p in enumerate([320,140,300,160,280,180,260,200]):
        t+=1000; v.compute(mk(p,t))
        a=max(1.0/(i+2),0.10); x=f32(x+f32(a*f32(v.carbRateAt(float(p))-x)))
        if not relEq(v.carbRate,x,1e-4): ok=False
    check("warmup_ramp", ok and v.rollN==9)

    # test_warmup_not_consumed_by_coast_prefix
    v=View(**kw)
    v.compute(mk(None,1000)); v.compute(mk(None,2000)); v.compute(mk(0,3000)); v.compute(mk(None,4000))
    a1=(v.rollN==0); a2=relEq(v.nullSec,2.0,1e-4); a3=(v.lastPower<0.0 and v.carryArmed==False)
    v.compute(mk(200,5000))
    a4=relEq(v.carbRate,v.carbRateAt(200.0),1e-4) and v.rollN==1; a5=(v.nullSec==0.0)
    check("warmup_not_consumed", a1 and a2 and a3 and a4 and a5, f"nullSec={v.nullSec}")

    # test_reset_rearms_warmup
    v=warm(200,15,**kw); wn=v.rollN; v.reset()
    r=(v.rollN==0 and v.nullSec==0.0 and v.lastPower<0.0 and v.carryArmed==False
       and v.fluxLow==True and v.activeRun==0 and relEq(v.carbRate,0.0,1e-4))
    v.compute(mk(200,100000)); v.compute(mk(200,101000))
    check("reset_rearms", wn>=10 and r and relEq(v.carbRate,v.carbRateAt(200.0),1e-4) and v.rollN==1)

    # test_steady_state_matches_fixed_alpha
    v=warm(150,13,**kw); ref=v.carbRate; t=14000; ok=True
    for p in [300,120,250,90,200,175]:
        t+=1000; v.compute(mk(p,t))
        ref=f32(ref+f32(f32(0.10)*f32(v.carbRateAt(float(p))-ref)))
        if not relEq(v.carbRate,ref,1e-4): ok=False
    check("steady_state", ok)

    # test_dt_invariance
    v1=warm(220,15,**kw); v2=warm(220,15,**kw); wv=v1.carbRate
    v1.compute(mk(350,18000)); v2.compute(mk(350,17000)); v2.compute(mk(350,18000))
    gap=abs(v1.carbRateAt(350.0)-wv); delta=abs(v1.carbRate-wv)
    check("dt_invariance", relEq(v1.carbRate,v2.carbRate,1e-4) and gap>0.0 and delta>=0.10*gap)

    # test_dropout_carry_and_grace_boundary
    v=warm(400,20,**kw); held=v.carbRate; t=21000
    t+=1000; v.compute(mk(None,t)); t+=1000; v.compute(mk(None,t))
    c1=relEq(v.carbRate,held,1e-6) and relEq(v.nullSec,2.0,1e-4)
    t+=1000; v.compute(mk(None,t))
    c2=(v.carbRate<held) and relEq(v.nullSec,3.0,1e-4); afterS=v.carbRate
    t+=1000; v.compute(mk(None,t))
    c3=(v.carbRate<afterS); c4=(held-afterS)<(afterS-v.carbRate)
    check("dropout_carry_boundary", c1 and c2 and c3 and c4,
          f"held={held:.4f} straddle={afterS:.4f} now={v.carbRate:.4f}")

    # test_dropout_carry_bounded_on_one_long_sample
    v=warm(400,20,**kw); t=21000; k0=v.modelKcal
    t+=1000; v.compute(mk(400,t)); kps=v.modelKcal-k0
    pctHeld=v.pct; before=v.modelKcal
    t+=300000; v.compute(mk(None,t))
    carried=(v.modelKcal-before)/kps
    b1=(kps>0.0 and 2.0<carried<3.0)
    b2=(v.carbRate<0.02*v.carbRateAt(400.0))
    b3=(v.pct==0.0 and v.pct==v.pct)
    b4=(v.fluxLow==True and v.carbPctStr()=="--")
    b5=(v.zoneColor()==GREY)
    check("carry_bounded_long", b1 and b2 and b3 and b4 and b5,
          f"carried={carried:.4f}s pct={v.pct} rate={v.carbRate:.3g}")

    # test_carry_rearm_requires_consecutive_active
    v=View(**kw); t=1000; v.compute(mk(400,t))
    t+=1000; v.compute(mk(400,t)); n1=(v.carryArmed==False)
    t+=1000; v.compute(mk(400,t)); n2=(v.carryArmed==True)
    t+=4000; v.compute(mk(None,t)); n3=(v.carryArmed==False)
    t+=1000; v.compute(mk(400,t)); n4=(v.carryArmed==False and v.activeRun==1)
    k0=v.modelKcal; t+=1000; v.compute(mk(None,t)); n5=(v.modelKcal==k0)
    t+=1000; v.compute(mk(400,t)); t+=1000; v.compute(mk(400,t)); n6=(v.carryArmed==True)
    k1=v.modelKcal; t+=1000; v.compute(mk(None,t)); n7=(v.modelKcal>k1)
    check("carry_rearm", n1 and n2 and n3 and n4 and n5 and n6 and n7,
          f"{n1}{n2}{n3}{n4}{n5}{n6}{n7}")

    # test_carry_suppressed_when_stopped
    vF=warm(400,20,**kw); vS=warm(400,20,**kw); vC=warm(400,20,**kw); held=vF.carbRate
    t=22000
    vF.compute(mk(None,t)); vS.compute(mk(None,t,speed=0.0)); vC.compute(mk(None,t,speed=12.0,cad=0))
    check("carry_suppressed_stopped",
          relEq(vF.carbRate,held,1e-6) and vS.carbRate<held and vC.carbRate<held)

    # test_coast_cold_start_null_and_zero
    v=View(**kw); v.compute(mk(None,1000)); v.compute(mk(None,2000))
    z1=relEq(v.nullSec,1.0,1e-4); v.compute(mk(0,3000)); z2=relEq(v.nullSec,1.0,1e-4)
    check("cold_start", z1 and z2 and v.rollN==0 and v.pct==0.0 and v.carbPctStr()=="--")

    # test_derived_pct_duty_cycle_invariant
    vFull=warm(300,30,**kw); pc=vFull.pct
    vD=View(**kw); t=1000; vD.compute(mk(300,t))
    for _ in range(30):
        t+=1000; vD.compute(mk(300,t)); t+=1000; vD.compute(mk(0,t))
    pd=vD.pct
    check("duty_cycle_invariant", vD.carbRate<0.8*vFull.carbRate and abs(pc-pd)<0.5,
          f"clean={pc:.4f} duty={pd:.4f} rateFull={vFull.carbRate:.2f} rateDuty={vD.carbRate:.2f}")

    # test_flux_floor_hysteresis
    v=View(**kw); v.compute(mk(None,1000)); t=2000
    h0=(v.fluxLow==True)
    def setflux(v,x): v.carbRate=f32(x); v.fatRate=0.0
    setflux(v,6.0);  t+=1000; v.compute(mk(None,t)); h1=(v.fluxLow==True)
    setflux(v,40.0); t+=1000; v.compute(mk(None,t)); h2=(v.fluxLow==False)
    setflux(v,6.0);  t+=1000; v.compute(mk(None,t)); h3=(v.fluxLow==False)
    setflux(v,1.0);  t+=1000; v.compute(mk(None,t)); h4=(v.fluxLow==True)
    check("flux_floor_hysteresis", h0 and h1 and h2 and h3 and h4, f"{h0}{h1}{h2}{h3}{h4}")

    # test_flux_floor_cannot_grey_blue_band
    v=View(**kw); v.pct=10.0; peak=v.fatMaxRate
    v.fluxLow=True; v.fatRate=peak; v.carbRate=0.0
    g1=(v.zoneColor()==BLUE); g2=(v.carbPctStr()!="--")
    v.fatRate=f32(f32(0.90*peak)*f32(0.001))
    g3=(v.zoneColor()==GREY and v.carbPctStr()=="--")
    check("floor_not_grey_blue", g1 and g2 and g3, f"{g1}{g2}{g3}")

    # test_flux_floor_precedes_red
    v=View(**kw); v.pct=90.0; v.fatRate=0.0; v.carbRate=0.0; v.fluxLow=False
    p1=(v.zoneColor()==RED); v.fluxLow=True
    p2=(v.zoneColor()==GREY and v.carbPctStr()=="--")
    check("floor_precedes_red", p1 and p2)

    # test_resume_after_long_gap_recolours_at_once
    v=warm(400,20,**kw); pctB=v.pct; preR=v.carbRate; t=21000
    for _ in range(60):
        t+=1000; v.compute(mk(None,t))
    r1=(v.zoneColor()==GREY); r2=(v.carbPctStr()=="--")
    r3=(preR>0.0 and v.carbRate<0.02*preR); r4=relEq(v.pct,pctB,1e-4)
    t+=1000; v.compute(mk(400,t))
    r5=(v.fluxLow==False and v.carbPctStr()!="--")
    r6=relEq(v.pct,f32(v.cho(400)*f32(100.0)),1e-4)
    check("resume_recolours", r1 and r2 and r3 and r4 and r5 and r6,
          f"pctBefore={pctB:.4f} pctAfterCoast->{v.pct:.4f} flux={v.totalFlux():.4f}")

    # test_zonecolor_recon_invariant
    v=View(**kw); v.pct=10.0; v.fluxLow=False; peak=v.fatMaxRate
    v.fatRate=f32(0.90*peak); b=v.zoneColor(); bi=(b!=BLUE)
    v.fatRate=peak; ab=(v.zoneColor()==BLUE)
    check("zonecolor_recon", bi and ab, f"below={b}")


def run2(settings):
    ftp,lt1,ge=settings; kw={'ftp':ftp,'lt1':lt1,'ge':ge}
    print(f"----- extra: ftp={ftp} lt1={lt1} ge={ge}")
    # measured zero invalidates carry
    v=warm(400,20,**kw); a0=(v.carryArmed==True); t=21000
    for _ in range(60):
        t+=1000; v.compute(mk(0,t,speed=12.0))
    a1=(v.carryArmed==False); a2=(v.fluxLow==True and v.carbPctStr()=="--")
    kb=v.modelKcal; rb=v.carbRate
    t+=1000; v.compute(mk(None,t,speed=12.0))
    a3=(v.modelKcal==kb and v.carbRate<=rb and v.fluxLow==True and v.carbPctStr()=="--")
    t+=1000; v.compute(mk(400,t)); a4=(v.carryArmed==False)
    t+=1000; v.compute(mk(400,t)); a5=(v.carryArmed==True)
    check("measured_zero_invalidates", a0 and a1 and a2 and a3 and a4 and a5, f"{a0}{a1}{a2}{a3}{a4}{a5}")

    # per-gap energy bound
    v=warm(400,4,**kw); t=5000; k0=v.modelKcal
    t+=1000; v.compute(mk(400,t)); kps=v.modelKcal-k0; before=v.modelKcal
    for _ in range(30):
        t+=1000; v.compute(mk(400,t)); t+=1000; v.compute(mk(400,t)); t+=1000; v.compute(mk(None,t))
    sec=(v.modelKcal-before)/kps
    b1=(kps>0.0 and 89.0<sec<91.0)
    t+=1000; v.compute(mk(400,t))          # clear mNullSec before the long gap
    b2=(v.carryArmed==True and v.nullSec==0.0)
    k1=v.modelKcal; t+=10000; v.compute(mk(None,t)); one=(v.modelKcal-k1)/kps
    b3=(2.0<one<3.0)
    check("per_gap_bound", b1 and b2 and b3, f"sec={sec:.4f} oneGap={one:.4f}")

    # exact floor boundaries (dt=0 re-use of timerTime)
    v=View(**kw); t=1000; v.compute(mk(None,t))
    def sf(x): v.carbRate=f32(x); v.fatRate=0.0
    sf(8.0);   v.compute(mk(None,t)); e1=(v.fluxLow==True)
    sf(8.001); v.compute(mk(None,t)); e2=(v.fluxLow==False)
    sf(5.0);   v.compute(mk(None,t)); e3=(v.fluxLow==False)
    sf(4.999); v.compute(mk(None,t)); e4=(v.fluxLow==True)
    check("exact_boundaries", e1 and e2 and e3 and e4, f"{e1}{e2}{e3}{e4}")

    # compute-driven RED at 3000 W
    v=View(**kw); t=1000; v.compute(mk(3000,t)); t+=1000; v.compute(mk(3000,t))
    check("compute_drives_red", v.pct>=85.0 and v.fluxLow==False and v.zoneColor()==RED
          and v.carbPctStr()!="--", f"pct={v.pct}")

    # FIXED argmax pin
    v=View(**kw); w=v.fatMaxW
    def fs(pw): return f32(f32(pw)*f32(f32(1.0)-v.cho(pw)))
    best=fs(w); n=0; isMax=True
    for pw in range(30,v.scanMax+1,2):
        n+=1
        if fs(pw)>best: isMax=False
    check("fatmax_pin_fixed", 30<=w<=v.scanMax and isMax and n>=16
          and relEq(v.fatMaxRate,v.fatRateAt(w),1e-6), f"w={w} n={n}")

def demo_superseded_pin():
    """Evidence for why test_fatmax_is_scan_argmax compares the SCAN'S OWN score
    expression rather than fatRateAt(). An earlier revision asserted
    fatRateAt(mFatMaxW) >= fatRateAt(mFatMaxW +- 2); fatRateAt is the same
    quantity in a different operation order, so in binary32 it can rank two watts
    the other way round and RED-LIGHT CORRECT CODE. This is not a failure of the
    model - it is the bug the shipped test no longer has."""
    print("\n--- superseded +-2 fatRateAt pin: false-RED witnesses ---")
    hits=0
    for (ftp,lt1,ge) in [(540,18,28),(350,144,28),(565,264,21),(250,0,21)]:
        v=View(ftp=ftp,lt1=lt1,ge=ge); w=v.fatMaxW; pk=v.fatRateAt(w)
        bad=False
        if w-2>=30 and pk<v.fatRateAt(w-2): bad=True
        if w+2<=v.scanMax and pk<v.fatRateAt(w+2): bad=True
        if bad: hits+=1
        print(f"  ({ftp},{lt1},{ge}) w={w}: fr(w)={pk!r} fr(w+2)={v.fatRateAt(w+2)!r} "
              f"-> superseded pin would {'FAIL' if bad else 'pass'}")
    print(f"  witnesses found: {hits}")

SET=[(250,0,21),(50,19,28),(600,50,15),(400,0,21),(50,6,28),(189,16,21),(300,299,28),
     (540,18,28),(350,144,28),(600,599,21),(565,264,21),(50,49,28),(120,84,15)]
for s in SET:
    run(s); run2(s)
demo_superseded_pin()
print("\n==== FAILURES:", FAIL if FAIL else "none", "====")
import sys
sys.exit(1 if FAIL else 0)
print("\n==== FAILURES:", FAIL if FAIL else "none", "====")
