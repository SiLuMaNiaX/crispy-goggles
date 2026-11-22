"""Port of the EA's server->London/NY time functions, checked against the tz database (every 30 min, 2024-2027)."""
import pandas as pd, datetime as dt
def nth_sunday(y, m, n):
    d = dt.datetime(y, m, 1); d += dt.timedelta(days=(6 - d.weekday()) % 7)      # first Sunday
    if n > 0: return d + dt.timedelta(weeks=n - 1)
    while (d + dt.timedelta(weeks=1)).month == m: d += dt.timedelta(weeks=1)
    return d
us = lambda u: nth_sunday(u.year, 3, 2) + dt.timedelta(hours=7) <= u < nth_sunday(u.year, 11, 1) + dt.timedelta(hours=6)
eu = lambda u: nth_sunday(u.year, 3, -1) + dt.timedelta(hours=1) <= u < nth_sunday(u.year, 10, -1) + dt.timedelta(hours=1)
def srv_to_utc(s, gmt=2):
    u = s - dt.timedelta(hours=gmt)
    return u - dt.timedelta(hours=1) if us(u - dt.timedelta(hours=1)) else u
bad = 0; n = 0
for u in pd.date_range("2024-01-01", "2027-01-01", freq="30min"):
    u = u.to_pydatetime()
    srv = u + dt.timedelta(hours=2 + (1 if us(u) else 0))                         # typical GMT+2/+3 server
    uu = srv_to_utc(srv)
    lon = uu + dt.timedelta(hours=1 if eu(uu) else 0); ny = uu - dt.timedelta(hours=4 if us(uu) else 5)
    ref = pd.Timestamp(u, tz="UTC")
    ok = (uu == u and lon.strftime("%H:%M") == ref.tz_convert("Europe/London").strftime("%H:%M")
          and ny.strftime("%H:%M") == ref.tz_convert("America/New_York").strftime("%H:%M"))
    bad += not ok; n += 1
    if not ok: print("  mismatch at UTC", u.strftime("%a %Y-%m-%d %H:%M"))
print(f"checked {n} half-hours 2024-2026: mismatches {bad}")
