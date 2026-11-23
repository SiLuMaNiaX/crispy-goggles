"""Port of "The Mathematical Indicator · 2-Candle Bias" (roan-maverick/tradingview-mathematical-indicator, MIT)
to Python, following mathematical-indicator.pine bar by bar (defaults, 15m chart).

Two execution models:
  exec="pine" : exactly how the script's on-chart record scores trades (decides at bar close, fills at the
                trigger inside that bar, assumes the dip came first, no costs unless `cost` is given).
  exec="ea"   : what a live EA can actually do. The 15m bar is replayed through its three 5m sub-bars:
                the stop order is only armed once a dip has happened, a break before any dip cancels,
                management (stop first, then 1R / breakeven / target) runs on sub-bars. Costs applied.

Time alignment follows a typical GMT+2/+3 MT5 broker: server time = New York time + 7h, so the daily candle
starts 17:00 New York and 4H candles start at 17, 21, 01, 05, 09, 13 New York.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

P = dict(  # script defaults
    piv_htf=1, piv_ltf=2, stair_len=2, keep_lvl=3, merge_atr=0.15,
    zone_run=3, zone_move=1.5, zone_req=True, keep_zones=8,
    prox_atr=0.25, block_ceil=True,
    mode_on=True, trend_body=60.0, trend_size=1.0, pb_depth=38.2,
    min_range=3, max_range=20, min_opp=2, min_range_atr=0.5, max_range_atr=4.0,
    min_body=50.0, max_break=50.0, wick_atr=0.10, wick_pct=20.0, max_wait=6, buf=0.0,
    exit_plan="level", part_pct=50.0, max_r=3.0, fast_on=True, fast_r=1.5, fast_bars=3, fast_exit=True,
    max_hold_min=240, max_trades_sess=2, tie="story",
    sessions=(("Asia", "Asia/Tokyo", "09:00", "10:00", True), ("London", "Europe/London", "08:00", "09:00", True),
              ("NewYork", "America/New_York", "08:30", "09:30", False), ("NYSE", "America/New_York", "09:30", "10:30", True),
              ("Power", "America/New_York", "15:00", "16:00", False)),
)


# ───────────────────────── data ─────────────────────────
def server_time(idx_utc: pd.DatetimeIndex) -> pd.DatetimeIndex:
    return idx_utc.tz_convert("America/New_York").tz_localize(None) + pd.Timedelta(hours=7)


def ohlc(g):
    return g.agg(open=("open", "first"), high=("high", "max"), low=("low", "min"), close=("close", "last"),
                 t=("t", "first"))


def rma(x, n):
    out = np.full(len(x), np.nan)
    if len(x) >= n:
        out[n - 1] = np.mean(x[:n])
        for i in range(n, len(x)):
            out[i] = (out[i - 1] * (n - 1) + x[i]) / n
    return out


def atr(o, h, l, c, n=14):
    tr = np.r_[h[0] - l[0], np.maximum(h[1:] - l[1:], np.maximum(abs(h[1:] - c[:-1]), abs(l[1:] - c[:-1])))]
    return rma(tr, n)


def body_piv(o, c, t, n):
    """f_bodyPiv at every bar: (res, sup, tt). tt = time n bars back."""
    m = len(c); res = np.full(m, np.nan); sup = np.full(m, np.nan); tt = np.full(m, np.nan)
    for j in range(2 * n - 1, m):
        isR = isS = True; hi = -np.inf; lo = np.inf
        for i in range(2 * n):
            g, r = c[j - i] > o[j - i], c[j - i] < o[j - i]
            if i < n: isR &= r; isS &= g
            else:     isR &= g; isS &= r
            hi = max(hi, o[j - i], c[j - i]); lo = min(lo, o[j - i], c[j - i])
        if isR: res[j] = hi
        if isS: sup[j] = lo
        tt[j] = t[j - n]
    return res, sup, tt


def stair(h, l, ln):
    m = len(h); s = np.full(m, np.nan); h1 = h2 = l1 = l2 = np.nan
    for j in range(m):
        p = j - ln
        if p - ln >= 0:
            if h[p] == max(h[p - ln:p + ln + 1]) and h[p] > max(h[p - ln:p]) and h[p] >= max(h[p + 1:p + ln + 1]):
                h2, h1 = h1, h[p]
            if l[p] == min(l[p - ln:p + ln + 1]) and l[p] < min(l[p - ln:p]) and l[p] <= min(l[p + 1:p + ln + 1]):
                l2, l1 = l1, l[p]
        if not (np.isnan(h2) or np.isnan(l2)):
            s[j] = 1 if (h1 > h2 and l1 > l2) else -1 if (h1 < h2 and l1 < l2) else 0
    return s


def build(df5: pd.DataFrame, tf="15min", p=P):
    d = df5.copy(); d["t"] = d.index; d["srv"] = server_time(d.index)
    chart = ohlc(d.groupby(d.srv.dt.floor(tf))); chart.index.name = "srv"
    d["ci"] = np.searchsorted(chart.index.values, d.srv.dt.floor(tf).values)
    htf = {}
    for name, key, n in (("D", d.srv.dt.floor("D"), p["piv_htf"]), ("4H", d.srv.dt.floor("4h"), p["piv_htf"]),
                         ("1H", d.srv.dt.floor("1h"), p["piv_ltf"]), ("W", d.srv.dt.to_period("W-SUN").dt.start_time, 0)):
        b = ohlc(d.groupby(key)); o, h, l, c = (b[k].to_numpy() for k in ("open", "high", "low", "close"))
        tt_ = b.t.to_numpy().astype("datetime64[ns]").astype(np.int64)
        res, sup, tt = body_piv(o, c, tt_, n) if n else (None, None, None)
        b = b.assign(atr=atr(o, h, l, c), stair=stair(h, l, p["stair_len"]), res=res, sup=sup, tt=tt)
        # index of the HTF bar containing each chart bar
        chart[f"j_{name}"] = np.searchsorted(b.index.values, chart.index.values, side="right") - 1
        htf[name] = b
    return d, chart, htf


# ───────────────────────── strategy ─────────────────────────
def run(df5: pd.DataFrame, exec="ea", cost=0.40, slip=0.10, p=P, built=None, diag=None):
    d, ch, htf = built or build(df5, p=p)
    o, h, l, c = (ch[k].to_numpy() for k in ("open", "high", "low", "close"))
    t_utc = pd.DatetimeIndex(ch.t)
    n = len(c); a = atr(o, h, l, c)
    cres, csup, ctt = body_piv(o, c, t_utc.asi8, p["piv_ltf"])
    sub_start = np.searchsorted(d.ci.values, np.arange(n)); sub_end = np.r_[sub_start[1:], len(d)]
    so, sh, sl_, sc = (d[k].to_numpy() for k in ("open", "high", "low", "close"))

    # session index per chart bar (bar open time inside the window, DST aware)
    sess = np.zeros(n, int)
    for k, (nm, tz, a0, a1, on) in enumerate(p["sessions"], start=1):
        if not on: continue
        lt = t_utc.tz_convert(tz); m = (lt.hour * 60 + lt.minute).to_numpy()
        h0, m0 = map(int, a0.split(":")); h1_, m1 = map(int, a1.split(":"))
        inside = (m >= h0 * 60 + m0) & (m < h1_ * 60 + m1)
        sess = np.where((sess == 0) & inside, k, sess)
    day_key = ch.index.floor("D").values
    new_day = np.r_[True, day_key[1:] != day_key[:-1]]

    # clean-zone state machine on the chart timeframe (f_clean), output used one bar later
    zout = [None] * n
    rDir = rCount = rOpp = 0; rStart = rExt = np.nan; rT0 = None
    for i in range(n):
        cd = 1 if c[i] > o[i] else -1 if c[i] < o[i] else 0
        if rDir == 0:
            if cd != 0: rDir, rCount, rOpp, rStart, rExt, rT0 = cd, 1, 0, o[i], c[i], i
        elif cd == rDir:
            rCount += 1; rOpp = 0
            if (rDir == 1 and c[i] > rExt) or (rDir == -1 and c[i] < rExt): rExt = c[i]
        elif cd == -rDir:
            rOpp += 1
            if rOpp >= 2:
                if rCount >= p["zone_run"] and not np.isnan(a[i]) and abs(rExt - rStart) >= p["zone_move"] * a[i]:
                    zout[i] = (max(rStart, rExt), min(rStart, rExt), rDir)
                rDir, rCount, rOpp, rStart = cd, 2, 0, o[i - 1]
                rExt = max(c[i], c[i - 1]) if cd == 1 else min(c[i], c[i - 1])

    levels = []   # dict(price, dir, tfc, broken, touches)
    zones = []    # dict(top, bot, active)

    def trim(tfc, dr):
        cnt = brk = 0
        for lv in reversed(list(levels)):
            if lv["tfc"] == tfc and lv["dir"] == dr:
                if lv["broken"]:
                    brk += 1
                    if brk > 1: levels.remove(lv)
                else:
                    cnt += 1
                    if cnt > p["keep_lvl"]: levels.remove(lv)

    def feed(tfc, cc, hh, ll, res, sup, tol):
        for lv in levels:
            if lv["tfc"] == tfc and not lv["broken"]:
                if (cc > lv["price"]) if lv["dir"] == 1 else (cc < lv["price"]): lv["broken"] = True
        trim(tfc, 1); trim(tfc, -1)
        for px, dr in ((res, 1), (sup, -1)):
            if np.isnan(px): continue
            if any(lv["tfc"] == tfc and lv["dir"] == dr and not lv["broken"] and abs(lv["price"] - px) <= tol for lv in levels):
                continue
            levels.append(dict(price=px, dir=dr, tfc=tfc, broken=False)); trim(tfc, dr)
            if 1 <= tfc <= 3:
                for z in zones:
                    pad = (z["top"] - z["bot"]) * 0.08
                    if z["active"] and z["bot"] + pad < px < z["top"] - pad: z["active"] = False

    def next_level(side, frm, mind):
        best = None
        for lv in levels:
            if not lv["broken"] and lv["dir"] == side:
                ahead = lv["price"] > frm + mind if side == 1 else lv["price"] < frm - mind
                if ahead and (best is None or (lv["price"] < best if side == 1 else lv["price"] > best)): best = lv["price"]
        return best

    def in_zone(px):
        return any(z["active"] and z["bot"] <= px <= z["top"] for z in zones)

    def hv(name, i, col):
        j = ch[f"j_{name}"].iat[i] - 1
        return htf[name][col].iat[j] if j >= 0 else np.nan

    jD, j4, j1 = ch.j_D.to_numpy(), ch["j_4H"].to_numpy(), ch["j_1H"].to_numpy()
    trades = []

    def manage_subbars(s0, s1):
        """EA management on 5m sub-bars: stop first, then 1R partial + breakeven, pre-level breakeven, target."""
        nonlocal sP, beOn, partDone
        for s in range(s0, s1):
            if (sl_[s] <= sP) if sd == 1 else (sh[s] >= sP):
                px = (min(so[s], sP) - slip) if sd == 1 else (max(so[s], sP) + slip)
                return px, ("breakeven" if beOn else "stop")
            if not partDone and ((sh[s] >= r1) if sd == 1 else (sl_[s] <= r1)):
                if p["exit_plan"] == "1R":
                    return r1, "1R"
                partDone = True
                if not beOn:
                    beOn, sP = True, eP
            if not beOn and pre is not None and ((sh[s] >= pre) if sd == 1 else (sl_[s] <= pre)):
                beOn, sP = True, eP
            if (sh[s] >= tgt) if sd == 1 else (sl_[s] <= tgt):
                return tgt, "target"
        return None, None

    def record():
        part = p["part_pct"] / 100 if (partDone and p["exit_plan"] == "level") else 0.0
        R = part + (1 - part) * (exit_px - eP) * sd / risk
        trades.append(dict(t=eT, side=sd, sess=sIdx, entry=eP, stop0=stp, risk=risk, tgt=tgt, R=R,
                           R_net=R - cost / risk, why=why, part=partDone))
    st = 0; sBias = 0; sIdx = 0; sMode = 1; preHi = preLo = np.nan; tradesSess = 0; blkL = blkS = False
    prev_sess = 0
    for i in range(n):
        # ① levels: daily, 4H, 1H on a new higher-timeframe candle, then the chart's own
        for name, jj, tfc in (("D", jD, 0), ("4H", j4, 1), ("1H", j1, 2)):
            if i > 0 and jj[i] != jj[i - 1] and jj[i] >= 1:
                b = htf[name].iloc[jj[i] - 1]
                feed(tfc, b.close, b.high, b.low, b.res, b.sup, p["merge_atr"] * (0 if np.isnan(b.atr) else b.atr))
        feed(4, c[i], h[i], l[i], cres[i], csup[i], p["merge_atr"] * (0 if np.isnan(a[i]) else a[i]))
        # clean zone from the previous bar
        if i > 0 and zout[i - 1] is not None:
            zones.append(dict(top=zout[i - 1][0], bot=zout[i - 1][1], active=True))
            while len(zones) > p["keep_zones"]: zones.pop(0)
        if np.isnan(a[i]):
            prev_sess = sess[i]; continue
        # ① story
        dO, dC, dAtr = hv("D", i, "open"), hv("D", i, "close"), hv("D", i, "atr")
        hO, hC, hH, hL, hAtr = (hv("4H", i, k) for k in ("open", "close", "high", "low", "atr"))
        dDir = 0 if np.isnan(dC) else int(np.sign(dC - dO)); hDir = 0 if np.isnan(hC) else int(np.sign(hC - hO))
        ws = hv("W", i, "stair"); story = hv("D", i, "stair") if np.isnan(ws) else ws
        prox = p["prox_atr"] * (dAtr if not np.isnan(dAtr) else a[i] * 10)
        atC = any(lv["tfc"] == 0 and not lv["broken"] and lv["dir"] == 1 and c[i] >= lv["price"] - prox for lv in levels)
        atF = any(lv["tfc"] == 0 and not lv["broken"] and lv["dir"] == -1 and c[i] <= lv["price"] + prox for lv in levels)
        if dDir != 0 and dDir == hDir: bias = dDir
        elif p["tie"] == "skip": bias = 0
        elif p["tie"] == "daily": bias = dDir
        elif atC and not atF: bias = -1
        elif atF and not atC: bias = 1
        elif not np.isnan(story) and story != 0: bias = int(story)
        else: bias = dDir if dDir != 0 else hDir
        rngP = hH - hL
        preRan = rngP > 0 and abs(hC - hO) >= p["trend_body"] / 100 * rngP and rngP >= p["trend_size"] * hAtr
        preDir = int(np.sign(hC - hO)) if not np.isnan(hC) else 0
        # sessions
        if new_day[i]: blkL = blkS = False
        if sess[i] != 0 and sess[i] != prev_sess:
            sBias = bias; sMode = 2 if (p["mode_on"] and preRan and preDir == bias and bias != 0) else 1
            preHi, preLo, sIdx, tradesSess = hH, hL, sess[i], 0
        prev_sess = sess[i]
        if sess[i] != 0 and p["block_ceil"]:
            if sBias == 1 and atC: blkL = True
            if sBias == -1 and atF: blkS = True

        # ③ look for a breakout candle
        D_ = diag if diag is not None else {}
        def bump(k): D_[k] = D_.get(k, 0) + 1
        if sess[i] != 0: bump("bars in session window")
        if sess[i] != 0 and sBias == 0: bump("window bars with no bias")
        if st == 0 and sess[i] != 0 and sIdx == sess[i] and tradesSess < p["max_trades_sess"] and sBias != 0 and i >= p["max_range"]:
            side = sBias
            ok = False; top = bot = None; kk = 0; T = B = None; opp = 0
            for k in range(1, p["max_range"] + 1):
                bt_, bb_ = max(o[i - k], c[i - k]), min(o[i - k], c[i - k])
                T = bt_ if T is None else max(T, bt_); B = bb_ if B is None else min(B, bb_)
                opp += (c[i - k] < o[i - k]) if side == 1 else (c[i - k] > o[i - k])
                if T - B > p["max_range_atr"] * a[i]: break
                outside = c[i] > T if side == 1 else c[i] < B
                if k >= p["min_range"] and opp >= p["min_opp"] and T - B >= p["min_range_atr"] * a[i] and outside:
                    ok, top, bot, kk = True, T, B, k
            rng_c = h[i] - l[i]
            strong = rng_c > 0 and abs(c[i] - o[i]) >= p["min_body"] / 100 * rng_c
            dir_ok = c[i] > o[i] if side == 1 else c[i] < o[i]
            if ok: bump("valid range")
            if ok and dir_ok: bump("…and close breaks it in bias direction")
            if ok and dir_ok and strong:
                bump("…and strong body (breakout candle)")
                hgt = top - bot; px = h[i] if side == 1 else l[i]
                pb = preHi - p["pb_depth"] / 100 * (preHi - preLo) if side == 1 else preLo + p["pb_depth"] / 100 * (preHi - preLo)
                if (blkL if side == 1 else blkS): bump("✕ at daily level, blocked today")
                elif rng_c > p["max_break"] / 100 * hgt: bump("✕ breakout candle > 50% of range")
                elif sMode == 2 and not np.isnan(pb) and not (bot <= pb if side == 1 else top >= pb): bump("✕ pullback depth not met")
                elif p["zone_req"] and not in_zone(px): bump("✕ not in a clean zone")
                else:
                    bump("✓ stop order placed")
                    st, sd, rTop, rBot, bHi, bLo, bBar, trig, wickSeen = 1, side, top, bot, h[i], l[i], i, px, False

        # ③ working stop order → fill;  ④ manage
        if st == 1 and i > bBar:
            lw = (min(o[i], c[i]) - l[i]) if sd == 1 else (h[i] - max(o[i], c[i]))
            wick_close = lw >= p["wick_atr"] * a[i] and (h[i] - l[i]) > 0 and lw >= p["wick_pct"] / 100 * (h[i] - l[i])
            filled = cancelled = False
            if exec == "pine":
                hit = h[i] >= trig if sd == 1 else l[i] <= trig
                if hit:
                    if wickSeen or (wick_close and (o[i] < trig if sd == 1 else o[i] > trig)):
                        fill_px = max(o[i], trig) if sd == 1 else min(o[i], trig); filled = True; fill_sub = None
                    else: cancelled = True; bump("✕ broke with no dip first")
            else:   # EA: replay 5m sub-bars; dip = price moved wick_atr*ATR against the trade from this bar's open
                need = p["wick_atr"] * a[i - 1]
                ext = o[i]
                for s in range(sub_start[i], sub_end[i]):
                    ext = min(ext, sl_[s]) if sd == 1 else max(ext, sh[s])
                    dip_now = (o[i] - ext >= need) if sd == 1 else (ext - o[i] >= need)
                    hit = sh[s] >= trig if sd == 1 else sl_[s] <= trig
                    if hit:
                        opened_before = so[s] < trig if sd == 1 else so[s] > trig
                        if wickSeen or (dip_now and opened_before):
                            fill_px = (max(so[s], trig) + slip) if sd == 1 else (min(so[s], trig) - slip)
                            filled = True; fill_sub = s
                        else: cancelled = True; bump("✕ broke with no dip first")
                        break
                    if dip_now: wickSeen = True
            if filled:
                stp = bLo - p["buf"] if sd == 1 else bHi + p["buf"]
                risk = abs(fill_px - stp)
                if risk <= 0 or (sd == 1 and stp >= fill_px) or (sd == -1 and stp <= fill_px):
                    st = 0
                else:
                    st, eP, sP, eBar, eT = 2, fill_px, stp, i, t_utc[i]; bump("✓ filled")
                    r1 = eP + sd * risk; beOn = partDone = False; fastCnt = 0; tradesSess += 1
                    nl = next_level(sd, eP, risk * 0.05); far = next_level(sd, r1 - sd * risk * 0.02, 0)
                    cap = eP + sd * p["max_r"] * risk
                    tgt = r1 if p["exit_plan"] == "1R" else (cap if far is None or (far > cap if sd == 1 else far < cap) else far)
                    pre = nl if nl is not None and (nl < r1 if sd == 1 else nl > r1) else None
                    exit_px = None
                    if exec == "pine":
                        if (c[i] <= sP) if sd == 1 else (c[i] >= sP): exit_px, why = sP, "stop"
                    else:
                        exit_px, why = manage_subbars(fill_sub + 1, sub_end[i])
            elif cancelled:
                st = 0
            else:
                if wick_close: wickSeen = True
                if (c[i] < rTop) if sd == 1 else (c[i] > rBot): st = 0; bump("✕ closed back inside range")
                elif i - bBar >= p["max_wait"]: st = 0; bump("✕ stop order expired")
            if st == 2 and exit_px is not None:
                record(); st = 0
        elif st == 2 and i > eBar:
            exit_px = None
            if exec == "pine":
                if (l[i] <= sP) if sd == 1 else (h[i] >= sP):
                    exit_px = min(o[i], sP) if sd == 1 else max(o[i], sP); why = "stop"
                else:
                    if not partDone and ((h[i] >= r1) if sd == 1 else (l[i] <= r1)):
                        if p["exit_plan"] == "1R": exit_px, why = r1, "1R"
                        else:
                            partDone = True
                            if not beOn: beOn, sP = True, eP
                    if exit_px is None and not beOn and pre is not None and ((h[i] >= pre) if sd == 1 else (l[i] <= pre)):
                        beOn, sP = True, eP
                    if exit_px is None and ((h[i] >= tgt) if sd == 1 else (l[i] <= tgt)): exit_px, why = tgt, "target"
            else:
                exit_px, why = manage_subbars(sub_start[i], sub_end[i])
            if exit_px is None:
                fastCnt = fastCnt + 1 if ((c[i] > o[i] and c[i] > c[i - 1]) if sd == 1 else (c[i] < o[i] and c[i] < c[i - 1])) else 0
                if p["fast_on"] and p["fast_exit"] and (c[i] - eP) * sd / risk >= p["fast_r"] and fastCnt >= p["fast_bars"]:
                    exit_px, why = c[i], "too fast"
            if exit_px is None and p["max_hold_min"] > 0 and (t_utc[i] + pd.Timedelta(minutes=15) - eT) >= pd.Timedelta(minutes=p["max_hold_min"]):
                exit_px, why = c[i], "time"
            if exit_px is not None:
                record(); st = 0
    return pd.DataFrame(trades)

