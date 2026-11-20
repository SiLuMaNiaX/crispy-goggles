# Research scripts

Every script takes two arguments: the path to this folder (for `hwm.py`) and a data folder.

The data folder holds PAXGUSDT 5m candles (`a.csv`, `b.csv`), exported with the TextToQuant `export_candles` tool.
- `a.csv`: 2024-06-01 → 2026-04-25
- `b.csv`: 2026-04-26 → 2026-11-18

`norepaint.py` builds `xau5.pkl` from them, with weekend bars removed to match XAUUSD trading hours. Run it first.

| Script | Purpose |
|---|---|
| `hwm.py` | Python port of the indicator, plus the backtester |
| `norepaint.py` | Proves that truncated history gives the same signals (no repaint) |
| `baseline.py` | Raw signals with several exit models, with and without costs |
| `explore.py`, `explore2.py` | Forward returns by context; drift baseline (in-sample only) |
| `tfscan.py` | Same logic on 5m, 15m, 30m and 1h (in-sample only) |
| `robust.py` | 108-configuration neighbourhood grid (in-sample only) |
| `oos.py` | The single out-of-sample run of the chosen candidates |
| `stress.py` | Cost stress, 6-month windows, Monte Carlo |
| `eacheck.py` | Checks the EA's windowed calculation and broker timezone |
