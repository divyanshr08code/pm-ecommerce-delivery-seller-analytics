"""Draw the static charts used in the README and memo, from outputs/tables and the database.

Colours follow a fixed role: blue = main series, orange = comparison, aqua and yellow = further
categories. One axis per chart. Thin marks, recessive grid, selective labels.
"""
from pathlib import Path

import duckdb
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
TABLES = ROOT / "outputs" / "tables"
CHARTS = ROOT / "outputs" / "charts"
CHARTS.mkdir(parents=True, exist_ok=True)

BLUE, ORANGE, AQUA, YELLOW, MAGENTA = "#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"
INK, MUTED, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"

plt.rcParams.update({
    "font.family": "sans-serif", "font.size": 10, "axes.edgecolor": GRID, "axes.labelcolor": MUTED,
    "xtick.color": MUTED, "ytick.color": MUTED, "text.color": INK, "axes.grid": True,
    "grid.color": GRID, "grid.linewidth": 0.7, "axes.axisbelow": True, "axes.spines.top": False,
    "axes.spines.right": False, "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "axes.titlelocation": "left", "axes.titlesize": 12, "axes.titleweight": "bold", "legend.frameon": False,
})


def read(name):
    return pd.read_csv(TABLES / f"{name}.csv")


def save(fig, name):
    fig.tight_layout()
    fig.savefig(CHARTS / f"{name}.png", dpi=160)
    plt.close(fig)


def monthly_trend():
    d = read("rpt_kpi_monthly")
    d["month"] = pd.to_datetime(d.purchase_month)
    fig, ax = plt.subplots(figsize=(9, 4))
    ax.plot(d.month, d.breach_rate * 100, color=BLUE, lw=2, marker="o", ms=4, label="Monthly breach rate")
    ax.plot(d.month, d.breach_rate_rolling_3m * 100, color=ORANGE, lw=2, label="Rolling 3 months (pooled)")
    for _, row in d[d.breach_rate >= 0.12].iterrows():
        ax.annotate(f"{row.month:%b %Y}\n{row.breach_rate * 100:.1f}%", (row.month, row.breach_rate * 100),
                    textcoords="offset points", xytext=(-24 if row.month.month == 2 else 0, 8), ha="center", fontsize=8.5, color=INK)
    ax.set_ylim(0, 24)
    ax.set_ylabel("Late orders, % of delivered")
    ax.set_title("Lateness comes in waves: three months hold about half of all late orders")
    ax.legend(loc="upper left")
    save(fig, "01_monthly_breach")


def root_cause():
    d = read("rpt_root_cause")
    d = d[d.root_cause != "unattributable"].sort_values("share_of_late")
    labels = {"carrier": "Carrier slower than lane norm", "promise": "Promise too tight", "seller": "Seller missed dispatch",
              "compound": "Needs both seller and carrier fixed", "either": "Either fix alone rescues it"}
    fig, ax = plt.subplots(figsize=(9, 3.4))
    colors = [ORANGE if c == "promise" else BLUE for c in d.root_cause]
    ax.barh([labels[c] for c in d.root_cause], d.share_of_late * 100, color=colors, height=0.6)
    for y, v in enumerate(d.share_of_late * 100):
        ax.text(v + 0.8, y, f"{v:.1f}%", va="center", fontsize=9)
    ax.set_xlabel("Share of late orders (blue = execution, orange = promise)")
    ax.set_title("Root cause of late orders, using each lane's P75 transit as normal")
    ax.grid(axis="y", visible=False)
    save(fig, "02_root_cause")


def state_wave():
    d = read("rpt_state_chronic_vs_episodic").sort_values("breach_rate")
    fig, ax = plt.subplots(figsize=(8, 6.2))
    y = range(len(d))
    ax.hlines(y, d.non_wave_breach_rate * 100, d.wave_breach_rate * 100, color=GRID, lw=2)
    ax.scatter(d.non_wave_breach_rate * 100, y, color=BLUE, s=42, zorder=3, label="Outside wave months", edgecolor=SURFACE)
    ax.scatter(d.wave_breach_rate * 100, y, color=ORANGE, s=42, zorder=3, label="Wave months", edgecolor=SURFACE)
    ax.set_yticks(list(y), d.customer_state)
    ax.set_xlabel("Late orders, % of delivered")
    ax.set_title("AL is late all the time; RJ is late mostly during waves")
    ax.legend(loc="lower right")
    ax.grid(axis="y", visible=False)
    save(fig, "03_state_chronic_vs_episodic")


def review_impact():
    d = read("rpt_review_by_lateness").sort_values("bucket_sort")
    fig, ax = plt.subplots(figsize=(7, 3.6))
    ax.bar(d.bucket, d.low_review_rate * 100, color=BLUE, width=0.55)
    for x, v in enumerate(d.low_review_rate * 100):
        ax.text(x, v + 1.5, f"{v:.1f}%", ha="center", fontsize=9)
    ax.set_ylim(0, 95)
    ax.set_ylabel("Reviews scored 1-2, % of reviews")
    ax.set_title("Low reviews rise steeply with days late (association)")
    ax.grid(axis="x", visible=False)
    save(fig, "04_reviews_by_lateness")


def promise_distribution():
    con = duckdb.connect(str(ROOT / "data" / "olist.duckdb"), read_only=True)
    d = con.sql("SELECT days_vs_promise FROM fct_orders WHERE is_delivered").df()
    con.close()
    v = d.days_vs_promise.clip(-50, 30)
    early, late = v[v <= 0], v[v > 0]
    fig, ax = plt.subplots(figsize=(9, 3.6))
    ax.hist(early, bins=range(-50, 1), color=BLUE, label="On time", rwidth=0.9)
    ax.hist(late, bins=range(1, 31), color=ORANGE, label="Late", rwidth=0.9)
    ax.set_xlabel("Days delivered versus promised date (negative = early; ends clipped at -50 and +30)")
    ax.set_ylabel("Orders")
    ax.set_title("Most orders arrive far ahead of the promise, while a thin tail still misses it")
    ax.legend()
    ax.grid(axis="x", visible=False)
    save(fig, "05_days_vs_promise")


def state_stage_mix():
    d = read("rpt_root_cause_by_state")
    top = d.groupby("customer_state").state_late.first().sort_values(ascending=False).head(10).index
    pivot = (d[d.customer_state.isin(top)]
             .assign(group=lambda x: x.root_cause.replace({"either": "other", "compound": "other", "unattributable": "other"}))
             .pivot_table(index="customer_state", columns="group", values="share_of_state_late", aggfunc="sum")
             .reindex(top[::-1]).fillna(0) * 100)
    fig, ax = plt.subplots(figsize=(9, 4.2))
    left = pd.Series(0.0, index=pivot.index)
    for name, color, label in [("carrier", BLUE, "Carrier"), ("seller", ORANGE, "Seller"),
                               ("promise", AQUA, "Promise"), ("other", YELLOW, "Either or both")]:
        ax.barh(pivot.index, pivot[name], left=left, color=color, height=0.65, label=label,
                edgecolor=SURFACE, linewidth=1.5)
        left += pivot[name]
    ax.set_xlim(0, 100)
    ax.set_xlabel("Share of the state's late orders, %")
    ax.set_title("Carrier is the largest cause in each of the ten states with most late orders")
    ax.legend(ncols=4, loc="upper center", bbox_to_anchor=(0.5, -0.18))
    ax.grid(axis="y", visible=False)
    save(fig, "06_stage_mix_by_state")


for chart in [monthly_trend, root_cause, state_wave, review_impact, promise_distribution, state_stage_mix]:
    chart()
print(f"Saved charts to {CHARTS}")
