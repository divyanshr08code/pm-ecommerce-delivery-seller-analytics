"""Tests: grain, reconciliation, formulas, and independent re-derivation of headline numbers.

The pandas tests read the raw CSVs and never touch the SQL tables' logic, so a bug in the SQL
cannot hide by agreeing with itself.
"""
import json
import math
from pathlib import Path

import duckdb
import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
TIME_COLS = ["order_purchase_timestamp", "order_delivered_customer_date", "order_estimated_delivery_date"]


@pytest.fixture(scope="module")
def con():
    connection = duckdb.connect(str(ROOT / "data" / "olist.duckdb"), read_only=True)
    yield connection
    connection.close()


@pytest.fixture(scope="module")
def results():
    return json.loads((ROOT / "outputs" / "results.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def delivered():
    orders = pd.read_csv(RAW / "olist_orders_dataset.csv", parse_dates=TIME_COLS)
    d = orders[(orders.order_status == "delivered") & orders.order_delivered_customer_date.notna()].copy()
    d["late"] = d.order_delivered_customer_date.dt.normalize() > d.order_estimated_delivery_date.dt.normalize()
    return d


@pytest.fixture(scope="module")
def reviewed(delivered):
    reviews = pd.read_csv(RAW / "olist_order_reviews_dataset.csv", parse_dates=["review_answer_timestamp"])
    latest = (reviews.sort_values(["review_answer_timestamp", "review_id"], ascending=[False, True])
              .drop_duplicates("order_id"))
    return delivered.merge(latest[["order_id", "review_score"]], on="order_id")


def scalar(con, sql):
    return con.sql(sql).fetchall()[0][0]


# ---------- Grain and reconciliation ----------
def test_fact_is_one_row_per_order(con):
    assert scalar(con, "SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM fct_orders") == 0
    assert scalar(con, "SELECT COUNT(*) FROM fct_orders") == scalar(con, "SELECT COUNT(*) FROM raw_orders")


@pytest.mark.parametrize("view,key", [("stg_reviews", "order_id"), ("stg_order_items", "order_id"),
                                      ("stg_payments", "order_id"), ("stg_geolocation", "zip_prefix")])
def test_staging_views_are_unique(con, view, key):
    assert scalar(con, f"SELECT COUNT(*) - COUNT(DISTINCT {key}) FROM {view}") == 0


def test_money_reconciles_to_raw(con):
    assert scalar(con, "SELECT SUM(item_value) FROM fct_orders") == pytest.approx(
        scalar(con, "SELECT SUM(price) FROM raw_items"))
    assert scalar(con, "SELECT SUM(payment_value) FROM fct_orders") == pytest.approx(
        scalar(con, "SELECT SUM(payment_value) FROM raw_payments"))


def test_state_table_adds_to_total(con):
    assert scalar(con, "SELECT SUM(late) FROM rpt_kpi_state") == scalar(con, "SELECT late FROM rpt_kpi_overall")


def test_root_cause_covers_every_late_order_once(con):
    assert scalar(con, "SELECT SUM(late_orders) FROM rpt_root_cause") == scalar(con, "SELECT late FROM rpt_kpi_overall")
    assert scalar(con, "SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM stg_late_attributed") == 0


def test_dashboard_extract_has_no_order_or_customer_ids(con):
    columns = [r[0] for r in con.sql("DESCRIBE dash_fact").fetchall()]
    assert not [c for c in columns if "order_id" in c or "customer_id" in c or "unique" in c]


# ---------- Formulas ----------
def test_wilson_macro_matches_hand_calculation(con):
    # 8 of 40, z = 1.96, from the textbook formula.
    n, p, z = 40, 0.2, 1.96
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    assert scalar(con, "SELECT wilson_low(8, 40)") == pytest.approx(centre - half)
    assert scalar(con, "SELECT wilson_high(8, 40)") == pytest.approx(centre + half)


def test_wilson_matches_scipy(con):
    stats = pytest.importorskip("scipy.stats")
    ci = stats.binomtest(8, 40).proportion_ci(confidence_level=0.95, method="wilson")
    assert scalar(con, "SELECT wilson_low(8, 40)") == pytest.approx(ci.low, abs=1e-3)
    assert scalar(con, "SELECT wilson_high(8, 40)") == pytest.approx(ci.high, abs=1e-3)


def test_pilot_sample_size_by_hand(con):
    row = con.sql("SELECT baseline_rate, target_rate, n_per_arm FROM rpt_pilot_sizing "
                  "WHERE segment = 'Customers in RJ, BA, ES' AND relative_reduction = 0.33").fetchall()[0]
    p1, p2, n = row
    assert n == math.ceil(2.8 ** 2 * (p1 * (1 - p1) + p2 * (1 - p2)) / (p1 - p2) ** 2)


# ---------- Independent re-derivation from raw CSVs with pandas ----------
def test_rederive_delivered_late_and_breach(delivered, results):
    assert len(delivered) == results["delivered"]["value"]
    assert delivered.late.sum() == results["late"]["value"]
    assert delivered.late.mean() == pytest.approx(results["breach_rate"]["value"])


def test_rederive_delivery_time_percentiles(delivered, results):
    days = (delivered.order_delivered_customer_date - delivered.order_purchase_timestamp).dt.total_seconds() / 86400
    assert days.mean() == pytest.approx(results["mean_days"]["value"])
    assert days.median() == pytest.approx(results["p50_days"]["value"])
    assert days.quantile(0.9) == pytest.approx(results["p90_days"]["value"])


def test_rederive_rj_breach(delivered, results):
    customers = pd.read_csv(RAW / "olist_customers_dataset.csv")
    joined = delivered.merge(customers, on="customer_id")
    assert joined[joined.customer_state == "RJ"].late.mean() == pytest.approx(results["br_RJ"]["value"])


def test_rederive_low_review_share(reviewed, results):
    low = reviewed[reviewed.review_score <= 2]
    assert (~low.late).mean() == pytest.approx(results["share_low_ontime"]["value"])


def test_rederive_wave_share(delivered, results):
    month = delivered.order_purchase_timestamp.dt.strftime("%Y-%m")
    wave = month.isin(["2017-11", "2018-02", "2018-03"])
    assert delivered[wave].late.sum() / delivered.late.sum() == pytest.approx(results["wave_share_late"]["value"])


def test_rederive_review_gradient(reviewed, results):
    days = (reviewed.order_delivered_customer_date.dt.normalize()
            - reviewed.order_estimated_delivery_date.dt.normalize()).dt.days
    assert reviewed[days <= 0].review_score.mean() == pytest.approx(results["review_ontime"]["value"])
    assert reviewed[days >= 8].review_score.mean() == pytest.approx(results["review_8p"]["value"])


def test_rederive_estimate_shift(delivered, results):
    days = (delivered.order_delivered_customer_date.dt.normalize()
            - delivered.order_estimated_delivery_date.dt.normalize()).dt.days
    assert (days > 7).mean() == pytest.approx(results["shift_7"]["value"])


def test_rederive_root_cause_shares_in_pandas(con, results):
    """Re-implement the counterfactual in pandas on fct_orders columns."""
    f = con.sql("SELECT lane, customer_state, carrier_ts, shipping_limit_ts, estimated_date, carrier_transit_days, "
                "is_delivered, is_late FROM fct_orders").df()
    f = f[f.is_delivered == True].copy()  # noqa: E712
    valid = f[f.carrier_transit_days.notna()]
    lane_counts = valid.groupby("lane").carrier_transit_days.transform("count")
    lane_norm = valid[lane_counts >= 30].groupby("lane").carrier_transit_days.quantile(0.75)
    state_norm = valid.groupby("customer_state").carrier_transit_days.quantile(0.75)
    late = f[(f.is_late == True) & f.carrier_transit_days.notna() & f.shipping_limit_ts.notna()].copy()  # noqa: E712
    late["norm"] = late.lane.map(lane_norm).fillna(late.customer_state.map(state_norm))
    capped = late[["carrier_transit_days", "norm"]].min(axis=1)
    pickup = late[["carrier_ts", "shipping_limit_ts"]].min(axis=1)
    both_fixed = (pickup + pd.to_timedelta((capped * 86400).astype("int64"), unit="s")).dt.normalize()
    promise = both_fixed > pd.to_datetime(late.estimated_date)
    assert promise.mean() == pytest.approx(results["promise_share"]["value"], abs=1e-3)


# ---------- Results registry ----------
def test_two_ways_match(results):
    assert results["two_way_a"]["value"] == pytest.approx(results["two_way_b"]["value"])


def test_shares_sum_to_one(results):
    total = sum(results[k]["value"] for k in ["promise_share", "carrier_share", "seller_share", "either_share", "compound_share"])
    assert total == pytest.approx(1.0)
