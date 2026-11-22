"""In-sample grid for the opening-range FADE (2024-06..2025-12). Args: <this dir> <data dir>"""
import sys; sys.path.insert(0, sys.argv[1]); D = sys.argv[2]
import pandas as pd, numpy as np, itertools, intraday as I, warnings; warnings.filterwarnings("ignore")
from multiprocessing import Pool
df = pd.read_pickle(f"{D}/xau5.pkl"); IS = df[df.index < "2026-01-01"]
def run(a):
    s, rm, k, tg = a; tr = I.orb_fade(IS, s, rm, k, tg)
    h1 = I.stats(tr[tr.t < "2025-03-01"]).get("PF"); h2 = I.stats(tr[tr.t >= "2025-03-01"]).get("PF")
    return dict(sess=s, range=rm, stop_k=k, tgt=tg, **I.stats(tr), PF_h1=h1, PF_h2=h2,
                L=I.stats(tr[tr.side==1]).get("PF"), S=I.stats(tr[tr.side==-1]).get("PF"))
g = list(itertools.product(["LDN","COMEX","NY"], [15,30,60], [0.5,1.0], ["mid","opp","1R"]))
with Pool(4) as p: r = pd.DataFrame(p.map(run, g))
r.to_pickle(f"{D}/grid_fade.pkl"); pd.set_option("display.width", 250)
print(r.groupby(["sess","range"]).agg(PF_med=("PF","median"), share_gt1=("PF", lambda v:(v>1).mean()), n=("n","median"), avgR=("avgR","median"), h1=("PF_h1","median"), h2=("PF_h2","median")).round(2).to_string())
print(r.groupby(["stop_k","tgt"]).agg(PF_med=("PF","median"), share_gt1=("PF", lambda v:(v>1).mean())).round(2).to_string())
print(r.sort_values("PF", ascending=False).head(10).to_string())
