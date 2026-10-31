"""Generate docs/RESULTS.md and outputs/results.json from the built database.

Why generated: a hand-typed results file can drift away from the data. Each row here is read
from the table that produced it, and the file and line are looked up, not typed.
Other docs quote these values; scripts/audit_docs.py checks that they match.
"""
import datetime as dt
import json
import re
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent
con = duckdb.connect(str(ROOT / "data" / "olist.duckdb"), read_only=True)

SQL_LINES = {p.name: p.read_text(encoding="utf-8").splitlines() for p in sorted((ROOT / "sql").glob("*.sql"))}


def locate(table):
    """Return 'sql/file.sql:line' for the statement that creates a table."""
    pattern = re.compile(rf"CREATE OR REPLACE TABLE {re.escape(table)}\b")
    for name, lines in SQL_LINES.items():
        for number, line in enumerate(lines, 1):
            if pattern.search(line):
                return f"sql/{name}:{number}"
    raise ValueError(f"No SQL creates {table}")


FORMATS = {
    "int": lambda v: f"{int(round(v)):,}",
    "pct": lambda v: f"{v * 100:.1f}%",
    "d1": lambda v: f"{v:.1f}",
    "d2": lambda v: f"{v:.2f}",
    "brl": lambda v: f"R$ {v:,.0f}",
}

# Sections: (heading, [(key, label, table, column, where, format), ...])
O = "rpt_kpi_overall"
S = "rpt_kpi_state"
M = "rpt_kpi_monthly"
RC = "rpt_root_cause"
PE = "rpt_promise_vs_execution"
ST = "rpt_stage_late_vs_ontime"
EO = "rpt_estimate_overall"
SH = "rpt_estimate_shift"
TI = "rpt_seller_tiers"
CO = "rpt_seller_concentration"
DB = "rpt_dispatch_vs_breach"
RL = "rpt_review_by_lateness"
LS = "rpt_low_review_split"
OT = "rpt_on_time_low_review_drivers"
RB = "rpt_robustness"
WV = "rpt_wave_summary"
CE = "rpt_state_chronic_vs_episodic"
SI = "rpt_simpson_sp_sellers"
PS = "rpt_pilot_segments"
PZ = "rpt_pilot_sizing"
BF = "rpt_black_friday"
RCS = "rpt_root_cause_by_state"
RCM = "rpt_root_cause_by_month"
DQ = "rpt_dq_checks"
RC_ROW = "rpt_row_counts"
SC = "rpt_seller_scorecard"
CA = "rpt_category_scorecard"
LANE = "rpt_lane_sp_rj_monthly"
SOP = "rpt_sop_scope"
EQ = "rpt_estimate_quality"
AN = "rpt_anomalies"
AM = "rpt_anomaly_months"
TW = "rpt_two_way_check"
WIN = "rpt_lateness_penalty_within_state"


def month(m):
    return f"purchase_month = DATE '{m}-01'"


def state(s):
    return f"customer_state = '{s}'"


def test(name):
    return f"test = '{name}'"


def dq(name):
    return f"check_name = '{name}'"


def cause(c):
    return f"root_cause = '{c}'"


def size(seg, red):
    return f"segment = '{seg}' AND relative_reduction = {red}"


SECTIONS = [
    ("Row counts per raw table", [
        (f"rows_{t}", f"Rows in {t}", RC_ROW, "row_count", f"table_name = '{t}'", "int")
        for t in ["orders", "items", "payments", "reviews", "customers", "sellers", "products", "translation", "geolocation"]
    ]),
    ("Data quality", [
        ("dq_no_items", "Orders with no item rows", DQ, "affected_rows", dq("orders with no item rows (anti join)"), "int"),
        ("dq_no_items_except", "Same count via EXCEPT", "rpt_orders_without_items_check", "by_except", None, "int"),
        ("dq_no_review", "Orders with no review", DQ, "affected_rows", dq("orders with no review (anti join)"), "int"),
        ("dq_no_payment", "Orders with no payment", DQ, "affected_rows", dq("orders with no payment row (anti join)"), "int"),
        ("dq_extra_reviews", "Extra review rows beyond one per order", DQ, "affected_rows", dq("extra review rows beyond one per order"), "int"),
        ("dq_shared_review_id", "Review rows sharing a review_id", DQ, "affected_rows", dq("review_id values shared by more than one row"), "int"),
        ("dq_multi_item", "Orders with more than one item line", DQ, "affected_rows", dq("orders with more than one item line"), "int"),
        ("dq_multi_seller", "Orders with more than one seller", DQ, "affected_rows", dq("orders with more than one seller"), "int"),
        ("dq_deliv_no_date", "Delivered status, delivered date missing", DQ, "affected_rows", dq("status delivered but delivered date missing"), "int"),
        ("dq_cancel_date", "Canceled status, delivered date present", DQ, "affected_rows", dq("status canceled but delivered date present"), "int"),
        ("dq_no_approval", "Delivered status, approval missing", DQ, "affected_rows", dq("status delivered, approval timestamp missing"), "int"),
        ("dq_no_carrier", "Delivered status, carrier date missing", DQ, "affected_rows", dq("status delivered, carrier date missing"), "int"),
        ("dq_neg_handoff", "Carrier pickup before approval", DQ, "affected_rows", dq("carrier pickup before approval (negative handoff)"), "int"),
        ("dq_pick_purchase", "Carrier pickup before purchase", DQ, "affected_rows", dq("carrier pickup before purchase"), "int"),
        ("dq_neg_transit", "Delivered before carrier pickup", DQ, "affected_rows", dq("delivered to customer before carrier pickup (negative transit)"), "int"),
        ("dq_no_category", "Products with no category", DQ, "affected_rows", dq("products with no category"), "int"),
        ("dq_geo_outside", "Geolocation rows outside Brazil box", DQ, "affected_rows", dq("geolocation rows outside Brazil bounding box"), "int"),
        ("dq_geo_extra", "Geolocation rows beyond one per prefix", DQ, "affected_rows", dq("geolocation rows beyond one per zip prefix"), "int"),
        ("pop_status_delivered", "Orders with status delivered", "rpt_population_waterfall", "orders", "step = 2", "int"),
        ("pop_not_delivered", "Orders with any other status", "rpt_population_waterfall", "MAX(orders) - MIN(orders)", "step <= 2", "int"),
    ]),
    ("Overall KPIs", [
        ("orders", "All orders", O, "orders", None, "int"),
        ("delivered", "Delivered orders with a delivered date (breach denominator)", O, "delivered", None, "int"),
        ("late", "Late orders (by date)", O, "late", None, "int"),
        ("breach_rate", "SLA-breach rate", O, "breach_rate", None, "pct"),
        ("promise_accuracy", "Promise accuracy", O, "promise_accuracy", None, "pct"),
        ("mean_days", "Mean purchase-to-delivery days", O, "mean_delivery_days", None, "d1"),
        ("p50_days", "P50 purchase-to-delivery days", O, "p50_delivery_days", None, "d1"),
        ("p90_days", "P90 purchase-to-delivery days", O, "p90_delivery_days", None, "d1"),
        ("mean_promised", "Mean promised days", O, "mean_promised_days", None, "d1"),
        ("mean_approval", "Mean approval lag days", O, "mean_approval_lag_days", None, "d2"),
        ("mean_handoff", "Mean seller handoff days", O, "mean_seller_handoff_days", None, "d1"),
        ("p50_handoff", "P50 seller handoff days", O, "p50_seller_handoff_days", None, "d1"),
        ("p90_handoff", "P90 seller handoff days", O, "p90_seller_handoff_days", None, "d1"),
        ("mean_transit", "Mean carrier transit days", O, "mean_carrier_transit_days", None, "d1"),
        ("p50_transit", "P50 carrier transit days", O, "p50_carrier_transit_days", None, "d1"),
        ("p90_transit", "P90 carrier transit days", O, "p90_carrier_transit_days", None, "d1"),
        ("mean_days_late", "Mean days late, late orders only", O, "mean_days_late_when_late", None, "d1"),
        ("p50_days_late", "P50 days late, late orders only", O, "p50_days_late_when_late", None, "d1"),
        ("cancel_rate", "Cancellation rate (canceled or unavailable)", O, "cancellation_rate", None, "pct"),
        ("cancel_n", "Canceled or unavailable orders", O, "canceled_unavailable", None, "int"),
        ("defect_rate", "Order defect proxy rate", O, "defect_rate", None, "pct"),
        ("cancel_value", "Payment value on canceled or unavailable orders", O, "canceled_unavailable_value", None, "brl"),
        ("total_value", "Total payment value", O, "total_payment_value", None, "brl"),
        ("late_value", "Payment value on late delivered orders", O, "late_order_value", None, "brl"),
        ("cancel_value_share", "Canceled or unavailable value, share of total", O, "canceled_unavailable_value / total_payment_value", None, "pct"),
        ("late_value_share", "Late order value, share of total", O, "late_order_value / total_payment_value", None, "pct"),
    ]),
    ("Monthly trend and waves", [
        *[(f"br_{m.replace('-', '_')}", f"Breach rate {m}", M, "breach_rate", month(m), "pct")
          for m in ["2017-10", "2017-11", "2017-12", "2018-01", "2018-02", "2018-03", "2018-04", "2018-06", "2018-08"]],
        ("growth_2017_11", "Order growth Nov 2017 vs Oct", M, "orders_mom_growth", month("2017-11"), "pct"),
        ("growth_2018_01", "Order growth Jan 2018 vs Dec", M, "orders_mom_growth", month("2018-01"), "pct"),
        ("growth_2018_02", "Order growth Feb 2018 vs Jan", M, "orders_mom_growth", month("2018-02"), "pct"),
        ("growth_2018_03", "Order growth Mar 2018 vs Feb", M, "orders_mom_growth", month("2018-03"), "pct"),
        ("transit_2018_01", "Mean transit days Jan 2018", M, "mean_transit_days", month("2018-01"), "d1"),
        ("transit_2018_02", "Mean transit days Feb 2018", M, "mean_transit_days", month("2018-02"), "d1"),
        ("transit_2018_03", "Mean transit days Mar 2018", M, "mean_transit_days", month("2018-03"), "d1"),
        ("promised_2018_06", "Mean promised days Jun 2018", M, "mean_promised_days", month("2018-06"), "d1"),
        ("promised_2018_08", "Mean promised days Aug 2018", M, "mean_promised_days", month("2018-08"), "d1"),
        ("mean_days_2018_06", "Mean delivery days Jun 2018", M, "mean_delivery_days", month("2018-06"), "d1"),
        ("mean_days_2018_08", "Mean delivery days Aug 2018", M, "mean_delivery_days", month("2018-08"), "d1"),
        ("promise_share_2018_08", "Promise share of late orders Aug 2018", RCM, "share_of_month_late", f"{month('2018-08')} AND {cause('promise')}", "pct"),
        ("wave_share_delivered", "Three wave months: share of delivered", WV, "wave_share_of_delivered", None, "pct"),
        ("wave_share_late", "Three wave months: share of late", WV, "wave_share_of_late", None, "pct"),
        ("wave_breach", "Breach rate inside wave months", WV, "wave_breach_rate", None, "pct"),
        ("non_wave_breach", "Breach rate outside wave months", WV, "non_wave_breach_rate", None, "pct"),
        ("bf_per_day", "Orders per day, Black Friday weekend 2017", BF, "orders_per_day", "period LIKE '1%'", "int"),
        ("bf_before_per_day", "Orders per day, four weeks before", BF, "orders_per_day", "period LIKE '0%'", "int"),
        ("bf_breach", "Breach rate, Black Friday weekend orders", BF, "breach_rate", "period LIKE '1%'", "pct"),
        ("bf_before_breach", "Breach rate, four weeks before", BF, "breach_rate", "period LIKE '0%'", "pct"),
        ("bf_transit", "Mean transit, Black Friday weekend orders", BF, "mean_transit_days", "period LIKE '1%'", "d1"),
        ("bf_before_transit", "Mean transit, four weeks before", BF, "mean_transit_days", "period LIKE '0%'", "d1"),
        ("bf_handoff", "Mean handoff, Black Friday weekend orders", BF, "mean_handoff_days", "period LIKE '1%'", "d1"),
        ("bf_before_handoff", "Mean handoff, four weeks before", BF, "mean_handoff_days", "period LIKE '0%'", "d1"),
    ]),
    ("Anomalies", [
        ("anom_total", "Flagged state-months", AN, "COUNT(*)", None, "int"),
        ("anom_wave", "Flagged state-months inside the three wave months", AN, "COUNT(*)",
         "purchase_month IN (DATE '2017-11-01', DATE '2018-02-01', DATE '2018-03-01')", "int"),
        ("anom_nov", "States flagged Nov 2017", AM, "flagged_states", month("2017-11"), "int"),
        ("anom_feb", "States flagged Feb 2018", AM, "flagged_states", month("2018-02"), "int"),
        ("anom_mar", "States flagged Mar 2018", AM, "flagged_states", month("2018-03"), "int"),
        ("anom_single", "Flags labelled single seller concentration", AN, "COUNT(*)", "driver_label = 'single seller concentration'", "int"),
    ]),
    ("States", [
        *[(f"br_{s}", f"Breach rate {s}", S, "breach_rate", state(s), "pct") for s in ["AL", "MA", "RJ", "RS", "SP", "BA", "ES", "AC", "AM", "RR"]],
        ("rj_delivered", "RJ delivered orders", S, "delivered", state("RJ"), "int"),
        ("rj_late", "RJ late orders", S, "late", state("RJ"), "int"),
        ("sp_late", "SP late orders", S, "late", state("SP"), "int"),
        ("rj_share_late", "RJ share of all late orders", S, "share_of_late", state("RJ"), "pct"),
        ("rj_share_orders", "RJ share of all orders", S, "share_of_orders", state("RJ"), "pct"),
        ("sp_share_late", "SP share of all late orders", S, "share_of_late", state("SP"), "pct"),
        ("sp_share_orders", "SP share of all orders", S, "share_of_orders", state("SP"), "pct"),
        ("al_delivered", "AL delivered orders", S, "delivered", state("AL"), "int"),
        ("al_ci_low", "AL breach rate, Wilson low", S, "breach_ci_low", state("AL"), "pct"),
        ("al_ci_high", "AL breach rate, Wilson high", S, "breach_ci_high", state("AL"), "pct"),
        ("rr_delivered", "RR delivered orders", S, "delivered", state("RR"), "int"),
        ("rr_ci_low", "RR breach rate, Wilson low", S, "breach_ci_low", state("RR"), "pct"),
        ("rr_ci_high", "RR breach rate, Wilson high", S, "breach_ci_high", state("RR"), "pct"),
        ("rj_mean", "RJ mean delivery days", S, "mean_delivery_days", state("RJ"), "d1"),
        ("rs_mean", "RS mean delivery days", S, "mean_delivery_days", state("RS"), "d1"),
        ("rj_p90", "RJ P90 delivery days", S, "p90_delivery_days", state("RJ"), "d1"),
        ("rs_p90", "RS P90 delivery days", S, "p90_delivery_days", state("RS"), "d1"),
        ("rj_promised", "RJ mean promised days", S, "mean_promised_days", state("RJ"), "d1"),
        ("rs_promised", "RS mean promised days", S, "mean_promised_days", state("RS"), "d1"),
        ("rj_wave", "RJ breach in wave months", CE, "wave_breach_rate", state("RJ"), "pct"),
        ("rj_nonwave", "RJ breach outside wave months", CE, "non_wave_breach_rate", state("RJ"), "pct"),
        ("rs_nonwave", "RS breach outside wave months", CE, "non_wave_breach_rate", state("RS"), "pct"),
        ("rj_wave_share", "Share of RJ late orders in wave months", CE, "wave_share_of_late", state("RJ"), "pct"),
        ("rj_rank", "RJ overall breach rank (states with 300+ delivered)", CE, "overall_rank", state("RJ"), "int"),
        ("rj_nw_rank", "RJ non-wave breach rank", CE, "non_wave_rank", state("RJ"), "int"),
        ("al_wave", "AL breach in wave months", CE, "wave_breach_rate", state("AL"), "pct"),
        ("al_nonwave", "AL breach outside wave months", CE, "non_wave_breach_rate", state("AL"), "pct"),
        ("al_wave_share", "Share of AL late orders in wave months", CE, "wave_share_of_late", state("AL"), "pct"),
        ("al_nw_rank", "AL non-wave breach rank", CE, "non_wave_rank", state("AL"), "int"),
        ("lane_mar", "SP>RJ breach rate Mar 2018", LANE, "breach_rate", month("2018-03"), "pct"),
        ("lane_jun_promised", "SP>RJ mean promised days Jun 2018", LANE, "mean_promised_days", month("2018-06"), "d1"),
        ("lane_jun_actual", "SP>RJ mean actual days Jun 2018", LANE, "mean_actual_days", month("2018-06"), "d1"),
        ("lane_oct_promised", "SP>RJ mean promised days Oct 2017", LANE, "mean_promised_days", month("2017-10"), "d1"),
        ("lane_aug_promised", "SP>RJ mean promised days Aug 2018", LANE, "mean_promised_days", month("2018-08"), "d1"),
    ]),
    ("Root cause (transit norm P75)", [
        ("attributable", "Attributable late orders", PE, "attributable_late", None, "int"),
        ("execution_share", "Execution share of late orders", PE, "execution_share", None, "pct"),
        ("promise_share", "Promise share of late orders", PE, "promise_share", None, "pct"),
        ("carrier_share", "Carrier-only share", PE, "carrier_share", None, "pct"),
        ("seller_share", "Seller-only share", PE, "seller_share", None, "pct"),
        ("either_share", "Either-fix share", PE, "either_share", None, "pct"),
        ("compound_share", "Compound share", PE, "compound_share", None, "pct"),
        *[(f"n_{c}", f"Late orders: {c}", RC, "late_orders", cause(c), "int") for c in ["carrier", "promise", "seller", "compound", "either", "unattributable"]],
        ("carrier_promised", "Mean promised days, carrier-caused", RC, "mean_promised_days", cause("carrier"), "d1"),
        ("promise_promised", "Mean promised days, promise-caused", RC, "mean_promised_days", cause("promise"), "d1"),
        ("late_transit", "Mean transit days, late orders", ST, "mean_transit_days", "outcome = 'late'", "d1"),
        ("ontime_transit", "Mean transit days, on-time orders", ST, "mean_transit_days", "outcome = 'on time'", "d1"),
        ("late_handoff", "Mean handoff days, late orders", ST, "mean_handoff_days", "outcome = 'late'", "d1"),
        ("ontime_handoff", "Mean handoff days, on-time orders", ST, "mean_handoff_days", "outcome = 'on time'", "d1"),
        ("late_promised", "Mean promised days, late orders", ST, "mean_promised_days", "outcome = 'late'", "d1"),
        ("ontime_promised", "Mean promised days, on-time orders", ST, "mean_promised_days", "outcome = 'on time'", "d1"),
        ("late_dispatch", "Late orders where seller missed dispatch deadline", ST, "seller_dispatch_late_rate", "outcome = 'late'", "pct"),
        ("ontime_dispatch", "On-time orders where seller missed dispatch deadline", ST, "seller_dispatch_late_rate", "outcome = 'on time'", "pct"),
        ("breach_missed", "Breach rate when dispatch deadline missed (order x seller)", DB, "breach_rate", "dispatch_outcome = 'missed dispatch deadline'", "pct"),
        ("breach_met", "Breach rate when dispatch deadline met (order x seller)", DB, "breach_rate", "dispatch_outcome = 'met dispatch deadline'", "pct"),
        ("rj_carrier", "Carrier share of RJ late orders", RCS, "share_of_state_late", f"{state('RJ')} AND {cause('carrier')}", "pct"),
        ("sp_carrier", "Carrier share of SP late orders", RCS, "share_of_state_late", f"{state('SP')} AND {cause('carrier')}", "pct"),
        ("sp_seller", "Seller share of SP late orders", RCS, "share_of_state_late", f"{state('SP')} AND {cause('seller')}", "pct"),
        ("al_promise", "Promise share of AL late orders", RCS, "share_of_state_late", f"{state('AL')} AND {cause('promise')}", "pct"),
        ("al_carrier", "Carrier share of AL late orders", RCS, "share_of_state_late", f"{state('AL')} AND {cause('carrier')}", "pct"),
        ("ma_promise", "Promise share of MA late orders", RCS, "share_of_state_late", f"{state('MA')} AND {cause('promise')}", "pct"),
        ("ma_carrier", "Carrier share of MA late orders", RCS, "share_of_state_late", f"{state('MA')} AND {cause('carrier')}", "pct"),
        ("rs_carrier", "Carrier share of RS late orders", RCS, "share_of_state_late", f"{state('RS')} AND {cause('carrier')}", "pct"),
        ("states_dominant_carrier", "States where carrier is the dominant cause", RCS, "COUNT(*)", "cause_rank = 1 AND root_cause = 'carrier'", "int"),
        ("states_total", "States in the root-cause table", RCS, "COUNT(DISTINCT customer_state)", None, "int"),
    ]),
    ("Estimate quality", [
        ("buffer", "Mean buffer: promised minus actual days", EO, "mean_buffer_days", None, "d1"),
        ("p50_vs_promise", "Median days versus promise (negative = early)", EO, "p50_days_vs_promise", None, "int"),
        ("early_7", "Share delivered 7+ days early", EO, "share_7plus_days_early", None, "pct"),
        ("early_14", "Share delivered 14+ days early", EO, "share_14plus_days_early", None, "pct"),
        ("corr_promise", "Correlation, promised vs actual days", EO, "corr_promised_actual", None, "d2"),
        ("corr_dist_promise", "Correlation, distance vs promised days", EO, "corr_distance_promised", None, "d2"),
        ("corr_dist_actual", "Correlation, distance vs actual days", EO, "corr_distance_actual", None, "d2"),
        *[(f"shift_{k}".replace("-", "m"), f"Breach rate if every estimate moved {k:+d} days", SH, "breach_rate", f"shift_days = {k}", "pct") for k in [-7, -3, -1, 1, 3, 7, 14]],
    ]),
    ("Sellers and categories", [
        ("scored_sellers", "Sellers with 30+ delivered orders", CO, "scored_sellers", None, "int"),
        ("all_sellers", "All sellers with a delivered order", CO, "all_sellers", None, "int"),
        ("worst_decile_n", "Sellers in the worst excess-late decile", CO, "worst_decile_sellers", None, "int"),
        ("worst_decile_delivered", "Worst decile: share of scored delivered", CO, "worst_decile_share_of_delivered", None, "pct"),
        ("worst_decile_late", "Worst decile: share of scored late", CO, "worst_decile_share_of_late", None, "pct"),
        ("worst_decile_breach", "Worst decile: breach rate", CO, "worst_decile_breach_rate", None, "pct"),
        ("other_breach", "Other scored sellers: breach rate", CO, "other_breach_rate", None, "pct"),
        ("worst_decile_excess", "Worst decile: excess late orders", CO, "worst_decile_excess_late", None, "int"),
        *[(f"tier_{i}_breach", f"Breach rate, tier {t}", TI, "breach_rate", f"tier = '{i} {t}'", "pct") for i, t in [(1, "500+ orders"), (2, "100-499"), (3, "30-99"), (4, "under 30")]],
        *[(f"tier_{i}_miss", f"Dispatch miss rate, tier {t}", TI, "dispatch_miss_rate", f"tier = '{i} {t}'", "pct") for i, t in [(1, "500+ orders"), (4, "under 30")]],
        ("tier_1_sellers", "Sellers in the 500+ tier", TI, "sellers", "tier = '1 500+ orders'", "int"),
        ("tier_4_sellers", "Sellers in the under-30 tier", TI, "sellers", "tier = '4 under 30'", "int"),
        ("tier_4_share", "Under-30 tier share of delivered", TI, "share_of_delivered", "tier = '4 under 30'", "pct"),
        ("big_seller_delivered", "Largest excess-late seller: delivered", SC, "delivered", "seller_id LIKE '4a3ca931%'", "int"),
        ("big_seller_breach", "Largest excess-late seller: breach rate", SC, "breach_rate", "seller_id LIKE '4a3ca931%'", "pct"),
        ("big_seller_rank", "Largest excess-late seller: rank by Wilson low", SC, "worst_rank", "seller_id LIKE '4a3ca931%'", "int"),
        ("big_seller_excess", "Largest excess-late seller: excess late orders", SC, "excess_late_orders", "seller_id LIKE '4a3ca931%'", "int"),
        ("worst_seller_delivered", "Worst-ranked seller: delivered", SC, "delivered", "worst_rank = 1", "int"),
        ("worst_seller_breach", "Worst-ranked seller: breach rate", SC, "breach_rate", "worst_rank = 1", "pct"),
        ("worst_seller_miss", "Worst-ranked seller: dispatch miss rate", SC, "dispatch_miss_rate", "worst_rank = 1", "pct"),
        ("cat_office_defect", "office_furniture defect proxy", CA, "defect_rate", "category = 'office_furniture'", "pct"),
        ("cat_office_ontime", "office_furniture defect proxy, on-time orders", CA, "defect_rate_when_on_time", "category = 'office_furniture'", "pct"),
        ("cat_office_breach", "office_furniture breach rate", CA, "breach_rate", "category = 'office_furniture'", "pct"),
        ("cat_office_orders", "office_furniture orders", CA, "orders", "category = 'office_furniture'", "int"),
        ("cat_audio_breach", "audio breach rate", CA, "breach_rate", "category = 'audio'", "pct"),
        ("cat_food_defect", "food_drink defect proxy", CA, "defect_rate", "category = 'food_drink'", "pct"),
        ("simpson_sp_all", "SP sellers: mean delivery days, all", SI, "mean_delivery_days", "seller_group = 'SP sellers' AND lane_type = 'ALL'", "d2"),
        ("simpson_ot_all", "Other sellers: mean delivery days, all", SI, "mean_delivery_days", "seller_group = 'other sellers' AND lane_type = 'ALL'", "d2"),
        ("simpson_sp_inter", "SP sellers: interstate", SI, "mean_delivery_days", "seller_group = 'SP sellers' AND lane_type = 'interstate'", "d2"),
        ("simpson_ot_inter", "Other sellers: interstate", SI, "mean_delivery_days", "seller_group = 'other sellers' AND lane_type = 'interstate'", "d2"),
        ("simpson_sp_same", "SP sellers: same state", SI, "mean_delivery_days", "seller_group = 'SP sellers' AND lane_type = 'same state'", "d2"),
        ("simpson_ot_same", "Other sellers: same state", SI, "mean_delivery_days", "seller_group = 'other sellers' AND lane_type = 'same state'", "d2"),
        ("simpson_sp_same_share", "SP sellers: same-state share of orders", SI, "share_of_group", "seller_group = 'SP sellers' AND lane_type = 'same state'", "pct"),
        ("simpson_ot_same_share", "Other sellers: same-state share of orders", SI, "share_of_group", "seller_group = 'other sellers' AND lane_type = 'same state'", "pct"),
    ]),
    ("Customer impact (association, not causation)", [
        *[(f"review_{k}", f"Mean review, {b}", RL, "mean_review", f"bucket = '{b}'", "d2") for k, b in [("ontime", "on time"), ("1_3", "1-3 days late"), ("4_7", "4-7 days late"), ("8p", "8+ days late")]],
        *[(f"low_{k}", f"Low-review rate, {b}", RL, "low_review_rate", f"bucket = '{b}'", "pct") for k, b in [("ontime", "on time"), ("1_3", "1-3 days late"), ("4_7", "4-7 days late"), ("8p", "8+ days late")]],
        ("low_total", "Low reviews on delivered orders", LS, "low_reviews_delivered", None, "int"),
        ("low_late_n", "Low reviews on late orders", LS, "low_reviews_late", None, "int"),
        ("low_ontime_n", "Low reviews on on-time orders", LS, "low_reviews_on_time", None, "int"),
        ("share_low_late", "Share of low reviews on late orders", LS, "share_low_reviews_late", None, "pct"),
        ("share_low_ontime", "Share of low reviews on on-time orders", LS, "share_low_reviews_on_time", None, "pct"),
        ("share_reviewed_late", "Share of reviewed delivered orders that were late", LS, "share_reviewed_orders_late", None, "pct"),
        ("low_rate_late", "Low-review rate, late orders", LS, "low_rate_late", None, "pct"),
        ("low_rate_ontime", "Low-review rate, on-time orders", LS, "low_rate_on_time", None, "pct"),
        ("relative_risk", "Relative risk of a low review, late vs on time", LS, "relative_risk", None, "d1"),
        ("low_single", "On-time low-review rate, single item", OT, "low_review_rate", "order_shape LIKE '1%'", "pct"),
        ("low_multi_item", "On-time low-review rate, multi-item one seller", OT, "low_review_rate", "order_shape LIKE '2%'", "pct"),
        ("low_multi_seller", "On-time low-review rate, multi-seller", OT, "low_review_rate", "order_shape LIKE '3%'", "pct"),
        ("share_multi_seller_ot", "Multi-seller share of on-time reviewed orders", OT, "share_of_on_time_reviewed", "order_shape LIKE '3%'", "pct"),
        ("gap_within_state", "Review gap on-time minus late, weighted within state", WIN, "weighted_review_gap", None, "d2"),
        ("gap_states", "States compared within-state", WIN, "states_compared", None, "int"),
        ("gap_states_lower", "States where late orders score lower", WIN, "states_where_late_scores_lower", None, "int"),
    ]),
    ("Robustness", [
        ("rb_timestamp", "Breach rate by timestamp", RB, "variant_value", test("Breach by timestamp instead of date"), "pct"),
        ("rb_top5", "Top-5 states in common, date vs timestamp", RB, "variant_value", test("Top-5 worst states: date vs timestamp"), "int"),
        ("rb_strict", "Breach rate counting open orders past promise", RB, "variant_value", test("Count open orders past promise as late (survivorship)"), "pct"),
        ("rb_open", "Open orders past promise", RB, "variant_value", test("Open orders past promise"), "int"),
        ("rb_p50", "Execution share, transit norm P50", RB, "variant_value", test("Execution share: transit norm P50"), "pct"),
        ("rb_p90", "Execution share, transit norm P90", RB, "variant_value", test("Execution share: transit norm P90"), "pct"),
        ("rb_month", "Execution share, same-month norm", RB, "variant_value", test("Execution share: transit norm from the same month"), "pct"),
        ("rb_lowvol", "Execution share, sellers under 30 dropped", RB, "variant_value", test("Execution share: drop sellers under 30 orders"), "pct"),
        ("rb_multi", "Execution share, multi-seller dropped", RB, "variant_value", test("Execution share: drop multi-seller orders"), "pct"),
        ("rb_nowave", "Execution share, wave months dropped", RB, "variant_value", test("Execution share: drop the three wave months"), "pct"),
        ("rb_simple_p50", "Late orders with promise below lane median", RB, "variant_value", test("Late orders with promise below lane median total"), "pct"),
        ("rb_simple_p75", "Late orders with promise below lane P75", RB, "variant_value", test("Late orders with promise below lane P75 total"), "pct"),
        ("rb_top10", "Worst-10 sellers in common, min 30 vs min 100", RB, "variant_value", test("Worst-10 sellers: min 30 vs min 100 orders"), "int"),
        ("rb_defect", "Defect rate, reviewed orders only", RB, "variant_value", test("Defect rate: reviewed orders only as denominator"), "pct"),
        ("rb_review", "Share of low reviews on-time, earliest review used", RB, "variant_value", test("Share of low reviews on on-time orders: earliest review instead of latest"), "pct"),
        ("two_way_a", "Breach rate, method A (fact table)", TW, "method_a_fact_filter", None, "pct"),
        ("two_way_b", "Breach rate, method B (raw EXCEPT)", TW, "method_b_raw_except", None, "pct"),
    ]),
    ("Dashboard tile check values (Jan 2017 to Aug 2018, no filters)", [
        ("dash_orders", "Tile: orders", "dash_fact", "SUM(orders)", None, "int"),
        ("dash_delivered", "Delivered in the dashboard window", "dash_fact", "SUM(delivered)", None, "int"),
        ("dash_late", "Late in the dashboard window", "dash_fact", "SUM(late)", None, "int"),
        ("dash_accuracy", "Tile: promise accuracy", "dash_fact", "1 - SUM(late) * 1.0 / SUM(delivered)", None, "pct"),
        ("dash_mean_days", "Tile: average delivery days", "dash_fact", "SUM(sum_delivery_days) / SUM(delivered)", None, "d1"),
        ("dash_defect", "Tile: defect proxy", "dash_fact", "SUM(defects) * 1.0 / SUM(orders)", None, "pct"),
        ("dash_rows", "Rows in dash_fact", "dash_fact", "COUNT(*)", None, "int"),
    ]),
    ("Pilot inputs", [
        ("pilot_nonwave", "RJ+BA+ES non-wave breach baseline", PS, "non_wave_breach_rate", "segment = 'Customers in RJ, BA, ES'", "pct"),
        ("pilot_volume", "RJ+BA+ES delivered per month, Apr-Aug 2018", PS, "recent_orders_per_month", "segment = 'Customers in RJ, BA, ES'", "int"),
        ("pilot_target", "RJ+BA+ES target rate at 33% reduction", PZ, "target_rate", size("Customers in RJ, BA, ES", 0.33), "pct"),
        ("pilot_n", "RJ+BA+ES orders per arm at 33% reduction", PZ, "n_per_arm", size("Customers in RJ, BA, ES", 0.33), "int"),
        ("pilot_total", "RJ+BA+ES orders in total at 33% reduction", PZ, "n_per_arm * 2", size("Customers in RJ, BA, ES", 0.33), "int"),
        ("pilot_months", "RJ+BA+ES months needed at 33% reduction", PZ, "months_needed", size("Customers in RJ, BA, ES", 0.33), "d1"),
        ("pilot_n25", "RJ+BA+ES orders per arm at 25% reduction", PZ, "n_per_arm", size("Customers in RJ, BA, ES", 0.25), "int"),
        ("pilot_months25", "RJ+BA+ES months needed at 25% reduction", PZ, "months_needed", size("Customers in RJ, BA, ES", 0.25), "d1"),
        ("pilot_rj_volume", "RJ delivered per month, Apr-Aug 2018", PS, "recent_orders_per_month", "segment = 'Customers in RJ'", "int"),
        ("pilot_rj_base", "RJ non-wave breach baseline", PS, "non_wave_breach_rate", "segment = 'Customers in RJ'", "pct"),
        ("pilot_rj_months", "RJ months needed at 33% reduction", PZ, "months_needed", size("Customers in RJ", 0.33), "d1"),
        ("pilot_al_volume", "AL delivered per month, Apr-Aug 2018", PS, "recent_orders_per_month", "segment = 'Customers in AL'", "int"),
        ("pilot_al_months", "AL months needed at 33% reduction", PZ, "months_needed", size("Customers in AL", 0.33), "d1"),
        ("sop_sellers", "Scored sellers missing dispatch on 20%+ of orders", SOP, "sellers_miss_20pct", None, "int"),
        ("sop_orders", "Orders of those sellers", SOP, "orders_of_those_sellers", None, "int"),
        ("sop_breach", "Breach rate of those sellers", SOP, "breach_rate_those", None, "pct"),
        ("sop_others", "Breach rate of other scored sellers", SOP, "breach_rate_others", None, "pct"),
    ]),
]


def fetch(table, column, where):
    sql = f"SELECT {column} FROM {table}" + (f" WHERE {where}" if where else "")
    rows = con.sql(sql).fetchall()
    if len(rows) != 1 or rows[0][0] is None:
        raise ValueError(f"Expected one value from: {sql} -> {rows[:3]}")
    return float(rows[0][0])


def main():
    today = dt.date.today().isoformat()
    out = [
        "# Results",
        "",
        "Generated by `scripts/build_results.py`; do not edit by hand. Every value below is read from "
        "the table named in its row, built from the raw CSVs by `bash run_all.sh`.",
        "",
        f"**Command:** `bash run_all.sh`  |  **Run date:** {today}",
        "",
        "Money is in Brazilian reais (R$). Rates are shares of the population in the label.",
    ]
    values = {}
    for heading, rows in SECTIONS:
        out += ["", f"## {heading}", "", "| Key | Metric | Value | Source table | File:line |", "|---|---|---|---|---|"]
        for key, label, table, column, where, fmt in rows:
            value = fetch(table, column, where)
            shown = FORMATS[fmt](value)
            if key in values:
                raise ValueError(f"Duplicate key {key}")
            values[key] = {"value": value, "shown": shown, "label": label}
            out.append(f"| {key} | {label} | {shown} | {table} | {locate(table)} |")

    (ROOT / "docs").mkdir(exist_ok=True)
    (ROOT / "docs" / "RESULTS.md").write_text("\n".join(out) + "\n", encoding="utf-8")
    (ROOT / "outputs" / "results.json").write_text(json.dumps(values, indent=1), encoding="utf-8")
    print(f"Wrote {len(values)} results to docs/RESULTS.md")


if __name__ == "__main__":
    main()
